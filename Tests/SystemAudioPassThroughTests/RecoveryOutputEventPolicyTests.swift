import PrototypeSupport
import XCTest

final class RecoveryOutputEventPolicyTests: XCTestCase {
    func testDeviceListNotificationDuringConnectingDoesNotCancelStartupByItself() {
        XCTAssertFalse(RecoveryOutputEventPolicy.cancelsConnectingStartup(for: .deviceListChanged))
    }

    func testDefaultOutputNotificationDuringConnectingStillCancelsStartup() {
        XCTAssertTrue(RecoveryOutputEventPolicy.cancelsConnectingStartup(for: .defaultOutputChanged))
    }

    func testActiveOutputAliveNotificationDuringConnectingStillCancelsStartup() {
        XCTAssertTrue(RecoveryOutputEventPolicy.cancelsConnectingStartup(for: .activeDeviceAliveChanged))
    }

    func testAggregateCreationDeviceListEventDoesNotCancelUnchangedOutputRecovery() {
        let expected = OutputDeviceIdentity(deviceID: 144,
                                            uid: "98-47-44-02-D8-8B",
                                            formatFingerprint: "44100-stereo-f32")
        let resolvedAfterAggregateCreation = expected

        XCTAssertFalse(RecoveryOutputEventPolicy.cancelsConnectingStartup(for: .deviceListChanged))
        XCTAssertEqual(resolvedAfterAggregateCreation, expected)
    }

    func testStopAndQuitIntentStillPrecludeRecoveryAfterDeviceListEvent() throws {
        for shouldQuit in [false, true] {
            var reducer = SessionLifecycleReducer()
            let initialGeneration = try XCTUnwrap(reducer.beginStart())
            XCTAssertTrue(reducer.startupSucceeded(generation: initialGeneration))
            XCTAssertTrue(reducer.recordOutputChange(generation: reducer.generation))

            // A device-list event is settling-invalidating but does not cancel
            // recovery startup. User intent remains the higher-priority gate.
            XCTAssertFalse(RecoveryOutputEventPolicy.cancelsConnectingStartup(for: .deviceListChanged))
            if shouldQuit {
                reducer.requestQuit()
            } else {
                reducer.requestStop()
            }
            XCTAssertNil(reducer.beginRecoveryAttempt())
        }
    }
}
