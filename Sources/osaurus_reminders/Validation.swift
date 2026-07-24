import Foundation

/// Pure argument-validation and result-shaping helpers, kept framework-free so
/// they can be unit tested without EventKit/TCC access.
enum Validation {
  static let maxLimit = 1000

  enum LimitResult: Equatable {
    case ok(Int)
    case invalid(String)
  }

  /// Resolves a requested limit against a default, rejecting non-positive
  /// values (negative values trap in `prefix(_:)`) and clamping huge ones.
  static func resolveLimit(_ requested: Int?, default defaultLimit: Int) -> LimitResult {
    guard let requested else { return .ok(defaultLimit) }
    guard requested > 0 else {
      return .invalid("limit must be a positive integer, got \(requested)")
    }
    return .ok(min(requested, maxLimit))
  }

  enum Status: String {
    case incomplete
    case completed
    case all
  }

  /// Parses the status filter; nil input defaults to incomplete, unknown
  /// values are rejected instead of silently treated as a default.
  static func parseStatus(_ raw: String?) -> Status? {
    guard let raw else { return .incomplete }
    return Status(rawValue: raw)
  }

  private static let isoFractionalFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  private static let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  static func parseISODate(_ s: String) -> Date? {
    return isoFractionalFormatter.date(from: s) ?? isoFormatter.date(from: s)
  }

  /// Reminder priorities are 1 (highest) through 9 (lowest) per the manifest.
  static func priorityError(_ priority: Int?) -> String? {
    guard let priority else { return nil }
    guard (1...9).contains(priority) else {
      return "priority must be between 1 and 9, got \(priority)"
    }
    return nil
  }

  /// Due-date range filter used for completed reminders, whose EventKit
  /// predicate can only constrain the COMPLETION date. A reminder with no due
  /// date is excluded whenever a due-date bound is requested.
  static func dueDateInRange(_ due: Date?, after: Date?, before: Date?) -> Bool {
    if after == nil && before == nil { return true }
    guard let due else { return false }
    if let after, due < after { return false }
    if let before, due > before { return false }
    return true
  }
}
