import OsaurusPluginKit
import XCTest

@testable import osaurus_reminders

final class RemindersTests: XCTestCase {
  private func manifest() throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(remindersManifestJSON.utf8))
    return try XCTUnwrap(object as? [String: Any])
  }

  private func manifestTools() throws -> [[String: Any]] {
    let capabilities = try XCTUnwrap(try manifest()["capabilities"] as? [String: Any])
    return try XCTUnwrap(capabilities["tools"] as? [[String: Any]])
  }

  func testManifestVersionAndExactToolSurface() throws {
    XCTAssertEqual(try manifest()["version"] as? String, "2.0.0")
    XCTAssertEqual(
      try manifestTools().compactMap { $0["id"] as? String },
      [
        "list_reminder_lists",
        "query_reminders",
        "create_reminder",
        "open_reminder",
      ])
    XCTAssertEqual(remindersTools.count, 4)
  }

  func testManifestToolsUseOnlySupportedFieldsAndStrictSchemas() throws {
    let supported = Set([
      "id", "description", "parameters", "requirements", "permission_policy",
    ])
    for tool in try manifestTools() {
      let id = try XCTUnwrap(tool["id"] as? String)
      XCTAssertEqual(Set(tool.keys), supported, "\(id) contains unsupported manifest fields")

      let schema = try XCTUnwrap(tool["parameters"] as? [String: Any])
      XCTAssertEqual(schema["type"] as? String, "object")
      XCTAssertNotNil(schema["properties"] as? [String: Any])
      XCTAssertNotNil(schema["required"] as? [String])
      XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
      XCTAssertNil(tool["annotations"])
      XCTAssertNil(tool["outputSchema"])
    }
  }

  func testManifestPoliciesAndRequirements() throws {
    let entries = Dictionary(
      uniqueKeysWithValues: try manifestTools().map {
        (try XCTUnwrap($0["id"] as? String), $0)
      })

    XCTAssertEqual(entries["list_reminder_lists"]?["permission_policy"] as? String, "auto")
    XCTAssertEqual(entries["query_reminders"]?["permission_policy"] as? String, "auto")
    XCTAssertEqual(entries["create_reminder"]?["permission_policy"] as? String, "ask")
    XCTAssertEqual(entries["open_reminder"]?["permission_policy"] as? String, "ask")

    XCTAssertEqual(entries["list_reminder_lists"]?["requirements"] as? [String], ["reminders"])
    XCTAssertEqual(entries["query_reminders"]?["requirements"] as? [String], ["reminders"])
    XCTAssertEqual(entries["create_reminder"]?["requirements"] as? [String], ["reminders"])
    XCTAssertEqual(
      entries["open_reminder"]?["requirements"] as? [String],
      ["reminders", "automation"])
  }

  func testManifestUsesOnlySnakeCaseParameterNames() throws {
    let pattern = try NSRegularExpression(pattern: #"^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$"#)
    for tool in try manifestTools() {
      let schema = try XCTUnwrap(tool["parameters"] as? [String: Any])
      let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
      for key in properties.keys {
        let range = NSRange(key.startIndex..., in: key)
        XCTAssertNotNil(pattern.firstMatch(in: key, range: range), "\(key) is not snake_case")
      }
    }
  }

  func testSkillIsPackagedOutsideRuntimeManifest() throws {
    let capabilities = try XCTUnwrap(try manifest()["capabilities"] as? [String: Any])
    XCTAssertNil(capabilities["skills"])

    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let skill = try String(
      contentsOf: repositoryRoot.appendingPathComponent("SKILL.md"),
      encoding: .utf8)
    XCTAssertTrue(skill.hasPrefix("---\nname: osaurus-reminders\n"))
  }

  private struct Failure: Decodable {
    let ok: Bool
    let kind: String
    let message: String
    let retryable: Bool
  }

  func testEnvelopeUsesCanonicalKindsAndDefaults() throws {
    let cases: [(Envelope.Kind, String, Bool)] = [
      (.invalidArgs, "invalid_args", true),
      (.rejected, "rejected", false),
      (.userDenied, "user_denied", false),
      (.timeout, "timeout", true),
      (.executionError, "execution_error", true),
      (.notFound, "not_found", false),
      (.unavailable, "unavailable", true),
      (.toolNotFound, "tool_not_found", false),
    ]
    for (kind, expected, retryable) in cases {
      let result = try JSONDecoder().decode(
        Failure.self,
        from: Data(Envelope.failure(kind, "x").utf8))
      XCTAssertFalse(result.ok)
      XCTAssertEqual(result.kind, expected)
      XCTAssertEqual(result.retryable, retryable)
    }
  }
}
