import XCTest

@testable import osaurus_reminders

final class ToolValidationTests: XCTestCase {
  private struct Failure: Decodable {
    let ok: Bool
    let kind: String
    let message: String
    let field: String?
    let tool: String?
    let retryable: Bool
  }

  private func failure(
    _ json: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> Failure {
    let data = try XCTUnwrap(json.data(using: .utf8), file: file, line: line)
    let result = try JSONDecoder().decode(Failure.self, from: data)
    XCTAssertFalse(result.ok, file: file, line: line)
    XCTAssertEqual(result.kind, "invalid_args", file: file, line: line)
    XCTAssertTrue(result.retryable, file: file, line: line)
    return result
  }

  func testListRejectsUnknownArguments() throws {
    let result = try failure(ListReminderListsTool().run(args: #"{"limit":10}"#))
    XCTAssertEqual(result.field, "limit")
    XCTAssertEqual(result.tool, "list_reminder_lists")
  }

  func testQueryRejectsMalformedJSON() throws {
    let result = try failure(QueryRemindersTool().run(args: "not json"))
    XCTAssertEqual(result.tool, "query_reminders")
  }

  func testQueryRejectsLegacyNamesAndListTitles() throws {
    for payload in [
      #"{"searchText":"milk"}"#,
      #"{"listName":"Groceries"}"#,
      #"{"list_name":"Groceries"}"#,
      #"{"dueAfter":"2026-08-06T17:00:00Z"}"#,
    ] {
      let result = try failure(QueryRemindersTool().run(args: payload))
      XCTAssertTrue(result.message.contains("Unknown argument"))
    }
  }

  func testQueryRejectsInvalidFiltersBeforeAccess() throws {
    let cases = [
      (#"{"query":"  "}"#, "query"),
      (#"{"list_id":""}"#, "list_id"),
      (#"{"status":"done"}"#, "status"),
      (#"{"due_after":"tomorrow"}"#, "due_after"),
      (#"{"due_before":"2026-08-06"}"#, "due_before"),
      (#"{"limit":0}"#, "limit"),
      (#"{"limit":201}"#, "limit"),
    ]
    for (payload, field) in cases {
      let result = try failure(QueryRemindersTool().run(args: payload))
      XCTAssertEqual(result.field, field)
    }
  }

  func testQueryRejectsReversedDateRange() throws {
    let result = try failure(
      QueryRemindersTool().run(
        args:
          #"{"due_after":"2026-08-07T00:00:00Z","due_before":"2026-08-06T00:00:00Z"}"#))
    XCTAssertEqual(result.field, "due_after")
  }

  func testCreateRejectsMissingOrEmptyTitle() throws {
    for payload in [#"{}"#, #"{"title":"  "}"#] {
      let result = try failure(CreateReminderTool().run(args: payload))
      XCTAssertEqual(result.tool, "create_reminder")
    }
  }

  func testCreateRejectsLegacyNamesAndInvalidValues() throws {
    let cases = [
      (#"{"title":"Milk","listName":"Groceries"}"#, "listName"),
      (#"{"title":"Milk","dueDate":"2026-08-06T17:00:00Z"}"#, "dueDate"),
      (#"{"title":"Milk","due_at":"tomorrow"}"#, "due_at"),
      (#"{"title":"Milk","priority":0}"#, "priority"),
      (#"{"title":"Milk","priority":10}"#, "priority"),
      (#"{"title":"Milk","notes":null}"#, "notes"),
    ]
    for (payload, field) in cases {
      let result = try failure(CreateReminderTool().run(args: payload))
      XCTAssertEqual(result.field, field)
    }
  }

  func testOpenRequiresNonemptyIDAndRejectsUnknownFields() throws {
    for payload in [#"{}"#, #"{"id":""}"#, #"{"id":"abc","title":"Milk"}"#] {
      let result = try failure(OpenReminderTool().run(args: payload))
      XCTAssertEqual(result.tool, "open_reminder")
    }
  }
}
