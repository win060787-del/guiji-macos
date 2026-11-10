import XCTest
@testable import ContextCore

final class DirectoryScanTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func write(_ path: String, root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
    }
    func testLargeFirstChildDoesNotHideRootFilesOrSiblingFolders() throws {
        let root = try fixture()
        for index in 0..<15 { try write("work2/deep/\(index).txt", root: root) }
        try write("other-project/README.md", root: root)
        try write("AGENTS.md", root: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let result = try ProjectFiles.scan(root, maxFiles: 3, maxEntries: 50)
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(result.files.contains { $0.path == "AGENTS.md" })
        XCTAssertTrue(result.files.contains { $0.path == "other-project/README.md" })
        XCTAssertTrue(Set(result.directories).isSuperset(of: ["work2", "work2/deep", "other-project", "empty"]))
    }
    func testEntryBudgetIsSpentOnRootBeforeDeepFiles() throws {
        let root = try fixture()
        for index in 0..<20 { try write("a-large/\(index).txt", root: root) }
        try write("z-other/README.md", root: root)
        try write("README.md", root: root)
        let result = try ProjectFiles.scan(root, maxFiles: 10, maxEntries: 6)
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(result.directories.contains("z-other"))
        XCTAssertTrue(result.files.contains { $0.path == "README.md" })
    }
    func testSubdirectoryCanBeReadSeparatelyAfterInitialBudget() throws {
        let root = try fixture()
        for index in 0..<5 { try write("a-large/\(index).txt", root: root) }
        try write("z-other/nested/config.json", root: root)
        let initial = try ProjectFiles.scan(root, maxFiles: 1, maxEntries: 30)
        XCTAssertTrue(initial.truncated)
        let sub = try ProjectFiles.checkedURL(root: root, path: "z-other")
        let loaded = try ProjectFiles.scan(sub)
        XCTAssertFalse(loaded.truncated)
        XCTAssertEqual(loaded.files.map(\.path), ["nested/config.json"])
    }
    func testExactlyAtFileLimitIsCompleteAndUnsafeEntriesStayExcluded() throws {
        let root = try fixture(), outside = try fixture()
        try write("README.md", root: root); try write("node_modules/ignored.js", root: root)
        try write("id_rsa", root: root); try write("outside.txt", root: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let result = try ProjectFiles.scan(root, maxFiles: 1, maxEntries: 20)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.files.map(\.path), ["README.md"])
        XCTAssertTrue(result.directories.isEmpty)
    }
    func testDefaultCapacityIndexesMoreThanPreviousFiveThousandLimit() throws {
        let root = try fixture()
        for index in 0..<5_010 { try write("files/\(index).txt", root: root) }
        try write("README.md", root: root)
        let result = try ProjectFiles.scan(root)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.files.count, 5_011)
    }
    func testUnknownStoredCapacityFallsBackAndKnownCapacityRestores() {
        XCTAssertEqual(ScanCapacity(storedValue: nil), .maximum)
        XCTAssertEqual(ScanCapacity(storedValue: "invalid"), .maximum)
        XCTAssertEqual(ScanCapacity(storedValue: ScanCapacity.maximum.rawValue), .maximum)
    }

    func testUpgradeMovesOldCapacityToMaximumOnceAndPreservesLaterChoices() throws {
        let suite = "NovaScanCapacityTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("20000", forKey: "indexCapacity")
        defaults.set("keep", forKey: "unrelated")
        XCTAssertEqual(ScanCapacity.load(from: defaults), .maximum)
        XCTAssertEqual(defaults.string(forKey: "indexCapacity"), "100000")
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
        defaults.set("50000", forKey: "indexCapacity")
        XCTAssertEqual(ScanCapacity.load(from: defaults), .expanded)
    }

}
