import AppKit
import EventKit
import Foundation
import OsaurusPluginABI
import OsaurusPluginKit

// MARK: - JSON models

private func rfc3339(_ date: Date?) -> String? {
  guard let date else { return nil }
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: date)
}

private func date(from components: DateComponents?) -> Date? {
  guard let components else { return nil }
  if let calendar = components.calendar {
    return calendar.date(from: components)
  }
  return Calendar.current.date(from: components)
}

private func reminderSort(_ lhs: EKReminder, _ rhs: EKReminder) -> Bool {
  let left = date(from: lhs.dueDateComponents) ?? lhs.creationDate
  let right = date(from: rhs.dueDateComponents) ?? rhs.creationDate
  switch (left, right) {
  case let (left?, right?):
    if left != right { return left < right }
  case (_?, nil):
    return true
  case (nil, _?):
    return false
  case (nil, nil):
    break
  }
  return lhs.calendarItemIdentifier < rhs.calendarItemIdentifier
}

private func sourceTypeName(_ type: EKSourceType) -> String {
  switch type {
  case .local: return "local"
  case .exchange: return "exchange"
  case .calDAV: return "caldav"
  case .mobileMe: return "mobile_me"
  case .subscribed: return "subscribed"
  case .birthdays: return "birthdays"
  @unknown default: return "unknown"
  }
}

private func colorHex(_ calendar: EKCalendar) -> String? {
  guard let cgColor = calendar.cgColor,
    let color = NSColor(cgColor: cgColor)?.usingColorSpace(.deviceRGB)
  else {
    return nil
  }
  let red = Int((color.redComponent * 255).rounded())
  let green = Int((color.greenComponent * 255).rounded())
  let blue = Int((color.blueComponent * 255).rounded())
  return String(format: "#%02X%02X%02X", red, green, blue)
}

struct ReminderListDTO: Encodable {
  let id: String
  let title: String
  let color_hex: String?
  let account_id: String
  let account_name: String
  let account_type: String
  let is_writable: Bool
  let is_default: Bool

  init(from calendar: EKCalendar, defaultListID: String?) {
    id = calendar.calendarIdentifier
    title = calendar.title
    color_hex = colorHex(calendar)
    account_id = calendar.source.sourceIdentifier
    account_name = calendar.source.title
    account_type = sourceTypeName(calendar.source.sourceType)
    is_writable = calendar.allowsContentModifications && !calendar.isImmutable
    is_default = calendar.calendarIdentifier == defaultListID
  }
}

struct ReminderAlarmDTO: Encodable {
  let absolute_at: String?
  let relative_offset_seconds: Double?

  init(from alarm: EKAlarm) {
    absolute_at = rfc3339(alarm.absoluteDate)
    relative_offset_seconds = alarm.absoluteDate == nil ? alarm.relativeOffset : nil
  }
}

struct ReminderDTO: Encodable {
  let id: String
  let title: String
  let notes: String?
  let due_at: String?
  let is_completed: Bool
  let completed_at: String?
  let priority: Int
  let list_id: String
  let list_title: String
  let created_at: String?
  let modified_at: String?
  let alarms: [ReminderAlarmDTO]

  init(from reminder: EKReminder) {
    id = reminder.calendarItemIdentifier
    title = reminder.title ?? ""
    notes = reminder.notes
    due_at = rfc3339(date(from: reminder.dueDateComponents))
    is_completed = reminder.isCompleted
    completed_at = rfc3339(reminder.completionDate)
    priority = reminder.priority
    list_id = reminder.calendar.calendarIdentifier
    list_title = reminder.calendar.title
    created_at = rfc3339(reminder.creationDate)
    modified_at = rfc3339(reminder.lastModifiedDate)
    alarms = (reminder.alarms ?? []).map(ReminderAlarmDTO.init)
  }
}

private struct ReminderListCollectionDTO: Encodable {
  let lists: [ReminderListDTO]
  let returned_count: Int
  let total_count: Int
  let limit: Int
  let has_more: Bool
}

private struct ReminderCollectionDTO: Encodable {
  let reminders: [ReminderDTO]
  let returned_count: Int
  let total_count: Int
  let limit: Int
  let has_more: Bool
}

