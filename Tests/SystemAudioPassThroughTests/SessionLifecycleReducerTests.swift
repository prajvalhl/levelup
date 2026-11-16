import PrototypeSupport
import XCTest

final class SessionLifecycleReducerTests: XCTestCase {
    func testUserStopDuringRecoveryCancelsAutomaticRestart() {
        var reducer = runningReducer()
        XCTAssertTrue(reducer.recordOutputChange(generation: reducer.generation))
        reducer.beginCleanup(reason: .outputRecovery)
        reducer.requestStop()
        XCTAssertEqual(reducer.intent, .stopped)
        XCTAssertEqual(reducer.cleanupSucceeded(), .stopped)
        XCTAssertNil(reducer.beginRecoveryAttempt())
    }

    func testUserQuitDuringRecoveryCancelsAutomaticRestart() {
        var reducer = runningReducer()
        XCTAssertTrue(reducer.recordOutputChange(generation: reducer.generation))
        reducer.beginCleanup(reason: .outputRecovery)
        reducer.requestQuit()
        XCTAssertEqual(reducer.cleanupSucceeded(), .quit)
        XCTAssertNil(reducer.beginRecoveryAttempt())
    }

    func testQuitRemainsPendingWhileCleanupIsIncompleteAndCompletesAfterRetry() {
        var reducer = runningReducer()
        reducer.beginCleanup(reason: .outputRecovery)
        reducer.requestQuit()
        reducer.cleanupFailed(reason: .outputRecovery)

        XCTAssertEqual(reducer.intent, .quit)
        XCTAssertTrue(reducer.cleanupPending)
        XCTAssertEqual(reducer.pendingCleanupReason, .quit)
        XCTAssertNil(reducer.beginStart())
        XCTAssertNil(reducer.beginRecoveryAttempt())

        XCTAssertEqual(reducer.cleanupSucceeded(reason: .quit), .quit)
        XCTAssertFalse(reducer.cleanupPending)
        XCTAssertEqual(reducer.intent, .quit)
    }

    func testSleepDuringStartupSuppressesCompletionAndRecovery() {
        var reducer = SessionLifecycleReducer()
        let startingGeneration = try! XCTUnwrap(reducer.beginStart())
        XCTAssertTrue(reducer.sleepBegan())
        XCTAssertFalse(reducer.startupSucceeded(generation: startingGeneration))
        XCTAssertEqual(reducer.intent, .running)
        XCTAssertEqual(reducer.phase, .sleeping)
        XCTAssertNil(reducer.beginRecoveryAttempt())
        XCTAssertTrue(reducer.wakeCompleted())
        XCTAssertTrue(reducer.outputChangePending)
        XCTAssertNotNil(reducer.beginRecoveryAttempt(), "Wake must initiate recovery even without a device notification")
    }

    func testSleepWhileRunningStopsRouteAndWakeRecoversWithoutOutputChange() {
        var reducer = runningReducer()
        XCTAssertTrue(reducer.sleepBegan())
        XCTAssertEqual(reducer.intent, .running)
        XCTAssertTrue(reducer.outputChangePending)
        XCTAssertNil(reducer.beginRecoveryAttempt())
        XCTAssertEqual(reducer.cleanupSucceeded(reason: .systemSleep), .sleeping)
        XCTAssertEqual(reducer.phase, .sleeping)
        XCTAssertTrue(reducer.wakeCompleted())
        XCTAssertNotNil(reducer.beginRecoveryAttempt())
    }

    func testChangedOutputWhileSleepingCoalescesWithWakeRecovery() {
        var reducer = runningReducer()
        XCTAssertTrue(reducer.sleepBegan())
        let revisionBeforeOutputEvent = reducer.outputEventRevision
        XCTAssertFalse(reducer.recordOutputChange(generation: reducer.generation), "Sleep already requested a coalesced recovery")
        XCTAssertEqual(reducer.outputEventRevision, revisionBeforeOutputEvent &+ 1)
        XCTAssertEqual(reducer.phase, .sleeping)
        XCTAssertTrue(reducer.wakeCompleted())
        XCTAssertEqual(reducer.phase, .recovering)
        XCTAssertNotNil(reducer.beginRecoveryAttempt())
    }

