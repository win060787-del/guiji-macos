import XCTest
import Foundation
import AppKit
import PDFKit
import ZIPFoundation
@testable import ContextCore

final class WorkspaceTests: XCTestCase {
    func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NovaContextTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    func write(_ text: String, _ name: String, _ root: URL) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func testEnvironmentValuesNeverReachPreview() throws {
        let root = try folder()
        try write("PUBLIC_URL=https://demo.invalid\nAPI_KEY=fixture-private-value\n# secret comment\nexport DATABASE_URL=postgres://demo:password@host/db\nBAD CONTINUATION", ".env.local", root)
        let files = try ProjectFiles.scan(root).files
        let preview = try ProjectFiles.text(root: root, file: XCTUnwrap(files.first))
        for result in [preview.text] {
            for forbidden in ["fixture-private-value", "https://demo.invalid", "secret comment", "postgres://", "BAD CONTINUATION"] { XCTAssertFalse(result.contains(forbidden), forbidden) }
            XCTAssertTrue(result.contains("API_KEY=[REDACTED]"))
            XCTAssertTrue(result.contains("DATABASE_URL=[REDACTED]"))
        }
    }
    func testOrdinaryTextCredentialsAreRedacted() throws {
        let input =
            "Example\nlet password = \"private-fixture\"\n{\"nested\":{\"api_key\":\"fixture-123\"}}\nBearer abcd0123456789\nhttps://user:fixturepass@example.invalid\n-----BEGIN PRIVATE KEY-----\nfixture-material\n-----END PRIVATE KEY-----\nDone"
        let safe = SecretRedactor.redact(input).text
        for forbidden in ["private-fixture", "fixture-123", "abcd0123456789", "fixturepass", "fixture-material"] { XCTAssertFalse(safe.contains(forbidden), forbidden) }
        XCTAssertTrue(safe.contains("Done"))
    }
    func testScanSkipsBuildDirectoriesCredentialsAndSymlinks() throws {
        let root = try folder(); let outside = try folder()
        try write("read", "README.md", root)
        try write("ignored", "node_modules/a.md", root)
        try write("ignored", ".git/a.md", root)
        try write("private", "id_rsa", root)
        try write("private", "service.pem", root)
        try write("outside", "outside.md", outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        XCTAssertEqual(try ProjectFiles.scan(root).files.map(\.path), ["README.md"])
        XCTAssertThrowsError(try ProjectFiles.checkedURL(root: root, path: "../outside.md"))
        XCTAssertThrowsError(try ProjectFiles.checkedURL(root: root, path: "linked/outside.md"))
    }
    func testFileReplacedBySymlinkAfterScanIsRejected() throws {
        let root = try folder(); let outside = try folder()
        try write("read", "README.md", root); try write("private", "private.md", outside)
        let file = try XCTUnwrap(ProjectFiles.scan(root).files.first)
        try FileManager.default.removeItem(at: root.appendingPathComponent(file.path))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(file.path), withDestinationURL: outside.appendingPathComponent("private.md"))
        XCTAssertThrowsError(try ProjectFiles.text(root: root, file: file))
    }
    func testMarkdownFrontmatterTablesAndScriptProtection() {
        let html = MarkdownRenderer.html("---\nprivate: metadata\n---\n# Heading\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n<script>alert(1)</script>")
        XCTAssertTrue(html.contains("<table>")); XCTAssertTrue(html.contains("<h1>Heading</h1>"))
        XCTAssertFalse(html.contains("private: metadata")); XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertTrue(html.contains("img-src 'none'"))
    }
    func office(_ entries: [String: String], ext: String, root: URL) throws -> URL {
        let url = root.appendingPathComponent("fixture." + ext)
        let zip = try Archive(url: url, accessMode: .create)
        for (path, value) in entries {
            let data = Data(value.utf8)
            try zip.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), provider: { offset, length in data.subdata(in: Int(offset)..<(Int(offset) + length)) })
        }
        return url
    }
    func testDOCXConvertsHeadingsListsTablesAndRetainsSource() throws {
        let root = try folder()
        let url = try office(
            [
                "word/document.xml": """
                <w:document xmlns:w="urn:word"><w:body><w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>项目目标</w:t></w:r></w:p><w:p><w:pPr><w:numPr/></w:pPr><w:r><w:t>任务一</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>名称</w:t></w:r></w:p></w:tc></w:tr><w:tr><w:tc><w:p><w:r><w:t>Orbit</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>
                """
            ], ext: "docx", root: root)
        let before = try Data(contentsOf: url)
        let result = try DocumentConverter.convert(url)
        XCTAssertTrue(result.markdown.contains("## 项目目标")); XCTAssertTrue(result.markdown.contains("- 任务一")); XCTAssertTrue(result.markdown.contains("| Orbit |"))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
    func testXLSXHandlesSharedStringsSparseCellsAndEscapesPipes() throws {
        let root = try folder()
        let url = try office(
            [
                "xl/workbook.xml": "<workbook xmlns:r='urn:r'><sheets><sheet name='需求表' r:id='rId1'/></sheets></workbook>",
                "xl/_rels/workbook.xml.rels": "<Relationships><Relationship Id='rId1' Target='worksheets/sheet1.xml'/></Relationships>",
                "xl/sharedStrings.xml": "<sst><si><t>名称|状态</t></si></sst>",
                "xl/worksheets/sheet1.xml": "<worksheet><sheetData><row r='1'><c r='A1' t='s'><v>0</v></c><c r='C1' t='inlineStr'><is><t>第三列</t></is></c></row><row r='3'><c r='B3'><v>42</v></c></row></sheetData></worksheet>",
            ], ext: "xlsx", root: root)
        let result = try DocumentConverter.convert(url)
        XCTAssertTrue(result.markdown.contains("需求表")); XCTAssertTrue(result.markdown.contains("| A | B | C |"))
        XCTAssertTrue(result.markdown.contains("名称\\|状态")); XCTAssertTrue(result.markdown.contains("|  | 42 |  |"))
    }
    func testPPTXUsesPresentationOrderAndRejectsExternalRelations() throws {
        let root = try folder()
        let url = try office(
            [
                "ppt/presentation.xml": "<p:presentation xmlns:p='urn:p' xmlns:r='urn:r'><p:sldIdLst><p:sldId r:id='second'/><p:sldId r:id='first'/></p:sldIdLst></p:presentation>",
                "ppt/_rels/presentation.xml.rels": "<Relationships><Relationship Id='first' Target='slides/slide1.xml'/><Relationship Id='second' Target='slides/slide2.xml'/></Relationships>",
                "ppt/slides/slide1.xml": "<slide><p><t>第一张文件</t></p></slide>",
                "ppt/slides/slide2.xml": "<slide><p><t>实际先显示</t></p></slide>",
            ], ext: "pptx", root: root)
        let result = try DocumentConverter.convert(url).markdown
        XCTAssertLessThan(try XCTUnwrap(result.range(of: "实际先显示")?.lowerBound), try XCTUnwrap(result.range(of: "第一张文件")?.lowerBound))
        XCTAssertThrowsError(try OfficeArchive.resolve("../../private.xml", base: "ppt"))
        XCTAssertThrowsError(try OfficeArchive.resolve("https://example.invalid/x", base: "ppt"))
    }
    func testInvalidOfficeInputFailsClearly() throws {
        let root = try folder(); try write("not a zip", "broken.docx", root)
        XCTAssertThrowsError(try DocumentConverter.convert(root.appendingPathComponent("broken.docx")))
        try write("old binary", "old.doc", root)
        XCTAssertThrowsError(try DocumentConverter.convert(root.appendingPathComponent("old.doc")))
    }
    func testRealOfficeAndPDFDemoFixtures() throws {
        let demo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let references = demo.appendingPathComponent("Sources/NovaContext/Resources/SampleProject/references")
        for (name, expected) in [("需求说明.docx", "邮箱登录"), ("任务清单.xlsx", "失败重试"), ("产品概览.pptx", "首版目标"), ("Product-Brief.pdf", "Orbit Project Brief"), ("白板草图.png", "ORBIT PROJECT")] {
            let result = try DocumentConverter.convert(references.appendingPathComponent(name))
            XCTAssertTrue(result.markdown.contains(expected), name)
        }
    }
    func testEnglishSampleDocumentsConvertInEnglish() throws {
        let demo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let references = demo.appendingPathComponent("Sources/NovaContext/Resources/SampleProjectEnglish/references")
        for (file, expected) in [
            ("Requirements.docx", "Email sign-in"),
            ("Task-List.xlsx", "Retry after failure"),
            ("Product-Overview.pptx", "First release goals"),
            ("Product-Brief.pdf", "Orbit Project Brief"),
            ("Project-Notes.png", "Project environment settings"),
        ] {
            let result = try DocumentConverter.convert(references.appendingPathComponent(file))
            XCTAssertTrue(result.markdown.contains(expected), file)
        }
    }
    @MainActor func testPDFAndImageOCR() throws {
        let root = try folder()
        let image = NSImage(size: NSSize(width: 1000, height: 400))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 400).fill()
        ("NOVA CONTEXT\nProject documentation 2026" as NSString).draw(at: NSPoint(x: 60, y: 170), withAttributes: [.font: NSFont.systemFont(ofSize: 42), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let pngURL = root.appendingPathComponent("image.png"); try png.write(to: pngURL)
        let recognized = try DocumentConverter.convert(pngURL)
        XCTAssertTrue(recognized.markdown.contains("NOVA CONTEXT"))
        let page = try XCTUnwrap(PDFPage(image: image))
        let pdf = PDFDocument(); pdf.insert(page, at: 0)
        let pdfURL = root.appendingPathComponent("scan.pdf"); XCTAssertTrue(pdf.write(to: pdfURL))
        let result = try DocumentConverter.convert(pdfURL)
        XCTAssertTrue(result.markdown.contains(L("## 第 \(1) 页\n\n\("")"))); XCTAssertTrue(result.markdown.contains("NOVA CONTEXT"))
        XCTAssertTrue(result.warnings.contains { $0.contains("OCR") })
    }
}