private struct OpenReminderResultDTO: Encodable {
  let opened: Bool
  let reminder: ReminderDTO
}

private func encodedJSON<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  let data = try encoder.encode(value)
  guard let json = String(data: data, encoding: .utf8) else {
    throw EnvelopeFailure(.executionError, "Failed to encode tool result")
  }
  return json
}

private func success<T: Encodable>(tool: String, result: T) -> String {
  do {
    return Envelope.success(tool: tool, rawResult: try encodedJSON(result))
  } catch let failure as EnvelopeFailure {
    return render(failure, tool: tool)
  } catch {
    return Envelope.failure(
      .executionError,
      "Failed to encode tool result: \(error.localizedDescription)",
      tool: tool)
  }
}

private func render(_ failure: EnvelopeFailure, tool: String) -> String {
  Envelope.failure(
    failure.kind,
    failure.message,
    retryable: failure.retryable,
    field: failure.field,
    expected: failure.expected,
    tool: tool,
    dataJSON: failure.dataJSON)
}

// MARK: - EventKit access

enum ReminderAccess {
  case granted
  case denied
  case timedOut
}

private func requireRemindersAccess(tool: String) -> String? {
  switch ReminderManager.shared.ensureAccess() {
  case .granted:
    return nil
  case .denied:
    return Envelope.failure(
      .userDenied,
      "Reminders access was denied. Enable it in System Settings > Privacy & Security > Reminders.",
      tool: tool)
  case .timedOut:
    return Envelope.failure(
      .timeout,
      "Timed out waiting for Reminders access.",
      tool: tool)
  }
}

final class ReminderManager {
  static let shared = ReminderManager()
  let store = EKEventStore()

  private init() {}

  private func hasAccess() -> Bool {
    let status = EKEventStore.authorizationStatus(for: .reminder)
    if #available(macOS 14.0, *) {
      return status == .fullAccess || status == .authorized
    }
    return status == .authorized
  }

  func ensureAccess() -> ReminderAccess {
    if hasAccess() { return .granted }

    let status = EKEventStore.authorizationStatus(for: .reminder)
    guard status == .notDetermined else { return .denied }

    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var granted = false

    let completion: (Bool, Error?) -> Void = { success, _ in
      lock.lock()
      granted = success
      lock.unlock()
      semaphore.signal()
    }

    if #available(macOS 14.0, *) {
      store.requestFullAccessToReminders(completion: completion)
    } else {
      store.requestAccess(to: .reminder, completion: completion)
    }

    guard semaphore.wait(timeout: .now() + 20) != .timedOut else {
      return .timedOut
    }
    lock.lock()
    defer { lock.unlock() }
    return granted ? .granted : .denied
  }

  func lists() -> [EKCalendar] {
    store.calendars(for: .reminder)
  }

  func list(id: String) -> EKCalendar? {
    lists().first { $0.calendarIdentifier == id }
  }

  func reminder(id: String) -> EKReminder? {
    store.calendarItem(withIdentifier: id) as? EKReminder
  }

  func fetch(predicate: NSPredicate, timeout: TimeInterval = 30) -> [EKReminder]? {
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var results: [EKReminder]?

    store.fetchReminders(matching: predicate) { reminders in
      lock.lock()
      results = reminders ?? []
      lock.unlock()
      semaphore.signal()
    }

    guard semaphore.wait(timeout: .now() + timeout) != .timedOut else {
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
  func run(args: String) -> String
}

private extension Tool {
  func parse(_ payload: String, allowedKeys: Set<String>) throws -> [String: Any] {
    let args = try ArgValidation.parseObject(payload)
    let unknown = Set(args.keys).subtracting(allowedKeys).sorted()
    guard unknown.isEmpty else {
      throw EnvelopeFailure(
        .invalidArgs,
        "Unknown argument\(unknown.count == 1 ? "" : "s"): \(unknown.joined(separator: ", "))",
        field: unknown.first,
        expected: "one of: \(allowedKeys.sorted().joined(separator: ", "))",
        tool: name)
    }
    return args
  }

  func optionalNonemptyString(_ args: [String: Any], _ key: String) throws -> String? {
    guard args[key] != nil else { return nil }
    guard !(args[key] is NSNull) else {
      throw EnvelopeFailure(
        .invalidArgs, "\(key) must be a string", field: key, expected: "non-empty string")
    }
    guard let value = try ArgValidation.optionalString(args, key),
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw EnvelopeFailure(
        .invalidArgs, "\(key) must not be empty", field: key, expected: "non-empty string")
    }
    return value
  }

  func finish(_ body: () throws -> String) -> String {
    do {
      return try body()
    } catch let failure as EnvelopeFailure {
      return render(failure, tool: name)
    } catch {
      return Envelope.failure(
        .executionError,
        error.localizedDescription,
        tool: name)
    }
  }
}