    func testStopDuringSleepPreventsWakeRecovery() {
        var reducer = runningReducer()
        XCTAssertTrue(reducer.sleepBegan())
        reducer.requestStop()
        XCTAssertFalse(reducer.outputChangePending)
        XCTAssertTrue(reducer.wakeCompleted())
        XCTAssertEqual(reducer.intent, .stopped)
        XCTAssertEqual(reducer.phase, .stopped)
        XCTAssertNil(reducer.beginRecoveryAttempt())
    }

    func testQuitDuringSleepCleanupTakesPrecedenceAndNeverRestarts() {
        var reducer = runningReducer()
        XCTAssertTrue(reducer.sleepBegan())
        reducer.beginCleanup(reason: .systemSleep)
        reducer.requestQuit()
        reducer.cleanupFailed(reason: .systemSleep)
        XCTAssertTrue(reducer.cleanupPending)
        XCTAssertNil(reducer.beginRecoveryAttempt())
        XCTAssertTrue(reducer.wakeCompleted())
        XCTAssertEqual(reducer.cleanupSucceeded(reason: .systemSleep), .quit)
        XCTAssertNil(reducer.beginStart())
        XCTAssertNil(reducer.beginRecoveryAttempt())
    }

    func testWakeKeepsRecoveryBlockedUntilSleepCleanupSucceeds() {
        var reducer = runningReducer()
        XCTAssertTrue(reducer.sleepBegan())
        reducer.beginCleanup(reason: .systemSleep)
        reducer.cleanupFailed(reason: .systemSleep)
        XCTAssertTrue(reducer.wakeCompleted())
        XCTAssertTrue(reducer.cleanupPending)
        XCTAssertNil(reducer.beginRecoveryAttempt())
        XCTAssertEqual(reducer.cleanupSucceeded(reason: .systemSleep), .recover)
        XCTAssertNotNil(reducer.beginRecoveryAttempt())
    }

    func testCleanupStartedBeforeSleepCompletesAfterWakeAndThenAllowsRecovery() {
        var reducer = runningReducer()
        reducer.beginCleanup(reason: .outputRecovery)
        let cleanupGeneration = reducer.generation

        XCTAssertTrue(reducer.sleepBegan())
        XCTAssertFalse(reducer.isCurrent(cleanupGeneration))
        XCTAssertTrue(reducer.wakeCompleted())
        XCTAssertEqual(reducer.cleanupSucceeded(reason: .outputRecovery), .recover)
        XCTAssertNotNil(reducer.beginRecoveryAttempt())
    }

    func testStopDuringSleepCleanupPreventsRecoveryAfterCleanupCompletes() {
        var reducer = runningReducer()
        XCTAssertTrue(reducer.sleepBegan())
        reducer.beginCleanup(reason: .systemSleep)
        reducer.requestStop()
        XCTAssertTrue(reducer.wakeCompleted())

        XCTAssertEqual(reducer.cleanupSucceeded(reason: .systemSleep), .stopped)
        XCTAssertNil(reducer.beginRecoveryAttempt())
        XCTAssertEqual(reducer.intent, .stopped)
    }

    func testQuitDuringSleepCleanupRemainsHighestPriorityAfterWake() {
        var reducer = runningReducer()
        XCTAssertTrue(reducer.sleepBegan())
        reducer.beginCleanup(reason: .systemSleep)
        reducer.requestQuit()
        XCTAssertTrue(reducer.wakeCompleted())

        XCTAssertEqual(reducer.cleanupSucceeded(reason: .systemSleep), .quit)
        XCTAssertNil(reducer.beginStart())
        XCTAssertNil(reducer.beginRecoveryAttempt())
    }

