import Foundation
import OsaurusPluginKit

/// Pure argument-validation and result-shaping helpers, kept framework-free so
/// they can be unit tested without EventKit/TCC access.
enum Validation {
  static let maxQueryLimit = 200
  static let maxListLimit = 200

  static func resolveLimit(_ raw: Any?, defaultValue: Int) throws -> Int {
    guard let raw, !(raw is NSNull) else { return defaultValue }
    guard !(raw is Bool), let value = raw as? Int else {
      throw EnvelopeFailure(
        .invalidArgs,
        "limit must be an integer",
        field: "limit",
        expected: "integer from 1 through \(maxQueryLimit)")
    }
    guard (1...maxQueryLimit).contains(value) else {
      throw EnvelopeFailure(
        .invalidArgs,
        "limit must be between 1 and \(maxQueryLimit)",
        field: "limit",
        expected: "integer from 1 through \(maxQueryLimit)")
    }
    return value
  }

  enum Status: String {
    case incomplete
    case completed
    case all
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

  static func parseRFC3339(_ s: String) -> Date? {
    return isoFractionalFormatter.date(from: s) ?? isoFormatter.date(from: s)
  }

  static func optionalPriority(_ raw: Any?) throws -> Int? {
    guard let raw, !(raw is NSNull) else { return nil }
    guard !(raw is Bool), let priority = raw as? Int else {
      throw EnvelopeFailure(
        .invalidArgs,
        "priority must be an integer",
        field: "priority",
        expected: "integer from 1 through 9")
    }
    guard (1...9).contains(priority) else {
      throw EnvelopeFailure(
        .invalidArgs,
        "priority must be between 1 and 9",
        field: "priority",
        expected: "integer from 1 through 9")
    }
    return priority
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