struct ListReminderListsTool: Tool {
  let name = "list_reminder_lists"
  let description =
    "List reminder lists with stable IDs, account details, writability, and the default-list marker."
  let requirements = ["reminders"]
  let permissionPolicy = "auto"
  let parameters = """
    {
      "type": "object",
      "properties": {},
      "required": [],
      "additionalProperties": false
    }
    """

  func run(args: String) -> String {
    finish {
      _ = try parse(args, allowedKeys: [])
      if let failure = requireRemindersAccess(tool: name) { return failure }

      let limit = Validation.maxListLimit
      let manager = ReminderManager.shared
      let defaultID = manager.store.defaultCalendarForNewReminders()?.calendarIdentifier
      let all = manager.lists().sorted {
        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
      let lists = all.prefix(limit).map {
        ReminderListDTO(from: $0, defaultListID: defaultID)
      }
      return success(
        tool: name,
        result: ReminderListCollectionDTO(
          lists: Array(lists),
          returned_count: lists.count,
          total_count: all.count,
          limit: limit,
          has_more: all.count > limit))
    }
  }
}

struct QueryRemindersTool: Tool {
  let name = "query_reminders"
  let description =
    "Query reminders by optional text, stable list ID, completion status, and RFC3339 due-date bounds."
  let requirements = ["reminders"]
  let permissionPolicy = "auto"
  let parameters = """
    {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "minLength": 1,
          "maxLength": 500,
          "description": "Optional case-insensitive text matched against title and notes."
        },
        "list_id": {
          "type": "string",
          "minLength": 1,
          "description": "Stable list ID from list_reminder_lists. List names are not accepted."
        },
        "status": {
          "type": "string",
          "enum": ["incomplete", "completed", "all"],
          "default": "incomplete"
        },
        "due_after": {
          "type": "string",
          "format": "date-time",
          "description": "Inclusive RFC3339 lower bound for the reminder due time."
        },
        "due_before": {
          "type": "string",
          "format": "date-time",
          "description": "Inclusive RFC3339 upper bound for the reminder due time."
        },
        "limit": {
          "type": "integer",
          "minimum": 1,
          "maximum": 200,
          "default": 50
        }
      },
      "required": [],
      "additionalProperties": false
    }
    """

