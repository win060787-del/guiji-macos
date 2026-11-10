import XCTest

@testable import ContextCore

final class ProjectLibraryTests: XCTestCase {
  private func location() -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root.appendingPathComponent("cards.json")
  }
  func testReopenDeduplicatesAndPreservesConfiguration() async throws {
    let file = location()
    let root = URL(fileURLWithPath: "/tmp/card-project")
    let library = ProjectLibrary(url: file)
    let initial = try await library.visit(root)
    var card = try XCTUnwrap(initial.first)
    card.name = "My project"
    card.runtime = "Node.js 22"
    card.environment = "测试"
    _ = try await library.save(card)
    let revisited = try await library.visit(root.appendingPathComponent("."))
    XCTAssertEqual(revisited.count, 1)
    let persisted = try await ProjectLibrary(url: file).records()
    XCTAssertEqual(persisted.first?.name, "My project")
    XCTAssertEqual(persisted.first?.runtime, "Node.js 22")
    XCTAssertEqual(persisted.first?.environment, "测试")
    let permission =
      try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    XCTAssertEqual(permission, 0o600)
  }
  func testRemovalNeverDeletesProjectFilesAndStaleSaveFails() async throws {
    let file = location()
    let root = file.deletingLastPathComponent().appendingPathComponent("project")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let document = root.appendingPathComponent("README.md")
    try Data("preserve".utf8).write(to: document)
    let library = ProjectLibrary(url: file)
    let cards = try await library.visit(root)
    _ = try await library.remove(cards[0].path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: document.path))
    do {
      _ = try await library.save(cards[0])
      XCTFail("Removed card must not reappear")
    } catch {}
  }
  func testCorruptLibraryIsNotOverwritten() async throws {
    let file = location()
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("invalid-json".utf8)
    try original.write(to: file)
    let library = ProjectLibrary(url: file)
    do {
      _ = try await library.visit(URL(fileURLWithPath: "/tmp/another-project"))
      XCTFail()
    } catch {}
    XCTAssertEqual(try Data(contentsOf: file), original)
  }
  func testExportIncludesOnlyMatchingProjectConfigurationAndReferences() throws {
    let root = URL(fileURLWithPath: "/tmp/card-export")
    var card = ProjectCard(url: root)
    card.environment = "生产"
    card.runtime = "Python 3.12"
    var record = CredentialRecord()
    record.name = "API"
    record.variable = "API_TOKEN"
    record.projects = [CredentialProject(url: root)]
    record.secretID = UUID()
    var other = record
    other.id = UUID()
    other.name = "Other project"
    other.projects = []
    let data = try CredentialVault.environmentDescription(
      records: [record, other], project: CredentialProject(url: root), configuration: card)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["runtime"] as? String, "Python 3.12")
    XCTAssertEqual(object["environment"] as? String, "生产")
    XCTAssertEqual((object["credentials"] as? [[String: Any]])?.count, 1)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(record.secretID!.uuidString))
    let unrelated = try CredentialVault.environmentDescription(
      records: [], project: CredentialProject(url: URL(fileURLWithPath: "/tmp/other")),
      configuration: card)
    XCTAssertFalse(String(decoding: unrelated, as: UTF8.self).contains("Python 3.12"))
  }
}
