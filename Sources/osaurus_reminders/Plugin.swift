import AppKit
import EventKit
import Foundation
import OsaurusPluginABI
import OsaurusPluginKit

// MARK: - Helpers

/// Escapes a string for safe interpolation inside an AppleScript double-quoted literal.
func escapeAppleScriptString(_ s: String) -> String {
  var out = ""
  out.reserveCapacity(s.count + 2)
  for ch in s {
    switch ch {
    case "\\": out += "\\\\"
    case "\"": out += "\\\""
    case "\n": out += "\\n"
    case "\r": out += "\\r"
    case "\t": out += "\\t"
    default: out.append(ch)
    }
  }
  return out
}

// MARK: - Models

struct ReminderDTO: Encodable {
  let id: String
  let title: String
  let notes: String?
  let dueDate: String?
  let isCompleted: Bool
  let priority: Int
  let list: String
  let creationDate: String?
  let modificationDate: String?

  init(from reminder: EKReminder) {
    self.id = reminder.calendarItemIdentifier
    self.title = reminder.title
    self.notes = reminder.notes
    self.isCompleted = reminder.isCompleted
    self.priority = reminder.priority
    self.list = reminder.calendar.title

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime]

    if let dueComponents = reminder.dueDateComponents,
      let date = Calendar.current.date(from: dueComponents)
    {
      self.dueDate = isoFormatter.string(from: date)
    } else {
      self.dueDate = nil
    }

    if let created = reminder.creationDate {
      self.creationDate = isoFormatter.string(from: created)
    } else {
      self.creationDate = nil
    }

    if let modified = reminder.lastModifiedDate {
      self.modificationDate = isoFormatter.string(from: modified)
    } else {
      self.modificationDate = nil
    }
  }
}

struct ReminderListDTO: Encodable {
  let id: String
  let title: String
  let color: String?  // Hex representation if possible, or just skip

  init(from calendar: EKCalendar) {
    self.id = calendar.calendarIdentifier
    self.title = calendar.title
    // Basic hex conversion could go here, skipping for brevity
    self.color = nil
  }
}

// MARK: - Manager

enum ReminderAccess {
  case granted
  case denied
  case timedOut
}

/// Returns a failure envelope for non-granted access, or nil when granted.
func remindersAccessFailure(_ access: ReminderAccess) -> String? {
  switch access {
  case .granted:
    return nil
  case .denied:
    return Envelope.failure(
      .permissionDenied,
      "Access to Reminders denied. Please enable in System Settings > Privacy & Security > Reminders.")
  case .timedOut:
    return Envelope.failure(.timeout, "Timed out waiting for Reminders permission")
  }
}

class ReminderManager {
  static let shared = ReminderManager()
  let store = EKEventStore()

  private init() {}

  func checkAccess() -> Bool {
    let status = EKEventStore.authorizationStatus(for: .reminder)
    if #available(macOS 14.0, *) {
      return status == .fullAccess || status == .authorized
    }
    return status == .authorized
  }

  // Attempt to request access if not determined
  // Note: Requesting access is async, but we might be in a sync context.
  // The blocking wait is deadline-bounded so a stuck permission prompt cannot
  // hang the host indefinitely, and a timeout is distinguishable from denial.
  func ensureAccess() -> ReminderAccess {
    if checkAccess() { return .granted }

    let status = EKEventStore.authorizationStatus(for: .reminder)
    guard status == .notDetermined else { return .denied }

    let sema = DispatchSemaphore(value: 0)
    var granted = false

    if #available(macOS 14.0, *) {
      store.requestFullAccessToReminders { success, _ in
        granted = success
        sema.signal()
      }
    } else {
      store.requestAccess(to: .reminder) { success, _ in
        granted = success
        sema.signal()
      }
    }

    if sema.wait(timeout: .now() + 20) == .timedOut {
      return .timedOut
    }
    return granted ? .granted : .denied
  }

  func getLists() -> [EKCalendar] {
    return store.calendars(for: .reminder)
  }

  /// Fetches reminders matching the predicate. Returns nil on timeout so
  /// callers can report a timeout instead of a misleading empty result.
  func fetchReminders(predicate: NSPredicate, timeout: TimeInterval = 30) -> [EKReminder]? {
    let sema = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var results: [EKReminder]?

    store.fetchReminders(matching: predicate) { reminders in
      lock.lock()
      results = reminders ?? []
      lock.unlock()
      sema.signal()
    }

    if sema.wait(timeout: .now() + timeout) == .timedOut {
      return nil
    }
    lock.lock()
    defer { lock.unlock() }
    return results
  }
}

