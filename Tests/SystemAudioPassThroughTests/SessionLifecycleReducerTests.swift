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
        reducer.sleepBegan()
        XCTAssertFalse(reducer.startupSucceeded(generation: startingGeneration))
        XCTAssertEqual(reducer.intent, .running)
        XCTAssertEqual(reducer.phase, .sleeping)
        XCTAssertNil(reducer.beginRecoveryAttempt())
    }

    func testOutputChangeWhileSleepingIsRememberedForWake() {
        var reducer = runningReducer()
        reducer.sleepBegan()
        XCTAssertTrue(reducer.recordOutputChange(generation: reducer.generation))
        XCTAssertEqual(reducer.phase, .sleeping)
        reducer.wakeCompleted()
        XCTAssertEqual(reducer.phase, .recovering)
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
