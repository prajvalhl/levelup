import PrototypeSupport
import XCTest

final class StartupControlTests: XCTestCase {
    func testSignalDuringStartupDefersCleanupUntilStartupUnwinds() {
        let control = StartupControl()
        XCTAssertFalse(control.requestStop("SIGINT"))
        XCTAssertEqual(control.cancellationReason(), "SIGINT")
        XCTAssertEqual(control.completeStartup(), "SIGINT")
        XCTAssertFalse(control.requestStop("second signal"))
    }

    func testStartupTimeoutRequestsCancellationAndCleanupAfterStartReturns() {
        let control = StartupControl()
        XCTAssertEqual(control.requestStartupTimeout(), true)
        XCTAssertEqual(control.cancellationReason(), "startup deadline expired")
        XCTAssertEqual(control.completeStartup(), "startup deadline expired")
        XCTAssertNil(control.requestStartupTimeout())
    }

    func testSignalAfterStartupSchedulesCleanupOnce() {
        let control = StartupControl()
        XCTAssertNil(control.completeStartup())
        XCTAssertTrue(control.requestStop("SIGTERM"))
        XCTAssertFalse(control.requestStop("SIGINT"))
    }

    func testTimeoutDoesNotOverwriteEarlierSignal() {
        let control = StartupControl()
        XCTAssertFalse(control.requestStop("SIGINT"))
        XCTAssertEqual(control.requestStartupTimeout(), false)
        XCTAssertEqual(control.cancellationReason(), "SIGINT")
    }
}