    func testSleepDuringStartupCleanupFailureBlocksWakeRecoveryUntilCleanupSucceeds() {
        var reducer = SessionLifecycleReducer()
        let startupGeneration = try! XCTUnwrap(reducer.beginStart())
        XCTAssertTrue(reducer.sleepBegan())
        XCTAssertFalse(reducer.startupSucceeded(generation: startupGeneration))
        reducer.cleanupFailed(reason: .systemSleep)
        XCTAssertTrue(reducer.wakeCompleted())

        XCTAssertTrue(reducer.cleanupPending)
        XCTAssertNil(reducer.beginRecoveryAttempt())
        XCTAssertEqual(reducer.cleanupSucceeded(reason: .systemSleep), .recover)
        XCTAssertNotNil(reducer.beginRecoveryAttempt())
    }

    func testSleepDuringStartupCleanupSuccessDefersRecoveryUntilWake() {
        var reducer = SessionLifecycleReducer()
        let startupGeneration = try! XCTUnwrap(reducer.beginStart())
        XCTAssertTrue(reducer.sleepBegan())
        XCTAssertFalse(reducer.startupSucceeded(generation: startupGeneration))
        reducer.beginCleanup(reason: .systemSleep)

        XCTAssertEqual(reducer.cleanupSucceeded(reason: .systemSleep), .sleeping)
        XCTAssertNil(reducer.beginRecoveryAttempt())
        XCTAssertTrue(reducer.wakeCompleted())
        XCTAssertNotNil(reducer.beginRecoveryAttempt())
    }

    func testRepeatedSleepAndWakeNotificationsAreIdempotent() {
        var reducer = runningReducer()
        let originalGeneration = reducer.generation
        XCTAssertTrue(reducer.sleepBegan())
        let sleepGeneration = reducer.generation
        XCTAssertFalse(reducer.sleepBegan())
        XCTAssertEqual(reducer.generation, sleepGeneration)
        XCTAssertGreaterThan(sleepGeneration, originalGeneration)
        XCTAssertTrue(reducer.wakeCompleted())
        let wakePhase = reducer.phase
        XCTAssertFalse(reducer.wakeCompleted())
        XCTAssertEqual(reducer.phase, wakePhase)
    }

    func testStaleStartupAndListenerEventsAfterWakeAreRejected() {
        var reducer = SessionLifecycleReducer()
        let oldGeneration = try! XCTUnwrap(reducer.beginStart())
        XCTAssertTrue(reducer.sleepBegan())
        XCTAssertTrue(reducer.wakeCompleted())
        XCTAssertFalse(reducer.startupSucceeded(generation: oldGeneration))
        XCTAssertFalse(reducer.recordOutputChange(generation: oldGeneration))
        XCTAssertNotNil(reducer.beginRecoveryAttempt())
    }

    func testCleanupFailureBlocksStartAndRetryCleanupPreservesRecoveryIntent() {
        var reducer = runningReducer()
        _ = reducer.recordOutputChange(generation: reducer.generation)
        reducer.beginCleanup(reason: .outputRecovery)
        reducer.cleanupFailed()
        XCTAssertNil(reducer.beginRecoveryAttempt())
        XCTAssertEqual(reducer.pendingCleanupReason, .outputRecovery)
        XCTAssertEqual(reducer.cleanupSucceeded(), .recover)
        XCTAssertEqual(reducer.intent, .running)
        XCTAssertFalse(reducer.cleanupPending)
    }

    func testStaleGenerationEventsAreIgnored() {
        var reducer = SessionLifecycleReducer()
        let oldGeneration = try! XCTUnwrap(reducer.beginStart())
        reducer.sleepBegan()
        reducer.wakeCompleted()
        XCTAssertFalse(reducer.startupSucceeded(generation: oldGeneration))
        XCTAssertFalse(reducer.recordOutputChange(generation: oldGeneration))
    }

