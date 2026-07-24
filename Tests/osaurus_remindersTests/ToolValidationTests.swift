import XCTest

@testable import osaurus_reminders

/// Regression tests for tool-level argument validation. All invalid-args paths
/// return before any EventKit access, so these run without TCC permission.
final class ToolValidationTests: XCTestCase {

  private struct Failure: Decodable {
    let ok: Bool
    let kind: String
    let message: String
    let retryable: Bool
  }

  private func decodeFailure(_ json: String, file: StaticString = #filePath, line: UInt = #line)
    throws -> Failure
  {
    let data = try XCTUnwrap(json.data(using: .utf8), file: file, line: line)
    return try JSONDecoder().decode(Failure.self, from: data)
  }

  // MARK: - get_reminders

  func testGetRemindersRejectsMalformedJSON() throws {
    let failure = try decodeFailure(GetRemindersTool().run(args: "not json"))
    XCTAssertEqual(failure.kind, "invalid_args")
    XCTAssertFalse(failure.retryable)
  }

  func testGetRemindersRejectsNegativeLimit() throws {
    // Regression: negative limit used to reach prefix(_:) and trap.
    let failure = try decodeFailure(GetRemindersTool().run(args: #"{"limit": -5}"#))
    XCTAssertEqual(failure.kind, "invalid_args")
    XCTAssertTrue(failure.message.contains("limit"))
  }

  func testGetRemindersRejectsUnknownStatus() throws {
    // Regression: unknown status was silently treated as "all".
    let failure = try decodeFailure(GetRemindersTool().run(args: #"{"status": "done"}"#))
    XCTAssertEqual(failure.kind, "invalid_args")
    XCTAssertTrue(failure.message.contains("status"))
  }

  func testGetRemindersRejectsInvalidDueAfter() throws {
    // Regression: invalid dates were silently ignored.
    let failure = try decodeFailure(GetRemindersTool().run(args: #"{"dueAfter": "yesterday"}"#))
    XCTAssertEqual(failure.kind, "invalid_args")
    XCTAssertTrue(failure.message.contains("dueAfter"))
  }

  func testGetRemindersRejectsInvalidDueBefore() throws {
    let failure = try decodeFailure(GetRemindersTool().run(args: #"{"dueBefore": "13/13/2026"}"#))
    XCTAssertEqual(failure.kind, "invalid_args")
    XCTAssertTrue(failure.message.contains("dueBefore"))
  }

  func testGetRemindersRejectsEmptyListName() throws {
    let failure = try decodeFailure(GetRemindersTool().run(args: #"{"listName": "  "}"#))
    XCTAssertEqual(failure.kind, "invalid_args")
  }

  // MARK: - search_reminders

  func testSearchRemindersRejectsEmptySearchText() throws {
    // Regression: empty search text used to match every reminder.
    let failure = try decodeFailure(SearchRemindersTool().run(args: #"{"searchText": ""}"#))
    XCTAssertEqual(failure.kind, "invalid_args")
    XCTAssertTrue(failure.message.contains("searchText"))
  }

  func testSearchRemindersRejectsWhitespaceSearchText() throws {
    let failure = try decodeFailure(SearchRemindersTool().run(args: #"{"searchText": " \n "}"#))
    XCTAssertEqual(failure.kind, "invalid_args")
  }

  func testSearchRemindersRejectsNegativeLimit() throws {
    let failure = try decodeFailure(
      SearchRemindersTool().run(args: #"{"searchText": "milk", "limit": -1}"#))
    XCTAssertEqual(failure.kind, "invalid_args")
    XCTAssertTrue(failure.message.contains("limit"))
  }

  // MARK: - create_reminder

  func testCreateReminderRejectsEmptyTitle() throws {
    let failure = try decodeFailure(CreateReminderTool().run(args: #"{"title": "  "}"#))
    XCTAssertEqual(failure.kind, "invalid_args")
    XCTAssertTrue(failure.message.contains("title"))
  }

  func testCreateReminderRejectsOutOfRangePriority() throws {
    // Regression: priority was passed to EventKit unvalidated.
    let failure = try decodeFailure(
      CreateReminderTool().run(args: #"{"title": "Buy milk", "priority": 42}"#))
    XCTAssertEqual(failure.kind, "invalid_args")
    XCTAssertTrue(failure.message.contains("priority"))
  }

  func testCreateReminderRejectsInvalidDueDate() throws {
    // Regression: invalid due dates were silently dropped.
    let failure = try decodeFailure(
      CreateReminderTool().run(args: #"{"title": "Buy milk", "dueDate": "tomorrow"}"#))
    XCTAssertEqual(failure.kind, "invalid_args")
    XCTAssertTrue(failure.message.contains("dueDate"))
  }

  // MARK: - search_reminders manifest documentation

  func testSearchRemindersDescriptionDocumentsCompletedWindow() {
    XCTAssertTrue(
      SearchRemindersTool().description.contains("30 days"),
      "Tool description must document the 30-day completed-reminder search window")
  }
}