// MARK: - Tools

protocol Tool {
  var name: String { get }
  var description: String { get }
  var parameters: String { get }
  var requirements: [String] { get }
  var permissionPolicy: String { get }
  /// opt-in flag: when true, this tool appears in the dashboard's add-widget picker
  var widget: Bool { get }
  func run(args: String) -> String
}

extension Tool {
  var requirements: [String] { [] }
  var permissionPolicy: String { "ask" }
  var widget: Bool { false }
}

// 1. Get Reminders
struct GetRemindersTool: Tool {
  let name = "get_reminders"
  let widget = true
  let description = "Get reminders, optionally filtering by list, status, or date range."
  let requirements = ["reminders"]
  let parameters = """
    {
        "type": "object",
        "properties": {
            "listName": { "type": "string", "description": "Name of the list to fetch from" },
            "status": { "type": "string", "enum": ["incomplete", "completed", "all"], "description": "Filter by status (default: incomplete)" },
            "limit": { "type": "integer", "description": "Max number of reminders to return (default: 50)" },
            "dueAfter": { "type": "string", "description": "ISO date string to filter reminders due after this date" },
            "dueBefore": { "type": "string", "description": "ISO date string to filter reminders due before this date" }
        }
    }
    """

  func run(args: String) -> String {
    struct Args: Decodable {
      let listName: String?
      let status: String?
      let limit: Int?
      let dueAfter: String?
      let dueBefore: String?
    }

    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else { return Envelope.failure(.invalidArgs, "Invalid arguments") }

    guard let status = Validation.parseStatus(input.status) else {
      return Envelope.failure(
        .invalidArgs,
        "status must be one of 'incomplete', 'completed', 'all', got '\(input.status ?? "")'")
    }

    let limit: Int
    switch Validation.resolveLimit(input.limit, default: 50) {
    case .ok(let value): limit = value
    case .invalid(let message): return Envelope.failure(.invalidArgs, message)
    }

    var start: Date? = nil
    if let dueAfter = input.dueAfter {
      guard let parsed = Validation.parseISODate(dueAfter) else {
        return Envelope.failure(.invalidArgs, "Invalid date for field 'dueAfter': \(dueAfter)")
      }
      start = parsed
    }

    var end: Date? = nil
    if let dueBefore = input.dueBefore {
      guard let parsed = Validation.parseISODate(dueBefore) else {
        return Envelope.failure(.invalidArgs, "Invalid date for field 'dueBefore': \(dueBefore)")
      }
      end = parsed
    }

    if let listName = input.listName,
      listName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return Envelope.failure(.invalidArgs, "listName must not be empty.")
    }

    if let failure = remindersAccessFailure(ReminderManager.shared.ensureAccess()) {
      return failure
    }

    let store = ReminderManager.shared.store
    var calendars: [EKCalendar]? = nil

    if let listName = input.listName {
      let all = ReminderManager.shared.getLists()
      if let match = all.first(where: { $0.title.caseInsensitiveCompare(listName) == .orderedSame })
      {
        calendars = [match]
      } else {
        return Envelope.failure(.notFound, "List '\(listName)' not found.")
      }
    }

    // Predicate construction: incomplete reminders can be constrained by due
    // date natively. predicateForCompletedReminders only constrains the
    // COMPLETION date, so completed reminders are fetched unconstrained and
    // filtered by DUE date in memory (matching the parameter names).
    func fetchIncomplete() -> [EKReminder]? {
      let p = store.predicateForIncompleteReminders(
        withDueDateStarting: start, ending: end, calendars: calendars)
      return ReminderManager.shared.fetchReminders(predicate: p)
    }

