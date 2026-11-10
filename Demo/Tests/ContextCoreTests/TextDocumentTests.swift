import XCTest
@testable import ContextCore

final class TextDocumentTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testTextAndSourceFormatsCanSaveWithoutRedaction() throws {
        let root = try root()
        for name in [
            "config.json", "data.jsonc", "note.txt", "config.yaml", "config.yml", "settings.toml", "app.ini", "app.conf", "table.csv", "table.tsv", "script.py", "main.ts", "Component.vue", "main.java", "app.swift", "Dockerfile", "Makefile",
            "NOTICE",
        ] {
            let url = root.appendingPathComponent(name)
            let original = Data([0xEF, 0xBB, 0xBF]) + Data("token=synthetic-value\r\n中文\r\n".utf8)
            try original.write(to: url)
            var document = try TextDocument(root: root, path: name)
            document.text += "update\r\n"; try document.save()
            XCTAssertEqual(try Data(contentsOf: url), original + Data("update\r\n".utf8), name)
            XCTAssertFalse(document.isDirty)
        }
    }
    func testJSONExternalChangeRetainsDraftAndDisk() throws {
        let root = try root(), name = "config.json"
        let url = root.appendingPathComponent(name)
        try Data("{\"enabled\":false}".utf8).write(to: url)
        var document = try TextDocument(root: root, path: name)
        document.text = "{\"enabled\":true}"
        let external = Data("{\"external\":true}".utf8); try external.write(to: url)
        XCTAssertThrowsError(try document.save())
        XCTAssertEqual(try Data(contentsOf: url), external)
        XCTAssertEqual(document.text, "{\"enabled\":true}"); XCTAssertTrue(document.isDirty)
    }
    func testEnvironmentOfficeAndBinaryFilesRemainProtected() throws {
        let root = try root()
        for name in [".env", ".env.local", "env", "prod.env", "notes.docx", "slides.pptx", "table.xlsx", "document.pdf", "image.png", "unknown.bin"] {
            let url = root.appendingPathComponent(name); let data = Data("fixture".utf8)
            try data.write(to: url)
            XCTAssertThrowsError(try TextDocument(root: root, path: name), name)
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
        for data in [Data([0xFF, 0xFE, 0x41, 0x00]), Data("text\0binary".utf8)] {
            try data.write(to: root.appendingPathComponent("binary.json"))
            XCTAssertThrowsError(try TextDocument(root: root, path: "binary.json"))
        }
    }
    func testExecutablePermissionsSurviveSave() throws {
        let root = try root(), url = root.appendingPathComponent("script.sh")
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        var document = try TextDocument(root: root, path: "script.sh")
        document.text += "# edited\n"; try document.save()
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o755)
    }
    func testOversizeSourceIsRejectedWithoutModification() throws {
        let root = try root(), url = root.appendingPathComponent("large.json")
        let data = Data(repeating: 65, count: 2_000_001); try data.write(to: url)
        XCTAssertThrowsError(try TextDocument(root: root, path: "large.json"))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}
