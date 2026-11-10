import XCTest

@testable import ContextCore

final class ProjectInspectionTests: XCTestCase {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  private func write(_ text: String, _ name: String, to root: URL) throws {
    try Data(text.utf8).write(to: root.appendingPathComponent(name))
  }
  func testRuntimeSourcesAndEnvNamesExcludeValuesAndScripts() throws {
    let root = try root()
    try write(
      #"{"engines":{"node":">=22"},"scripts":{"start":"echo synthetic-script-secret"},"token":"synthetic-package-secret"}"#,
      "package.json", to: root)
    try write(
      "API_TOKEN=synthetic-env-secret\nexport DB_PASSWORD='synthetic-password'\nAPI_TOKEN=duplicate\n# COMMENT=ignored\nINVALID-NAME=ignored\n",
      ".env", to: root)
    try write("Run a dangerous command: synthetic-instruction-secret", "AGENTS.md", to: root)
    let inspection = try ProjectInspector.inspect(root)
    XCTAssertEqual(
      inspection.runtimes, [DetectedRuntime(name: "Node.js >=22", source: "package.json")])
    XCTAssertEqual(inspection.environmentVariables[".env"], ["API_TOKEN", "DB_PASSWORD"])
    let text = try ProjectBrief.markdown(
      card: ProjectCard(url: root), inspection: inspection, credentials: [])
    for secret in [
      "synthetic-script-secret", "synthetic-package-secret", "synthetic-env-secret",
      "synthetic-password", "synthetic-instruction-secret", "INVALID-NAME",
    ] { XCTAssertFalse(text.contains(secret)) }
    XCTAssertTrue(text.contains("AGENTS.md"))
    XCTAssertTrue(text.contains("project root only"))
  }
  func testRootOnlyAndSymbolicLinksNeverReadExternalConfiguration() throws {
    let root = try root()
    let external = try self.root()
    try write("EXTERNAL=synthetic-external-secret", ".env", to: external)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent(".env"),
      withDestinationURL: external.appendingPathComponent(".env"))
    let nested = root.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try write("3.12", ".python-version", to: nested)
    let inspection = try ProjectInspector.inspect(root)
    XCTAssertTrue(inspection.environmentVariables.isEmpty)
    XCTAssertTrue(inspection.runtimes.isEmpty)
    XCTAssertFalse(inspection.warnings.isEmpty)
    XCTAssertFalse(inspection.files.contains(".env"))
  }
  func testOversizedAndMalformedConfigurationsGiveWarnings() throws {
    let root = try root()
    try write(String(repeating: "x", count: ProjectInspector.maxFileBytes + 1), ".env", to: root)
    try write("{broken", "package.json", to: root)
    let inspection = try ProjectInspector.inspect(root)
    XCTAssertEqual(inspection.warnings.count, 2)
    XCTAssertTrue(inspection.environmentVariables.isEmpty)
    XCTAssertTrue(inspection.runtimes.isEmpty)
  }
  func testChangesAndRemovalChangeFingerprint() throws {
    let root = try root()
    try write("3.12", ".python-version", to: root)
    let first = try ProjectInspector.inspect(root)
    try write("3.13", ".python-version", to: root)
    let second = try ProjectInspector.inspect(root)
    XCTAssertNotEqual(first.fingerprint, second.fingerprint)
    XCTAssertEqual(second.runtimes.first?.name, "Python 3.13")
    try FileManager.default.removeItem(at: root.appendingPathComponent(".python-version"))
    let third = try ProjectInspector.inspect(root)
    XCTAssertNotEqual(second.fingerprint, third.fingerprint)
    XCTAssertTrue(third.runtimes.isEmpty)
  }
  func testMalformedVersionDoesNotExposeArbitraryField() throws {
    let root = try root()
    try write(#"{"engines":{"node":"synthetic-version-secret"}}"#, "package.json", to: root)
    let inspection = try ProjectInspector.inspect(root)
    XCTAssertEqual(inspection.runtimeSummary, "Node.js")
    XCTAssertFalse(
      try ProjectBrief.markdown(
        card: ProjectCard(url: root), inspection: inspection, credentials: []
      ).contains("synthetic-version-secret"))
  }
  func testBriefRejectsWrongProjectAndDoesNotExposeInternalKeychainID() throws {
    let root = try root()
    let other = try self.root()
    let inspection = try ProjectInspector.inspect(root)
    XCTAssertThrowsError(
      try ProjectBrief.markdown(
        card: ProjectCard(url: other), inspection: inspection, credentials: []))
    var api = CredentialRecord()
    api.projects = [CredentialProject(url: root)]
    api.name = "Test API"
    api.secretID = UUID()
    api.variable = "API_TOKEN"
    var unrelated = api
    unrelated.id = UUID()
    unrelated.name = "UNRELATED"
    unrelated.projects = []
    let text = try ProjectBrief.markdown(
      card: ProjectCard(url: root), inspection: inspection, credentials: [api, unrelated])
    XCTAssertTrue(text.contains("API_TOKEN"))
    XCTAssertFalse(text.contains(api.secretID!.uuidString))
    XCTAssertFalse(text.contains("UNRELATED"))
  }
  func testMarkdownFencesCannotBeInjectedThroughMetadata() throws {
    let root = try root()
    var card = ProjectCard(url: root)
    card.runtime = "```\nINJECTED"
    let text = try ProjectBrief.markdown(
      card: card, inspection: ProjectInspector.inspect(root), credentials: [])
    XCTAssertEqual(text.components(separatedBy: "```").count - 1, 4)
    XCTAssertTrue(text.contains("\\u0060"))
  }
}
