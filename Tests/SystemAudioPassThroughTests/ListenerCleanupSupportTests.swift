import Dispatch
import PrototypeSupport
import XCTest

final class ListenerCleanupSupportTests: XCTestCase {
    func testRouteStopAndActiveListenerRemovalRunOnControlQueue() {
        let controlQueue = DispatchQueue(label: "test.levelup.audio-control")
        let queueKey = DispatchSpecificKey<String>()
        controlQueue.setSpecific(key: queueKey, value: "audio-control")
        let completion = expectation(description: "cleanup completion delivered")

        StartupAttemptCleanup.enqueue(on: controlQueue,
                                      stopRoute: {
                                          XCTAssertEqual(DispatchQueue.getSpecific(key: queueKey), "audio-control")
                                          return (true, nil)
                                      },
                                      removeActiveListener: {
                                          XCTAssertEqual(DispatchQueue.getSpecific(key: queueKey), "audio-control")
                                          return nil
                                      }) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(result.isComplete)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
    }

    func testStartupCompletionHandoffKeepsFinishStartPublicationOnMainActor() {
        let controlQueue = DispatchQueue(label: "test.levelup.finish-start-control")
        let completion = expectation(description: "finishStart handoff")
        var publishedState: String?

        StartupAttemptCleanup.enqueue(on: controlQueue,
                                      stopRoute: { (true, nil) },
                                      removeActiveListener: { nil }) { result in
            XCTAssertTrue(Thread.isMainThread)
            publishedState = result.isComplete ? "stopped" : "cleanup-pending"
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
        XCTAssertEqual(publishedState, "stopped")
    }

    func testRouteStopFailureSkipsListenerRemovalAndReportsIncompleteCleanup() {
        let controlQueue = DispatchQueue(label: "test.levelup.route-stop-failure")
        let completion = expectation(description: "route-stop failure reported")
        var listenerRemovalCalled = false

        StartupAttemptCleanup.enqueue(on: controlQueue,
                                      stopRoute: { (false, "AudioDeviceStop failed (OSStatus -1)") },
                                      removeActiveListener: {
                                          listenerRemovalCalled = true
                                          return nil
                                      }) { result in
            XCTAssertFalse(result.routeStopped)
            XCTAssertFalse(result.activeListenerRemoved)
            XCTAssertFalse(result.isComplete)
            XCTAssertEqual(result.failure, "AudioDeviceStop failed (OSStatus -1)")
            XCTAssertFalse(listenerRemovalCalled)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
    }

    func testListenerRemovalFailureIsReportedAsIncompleteCleanup() {
        let controlQueue = DispatchQueue(label: "test.levelup.listener-remove-failure")
        let completion = expectation(description: "listener failure reported")

        StartupAttemptCleanup.enqueue(on: controlQueue,
                                      stopRoute: { (true, nil) },
                                      removeActiveListener: { "AudioObjectRemovePropertyListenerBlock failed (OSStatus -50)" }) { result in
            XCTAssertTrue(result.routeStopped)
            XCTAssertFalse(result.activeListenerRemoved)
            XCTAssertFalse(result.isComplete)
            XCTAssertEqual(result.failure, "AudioObjectRemovePropertyListenerBlock failed (OSStatus -50)")
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
    }

    func testFailedListenerRemovalRetainsRegistrationForRetry() {
        var registrations = ListenerRegistrationStore<String, Int>()
        registrations.insert(17, forKey: "active-alive")

        registrations.removeValue(forKey: "active-alive", removalSucceeded: false)
        XCTAssertEqual(registrations.count, 1)
        XCTAssertEqual(registrations.values, [17])

        registrations.removeValue(forKey: "active-alive", removalSucceeded: true)
        XCTAssertEqual(registrations.count, 0)
    }

    func testLateEventWithOldListenerTokenIsRejected() {
        let oldToken = UUID()
        let currentToken = UUID()
        XCTAssertFalse(ListenerEventGate.accepts(sessionActive: true,
                                                 eventSessionEpoch: 9,
                                                 currentSessionEpoch: 9,
                                                 isActiveDeviceEvent: true,
                                                 eventToken: oldToken,
                                                 activeDeviceToken: currentToken,
                                                 eventRouteGeneration: 4,
                                                 currentRouteGeneration: 4))
        XCTAssertFalse(ListenerEventGate.accepts(sessionActive: true,
                                                 eventSessionEpoch: 8,
                                                 currentSessionEpoch: 9,
                                                 isActiveDeviceEvent: false,
                                                 eventToken: oldToken,
                                                 activeDeviceToken: currentToken,
                                                 eventRouteGeneration: nil,
                                                 currentRouteGeneration: 4))
    }
}
