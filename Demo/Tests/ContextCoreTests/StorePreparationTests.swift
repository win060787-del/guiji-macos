import Foundation
import XCTest
@testable import ContextCore

final class StorePreparationTests: XCTestCase {
    func testMissingPermissionDoesNotAssumeSavedPathIsAuthorized() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmarks = ProjectBookmarks(file: root.appendingPathComponent("bookmarks.json"))
        do { _ = try await bookmarks.acquire(URL(fileURLWithPath: "/Users/demo/project")); XCTFail("A path is not a sandbox capability") }
        catch ProjectAccessError.authorizationRequired {}
        let direct = try await bookmarks.acquire(root, required: false)
        XCTAssertEqual(direct.url, root.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testCorruptPermissionFileIsNotOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("bookmarks.json"), original = Data("broken-record".utf8)
        try original.write(to: url)
        let bookmarks = ProjectBookmarks(file: url)
        do { _ = try await bookmarks.acquire(root, selected: true); XCTFail("Should preserve corrupt capability store") }
        catch ProjectAccessError.corrupt {}
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testUnresolvableBookmarkRequestsAuthorization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("bookmarks.json")
        let requested = root.standardizedFileURL.resolvingSymlinksInPath()
        try JSONEncoder().encode([requested.path: Data([0, 1, 2])]).write(to: file)
        do { _ = try await ProjectBookmarks(file: file).acquire(requested); XCTFail("Invalid capabilities must not fall back to a raw path") }
        catch ProjectAccessError.authorizationRequired {}
    }
    func testContainerEndpointLengthAndLegacyIsolation() {
        let home = URL(fileURLWithPath: "/Users/demo/Library/Containers/com.novatechai.context/Data")
        let fallback = home.appendingPathComponent("Library/Application Support/NovaContextDemo")
        let url = ServiceEndpoint.socket(home: home, fallback: fallback, sandboxed: true)
        XCTAssertTrue(ServiceEndpoint.fits(url)); XCTAssertTrue(url.path.hasPrefix(home.path + "/tmp/"))
        XCTAssertFalse(ServiceEndpoint.fits(fallback.appendingPathComponent("Service/api.sock")))
        XCTAssertEqual(ServiceEndpoint.socket(home: home, fallback: fallback, sandboxed: false), fallback.appendingPathComponent("Service/api.sock"))
        XCTAssertFalse(ServiceEndpoint.fits(URL(fileURLWithPath: "/" + String(repeating: "中", count: 35))))
    }
}