  func run(args: String) -> String {
    finish {
      let args = try parse(
        args,
        allowedKeys: ["query", "list_id", "status", "due_after", "due_before", "limit"])
      let query = try optionalNonemptyString(args, "query")
      let listID = try optionalNonemptyString(args, "list_id")
      let rawStatus = try optionalNonemptyString(args, "status") ?? "incomplete"
      guard let status = Validation.Status(rawValue: rawStatus) else {
        throw EnvelopeFailure(
          .invalidArgs,
          "status must be one of: incomplete, completed, all",
          field: "status",
          expected: "incomplete, completed, or all")
      }
      let limit = try Validation.resolveLimit(args["limit"], defaultValue: 50)
      let dueAfter = try dateArgument(args, key: "due_after")
      let dueBefore = try dateArgument(args, key: "due_before")
      if let dueAfter, let dueBefore, dueAfter > dueBefore {
        throw EnvelopeFailure(
          .invalidArgs,
          "due_after must be earlier than or equal to due_before",
          field: "due_after",
          expected: "RFC3339 date-time no later than due_before")
      }

      if let failure = requireRemindersAccess(tool: name) { return failure }

      let manager = ReminderManager.shared
      let calendars: [EKCalendar]?
      if let listID {
        guard let list = manager.list(id: listID) else {
          return Envelope.failure(
            .notFound,
            "No reminder list exists with ID '\(listID)'.",
            field: "list_id",
            tool: name,
            data: ["code": "LIST_NOT_FOUND", "list_id": listID])
        }
        calendars = [list]
      } else {
        calendars = nil
      }

      let store = manager.store
      func incomplete() throws -> [EKReminder] {
        let predicate = store.predicateForIncompleteReminders(
          withDueDateStarting: dueAfter,
          ending: dueBefore,
          calendars: calendars)
        guard let reminders = manager.fetch(predicate: predicate) else {
          throw EnvelopeFailure(.timeout, "Reminders query timed out")
        }
        return reminders
      }

      func completed() throws -> [EKReminder] {
        let predicate = store.predicateForCompletedReminders(
          withCompletionDateStarting: nil,
          ending: nil,
          calendars: calendars)
        guard let reminders = manager.fetch(predicate: predicate) else {
          throw EnvelopeFailure(.timeout, "Reminders query timed out")
        }
        return reminders.filter {
          Validation.dueDateInRange(
            date(from: $0.dueDateComponents),
            after: dueAfter,
            before: dueBefore)
        }
      }

      var reminders: [EKReminder]
      switch status {
      case .incomplete:
        reminders = try incomplete()
      case .completed:
        reminders = try completed()
      case .all:
        reminders = try incomplete() + completed()
      }

      var seen = Set<String>()
      reminders = reminders.filter { seen.insert($0.calendarItemIdentifier).inserted }
      if let query {
        reminders = reminders.filter {
          ($0.title?.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]) != nil)
            || ($0.notes?.range(
              of: query,
              options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
      }
      reminders.sort(by: reminderSort)

      let total = reminders.count
      let page = reminders.prefix(limit).map(ReminderDTO.init)
      return success(
        tool: name,
        result: ReminderCollectionDTO(
          reminders: Array(page),
          returned_count: page.count,
          total_count: total,
          limit: limit,
          has_more: total > limit))
    }
  }

  private func dateArgument(_ args: [String: Any], key: String) throws -> Date? {
    guard let value = try optionalNonemptyString(args, key) else { return nil }
    guard let parsed = Validation.parseRFC3339(value) else {
      throw EnvelopeFailure(
        .invalidArgs,
        "\(key) must be an RFC3339 date-time with a timezone",
        field: key,
        expected: "RFC3339 date-time, for example 2026-08-06T17:00:00Z")
    }
    return parsed
  }
}

struct CreateReminderTool: Tool {
  let name = "create_reminder"
  let description =
    "Create a reminder in the default list or in a writable list selected by stable list_id."
  let requirements = ["reminders"]
  let permissionPolicy = "ask"
  let parameters = """
    {
      "type": "object",
      "properties": {
        "title": {
          "type": "string",
          "minLength": 1,
          "maxLength": 500
        },
        "notes": {
          "type": "string",
          "maxLength": 10000
        },
        "list_id": {
          "type": "string",
          "minLength": 1,
          "description": "Stable list ID from list_reminder_lists. Omit to use the default list."
        },
        "due_at": {
          "type": "string",
          "format": "date-time",
          "description": "RFC3339 due time. An absolute notification alarm is created at the same time."
        },
        "priority": {
          "type": "integer",
          "minimum": 1,
          "maximum": 9,
          "description": "1 is highest, 5 is medium, and 9 is lowest."
        }
      },
      "required": ["title"],
      "additionalProperties": false
    }
    """

