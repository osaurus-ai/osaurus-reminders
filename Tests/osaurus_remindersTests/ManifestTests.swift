import Foundation
import Testing

@testable import osaurus_reminders

@Suite("Plugin Manifest")
struct ManifestTests {

  private enum ManifestError: Error {
    case entryPointFailed
    case nilManifest
    case invalidJSON
  }

  private func loadManifest() throws -> [String: Any] {
    guard let apiPtr = osaurus_plugin_entry() else {
      throw ManifestError.entryPointFailed
    }

    let fnPtrSize = MemoryLayout<UnsafeRawPointer?>.stride
    let initPtr = apiPtr.load(
      fromByteOffset: fnPtrSize,
      as: (@convention(c) () -> UnsafeMutableRawPointer?).self)
    let ctx = initPtr()

    let getManifestPtr = apiPtr.load(
      fromByteOffset: fnPtrSize * 3,
      as: (@convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?).self)
    guard let cStr = getManifestPtr(ctx) else {
      throw ManifestError.nilManifest
    }
    let jsonString = String(cString: cStr)

    let freeStringPtr = apiPtr.load(
      fromByteOffset: 0,
      as: (@convention(c) (UnsafePointer<CChar>?) -> Void).self)
    freeStringPtr(cStr)

    let destroyPtr = apiPtr.load(
      fromByteOffset: fnPtrSize * 2,
      as: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
    destroyPtr(ctx)

    guard let data = jsonString.data(using: .utf8),
      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw ManifestError.invalidJSON
    }
    return manifest
  }

  private func toolMap(from manifest: [String: Any]) -> [String: [String: Any]] {
    let capabilities = manifest["capabilities"] as? [String: Any]
    let tools = capabilities?["tools"] as? [[String: Any]] ?? []
    return Dictionary(
      uniqueKeysWithValues: tools.compactMap { tool -> (String, [String: Any])? in
        guard let id = tool["id"] as? String else { return nil }
        return (id, tool)
      })
  }

  @Test("manifest has correct plugin identity")
  func pluginIdentity() throws {
    let manifest = try loadManifest()
    #expect(manifest["plugin_id"] as? String == "osaurus.reminders")
  }

  @Test("manifest declares expected reminder tools")
  func toolIDs() throws {
    let map = try toolMap(from: loadManifest())
    #expect(
      Set(map.keys)
        == ["get_reminders", "search_reminders", "create_reminder", "get_lists", "open_reminder"])
  }

  @Test("manifest keeps reminder and automation requirements distinct")
  func requirements() throws {
    let map = try toolMap(from: loadManifest())
    for id in ["get_reminders", "search_reminders", "create_reminder", "get_lists"] {
      #expect(map[id]?["requirements"] as? [String] == ["reminders"])
    }
    #expect(map["open_reminder"]?["requirements"] as? [String] == ["automation"])
  }

  @Test("all reminder tools require approval")
  func permissionPolicies() throws {
    let map = try toolMap(from: loadManifest())
    for (id, tool) in map {
      #expect(tool["permission_policy"] as? String == "ask", "Tool '\(id)' should ask")
    }
  }

  @Test("mutating and search tools declare required parameters")
  func requiredParameters() throws {
    let map = try toolMap(from: loadManifest())

    let searchParams = map["search_reminders"]?["parameters"] as? [String: Any]
    let searchRequired = searchParams?["required"] as? [String] ?? []
    #expect(searchRequired.contains("searchText"))

    let createParams = map["create_reminder"]?["parameters"] as? [String: Any]
    let createRequired = createParams?["required"] as? [String] ?? []
    #expect(createRequired.contains("title"))
  }
}
