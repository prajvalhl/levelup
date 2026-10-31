import PrototypeSupport
import XCTest

final class SessionLifecycleReducerTests: XCTestCase {
    func testUserStopDuringRecoveryCancelsAutomaticRestart() {
        var reducer = runningReducer()
        XCTAssertTrue(reducer.recordOutputChange(generation: reducer.generation))
        reducer.requestStop()

        XCTAssertEqual(reducer.intent, .stopped)
        XCTAssertNil(reducer.beginRecoveryAttempt())
    }

    func testUserQuitDuringRecoveryCancelsAutomaticRestart() {
        var reducer = runningReducer()
        XCTAssertTrue(reducer.recordOutputChange(generation: reducer.generation))
        reducer.requestQuit()

        XCTAssertEqual(reducer.intent, .quit)
        XCTAssertNil(reducer.beginRecoveryAttempt())
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

    func testOutputChangeWhileSleepingIsSuppressedUntilWake() {
        var reducer = runningReducer()
        reducer.sleepBegan()

        XCTAssertTrue(reducer.recordOutputChange(generation: reducer.generation))
        XCTAssertTrue(reducer.outputChangePending)
        reducer.wakeCompleted()

        XCTAssertEqual(reducer.phase, .recovering)
        XCTAssertTrue(reducer.outputChangePending)
        XCTAssertNotNil(reducer.beginRecoveryAttempt())
    }

    func testCleanupFailureBlocksRecoveryStart() {
        var reducer = runningReducer()
        XCTAssertTrue(reducer.recordOutputChange(generation: reducer.generation))
        reducer.cleanupFailed()

        XCTAssertTrue(reducer.cleanupPending)
        XCTAssertNil(reducer.beginRecoveryAttempt())
    }

    func testStaleGenerationEventsAreIgnored() {
        var reducer = SessionLifecycleReducer()
        let oldGeneration = try! XCTUnwrap(reducer.beginStart())
        reducer.sleepBegan()
        reducer.wakeCompleted()

        XCTAssertFalse(reducer.startupSucceeded(generation: oldGeneration))
        XCTAssertFalse(reducer.recordOutputChange(generation: oldGeneration))
    }

    func testRepeatedOutputChangesCoalesceByGeneration() {
        var reducer = runningReducer()
        let generation = reducer.generation

        XCTAssertTrue(reducer.recordOutputChange(generation: generation))
        XCTAssertFalse(reducer.recordOutputChange(generation: generation))
        XCTAssertTrue(reducer.outputChangePending)
    }

    func testRecoveryAttemptsAreBoundedAndResetAfterSuccessfulStart() {
        var reducer = runningReducer(maximumRecoveryAttempts: 2)
        XCTAssertTrue(reducer.recordOutputChange(generation: reducer.generation))

        let attemptOne = try! XCTUnwrap(reducer.beginRecoveryAttempt())
        XCTAssertEqual(reducer.recoveryAttempts, 1)
        XCTAssertTrue(reducer.startupFailed(generation: attemptOne, cleanupSucceeded: true))
        let attemptTwo = try! XCTUnwrap(reducer.beginRecoveryAttempt())
        XCTAssertEqual(reducer.recoveryAttempts, 2)
        XCTAssertTrue(reducer.startupFailed(generation: attemptTwo, cleanupSucceeded: true))

        XCTAssertNil(reducer.beginRecoveryAttempt())
        let manualStart = try! XCTUnwrap(reducer.beginStart())
        XCTAssertTrue(reducer.startupSucceeded(generation: manualStart))
        XCTAssertEqual(reducer.recoveryAttempts, 0)
    }

    func testSuccessfulCleanupAuthorizesOnlyRequestedRestart() {
        var reducer = runningReducer()
        reducer.beginCleanup()
        XCTAssertEqual(reducer.cleanupSucceeded(restartAfter: true), .restart)
        XCTAssertFalse(reducer.cleanupPending)
        XCTAssertNotNil(reducer.beginStart())
    }

    func testQuitTakesPrecedenceOverEveryRestartPathAndIsConsumed() {
        for restartAfter in [false, true] {
            var reducer = runningReducer()
            reducer.requestQuit()
            XCTAssertEqual(reducer.cleanupSucceeded(restartAfter: restartAfter), .quit)
            XCTAssertEqual(reducer.intent, .quit)
            XCTAssertNil(reducer.beginStart())
        }

        var applyReducer = runningReducer()
        applyReducer.beginCleanup()
        applyReducer.requestQuit()
        XCTAssertEqual(applyReducer.cleanupSucceeded(restartAfter: true), .quit)
        XCTAssertNil(applyReducer.beginStart())
    }

    private func runningReducer(maximumRecoveryAttempts: Int = 3) -> SessionLifecycleReducer {
        var reducer = SessionLifecycleReducer(maximumRecoveryAttempts: maximumRecoveryAttempts)
        let generation = try! XCTUnwrap(reducer.beginStart())
        XCTAssertTrue(reducer.startupSucceeded(generation: generation))
        return reducer
    }
}
