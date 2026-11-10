import XCTest
@testable import ContextCore

final class BrowserSnapshotTests: XCTestCase {
    private func files(_ count: Int, folders: Int = 100) -> [ProjectFile] {
        (0..<count).map { index in
            ProjectFile(path: String(format: "project-%03d/file-%06d.json", index % folders, index), size: index, modified: Date(timeIntervalSince1970: Double(index)))
        }
    }
    private func snapshot(
        _ index: BrowserIndex, query: String = "", expanded: Set<String> = [], page: Int = 0,
        fixed: Bool = false, pins: Set<String> = [], filter: BrowserFilter = BrowserFilter()
    ) throws -> BrowserSnapshot {
        try BrowserSnapshot.make(index: index, filter: filter, query: query, folder: "", fixed: fixed, pins: pins, expanded: expanded, opened: [:], page: page)
    }
    func testHundredThousandFilesOnlyPublishCollapsedFolders() throws {
        let start = Date()
        let index = BrowserIndex(files: files(100_000))
        let result = try snapshot(index)
        XCTAssertEqual(result.rows.count, 100)
        XCTAssertFalse(result.hasNext)
        XCTAssertTrue(result.rows.allSatisfy { $0.folder != nil })
        XCTAssertEqual(index.byPath["project-099/file-099999.json"]?.size, 99_999)
        print("100k metadata index + collapsed projection seconds: \(Date().timeIntervalSince(start))")
    }
    func testExpandedLargeDirectoryIsPagedWithoutDuplicateOrLostRows() throws {
        let index = BrowserIndex(files: files(1_001, folders: 1))
        var all: [BrowserRow] = [], page = 0
        while true {
            let result = try snapshot(index, expanded: ["project-000"], page: page)
            XCTAssertLessThanOrEqual(result.rows.count, BrowserSnapshot.pageSize)
            all += result.rows
            if !result.hasNext { break }; page += 1
        }
        XCTAssertEqual(all.count, 1_002)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertEqual(all.filter { $0.file != nil }.count, 1_001)
    }
    func testSearchMatchesAcrossUnexpandedDirectoriesAndKeepsPagesBounded() throws {
        let index = BrowserIndex(files: files(10_000))
        let first = try snapshot(index, query: ".json")
        let second = try snapshot(index, query: ".json", page: 1)
        XCTAssertEqual(first.rows.count, 200); XCTAssertTrue(first.hasNext)
        XCTAssertEqual(second.page, 1)
        XCTAssertTrue(Set(first.rows.map(\.id)).isDisjoint(with: second.rows.map(\.id)))
        let exact = try snapshot(index, query: "file-009999.json")
        XCTAssertEqual(exact.rows.first?.file?.size, 9_999)
        XCTAssertFalse(exact.hasNext)
    }
    func testPinnedFilterAndPageResetRemainCorrect() throws {
        let index = BrowserIndex(files: files(500))
        let pins: Set<String> = ["project-001/file-000001.json", "project-002/file-000002.json"]
        let result = try snapshot(index, page: 10, fixed: true, pins: pins)
        XCTAssertEqual(result.page, 0); XCTAssertEqual(result.rows.count, 2)
        var filter = BrowserFilter(); filter.formats = [.pdf]
        XCTAssertTrue(try snapshot(index, query: "file", filter: filter).rows.isEmpty)
    }
    func testHundredThousandFileSearchProjectsOnlyOnePage() throws {
        let index = BrowserIndex(files: files(100_000))
        let start = Date()
        let result = try snapshot(index, query: "file-")
        XCTAssertEqual(result.rows.count, 200); XCTAssertTrue(result.hasNext)
        print("100k matched metadata search projection seconds: \(Date().timeIntervalSince(start))")
    }
}
