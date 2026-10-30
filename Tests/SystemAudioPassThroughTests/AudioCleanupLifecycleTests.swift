import PrototypeSupport
import XCTest

final class AudioCleanupLifecycleTests: XCTestCase {
    func testRegisteredButNeverStartedSkipsStopAndDestroysIOProcFirst() {
        var lifecycle = AudioCleanupLifecycle()
        lifecycle.tapCreated()
        lifecycle.aggregateCreated()
        lifecycle.ioProcCreated()

        XCTAssertEqual(lifecycle.nextAction, .destroyIOProc)
        lifecycle.ioProcDestroyed()
        XCTAssertEqual(lifecycle.nextAction, .destroyAggregate)
        lifecycle.aggregateDestroyed()
        XCTAssertEqual(lifecycle.nextAction, .destroyTap)
        lifecycle.tapDestroyed()
        XCTAssertTrue(lifecycle.isComplete)
    }

    func testStartedIOProcCleanupUsesStopDestroyAggregateTapOrder() {
        var lifecycle = activeLifecycle()
        XCTAssertEqual(lifecycle.nextAction, .stopIOProc)
        lifecycle.ioProcStopSucceeded()
        XCTAssertEqual(lifecycle.nextAction, .destroyIOProc)
        lifecycle.ioProcDestroyed()
        XCTAssertEqual(lifecycle.nextAction, .destroyAggregate)
        lifecycle.aggregateDestroyed()
        XCTAssertEqual(lifecycle.nextAction, .destroyTap)
        lifecycle.tapDestroyed()
        XCTAssertTrue(lifecycle.isComplete)
    }

    func testFailedStopRetainsPotentiallyActiveIOProcAndAllDependenciesForRetry() {
        var lifecycle = activeLifecycle()
        XCTAssertEqual(lifecycle.nextAction, .stopIOProc)
        lifecycle.operationFailed(.stopIOProc)
        XCTAssertEqual(lifecycle.nextAction, .stopIOProc)
        XCTAssertEqual(lifecycle.ioProcState, .active)
        XCTAssertTrue(lifecycle.aggregateRetained)
        XCTAssertTrue(lifecycle.tapRetained)
    }

    func testRepeatedStopFailureCannotAdvanceCleanup() {
        var lifecycle = activeLifecycle()
        for _ in 0..<3 {
            XCTAssertEqual(lifecycle.nextAction, .stopIOProc)
            lifecycle.operationFailed(.stopIOProc)
            XCTAssertEqual(lifecycle.ioProcState, .active)
        }
        XCTAssertFalse(lifecycle.isComplete)
    }

    func testSuccessfulStopAfterFailureAllowsDestroyAndOrderedRetry() {
        var lifecycle = activeLifecycle()
        XCTAssertEqual(lifecycle.nextAction, .stopIOProc)
        lifecycle.operationFailed(.stopIOProc)
        XCTAssertEqual(lifecycle.nextAction, .stopIOProc)
        lifecycle.ioProcStopSucceeded()
        XCTAssertEqual(lifecycle.nextAction, .destroyIOProc)
        lifecycle.ioProcDestroyed()
        XCTAssertEqual(lifecycle.nextAction, .destroyAggregate)
    }

    func testFailedIOProcDestroyRetainsContextOwnershipAndDependencies() {
        var lifecycle = activeLifecycle()
        lifecycle.ioProcStopSucceeded()

        XCTAssertEqual(lifecycle.nextAction, .destroyIOProc)
        lifecycle.operationFailed(.destroyIOProc)
        XCTAssertEqual(lifecycle.ioProcState, .stopped)
        XCTAssertTrue(lifecycle.aggregateRetained)
        XCTAssertTrue(lifecycle.tapRetained)
        XCTAssertFalse(lifecycle.isComplete)
    }

    func testAggregateDestroyFailureRetriesWithoutRepeatingEarlierCalls() {
        var lifecycle = activeLifecycle()
        lifecycle.ioProcStopSucceeded()
        lifecycle.ioProcDestroyed()
        XCTAssertEqual(lifecycle.nextAction, .destroyAggregate)

        XCTAssertEqual(lifecycle.nextAction, .destroyAggregate)
        lifecycle.operationFailed(.destroyAggregate)
        XCTAssertTrue(lifecycle.aggregateRetained)
        XCTAssertTrue(lifecycle.tapRetained)
        lifecycle.aggregateDestroyed()
        XCTAssertEqual(lifecycle.nextAction, .destroyTap)
        lifecycle.operationFailed(.destroyTap)
    }

    func testTapDestroyFailureRetainsTapForRetry() {
        var lifecycle = activeLifecycle()
        lifecycle.ioProcStopSucceeded()
        lifecycle.ioProcDestroyed()
        lifecycle.aggregateDestroyed()
        XCTAssertEqual(lifecycle.nextAction, .destroyTap)

        XCTAssertEqual(lifecycle.nextAction, .destroyTap)
        XCTAssertTrue(lifecycle.tapRetained)
        XCTAssertFalse(lifecycle.isComplete)
        lifecycle.tapDestroyed()
        XCTAssertTrue(lifecycle.isComplete)
    }

    func testIncompleteRouteCanNeverReportSuccessfulCleanup() {
        var lifecycle = AudioCleanupLifecycle()
        lifecycle.tapCreated()
        XCTAssertFalse(lifecycle.isComplete)
        XCTAssertEqual(lifecycle.nextAction, .destroyTap)
        lifecycle.tapDestroyed()
        XCTAssertTrue(lifecycle.isComplete)
    }

    private func activeLifecycle() -> AudioCleanupLifecycle {
        var lifecycle = AudioCleanupLifecycle()
        lifecycle.tapCreated()
        lifecycle.aggregateCreated()
        lifecycle.ioProcCreated()
        lifecycle.ioProcStartAttempted()
        lifecycle.ioProcStarted()
        return lifecycle
    }
}
