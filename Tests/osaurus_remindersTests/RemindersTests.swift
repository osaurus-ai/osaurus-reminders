import XCTest

@testable import osaurus_reminders

final class RemindersTests: XCTestCase {

  // MARK: - Manifest

  private struct Manifest: Decodable {
    let plugin_id: String
    let capabilities: Capabilities
    struct Capabilities: Decodable {
      let tools: [ToolEntry]
    }
    struct ToolEntry: Decodable {
      let id: String
      let description: String
    }
  }

  func testManifestParsesAndHasValidTools() throws {
    let data = try XCTUnwrap(remindersManifestJSON.data(using: .utf8))
    let manifest = try JSONDecoder().decode(Manifest.self, from: data)

    XCTAssertEqual(manifest.plugin_id, "osaurus.reminders")
    XCTAssertFalse(manifest.capabilities.tools.isEmpty, "Manifest should expose at least one tool")

    for tool in manifest.capabilities.tools {
      XCTAssertFalse(
        tool.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        "Tool id must be non-empty")
      XCTAssertFalse(
        tool.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        "Tool '\(tool.id)' description must be non-empty")
    }
  }

  func testManifestToolCountMatchesRegistry() throws {
    let data = try XCTUnwrap(remindersManifestJSON.data(using: .utf8))
    let manifest = try JSONDecoder().decode(Manifest.self, from: data)
    XCTAssertEqual(manifest.capabilities.tools.count, remindersTools.count)
  }

  // MARK: - Envelope

  private struct Failure: Decodable {
    let ok: Bool
    let kind: String
    let message: String
    let retryable: Bool
  }

  func testEnvelopeFailureRoundTrip() throws {
    let json = Envelope.failure(.notFound, "List 'Groceries' not found.")
    let data = try XCTUnwrap(json.data(using: .utf8))
    let failure = try JSONDecoder().decode(Failure.self, from: data)

    XCTAssertFalse(failure.ok)
    XCTAssertEqual(failure.kind, "not_found")
    XCTAssertEqual(failure.message, "List 'Groceries' not found.")
    XCTAssertFalse(failure.retryable, "not_found defaults to retryable: false")
  }

  func testEnvelopeDefaultRetryablePerKind() throws {
    let cases: [(Envelope.Kind, String, Bool)] = [
      (.invalidArgs, "invalid_args", false),
      (.executionError, "execution_error", true),
      (.notFound, "not_found", false),
      (.permissionDenied, "permission_denied", false),
      (.timeout, "timeout", true),
    ]
    for (kind, expectedKind, expectedRetryable) in cases {
      let data = try XCTUnwrap(Envelope.failure(kind, "x").data(using: .utf8))
      let failure = try JSONDecoder().decode(Failure.self, from: data)
      XCTAssertEqual(failure.kind, expectedKind)
      XCTAssertEqual(failure.retryable, expectedRetryable)
    }
  }

  func testEnvelopeFailureExplicitRetryableOverride() throws {
    let data = try XCTUnwrap(
      Envelope.failure(.executionError, "flaky", retryable: false).data(using: .utf8))
    let failure = try JSONDecoder().decode(Failure.self, from: data)
    XCTAssertEqual(failure.kind, "execution_error")
    XCTAssertFalse(failure.retryable)
  }

  func testEnvelopeEscapesSpecialCharacters() throws {
    let nasty = "quote:\" backslash:\\ newline:\n tab:\t"
    let data = try XCTUnwrap(Envelope.failure(.executionError, nasty).data(using: .utf8))
    // Must remain valid JSON and decode back to the original message.
    let failure = try JSONDecoder().decode(Failure.self, from: data)
    XCTAssertEqual(failure.message, nasty)
  }
}
