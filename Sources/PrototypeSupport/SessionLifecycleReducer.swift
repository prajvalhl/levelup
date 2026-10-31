/// Pure session-transition state owned by the menu-bar model. It does not
/// perform Core Audio work; it gates starts and resolves lifecycle intent.
public struct SessionLifecycleReducer: Equatable, Sendable {
    public enum Intent: Equatable, Sendable {
        case stopped
        case running
        case quit
    }

    public enum Phase: Equatable, Sendable {
        case stopped
        case starting
        case running
        case stopping
        case sleeping
        case recovering
        case cleanupPending
        case failed
    }

    public private(set) var intent: Intent = .stopped
    public private(set) var phase: Phase = .stopped
    public private(set) var generation = 0
    public private(set) var cleanupPending = false
    public private(set) var isSleeping = false
    public private(set) var outputChangePending = false
    public private(set) var recoveryAttempts = 0

    public var quitRequested: Bool { intent == .quit }

    public let maximumRecoveryAttempts: Int

    public init(maximumRecoveryAttempts: Int = 3) {
        self.maximumRecoveryAttempts = max(0, maximumRecoveryAttempts)
    }

    /// Begins a user start or an authorized restart. Quit, sleep, and retained
    /// cleanup resources always prevent a new route from being created.
    public mutating func beginStart() -> Int? {
        guard intent != .quit, !isSleeping, !cleanupPending else { return nil }
        guard phase == .stopped || phase == .failed || phase == .recovering else { return nil }
        intent = .running
        generation &+= 1
        phase = .starting
        return generation
    }

    @discardableResult
    public mutating func startupSucceeded(generation eventGeneration: Int) -> Bool {
        guard isCurrent(eventGeneration), intent == .running, !isSleeping, !cleanupPending,
              phase == .starting else { return false }
        phase = .running
        outputChangePending = false
        recoveryAttempts = 0
        return true
    }

    @discardableResult
    public mutating func startupFailed(generation eventGeneration: Int, cleanupSucceeded: Bool) -> Bool {
        guard isCurrent(eventGeneration) else { return false }
        if cleanupSucceeded {
            phase = isSleeping ? .sleeping : (intent == .running ? .failed : .stopped)
        } else {
            cleanupPending = true
            phase = .cleanupPending
        }
        return true
    }

    public mutating func requestStop() {
        guard intent != .quit else { return }
        intent = .stopped
        outputChangePending = false
        recoveryAttempts = 0
        phase = cleanupPending ? .cleanupPending : .stopping
    }

    public mutating func requestQuit() {
        intent = .quit
        outputChangePending = false
        phase = cleanupPending ? .cleanupPending : .stopping
    }

    public mutating func beginCleanup() {
        phase = cleanupPending ? .cleanupPending : .stopping
    }

    /// Marks the first pending output-change event. Further events for the
    /// current route coalesce until the caller clears the pending condition.
    public mutating func recordOutputChange(generation eventGeneration: Int) -> Bool {
        guard isCurrent(eventGeneration), intent == .running,
              !cleanupPending, !outputChangePending else { return false }
        outputChangePending = true
        if !isSleeping { phase = .recovering }
        return true
    }

    /// A recovery attempt must be explicitly scheduled after cleanup and is
    /// bounded. The resulting start receives a fresh generation.
    public mutating func beginRecoveryAttempt() -> Int? {
        guard intent == .running, !isSleeping, !cleanupPending,
              outputChangePending, recoveryAttempts < maximumRecoveryAttempts,
              phase == .recovering || phase == .failed || phase == .stopped else { return nil }
        recoveryAttempts += 1
        phase = .recovering
        generation &+= 1
        phase = .starting
        return generation
    }

    public mutating func sleepBegan() {
        isSleeping = true
        generation &+= 1 // Ignore callbacks and monitor events from the old route.
        phase = .sleeping
    }

    public mutating func wakeCompleted() {
        isSleeping = false
        if cleanupPending {
            phase = .cleanupPending
        } else if intent == .quit {
            phase = .stopping
        } else if intent == .running && outputChangePending {
            phase = .recovering
        } else if intent == .running {
            phase = .recovering
        } else {
            phase = .stopped
        }
    }

    /// Successful cleanup consumes pending intent. Quit always outranks a
    /// requested Apply/recovery restart and is consumed exactly once.
    public mutating func cleanupSucceeded(restartAfter: Bool) -> SessionCleanupDecision {
        cleanupPending = false
        if intent == .quit {
            phase = .stopped
            outputChangePending = false
            return .quit
        }
        guard restartAfter, intent == .running, !isSleeping else {
            phase = isSleeping ? .sleeping : (intent == .running ? .recovering : .stopped)
            return .stopped
        }
        phase = .stopped
        return .restart
    }

    public mutating func cleanupFailed() {
        cleanupPending = true
        phase = .cleanupPending
    }

    public func isCurrent(_ eventGeneration: Int) -> Bool {
        generation == eventGeneration
    }
}
