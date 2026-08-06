import OsaurusPluginKit
import XCTest

@testable import osaurus_reminders

final class ValidationTests: XCTestCase {
  func testLimitDefaultsAndAcceptsBounds() throws {
    XCTAssertEqual(try Validation.resolveLimit(nil, defaultValue: 50), 50)
    XCTAssertEqual(try Validation.resolveLimit(1, defaultValue: 50), 1)
    XCTAssertEqual(
      try Validation.resolveLimit(Validation.maxQueryLimit, defaultValue: 50),
      Validation.maxQueryLimit)
  }

  func testLimitRejectsInvalidValues() {
    for value: Any in [0, -1, Validation.maxQueryLimit + 1, true, 1.5, "5"] {
      XCTAssertThrowsError(try Validation.resolveLimit(value, defaultValue: 50)) { error in
        XCTAssertEqual((error as? EnvelopeFailure)?.kind, .invalidArgs)
      }
    }
  }

  func testRFC3339RequiresFullDateTimeAndTimezone() {
    XCTAssertNotNil(Validation.parseRFC3339("2026-08-06T17:00:00Z"))
    XCTAssertNotNil(Validation.parseRFC3339("2026-08-06T10:00:00.250-07:00"))
    XCTAssertNil(Validation.parseRFC3339("2026-08-06"))
    XCTAssertNil(Validation.parseRFC3339("2026-08-06T10:00:00"))
    XCTAssertNil(Validation.parseRFC3339("tomorrow"))
  }

  func testPriorityValidation() throws {
    XCTAssertNil(try Validation.optionalPriority(nil))
    XCTAssertEqual(try Validation.optionalPriority(1), 1)
    XCTAssertEqual(try Validation.optionalPriority(9), 9)

    for value: Any in [0, 10, -1, true, 1.5, "5"] {
      XCTAssertThrowsError(try Validation.optionalPriority(value)) { error in
        XCTAssertEqual((error as? EnvelopeFailure)?.kind, .invalidArgs)
      }
    }
  }

  func testDueDateBoundsAreInclusive() {
    let due = Date(timeIntervalSince1970: 1_000)
    XCTAssertTrue(Validation.dueDateInRange(due, after: due, before: due))
    XCTAssertFalse(
      Validation.dueDateInRange(
        due,
        after: Date(timeIntervalSince1970: 1_001),
        before: nil))
    XCTAssertFalse(
      Validation.dueDateInRange(
        due,
        after: nil,
        before: Date(timeIntervalSince1970: 999)))
  }

  func testDueDateBoundsExcludeMissingDueDate() {
    XCTAssertTrue(Validation.dueDateInRange(nil, after: nil, before: nil))
    XCTAssertFalse(Validation.dueDateInRange(nil, after: Date(), before: nil))
    XCTAssertFalse(Validation.dueDateInRange(nil, after: nil, before: Date()))
  }
}
