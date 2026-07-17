import XCTest

@testable import osaurus_reminders

final class ValidationTests: XCTestCase {

  // MARK: - Limits

  func testNilLimitUsesDefault() {
    XCTAssertEqual(Validation.resolveLimit(nil, default: 50), .ok(50))
  }

  func testPositiveLimitPassesThrough() {
    XCTAssertEqual(Validation.resolveLimit(5, default: 50), .ok(5))
  }

  func testNegativeLimitRejected() {
    // Regression: a negative limit used to reach prefix(_:) and trap at runtime.
    guard case .invalid = Validation.resolveLimit(-3, default: 50) else {
      return XCTFail("Negative limit must be rejected as invalid_args")
    }
  }

  func testZeroLimitRejected() {
    guard case .invalid = Validation.resolveLimit(0, default: 50) else {
      return XCTFail("Zero limit must be rejected as invalid_args")
    }
  }

  func testHugeLimitClamped() {
    XCTAssertEqual(Validation.resolveLimit(Int.max, default: 50), .ok(Validation.maxLimit))
  }

  // MARK: - Status

  func testStatusDefaultsToIncomplete() {
    XCTAssertEqual(Validation.parseStatus(nil), .incomplete)
  }

  func testKnownStatusesParse() {
    XCTAssertEqual(Validation.parseStatus("incomplete"), .incomplete)
    XCTAssertEqual(Validation.parseStatus("completed"), .completed)
    XCTAssertEqual(Validation.parseStatus("all"), .all)
  }

  func testUnknownStatusRejected() {
    // Regression: unknown statuses were silently treated as "all".
    XCTAssertNil(Validation.parseStatus("done"))
    XCTAssertNil(Validation.parseStatus("COMPLETED"))
    XCTAssertNil(Validation.parseStatus(""))
  }

  // MARK: - Dates

  func testParsesISODatesWithAndWithoutFractionalSeconds() {
    XCTAssertNotNil(Validation.parseISODate("2026-07-16T12:00:00Z"))
    XCTAssertNotNil(Validation.parseISODate("2026-07-16T12:00:00.500Z"))
  }

  func testRejectsInvalidDates() {
    XCTAssertNil(Validation.parseISODate("not-a-date"))
    XCTAssertNil(Validation.parseISODate("2026-07-16"))
    XCTAssertNil(Validation.parseISODate(""))
  }

  // MARK: - Priority

  func testPriorityBoundsEnforced() {
    XCTAssertNil(Validation.priorityError(nil))
    XCTAssertNil(Validation.priorityError(1))
    XCTAssertNil(Validation.priorityError(5))
    XCTAssertNil(Validation.priorityError(9))
    XCTAssertNotNil(Validation.priorityError(0))
    XCTAssertNotNil(Validation.priorityError(10))
    XCTAssertNotNil(Validation.priorityError(-1))
  }

  // MARK: - Due-date range filtering

  func testDueDateInRangeNoBoundsMatchesEverything() {
    XCTAssertTrue(Validation.dueDateInRange(nil, after: nil, before: nil))
    XCTAssertTrue(Validation.dueDateInRange(Date(), after: nil, before: nil))
  }

  func testDueDateInRangeFiltersByDueDateNotCompletionDate() {
    // Regression: dueAfter/dueBefore used to constrain the COMPLETION date of
    // completed reminders; the filter must apply to the DUE date.
    let due = Date(timeIntervalSince1970: 1_000_000)
    let before = Date(timeIntervalSince1970: 2_000_000)
    let after = Date(timeIntervalSince1970: 500_000)

    XCTAssertTrue(Validation.dueDateInRange(due, after: after, before: before))
    XCTAssertFalse(Validation.dueDateInRange(due, after: before, before: nil))
    XCTAssertFalse(Validation.dueDateInRange(due, after: nil, before: after))
  }

  func testDueDateInRangeExcludesRemindersWithoutDueDateWhenBounded() {
    XCTAssertFalse(Validation.dueDateInRange(nil, after: Date(), before: nil))
    XCTAssertFalse(Validation.dueDateInRange(nil, after: nil, before: Date()))
  }
}