    func fetchCompleted() -> [EKReminder]? {
      let p = store.predicateForCompletedReminders(
        withCompletionDateStarting: nil, ending: nil, calendars: calendars)
      guard let fetched = ReminderManager.shared.fetchReminders(predicate: p) else { return nil }
      return fetched.filter {
        Validation.dueDateInRange($0.dueDateComponents?.date, after: start, before: end)
      }
    }

    var reminders: [EKReminder]

    switch status {
    case .incomplete:
      guard let fetched = fetchIncomplete() else {
        return Envelope.failure(.timeout, "Reminders query timed out")
      }
      reminders = fetched
    case .completed:
      guard let fetched = fetchCompleted() else {
        return Envelope.failure(.timeout, "Reminders query timed out")
      }
      reminders = fetched
    case .all:
      guard let incomplete = fetchIncomplete(), let completed = fetchCompleted() else {
        return Envelope.failure(.timeout, "Reminders query timed out")
      }
      reminders = incomplete + completed
    }

    reminders.sort {
      let d1 = $0.dueDateComponents?.date ?? $0.creationDate ?? Date.distantPast
      let d2 = $1.dueDateComponents?.date ?? $1.creationDate ?? Date.distantPast
      return d1 < d2
    }

    let limited = Array(reminders.prefix(limit))

    let dtos = limited.map { ReminderDTO(from: $0) }
    guard let json = try? JSONEncoder().encode(dtos) else {
      return Envelope.failure(.executionError, "Encoding failed")
    }
    return String(data: json, encoding: .utf8) ?? "{}"
  }
}

// 2. Search Reminders
struct SearchRemindersTool: Tool {
  let name = "search_reminders"
  let description =
    "Search reminders by title or notes. Searches all incomplete reminders plus reminders completed within the last 30 days."
  let requirements = ["reminders"]
  let parameters = """
    {
        "type": "object",
        "properties": {
            "searchText": { "type": "string" },
            "limit": { "type": "integer" }
        },
        "required": ["searchText"]
    }
    """

  func run(args: String) -> String {
    struct Args: Decodable {
      let searchText: String
      let limit: Int?
    }
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return Envelope.failure(.invalidArgs, "Invalid arguments")
    }

    guard !input.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return Envelope.failure(.invalidArgs, "searchText must not be empty.")
    }

    let limit: Int
    switch Validation.resolveLimit(input.limit, default: 20) {
    case .ok(let value): limit = value
    case .invalid(let message): return Envelope.failure(.invalidArgs, message)
    }

    if let failure = remindersAccessFailure(ReminderManager.shared.ensureAccess()) {
      return failure
    }

    // We fetch all incomplete (and maybe recent completed?) and filter in memory since
    // there is no text search predicate in EventKit.
    let store = ReminderManager.shared.store
    let p1 = store.predicateForIncompleteReminders(
      withDueDateStarting: nil, ending: nil, calendars: nil)

    // NOTE: Searching ALL reminders (including completed history) can be slow.
    // We'll search incomplete reminders and the last 30 days of completed ones
    // (as documented in the tool description).
    let oneMonthAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())
    let p2 = store.predicateForCompletedReminders(
      withCompletionDateStarting: oneMonthAgo, ending: nil, calendars: nil)

    guard var all = ReminderManager.shared.fetchReminders(predicate: p1),
      let completed = ReminderManager.shared.fetchReminders(predicate: p2)
    else {
      return Envelope.failure(.timeout, "Reminders query timed out")
    }
    all.append(contentsOf: completed)

    let query = input.searchText.lowercased()
    let filtered = all.filter {
      ($0.title?.lowercased().contains(query) ?? false)
        || ($0.notes?.lowercased().contains(query) ?? false)
    }

    let limited = Array(filtered.prefix(limit))

    let dtos = limited.map { ReminderDTO(from: $0) }
    guard let json = try? JSONEncoder().encode(dtos) else {
      return Envelope.failure(.executionError, "Encoding failed")
    }
    return String(data: json, encoding: .utf8) ?? "{}"
  }
}

