import PrototypeSupport
import XCTest

final class SessionCleanupDecisionTests: XCTestCase {
    func testQuitDuringApplyWinsAndConsumesQuitRequest() {
        var quitRequested = true

        let decision = SessionCleanupDecision.resolve(restartAfter: true, quitRequested: &quitRequested)

        XCTAssertEqual(decision, .quit)
        XCTAssertFalse(quitRequested)
    }

    func testApplyRestartsWhenQuitWasNotRequested() {
        var quitRequested = false

        let decision = SessionCleanupDecision.resolve(restartAfter: true, quitRequested: &quitRequested)

        XCTAssertEqual(decision, .restart)
        XCTAssertFalse(quitRequested)
    }

    func testNormalStopDoesNotCarryAQuitRequestForward() {
        var quitRequested = false

        let decision = SessionCleanupDecision.resolve(restartAfter: false, quitRequested: &quitRequested)

        XCTAssertEqual(decision, .stopped)
        XCTAssertFalse(quitRequested)
    }
}