    func testRepeatedOutputNotificationsCoalesceButAdvanceRevision() {
        var reducer = runningReducer()
        let generation = reducer.generation
        XCTAssertTrue(reducer.recordOutputChange(generation: generation))
        let firstRevision = reducer.outputEventRevision
        XCTAssertFalse(reducer.recordOutputChange(generation: generation))
        XCTAssertEqual(reducer.outputEventRevision, firstRevision &+ 1)
        XCTAssertTrue(reducer.outputChangePending)
    }

    func testRecoveryBudgetDoesNotResetAtStartAndResetsOnlyAtHealthyMilestone() {
        var reducer = runningReducer(maximumRecoveryAttempts: 2)
        _ = reducer.recordOutputChange(generation: reducer.generation)
        let recoveryGeneration = try! XCTUnwrap(reducer.beginRecoveryAttempt())
        XCTAssertEqual(reducer.recoveryAttempts, 1)
        XCTAssertTrue(reducer.startupSucceeded(generation: recoveryGeneration))
        XCTAssertEqual(reducer.recoveryAttempts, 1)
        XCTAssertTrue(reducer.routeBecameHealthy(generation: recoveryGeneration))
        XCTAssertEqual(reducer.recoveryAttempts, 0)
        XCTAssertFalse(reducer.outputChangePending)
    }

    func testRecoveryExhaustionRequiresExplicitManualRetry() {
        var reducer = SessionLifecycleReducer(maximumRecoveryAttempts: 2)
        _ = reducer.beginStart()
        _ = reducer.recordOutputChange(generation: reducer.generation)
        for attempt in 0..<2 {
            let generation = try! XCTUnwrap(reducer.beginRecoveryAttempt())
            XCTAssertEqual(reducer.recoveryAttemptFailed(generation: generation, cleanupSucceeded: true), attempt == 0)
        }
        XCTAssertTrue(reducer.recoveryExhausted)
        XCTAssertNil(reducer.beginRecoveryAttempt())
        XCTAssertTrue(reducer.requestManualRecovery())
        XCTAssertEqual(reducer.recoveryAttempts, 0)
        XCTAssertNotNil(reducer.beginRecoveryAttempt())
    }

    func testApplyCleanupRestartsSeparatelyFromOutputRecovery() {
        var applyReducer = runningReducer()
        applyReducer.beginCleanup(reason: .applyChanges)
        XCTAssertEqual(applyReducer.cleanupSucceeded(), .restart)

        var recoveryReducer = runningReducer()
        _ = recoveryReducer.recordOutputChange(generation: recoveryReducer.generation)
        recoveryReducer.beginCleanup(reason: .outputRecovery)
        XCTAssertEqual(recoveryReducer.cleanupSucceeded(), .recover)
    }

    func testUserStopDuringApplyCleanupCancelsPendingRestart() {
        var reducer = runningReducer()
        reducer.beginCleanup(reason: .applyChanges)
        reducer.requestStop()
        XCTAssertEqual(reducer.intent, .stopped)
        XCTAssertEqual(reducer.cleanupSucceeded(), .stopped)
        XCTAssertFalse(reducer.outputChangePending)
    }

    func testQuitTakesPrecedenceOverApplyAndRecoveryRestart() {
        for reason in [SessionLifecycleReducer.CleanupReason.applyChanges, .outputRecovery] {
            var reducer = runningReducer()
            if reason == .outputRecovery {
                _ = reducer.recordOutputChange(generation: reducer.generation)
            }
            reducer.beginCleanup(reason: reason)
            reducer.requestQuit()
            XCTAssertEqual(reducer.cleanupSucceeded(), .quit)
            XCTAssertNil(reducer.beginStart())
            XCTAssertNil(reducer.beginRecoveryAttempt())
        }
    }

    private func runningReducer(maximumRecoveryAttempts: Int = 4) -> SessionLifecycleReducer {
        var reducer = SessionLifecycleReducer(maximumRecoveryAttempts: maximumRecoveryAttempts)
        let generation = try! XCTUnwrap(reducer.beginStart())
        XCTAssertTrue(reducer.startupSucceeded(generation: generation))
        return reducer
    }
}
