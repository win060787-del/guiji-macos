import XCTest
@testable import ContextCore

final class FileBrowserTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    private func date(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }
    private func file(_ path: String, size: Int = 0, modified: Date? = nil, created: Date? = nil) -> ProjectFile {
        ProjectFile(path: path, size: size, modified: modified ?? date(10, 27), created: created)
    }
    func testAgeCalendarCutoffs() {
        let now = date(10, 27)
        let expected: [(FileAge, Date)] = [(.sixMonths, date(4, 27)), (.threeMonths, date(7, 27)), (.oneMonth, date(9, 27)), (.oneWeek, date(10, 20)), (.threeDays, date(10, 24)), (.oneDay, date(10, 26))]
        XCTAssertNil(FileAge.all.cutoff(now: now, calendar: calendar))
        for (age, expected) in expected { XCTAssertEqual(age.cutoff(now: now, calendar: calendar), expected) }
    }
    func testOlderThanBoundaryAndDateField() {
        let files = [file("old.md", modified: date(10, 25), created: date(1, 1)), file("boundary.md", modified: date(10, 26)), file("new.md")]
        var filter = BrowserFilter(); filter.age = .oneDay
        XCTAssertEqual(filter.apply(files, now: date(10, 27), calendar: calendar).map(\.name), ["old.md"])
        filter.dateField = .opened
        XCTAssertEqual(filter.apply(files, opened: ["old.md": date(10, 27), "new.md": date(10, 24)], now: date(10, 27), calendar: calendar).map(\.name), ["new.md"])
        filter.dateField = .created; filter.age = .sixMonths
        XCTAssertEqual(filter.apply(files, now: date(10, 27), calendar: calendar).map(\.name), ["old.md"])
    }
    func testFormatMultiSelectAndOther() {
        let files = [file("rules.MD"), file(".env.local"), file("photo.HEIC"), file("archive.zip"), file("paper.docx"), file("book.xlsx"), file("slides.pptx"), file("app.test.ts"), file("README.txt"), file("report.pdf")]
        XCTAssertEqual(files.map(FileFormat.of), [.markdown, .configuration, .image, .other, .word, .spreadsheet, .presentation, .code, .text, .pdf])
        var filter = BrowserFilter(); filter.formats = [.markdown, .other]
        XCTAssertEqual(filter.apply(files).map(\.name), ["archive.zip", "rules.MD"])
        XCTAssertEqual(filter.apply(files, query: "RULES").map(\.name), ["rules.MD"])
    }
    func testSortsAndNeverOpenedLast() {
        let files = [file("file10.md", size: 10, modified: date(10, 25), created: date(1, 1)), file("file2.md", size: 100, modified: date(10, 24), created: date(2, 1)), file("other.md", size: 5)]
        var filter = BrowserFilter()
        XCTAssertEqual(filter.apply(files).map(\.name), ["file2.md", "file10.md", "other.md"])
        filter.sort = .size; filter.ascending = false
        XCTAssertEqual(filter.apply(files).map(\.size), [100, 10, 5])
        filter.sort = .created
        XCTAssertEqual(filter.apply(files).map(\.name), ["other.md", "file2.md", "file10.md"])
        filter.sort = .modified; filter.ascending = true
        XCTAssertEqual(filter.apply(files).map(\.name), ["file2.md", "file10.md", "other.md"])
        filter.sort = .opened
        let opened = ["file10.md": date(10, 27), "other.md": date(10, 26)]
        XCTAssertEqual(filter.apply(files, opened: opened).map(\.name), ["other.md", "file10.md", "file2.md"])
        filter.ascending = false
        XCTAssertEqual(filter.apply(files, opened: opened).map(\.name), ["file10.md", "other.md", "file2.md"])
    }
    func testFolderHierarchyExpandsOneLevelAndKeepsEmptyDirectories() {
        let index = DirectoryIndex(directories: ["empty", "src/nested"], files: [file("root.md"), file("src/main.swift"), file("src/nested/deep.md"), file("src2/other.md")])
        XCTAssertEqual(index.visible(expanded: []).map(\.path), ["empty", "src", "src2"])
        XCTAssertEqual(index.visible(expanded: ["src"]).map(\.path), ["empty", "src", "src/nested", "src2"])
        XCTAssertFalse(DirectoryIndex.contains(file("src2/other.md"), in: "src", recursively: true))
        XCTAssertTrue(DirectoryIndex.contains(file("src/nested/deep.md"), in: "src", recursively: true))
        XCTAssertFalse(DirectoryIndex.contains(file("src/nested/deep.md"), in: "src", recursively: false))
        XCTAssertTrue(DirectoryIndex.contains(file("root.md"), in: "", recursively: false))
    }
    func testScannerCapturesEmptyFoldersAndCreationDateWithoutSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("one/empty"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("one/doc.md")
        try Data("text".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: root.appendingPathComponent("one"))
        let scan = try ProjectFiles.scan(root)
        XCTAssertEqual(Set(scan.directories), ["one", "one/empty"])
        XCTAssertEqual(scan.files.map(\.path), ["one/doc.md"])
        XCTAssertEqual(try XCTUnwrap(scan.files.first).created.timeIntervalSince1970, try XCTUnwrap(source.resourceValues(forKeys: [.creationDateKey]).creationDate).timeIntervalSince1970, accuracy: 1)
    }
    func testHistoryRestoresFolderAndFilterTogether() {
        var filter = BrowserFilter(); filter.age = .oneWeek; filter.formats = [.pdf]; filter.sort = .size; filter.ascending = false
        let scoped = WorkspaceLocation(path: "docs/a.pdf", section: "项目文件", query: "a", folder: "docs", filter: filter)
        var history = NavigationHistory<WorkspaceLocation>()
        history.visit(scoped)
        history.visit(WorkspaceLocation(path: nil, section: "项目文件", query: "", folder: "empty"))
        XCTAssertEqual(history.back(), scoped)
        XCTAssertEqual(history.current?.filter.formats, [.pdf])
    }
}
