import PrototypeSupport
import XCTest

final class OutputSelectionTests: XCTestCase {
    func testSameUIDWithChangedDeviceIDIsDifferentSelection() {
        var gate = OutputDeviceStabilityGate()
        XCTAssertFalse(gate.observe(snapshot(id: 7, uid: "usb-a"), revision: 1))
        XCTAssertFalse(gate.observe(snapshot(id: 29, uid: "usb-a"), revision: 1))
        XCTAssertTrue(gate.observe(snapshot(id: 29, uid: "usb-a"), revision: 1))
    }

    func testNewOutputEventInvalidatesPreviousSettlingResult() {
        var gate = OutputDeviceStabilityGate()
        let current = snapshot(id: 8, uid: "speaker")
        XCTAssertFalse(gate.observe(current, revision: 3))
        XCTAssertTrue(gate.observe(current, revision: 3))
        XCTAssertFalse(gate.accepts(revision: 4))
        XCTAssertFalse(gate.observe(current, revision: 4))
    }

    func testInvalidTemporarySnapshotResetsStability() {
        var gate = OutputDeviceStabilityGate()
        XCTAssertFalse(gate.observe(snapshot(id: 3, uid: "bt"), revision: 1))
        XCTAssertFalse(gate.observe(snapshot(id: 3, uid: "bt", alive: false), revision: 1))
        XCTAssertFalse(gate.observe(snapshot(id: 3, uid: "bt"), revision: 1))
        XCTAssertTrue(gate.observe(snapshot(id: 3, uid: "bt"), revision: 1))
    }

    func testNonDefaultReconnectDoesNotChangeCurrentSelection() {
        var gate = OutputDeviceStabilityGate()
        let currentDefault = snapshot(id: 1, uid: "built-in")
        XCTAssertFalse(gate.observe(currentDefault, revision: 1))
        XCTAssertTrue(gate.observe(currentDefault, revision: 1))
        // A device-list event can represent a non-default reconnect. Once the
        // current default is re-resolved and remains stable, it stays selected.
        gate.invalidate(revision: 2)
        XCTAssertFalse(gate.observe(currentDefault, revision: 2))
        XCTAssertTrue(gate.observe(currentDefault, revision: 2))
        XCTAssertFalse(currentDefault.requiresRouteReplacement(comparedTo: currentDefault.identity))
    }

    func testReadinessRejectsMissingListAliveStreamsAndUnsupportedFormat() {
        XCTAssertEqual(snapshot(id: 1, uid: "x", listed: false).unavailableReason,
                       "The default output is not present in Core Audio's device list.")
        XCTAssertEqual(snapshot(id: 1, uid: "x", alive: false).unavailableReason,
                       "The default output device is not currently available.")
        XCTAssertEqual(snapshot(id: 1, uid: "x", streams: 0).unavailableReason,
                       "The default output device has no output streams.")
        XCTAssertEqual(snapshot(id: 1, uid: "x", floatPCM: false).unavailableReason,
                       "The default output format is not supported Float32 PCM.")
        XCTAssertTrue(snapshot(id: 1, uid: "x", listed: false)
            .requiresRouteReplacement(comparedTo: OutputDeviceIdentity(deviceID: 1,
                                                                         uid: "x",
                                                                         formatFingerprint: "48k-stereo-f32")))
    }

    func testSilentButOperationalRoutePassesHealthGate() {
        var health = RouteHealthGate(requiredProgressSamples: 2)
        XCTAssertFalse(health.observe(aggregateRunning: false, callbackCount: 1))
        XCTAssertFalse(health.observe(aggregateRunning: true, callbackCount: 1))
        XCTAssertFalse(health.observe(aggregateRunning: true, callbackCount: 2))
        // Callback count continues while captured peaks may remain exactly zero.
        XCTAssertTrue(health.observe(aggregateRunning: true, callbackCount: 3))
    }

    private func snapshot(id: UInt32,
                          uid: String,
                          listed: Bool = true,
                          alive: Bool = true,
                          streams: Int = 1,
                          floatPCM: Bool = true) -> OutputDeviceSnapshot {
        OutputDeviceSnapshot(
            identity: OutputDeviceIdentity(deviceID: id, uid: uid, formatFingerprint: "48k-stereo-f32"),
            name: uid,
            isInDeviceList: listed,
            isAlive: alive,
            outputStreamCount: streams,
            nominalSampleRate: 48_000,
            channelCount: 2,
            isFloatPCM: floatPCM,
            bitsPerChannel: 32
        )
    }
}
