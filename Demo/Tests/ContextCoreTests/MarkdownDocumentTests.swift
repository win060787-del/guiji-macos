import XCTest
@testable import ContextCore

final class MarkdownDocumentTests: XCTestCase {
    private func fixture(_ data: Data) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try data.write(to: root.appendingPathComponent("note.md"))
        return root
    }
    func testUTF8SavePreservesUnredactedContentAndBOM() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("# 日记\r\nAPI_KEY=private-fixture\r\n".utf8)
        let root = try fixture(original)
        var document = try MarkdownDocument(root: root, path: "note.md")
        XCTAssertFalse(document.isDirty)
        document.text += "新内容\r\n"
        XCTAssertTrue(document.isDirty)
        try document.save()
        XCTAssertFalse(document.isDirty)
        let saved = try Data(contentsOf: root.appendingPathComponent("note.md"))
        XCTAssertTrue(saved.starts(with: [0xEF, 0xBB, 0xBF]))
        XCTAssertTrue(String(decoding: saved, as: UTF8.self).contains("API_KEY=private-fixture\r\n"))
        XCTAssertTrue(String(decoding: saved, as: UTF8.self).contains("新内容"))
    }
    func testExternalChangesAreNeverOverwritten() throws {
        let root = try fixture(Data("original".utf8))
        var document = try MarkdownDocument(root: root, path: "note.md")
        document.text = "draft"
        try Data("external".utf8).write(to: root.appendingPathComponent("note.md"), options: .atomic)
        XCTAssertThrowsError(try document.save())
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8), "external")
        XCTAssertEqual(document.text, "draft")
        XCTAssertTrue(document.isDirty)
    }
    func testReplacedSymlinkCannotBeSaved() throws {
        let root = try fixture(Data("original".utf8))
        let outside = root.appendingPathComponent("outside.txt")
        try Data("untouched".utf8).write(to: outside)
        var document = try MarkdownDocument(root: root, path: "note.md")
        document.text = "draft"
        try FileManager.default.removeItem(at: root.appendingPathComponent("note.md"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("note.md"), withDestinationURL: outside)
        XCTAssertThrowsError(try document.save())
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched")
    }
    func testUndoToOriginalIsClean() throws {
        let root = try fixture(Data("# original\n".utf8))
        var document = try MarkdownDocument(root: root, path: "note.md")
        document.text += "change"
        document.text = document.savedText
        XCTAssertFalse(document.isDirty)
        try document.save()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("note.md")), Data("# original\n".utf8))
    }
    func testNonUTF8AndEnvironmentRemainProtected() throws {
        let root = try fixture(Data([0xFF, 0xFE, 0x41, 0x00]))
        XCTAssertThrowsError(try MarkdownDocument(root: root, path: "note.md"))
        try Data("KEY=secret".utf8).write(to: root.appendingPathComponent(".env"))
        XCTAssertThrowsError(try MarkdownDocument(root: root, path: ".env"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("note.md")), Data([0xFF, 0xFE, 0x41, 0x00]))
    }
}
