/// Tracks ownership and the conservative cleanup order for one Core Audio route.
/// A failed start is treated as potentially active until AudioDeviceStop succeeds.
public struct AudioCleanupLifecycle: Equatable, Sendable {
    public enum IOProcState: Equatable, Sendable {
        case absent
        case registered
        case mayBeActive
        case active
        case stopped
        case destroyed
    }

    public enum Action: Equatable, Sendable {
        case stopIOProc
        case destroyIOProc
        case destroyAggregate
        case destroyTap
        case complete
    }

    public private(set) var ioProcState: IOProcState = .absent
    public private(set) var aggregateRetained = false
    public private(set) var tapRetained = false

    public init() {}

    public var nextAction: Action {
        switch ioProcState {
        case .absent, .destroyed: break
        case .registered, .stopped: return .destroyIOProc
        case .mayBeActive, .active: return .stopIOProc
        }
        if aggregateRetained { return .destroyAggregate }
        if tapRetained { return .destroyTap }
        return .complete
    }

    public var isComplete: Bool { nextAction == .complete }

    public mutating func tapCreated() { tapRetained = true }
    public mutating func aggregateCreated() { aggregateRetained = true }

    public mutating func ioProcCreated() {
        precondition(ioProcState == .absent || ioProcState == .destroyed)
        ioProcState = .registered
    }

    /// Call before AudioDeviceStart: even a failed start must be stopped before
    /// dependent resources can be released because its activity is uncertain.
    public mutating func ioProcStartAttempted() {
        precondition(ioProcState == .registered)
        ioProcState = .mayBeActive
    }

    public mutating func ioProcStarted() {
        precondition(ioProcState == .mayBeActive)
        ioProcState = .active
    }

    public mutating func ioProcStopSucceeded() {
        precondition(ioProcState == .mayBeActive || ioProcState == .active)
        ioProcState = .stopped
    }

    /// A failed operation leaves ownership unchanged; validating the action here
    /// makes retry behavior explicit and testable without invoking Core Audio.
    public mutating func operationFailed(_ action: Action) {
        precondition(nextAction == action)
    }

    public mutating func ioProcDestroyed() {
        precondition(ioProcState == .registered || ioProcState == .stopped)
        ioProcState = .destroyed
    }

    public mutating func aggregateDestroyed() {
        precondition(ioProcState == .absent || ioProcState == .destroyed)
        precondition(aggregateRetained)
        aggregateRetained = false
    }

    public mutating func tapDestroyed() {
        precondition(!aggregateRetained)
        precondition(tapRetained)
        tapRetained = false
    }
}
