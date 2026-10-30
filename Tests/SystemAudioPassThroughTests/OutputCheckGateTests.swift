import PrototypeSupport
import XCTest

final class OutputCheckGateTests: XCTestCase {
    func testOnlyOneOutputCheckCanBeQueuedAtATime() {
        var gate = OutputCheckGate()

        XCTAssertTrue(gate.begin(generation: 4))
        XCTAssertFalse(gate.begin(generation: 4))
        XCTAssertTrue(gate.complete(generation: 4, currentGeneration: 4))
        XCTAssertTrue(gate.begin(generation: 4))
    }

    func testStaleResultIsIgnoredAndReleasesGateForNewSession() {
        var gate = OutputCheckGate()

        XCTAssertTrue(gate.begin(generation: 7))
        XCTAssertFalse(gate.complete(generation: 7, currentGeneration: 8))
        XCTAssertTrue(gate.begin(generation: 8))
        XCTAssertTrue(gate.complete(generation: 8, currentGeneration: 8))
    }

    func testMismatchedCompletionCannotClearAnotherCheck() {
        var gate = OutputCheckGate()

        XCTAssertTrue(gate.begin(generation: 2))
        XCTAssertFalse(gate.complete(generation: 1, currentGeneration: 2))
        XCTAssertFalse(gate.begin(generation: 2))
        XCTAssertTrue(gate.complete(generation: 2, currentGeneration: 2))
    }
}
