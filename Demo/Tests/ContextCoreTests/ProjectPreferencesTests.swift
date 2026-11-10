import XCTest
@testable import ContextCore

final class ProjectPreferencesTests: XCTestCase {
    private func configURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("project.json")
    }
    func testRetiredWorkflowBackedUpAndManualPinsPreserved() throws {
        let url = try configURL()
        let legacy = Data(#"{"pins":["docs/PRD.md"],"selected":["README.md"],"task":"legacy fixture","lastOpened":{},"expandedFolders":["docs"]}"#.utf8)
        try legacy.write(to: url)
        let preferences = try XCTUnwrap(ProjectPreferences.load(from: url))
        XCTAssertEqual(preferences.pins, ["docs/PRD.md"])
        XCTAssertEqual(preferences.expandedFolders, ["docs"])
        let backup = url.deletingPathExtension().appendingPathExtension("before-simplification.json")
        XCTAssertEqual(try Data(contentsOf: backup), legacy)
        let clean = try JSONEncoder().encode(preferences)
        try clean.write(to: url, options: .atomic)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: clean) as? [String: Any])
        XCTAssertNil(fields["selected"]); XCTAssertNil(fields["task"])
        XCTAssertEqual(try ProjectPreferences.load(from: url)?.pins, ["docs/PRD.md"])
        XCTAssertEqual(try Data(contentsOf: backup), legacy)
    }
    func testNewProjectsStartWithoutAutomaticPins() throws {
        let url = try configURL()
        XCTAssertNil(try ProjectPreferences.load(from: url))
        XCTAssertTrue(ProjectPreferences().pins.isEmpty)
        let oldMinimal = Data(#"{"pins":["README.md"]}"#.utf8)
        let decoded = try JSONDecoder().decode(ProjectPreferences.self, from: oldMinimal)
        XCTAssertEqual(decoded.pins, ["README.md"])
        XCTAssertTrue(decoded.lastOpened.isEmpty)
        XCTAssertTrue(decoded.expandedFolders.isEmpty)
    }
    func testMalformedPreferenceRemainsUntouched() throws {
        let url = try configURL()
        let original = Data("broken json".utf8)
        try original.write(to: url)
        XCTAssertThrowsError(try ProjectPreferences.load(from: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("before-simplification.json").path))
    }
}