  func run(args: String) -> String {
    finish {
      let args = try parse(
        args,
        allowedKeys: ["title", "notes", "list_id", "due_at", "priority"])
      let title = try ArgValidation.requireString(args, "title")
      guard title.count <= 500 else {
        throw EnvelopeFailure(
          .invalidArgs, "title exceeds 500 characters", field: "title", expected: "1-500 characters")
      }
      let notes = try optionalString(args, key: "notes", maximumLength: 10_000)
      let listID = try optionalNonemptyString(args, "list_id")
      let priority = try Validation.optionalPriority(args["priority"])

      var dueDate: Date?
      if let rawDue = try optionalNonemptyString(args, "due_at") {
        guard let parsed = Validation.parseRFC3339(rawDue) else {
          throw EnvelopeFailure(
            .invalidArgs,
            "due_at must be an RFC3339 date-time with a timezone",
            field: "due_at",
            expected: "RFC3339 date-time, for example 2026-08-06T17:00:00Z")
        }
        dueDate = parsed
      }

      if let failure = requireRemindersAccess(tool: name) { return failure }

      let manager = ReminderManager.shared
      let calendar: EKCalendar
      if let listID {
        guard let selected = manager.list(id: listID) else {
          return Envelope.failure(
            .notFound,
            "No reminder list exists with ID '\(listID)'.",
            field: "list_id",
            tool: name,
            data: ["code": "LIST_NOT_FOUND", "list_id": listID])
        }
        calendar = selected
      } else {
        guard let selected = manager.store.defaultCalendarForNewReminders() else {
          return Envelope.failure(
            .unavailable,
            "No default reminder list is configured.",
            tool: name,
            data: ["code": "DEFAULT_LIST_UNAVAILABLE"])
        }
        calendar = selected
      }

      guard calendar.allowsContentModifications && !calendar.isImmutable else {
        return Envelope.failure(
          .rejected,
          "The selected reminder list is read-only.",
          field: "list_id",
          tool: name,
          data: ["code": "LIST_READ_ONLY", "list_id": calendar.calendarIdentifier])
      }

      let reminder = EKReminder(eventStore: manager.store)
      reminder.title = title
      reminder.notes = notes
      reminder.calendar = calendar
      if let priority { reminder.priority = priority }
      if let dueDate {
        reminder.dueDateComponents = Calendar.current.dateComponents(
          in: TimeZone.current,
          from: dueDate)
        reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
      }

      do {
        try manager.store.save(reminder, commit: true)
      } catch {
        return Envelope.failure(
          .executionError,
          "Failed to save reminder: \(error.localizedDescription)",
          tool: name,
          data: ["code": "SAVE_FAILED"])
      }
      return success(tool: name, result: ReminderDTO(from: reminder))
    }
  }

  private func optionalString(
    _ args: [String: Any],
    key: String,
    maximumLength: Int
  ) throws -> String? {
    guard args[key] != nil else { return nil }
    guard !(args[key] is NSNull), let value = try ArgValidation.optionalString(args, key) else {
      throw EnvelopeFailure(
        .invalidArgs, "\(key) must be a string", field: key, expected: "string")
    }
    guard value.count <= maximumLength else {
      throw EnvelopeFailure(
        .invalidArgs,
        "\(key) exceeds \(maximumLength) characters",
        field: key,
        expected: "at most \(maximumLength) characters")
    }
    return value
  }
}

struct OpenReminderTool: Tool {
  let name = "open_reminder"
  let description =
    "Look up a reminder by stable ID, then open that exact reminder in Reminders."
  let requirements = ["reminders", "automation"]
  let permissionPolicy = "ask"
  let parameters = """
    {
      "type": "object",
      "properties": {
        "id": {
          "type": "string",
          "minLength": 1,
          "description": "Stable reminder ID returned by query_reminders or create_reminder."
        }
      },
      "required": ["id"],
      "additionalProperties": false
    }
    """

