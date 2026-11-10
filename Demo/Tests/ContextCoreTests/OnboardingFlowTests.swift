import XCTest
@testable import ContextCore
final class OnboardingFlowTests: XCTestCase {
    func testProjectSelectionRequiredAndBackPreservesFlow() {
        var flow = OnboardingFlow()
        XCTAssertEqual(flow.step, .language)
        XCTAssertTrue(flow.next(hasProject: false)); XCTAssertEqual(flow.step, .project)
        XCTAssertFalse(flow.next(hasProject: false)); XCTAssertEqual(flow.step, .project)
        XCTAssertTrue(flow.next(hasProject: true)); XCTAssertEqual(flow.step, .appearance)
        flow.back(); XCTAssertEqual(flow.step, .project)
        XCTAssertFalse(flow.completed)
    }
    func testFinishAndSkipAreTerminal() {
        var flow = OnboardingFlow()
        for _ in 0..<4 { XCTAssertTrue(flow.next(hasProject: true)) }
        XCTAssertTrue(flow.completed); XCTAssertFalse(flow.next(hasProject: true))
        flow.back(); XCTAssertEqual(flow.step, .access)
        var skipped = OnboardingFlow(); skipped.skip()
        XCTAssertTrue(skipped.completed); XCTAssertFalse(skipped.next(hasProject: false))
    }
}
