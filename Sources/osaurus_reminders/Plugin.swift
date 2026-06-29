import AppKit
import EventKit
import Foundation

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
  // Ideally the host app handles this, but we can try blocking wait.
  func ensureAccess() -> Bool {
    if checkAccess() { return true }

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

    _ = sema.wait(timeout: .now() + 20)  // Wait up to 20s
    return granted
  }

  func getLists() -> [EKCalendar] {
    return store.calendars(for: .reminder)
  }

  func fetchReminders(predicate: NSPredicate) -> [EKReminder] {
    let sema = DispatchSemaphore(value: 0)
    var results: [EKReminder] = []

    store.fetchReminders(matching: predicate) { reminders in
      results = reminders ?? []
      sema.signal()
    }

    _ = sema.wait(timeout: .now() + 30)
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
    guard ReminderManager.shared.ensureAccess() else {
      return Envelope.failure(
        .unavailable, "Access to Reminders denied. Please enable in System Settings.",
        retryable: false)
    }

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

    let store = ReminderManager.shared.store
    var calendars: [EKCalendar]? = nil

    if let listName = input.listName {
      guard !listName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return Envelope.failure(.invalidArgs, "listName must not be empty.")
      }
      let all = ReminderManager.shared.getLists()
      if let match = all.first(where: { $0.title.caseInsensitiveCompare(listName) == .orderedSame })
      {
        calendars = [match]
      } else {
        return Envelope.failure(.notFound, "List '\(listName)' not found.")
      }
    }

    // Predicate construction
    // EKEventStore.predicateForReminders(in: calendars) returns all incomplete
    // To get completed, we must use fetchReminders directly or filter manually?
    // Actually predicateForReminders(in:) gets *incomplete* reminders by default in documentation?
    // Wait, predicateForReminders(in:) returns a predicate for *all* reminders if no completion status is specified?
    // Documentation says "Creates a predicate for fetching reminders."
    // We usually use predicateForIncompleteReminders(...) or predicateForCompletedReminders(...)
    // But those methods are: predicateForIncompleteReminders(withDueDateStarting:ending:calendars:)
    // and predicateForCompletedReminders(withCompletionDateStarting:ending:calendars:)

    let status = input.status ?? "incomplete"
    var predicate: NSPredicate

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    // Fallback for non-fractional
    let isoFormatter2 = ISO8601DateFormatter()
    isoFormatter2.formatOptions = [.withInternetDateTime]

    func parse(_ s: String) -> Date? {
      return isoFormatter.date(from: s) ?? isoFormatter2.date(from: s)
    }

    let start = input.dueAfter.flatMap(parse)
    let end = input.dueBefore.flatMap(parse)

    if status == "incomplete" {
      predicate = store.predicateForIncompleteReminders(
        withDueDateStarting: start, ending: end, calendars: calendars)
    } else if status == "completed" {
      // "completed" usually filters by completion date, but here we might want due date?
      // predicateForCompletedReminders uses completion date range.
      predicate = store.predicateForCompletedReminders(
        withCompletionDateStarting: start, ending: end, calendars: calendars)
    } else {
      // "all" - this is harder with predicates. Usually we have to fetch both or construct a custom predicate?
      // EKEventStore predicates are opaque. We cannot OR them easily.
      // We'll fetch incomplete, and if requested "all", we might need another fetch?
      // For simplicity, let's just support incomplete/completed. If "all", we might just return incomplete for now or fetch both.
      // Let's fetch both if "all"
      let p1 = store.predicateForIncompleteReminders(
        withDueDateStarting: start, ending: end, calendars: calendars)
      let p2 = store.predicateForCompletedReminders(
        withCompletionDateStarting: start, ending: end, calendars: calendars)

      var allReminders = ReminderManager.shared.fetchReminders(predicate: p1)
      allReminders.append(contentsOf: ReminderManager.shared.fetchReminders(predicate: p2))

      // Sort and limit
      allReminders.sort { ($0.creationDate ?? Date()) > ($1.creationDate ?? Date()) }
      let limit = input.limit ?? 50
      let limited = Array(allReminders.prefix(limit))

      let dtos = limited.map { ReminderDTO(from: $0) }
      guard let json = try? JSONEncoder().encode(dtos) else {
        return Envelope.failure(.executionError, "Encoding failed")
      }
      return String(data: json, encoding: .utf8) ?? "{}"
    }

    // Single predicate path
    var reminders = ReminderManager.shared.fetchReminders(predicate: predicate)

    // Sort (by due date? creation?)
    reminders.sort {
      let d1 = $0.dueDateComponents?.date ?? $0.creationDate ?? Date.distantPast
      let d2 = $1.dueDateComponents?.date ?? $1.creationDate ?? Date.distantPast
      return d1 < d2
    }

    let limit = input.limit ?? 50
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
  let description = "Search reminders by title or notes."
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
    guard ReminderManager.shared.ensureAccess() else {
      return Envelope.failure(.unavailable, "Access to Reminders denied.", retryable: false)
    }

    struct Args: Decodable {
      let searchText: String
      let limit: Int?
    }
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return Envelope.failure(.invalidArgs, "Invalid arguments")
    }

    // We fetch all incomplete (and maybe recent completed?) and filter in memory since
    // there is no text search predicate in EventKit.
    let store = ReminderManager.shared.store
    let p1 = store.predicateForIncompleteReminders(
      withDueDateStarting: nil, ending: nil, calendars: nil)

    // NOTE: Searching ALL reminders (including completed history) can be slow.
    // We'll search incomplete reminders and maybe last 30 days of completed?
    let oneMonthAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())
    let p2 = store.predicateForCompletedReminders(
      withCompletionDateStarting: oneMonthAgo, ending: nil, calendars: nil)

    var all = ReminderManager.shared.fetchReminders(predicate: p1)
    all.append(contentsOf: ReminderManager.shared.fetchReminders(predicate: p2))

    let query = input.searchText.lowercased()
    let filtered = all.filter {
      ($0.title?.lowercased().contains(query) ?? false)
        || ($0.notes?.lowercased().contains(query) ?? false)
    }

    let limit = input.limit ?? 20
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
            "dueDate": { "type": "string", "description": "ISO date string" },
            "priority": { "type": "integer", "description": "1-9 (1 is highest, 5 is medium, 9 is low)" }
        },
        "required": ["title"]
    }
    """

  func run(args: String) -> String {
    guard ReminderManager.shared.ensureAccess() else {
      return Envelope.failure(.unavailable, "Access to Reminders denied.", retryable: false)
    }

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

    let store = ReminderManager.shared.store
    let reminder = EKReminder(eventStore: store)

    reminder.title = input.title
    reminder.notes = input.notes

    if let priority = input.priority {
      reminder.priority = priority
    }

    // Handle List
    if let listName = input.listName {
      guard !listName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return Envelope.failure(.invalidArgs, "listName must not be empty.")
      }
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

    // Handle Due Date
    if let dueStr = input.dueDate {
      let isoFormatter = ISO8601DateFormatter()
      isoFormatter.formatOptions = [.withInternetDateTime]
      if let date = isoFormatter.date(from: dueStr) {
        let components = Calendar.current.dateComponents(
          [.year, .month, .day, .hour, .minute, .second], from: date)
        reminder.dueDateComponents = components
      } else {
        // Try fallback format (without time?)
        // Or simply warn.
      }
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
    guard ReminderManager.shared.ensureAccess() else {
      return Envelope.failure(.unavailable, "Access to Reminders denied.", retryable: false)
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

private typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
private typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
private typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?
private typealias osr_invoke_t =
  @convention(c) (
    osr_plugin_ctx_t?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?
  ) -> UnsafePointer<CChar>?

private typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

private struct osr_plugin_api {
  var free_string: osr_free_string_t?
  var `init`: osr_init_t?
  var destroy: osr_destroy_t?
  var get_manifest: osr_get_manifest_t?
  var invoke: osr_invoke_t?
}

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

private func makeCString(_ s: String) -> UnsafePointer<CChar>? {
  guard let ptr = strdup(s) else { return nil }
  return UnsafePointer(ptr)
}

private var api: osr_plugin_api = {
  var api = osr_plugin_api()

  api.free_string = { ptr in
    if let p = ptr { free(UnsafeMutableRawPointer(mutating: p)) }
  }

  api.`init` = {
    let ctx = PluginContext()
    return Unmanaged.passRetained(ctx).toOpaque()
  }

  api.destroy = { ctxPtr in
    guard let ctxPtr = ctxPtr else { return }
    Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
  }

  api.get_manifest = { ctxPtr in
    guard ctxPtr != nil else { return nil }
    return makeCString(remindersManifestJSON)
  }

  api.invoke = { ctxPtr, typePtr, idPtr, payloadPtr in
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
      return makeCString(result)
    }

    return makeCString(Envelope.failure(.notFound, "Unknown capability or tool '\(id)'"))
  }

  return api
}()

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  return UnsafeRawPointer(&api)
}
