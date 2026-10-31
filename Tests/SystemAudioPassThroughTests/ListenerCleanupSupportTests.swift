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

    func testActiveDeviceBadObjectErrorRetiresOnlyWhenDeviceListConfirmsAbsence() {
        let disposition = ListenerRemovalPolicy.disposition(removalSucceeded: false,
                                                            isActivePhysicalDeviceListener: true,
                                                            returnedBadObjectError: true,
                                                            deviceConfirmedAbsent: true)
        XCTAssertEqual(disposition, .retiredConfirmedAbsentPhysicalDevice)
        var registrations = ListenerRegistrationStore<String, Int>()
        registrations.insert(83, forKey: "active-alive")
        registrations.removeValue(forKey: "active-alive", removalSucceeded: disposition != .retainForRetry)
        XCTAssertEqual(registrations.count, 0)

        XCTAssertEqual(ListenerRemovalPolicy.disposition(removalSucceeded: false,
                                                           isActivePhysicalDeviceListener: true,
                                                           returnedBadObjectError: true,
                                                           deviceConfirmedAbsent: false),
                       .retainForRetry)
    }

    func testNonBadObjectFailureIsRetainedEvenWhenDeviceIsAbsent() {
        XCTAssertEqual(ListenerRemovalPolicy.disposition(removalSucceeded: false,
                                                           isActivePhysicalDeviceListener: true,
                                                           returnedBadObjectError: false,
                                                           deviceConfirmedAbsent: true),
                       .retainForRetry)
    }

    func testSystemListenerBadObjectFailureRemainsRetryable() {
        let disposition = ListenerRemovalPolicy.disposition(removalSucceeded: false,
                                                            isActivePhysicalDeviceListener: false,
                                                            returnedBadObjectError: true,
                                                            deviceConfirmedAbsent: true)
        XCTAssertEqual(disposition, .retainForRetry)
        var registrations = ListenerRegistrationStore<String, Int>()
        registrations.insert(1, forKey: "system-default-output")
        registrations.removeValue(forKey: "system-default-output", removalSucceeded: disposition != .retainForRetry)
        XCTAssertEqual(registrations.count, 1)
    }

    func testSuccessfulListenerRemovalKeepsNormalSuccessPath() {
        XCTAssertEqual(ListenerRemovalPolicy.disposition(removalSucceeded: true,
                                                           isActivePhysicalDeviceListener: true,
                                                           returnedBadObjectError: false,
                                                           deviceConfirmedAbsent: false),
                       .removed)
    }

    func testRetiredDeviceTokenCannotAcceptAlreadyQueuedCallback() {
        let retiredToken = UUID()
        XCTAssertFalse(ListenerEventGate.accepts(sessionActive: true,
                                                 eventSessionEpoch: 12,
                                                 currentSessionEpoch: 12,
                                                 isActiveDeviceEvent: true,
                                                 eventToken: retiredToken,
                                                 activeDeviceToken: nil,
                                                 eventRouteGeneration: 7,
                                                 currentRouteGeneration: 7))
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