// 3. Create Reminder
struct CreateReminderTool: Tool {
  let name = "create_reminder"
  let description = "Create a new reminder."
  let requirements = ["reminders"]
  let parameters = """
    {
        "type": "object",
        "properties": {
            "title": { "type": "string" },
            "notes": { "type": "string" },
            "listName": { "type": "string" },
            "dueDate": { "type": "string", "description": "ISO date string; a notification alarm fires at this time" },
            "priority": { "type": "integer", "description": "1-9 (1 is highest, 5 is medium, 9 is low)" }
        },
        "required": ["title"]
    }
    """

  func run(args: String) -> String {
    struct Args: Decodable {
      let title: String
      let notes: String?
      let listName: String?
      let dueDate: String?
      let priority: Int?
    }

    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return Envelope.failure(.invalidArgs, "Invalid arguments")
    }

    guard !input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return Envelope.failure(.invalidArgs, "title must not be empty.")
    }

    if let message = Validation.priorityError(input.priority) {
      return Envelope.failure(.invalidArgs, message)
    }

    if let listName = input.listName,
      listName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return Envelope.failure(.invalidArgs, "listName must not be empty.")
    }

    var dueComponents: DateComponents? = nil
    if let dueStr = input.dueDate {
      guard let date = Validation.parseISODate(dueStr) else {
        return Envelope.failure(
          .invalidArgs,
          "Invalid date for field 'dueDate': \(dueStr). Use ISO format (YYYY-MM-DDTHH:mm:ssZ)")
      }
      dueComponents = Calendar.current.dateComponents(
        [.year, .month, .day, .hour, .minute, .second], from: date)
    }

    if let failure = remindersAccessFailure(ReminderManager.shared.ensureAccess()) {
      return failure
    }

    let store = ReminderManager.shared.store
    let reminder = EKReminder(eventStore: store)

    reminder.title = input.title
    reminder.notes = input.notes

    if let priority = input.priority {
      reminder.priority = priority
    }

    if let dueComponents {
      reminder.dueDateComponents = dueComponents
      // A due date alone is only metadata; macOS fires a notification for a
      // reminder only when it has an alarm, so mirror what Reminders.app does
      // for "remind me at" and attach an absolute alarm at the due date.
      if let alarmDate = Calendar.current.date(from: dueComponents) {
        reminder.addAlarm(EKAlarm(absoluteDate: alarmDate))
      }
    }

    // Handle List
    if let listName = input.listName {
      if let list = ReminderManager.shared.getLists().first(where: {
        $0.title.caseInsensitiveCompare(listName) == .orderedSame
      }) {
        reminder.calendar = list
      } else {
        return Envelope.failure(.notFound, "List '\(listName)' not found.")
      }
    } else {
      reminder.calendar = store.defaultCalendarForNewReminders()
    }

    do {
      try store.save(reminder, commit: true)
      return
        "{\"success\": true, \"id\": \"\(reminder.calendarItemIdentifier)\", \"message\": \"Reminder created\"}"
    } catch {
      return Envelope.failure(
        .executionError, "Failed to save reminder: \(error.localizedDescription)")
    }
  }
}

// 4. Get Lists
struct GetListsTool: Tool {
  let name = "get_lists"
  let widget = true
  let description = "Get all reminder lists."
  let requirements = ["reminders"]
  let parameters = "{ \"type\": \"object\", \"properties\": {} }"

  func run(args: String) -> String {
    if let failure = remindersAccessFailure(ReminderManager.shared.ensureAccess()) {
      return failure
    }

    let lists = ReminderManager.shared.getLists()
    let dtos = lists.map { ReminderListDTO(from: $0) }

    guard let json = try? JSONEncoder().encode(dtos) else {
      return Envelope.failure(.executionError, "Encoding failed")
    }
    return String(data: json, encoding: .utf8) ?? "{}"
  }
}

// 5. Open Reminder
struct OpenReminderTool: Tool {
  let name = "open_reminder"
  let description = "Open the Reminders app, optionally to a specific reminder."
  let requirements = ["automation"]
  let parameters = """
    {
        "type": "object",
        "properties": {
            "id": { "type": "string", "description": "The ID of the reminder to open" }
        }
    }
    """

  func run(args: String) -> String {
    struct Args: Decodable {
      let id: String?
    }

    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return Envelope.failure(.invalidArgs, "Invalid arguments")
    }