  func run(args: String) -> String {
    finish {
      let args = try parse(args, allowedKeys: ["id"])
      let reminderID = try ArgValidation.requireString(args, "id")
      if let failure = requireRemindersAccess(tool: name) { return failure }

      guard let reminder = ReminderManager.shared.reminder(id: reminderID) else {
        return Envelope.failure(
          .notFound,
          "No reminder exists with ID '\(reminderID)'.",
          field: "id",
          tool: name,
          data: ["code": "REMINDER_NOT_FOUND", "id": reminderID])
      }

      let script = """
        on run argv
          set reminderId to item 1 of argv
          tell application "Reminders"
            set targetReminder to first reminder whose id is reminderId
            show targetReminder
            activate
          end tell
          return reminderId
        end run
        """

      let output: ProcessRunner.Output
      do {
        output = try ProcessRunner.run(
          executable: "/usr/bin/osascript",
          arguments: ["-e", script, "--", reminderID],
          timeout: 15,
          maxOutputBytes: 64 * 1024)
      } catch {
        return Envelope.failure(
          .executionError,
          "Failed to launch Reminders automation: \(error.localizedDescription)",
          tool: name,
          data: ["code": "AUTOMATION_LAUNCH_FAILED"])
      }

      if output.timedOut {
        return Envelope.failure(
          .timeout,
          "Timed out opening the reminder.",
          tool: name,
          data: ["code": "AUTOMATION_TIMEOUT"])
      }
      if output.exitStatus != 0 {
        let detail = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        let denied = detail.contains("-1743") || detail.contains("-128")
        return Envelope.failure(
          denied ? .userDenied : .executionError,
          denied
            ? "Reminders automation was denied."
            : "Reminders could not open the selected reminder\(detail.isEmpty ? "." : ": \(detail)")",
          tool: name,
          data: ["code": denied ? "AUTOMATION_DENIED" : "AUTOMATION_FAILED"])
      }

      return success(
        tool: name,
        result: OpenReminderResultDTO(
          opened: true,
          reminder: ReminderDTO(from: reminder)))
    }
  }
}

// MARK: - Manifest and ABI

let remindersTools: [Tool] = [
  ListReminderListsTool(),
  QueryRemindersTool(),
  CreateReminderTool(),
  OpenReminderTool(),
]

let remindersManifestJSON: String = {
  let toolsJSON = remindersTools.map { tool -> String in
    let requirements = tool.requirements.map { "\"\(Envelope.escape($0))\"" }
      .joined(separator: ",")
    return """
      {
        "id": "\(tool.name)",
        "description": "\(Envelope.escape(tool.description))",
        "parameters": \(tool.parameters),
        "requirements": [\(requirements)],
        "permission_policy": "\(tool.permissionPolicy)"
      }
      """
  }.joined(separator: ",")

  return """
    {
      "plugin_id": "osaurus.reminders",
      "name": "Reminders",
      "version": "2.0.0",
      "description": "Read, create, and open macOS reminders through stable, strict tool contracts.",
      "license": "MIT",
      "authors": ["Osaurus"],
      "min_macos": "13.0",
      "min_osaurus": "0.5.0",
      "capabilities": {
        "tools": [\(toolsJSON)]
      }
    }
    """
}()

private final class PluginContext {
  let tools = Dictionary(uniqueKeysWithValues: remindersTools.map { ($0.name, $0) })
}

private var pluginAPI = PluginEntry.makeAPI(
  version: OsrABIVersion.v2,
  init: {
    Unmanaged.passRetained(PluginContext()).toOpaque()
  },
  destroy: { context in
    guard let context else { return }
    Unmanaged<PluginContext>.fromOpaque(context).release()
  },
  getManifest: { context in
    guard context != nil else { return nil }
    return osrMakeCString(remindersManifestJSON)
  },
  invoke: { context, typePointer, idPointer, payloadPointer in
    guard let context, let typePointer, let idPointer, let payloadPointer else {
      return nil
    }

    let plugin = Unmanaged<PluginContext>.fromOpaque(context).takeUnretainedValue()
    let type = String(cString: typePointer)
    let id = String(cString: idPointer)
    let payload = String(cString: payloadPointer)

    guard type == "tool" else {
      return osrMakeCString(
        Envelope.failure(
          .toolNotFound,
          "Unknown capability type '\(type)'.",
          data: ["code": "CAPABILITY_TYPE_NOT_FOUND", "type": type]))
    }
    guard let tool = plugin.tools[id] else {
      return osrMakeCString(
        Envelope.failure(
          .toolNotFound,
          "Unknown tool '\(id)'.",
          tool: id,
          data: ["code": "TOOL_NOT_FOUND", "id": id]))
    }
    return osrMakeCString(tool.run(args: payload))
  })

@_cdecl("osaurus_plugin_entry_v2")
public func osaurus_plugin_entry_v2(_ host: UnsafeRawPointer?) -> UnsafeRawPointer? {
  PluginEntry.enterV2(host, api: &pluginAPI)
}

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  PluginEntry.enterV1(api: &pluginAPI)
}
