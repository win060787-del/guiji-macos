import XCTest
@testable import ContextCore

final class NavigationHistoryTests: XCTestCase {
    func testInitialVisitDisablesBothDirections() {
        var history = NavigationHistory<String>()
        XCTAssertNil(history.back())
        XCTAssertNil(history.forward())
        history.visit("README.md")
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
    }

    func testBackForwardAndBoundaryKeepCurrentPage() {
        var history = NavigationHistory<String>()
        ["README.md", "AGENTS.md", ".env"].forEach { history.visit($0) }
        XCTAssertEqual(history.back(), "AGENTS.md")
        XCTAssertEqual(history.back(), "README.md")
        XCTAssertNil(history.back())
        XCTAssertEqual(history.current, "README.md")
        XCTAssertEqual(history.forward(), "AGENTS.md")
        XCTAssertEqual(history.forward(), ".env")
        XCTAssertNil(history.forward())
        XCTAssertEqual(history.current, ".env")
    }

    func testRepeatedClickDoesNotCreateExtraVisitOrDiscardForwardPage() {
        var history = NavigationHistory<String>()
        history.visit("README.md")
        history.visit("README.md")
        XCTAssertFalse(history.canGoBack)
        history.visit("AGENTS.md")
        _ = history.back()
        history.visit("README.md")
        XCTAssertTrue(history.canGoForward)
    }

    func testOpeningNewFileAfterGoingBackRetiresForwardBranch() {
        var history = NavigationHistory<String>()
        ["README.md", "AGENTS.md", ".env"].forEach { history.visit($0) }
        _ = history.back()
        history.visit("PRD.md")
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.back(), "AGENTS.md")
        XCTAssertEqual(history.forward(), "PRD.md")
    }

    func testHistoryRestoresSectionAndSearchWithDocument() {
        var history = NavigationHistory<WorkspaceLocation>()
        let readme = WorkspaceLocation(path: "README.md", section: "项目文件", query: "")
        let filtered = WorkspaceLocation(path: "README.md", section: "项目文件", query: "README")
        let fixed = WorkspaceLocation(path: "AGENTS.md", section: "固定资料", query: "")
        history.visit(readme)
        history.replaceCurrent(filtered)
        history.visit(fixed)
        XCTAssertEqual(history.back(), filtered)
        XCTAssertEqual(history.forward(), fixed)
    }

    func testRefreshRemovesDeletedFilesAndKeepsCursorAtCurrentFile() {
        var history = NavigationHistory<String>()
        ["README.md", "removed.md", "AGENTS.md", ".env"].forEach { history.visit($0) }
        _ = history.back()
        history.retain { $0 != "removed.md" }
        XCTAssertEqual(history.current, "AGENTS.md")
        XCTAssertEqual(history.back(), "README.md")
        XCTAssertEqual(history.forward(), "AGENTS.md")
        XCTAssertEqual(history.forward(), ".env")
        history.retain { _ in false }
        XCTAssertNil(history.current)
        XCTAssertFalse(history.canGoBack)
        history.visit("new.md")
        XCTAssertEqual(history.current, "new.md")
    }

    func testLongHistoryRetainsRecent150Visits() {
        var history = NavigationHistory<Int>()
        for i in 0..<170 { history.visit(i) }
        var backCount = 0
        while history.back() != nil { backCount += 1 }
        XCTAssertEqual(backCount, 149)
        XCTAssertEqual(history.current, 20)
    }
}