    // Use AppleScript to activate and show
    // Note: 'show reminder id "..."' works if the ID matches what Reminders expects.
    // EventKit ID: "x-apple-reminder://..." (UUID)
    // AppleScript ID often matches UUID.

    var scriptSource = "tell application \"Reminders\" to activate"

    if let id = input.id {
      guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return Envelope.failure(.invalidArgs, "id must not be empty.")
      }
      // Try to show specific reminder.
      // Note: AppleScript 'id' lookup usually needs the clean UUID or the full ID string.
      // Escape the user-supplied id to avoid breaking out of the AppleScript string literal.
      let safeId = escapeAppleScriptString(id)
      scriptSource = """
        tell application "Reminders"
            activate
            try
                show (first reminder whose id is "\(safeId)")
            on error
                -- Fallback or ignore if not found
            end try
        end tell
        """
    }

    var error: NSDictionary?
    if let script = NSAppleScript(source: scriptSource) {
      script.executeAndReturnError(&error)
      if let err = error {
        return Envelope.failure(.executionError, "AppleScript error: \(err)")
      }
      return "{\"success\": true, \"message\": \"Reminders app opened\"}"
    }

    return Envelope.failure(.executionError, "Failed to create AppleScript")
  }
}

// MARK: - C ABI

/// Canonical, ordered list of tools exposed by this plugin.
let remindersTools: [Tool] = [
  GetRemindersTool(),
  SearchRemindersTool(),
  CreateReminderTool(),
  GetListsTool(),
  OpenReminderTool(),
]

/// File-scope manifest JSON, extracted from the host callback so it can be unit tested.
let remindersManifestJSON: String = {
  let toolsJson = remindersTools.map { tool -> String in
    let reqs = tool.requirements.map { "\"\($0)\"" }.joined(separator: ",")
    let widgetField = tool.widget ? "\"widget\": true," : ""
    return """
      {
          "id": "\(tool.name)",
          \(widgetField)
          "description": "\(Envelope.escape(tool.description))",
          "parameters": \(tool.parameters),
          "requirements": [\(reqs)],
          "permission_policy": "\(tool.permissionPolicy)"
      }
      """
  }.joined(separator: ",")

  return """
    {
      "plugin_id": "osaurus.reminders",
      "name": "Reminders",
      "version": "1.1.1",
      "description": "An Osaurus plugin for interacting with macOS Reminders via EventKit.",
      "license": "MIT",
      "authors": ["Osaurus"],
      "min_macos": "13.0",
      "min_osaurus": "0.5.0",
      "capabilities": {
        "tools": [\(toolsJson)]
      }
    }
    """
}()

private class PluginContext {
  let tools: [String: Tool] = Dictionary(
    uniqueKeysWithValues: remindersTools.map { ($0.name, $0) })
}

private var pluginAPI = PluginEntry.makeAPI(
  version: OsrABIVersion.v2,
  init: {
    Unmanaged.passRetained(PluginContext()).toOpaque()
  },
  destroy: { ctxPtr in
    guard let ctxPtr = ctxPtr else { return }
    Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
  },
  getManifest: { ctxPtr in
    guard ctxPtr != nil else { return nil }
    return osrMakeCString(remindersManifestJSON)
  },
  invoke: { ctxPtr, typePtr, idPtr, payloadPtr in
    guard let ctxPtr = ctxPtr,
      let typePtr = typePtr,
      let idPtr = idPtr,
      let payloadPtr = payloadPtr
    else { return nil }

    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let type = String(cString: typePtr)
    let id = String(cString: idPtr)
    let payload = String(cString: payloadPtr)

    if type == "tool", let tool = ctx.tools[id] {
      let result = tool.run(args: payload)
      return osrMakeCString(result)
    }

    return osrMakeCString(Envelope.failure(.notFound, "Unknown capability or tool '\(id)'"))
  }
)

@_cdecl("osaurus_plugin_entry_v2")
public func osaurus_plugin_entry_v2(_ host: UnsafeRawPointer?) -> UnsafeRawPointer? {
  PluginEntry.enterV2(host, api: &pluginAPI)
}

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  PluginEntry.enterV1(api: &pluginAPI)
}
