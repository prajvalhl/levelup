import PrototypeSupport
import XCTest

final class RouteCallbackWatchdogTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000

    func testFirstCallbacksAtExistingFiveSecondBoundaryAreAccepted() {
        var watchdog = RouteCallbackWatchdog()
        watchdog.start(generation: 4, nowNanoseconds: 0)

        XCTAssertEqual(watchdog.observe(generation: 4, callbackCount: 0, nowNanoseconds: 5 * second), .waiting)
        XCTAssertEqual(watchdog.observe(generation: 4, callbackCount: 1, nowNanoseconds: 5 * second), .waiting)
        XCTAssertEqual(watchdog.observe(generation: 4, callbackCount: 2, nowNanoseconds: 6 * second), .waiting)
    }

    func testFirstCallbacksShortlyAfterFiveSecondsFitWithinStartupGrace() {
        var watchdog = RouteCallbackWatchdog()
        watchdog.start(generation: 7, nowNanoseconds: 10 * second)

        XCTAssertEqual(watchdog.observe(generation: 7, callbackCount: 0, nowNanoseconds: 15 * second), .waiting)
        XCTAssertEqual(watchdog.observe(generation: 7, callbackCount: 0, nowNanoseconds: 17 * second), .waiting)
        XCTAssertEqual(watchdog.observe(generation: 7, callbackCount: 1, nowNanoseconds: 17_500_000_000), .waiting)
    }

    func testRouteThatNeverProducesCallbacksTimesOutAtBoundedAcquisitionDeadline() {
        var watchdog = RouteCallbackWatchdog()
        watchdog.start(generation: 2, nowNanoseconds: 1_000)

        XCTAssertEqual(watchdog.observe(generation: 2, callbackCount: 0, nowNanoseconds: 8_000_000_999), .waiting)
        XCTAssertEqual(watchdog.observe(generation: 2, callbackCount: 0, nowNanoseconds: 8_000_001_000),
                       .failed(.callbackAcquisitionTimedOut))
    }

    func testPreviouslyOperationalRouteTimesOutWhenCallbackProgressStops() {
        var watchdog = RouteCallbackWatchdog()
        watchdog.start(generation: 9, nowNanoseconds: 0)

        XCTAssertEqual(watchdog.observe(generation: 9, callbackCount: 1, nowNanoseconds: second), .waiting)
        XCTAssertEqual(watchdog.observe(generation: 9, callbackCount: 2, nowNanoseconds: 2 * second), .waiting)
        XCTAssertEqual(watchdog.observe(generation: 9, callbackCount: 2, nowNanoseconds: 6_999_999_999), .waiting)
        XCTAssertEqual(watchdog.observe(generation: 9, callbackCount: 2, nowNanoseconds: 7 * second),
                       .failed(.callbackProgressStalled))
    }

    func testOldWatchdogObservationIsStaleAfterReplacementOrCancellation() {
        var watchdog = RouteCallbackWatchdog()
        watchdog.start(generation: 11, nowNanoseconds: 0)
        watchdog.start(generation: 12, nowNanoseconds: second)

        XCTAssertEqual(watchdog.observe(generation: 11, callbackCount: 0, nowNanoseconds: 20 * second), .stale)
        XCTAssertEqual(watchdog.observe(generation: 12, callbackCount: 0, nowNanoseconds: 8 * second), .waiting)
        watchdog.cancel()
        XCTAssertEqual(watchdog.observe(generation: 12, callbackCount: 0, nowNanoseconds: 20 * second), .stale)
    }

    func testMonotonicTimestampRegressionDoesNotTriggerPrematureFailure() {
        var watchdog = RouteCallbackWatchdog()
        watchdog.start(generation: 3, nowNanoseconds: 5 * second)

        XCTAssertEqual(watchdog.observe(generation: 3, callbackCount: 0, nowNanoseconds: 4 * second), .waiting)
    }
}
