/// Pure session-transition state owned by the menu-bar model. Core Audio work
/// remains outside this reducer and is serialized by LevelUpModel.audioQueue.
public struct SessionLifecycleReducer: Equatable, Sendable {
    public enum Intent: Equatable, Sendable { case stopped, running, quit }
    public enum Phase: Equatable, Sendable {
        case stopped, starting, running, stopping, sleeping, recovering, cleanupPending, failed
    }
    public enum CleanupReason: Equatable, Sendable {
        case userStop, quit, applyChanges, outputRecovery, startupFailure, routeHealthFailure
    }

    public private(set) var intent: Intent = .stopped
    public private(set) var phase: Phase = .stopped
    public private(set) var generation = 0
    public private(set) var cleanupPending = false
    public private(set) var pendingCleanupReason: CleanupReason?
    public private(set) var isSleeping = false
    public private(set) var outputChangePending = false
    public private(set) var outputEventRevision: UInt64 = 0
    public private(set) var recoveryAttempts = 0
    public let maximumRecoveryAttempts: Int

    public var quitRequested: Bool { intent == .quit }
    public var recoveryExhausted: Bool { recoveryAttempts >= maximumRecoveryAttempts }

    public init(maximumRecoveryAttempts: Int = 4) {
        self.maximumRecoveryAttempts = max(1, maximumRecoveryAttempts)
    }

    public mutating func beginStart() -> Int? {
        guard intent != .quit, !isSleeping, !cleanupPending else { return nil }
        guard phase == .stopped || phase == .failed || phase == .recovering else { return nil }
        intent = .running
        generation &+= 1
        phase = .starting
        return generation
    }

    public mutating func beginRecoveryAttempt() -> Int? {
        guard intent == .running, !isSleeping, !cleanupPending, outputChangePending,
              recoveryAttempts < maximumRecoveryAttempts,
              phase == .recovering || phase == .failed || phase == .stopped else { return nil }
        recoveryAttempts += 1
        generation &+= 1
        phase = .starting
        return generation
    }

    @discardableResult
    public mutating func startupSucceeded(generation eventGeneration: Int) -> Bool {
        guard isCurrent(eventGeneration), intent == .running, !isSleeping, !cleanupPending,
              phase == .starting else { return false }
        phase = .running
        // A successful AudioDeviceStart is not the healthy-route milestone.
        // Recovery budget resets only after running-state and callback checks.
        return true
    }

    @discardableResult
    public mutating func startupFailed(generation eventGeneration: Int, cleanupSucceeded: Bool) -> Bool {
        guard isCurrent(eventGeneration) else { return false }
        if cleanupSucceeded {
            phase = isSleeping ? .sleeping : (intent == .running ? (outputChangePending ? .recovering : .failed) : .stopped)
        } else {
            cleanupPending = true
            pendingCleanupReason = outputChangePending ? .outputRecovery : .startupFailure
            phase = .cleanupPending
        }
        return true
    }

    @discardableResult
    public mutating func advanceOutputEventRevision() -> UInt64 {
        outputEventRevision &+= 1
        return outputEventRevision
    }

    @discardableResult
    public mutating func recordOutputChange(generation eventGeneration: Int) -> Bool {
        guard isCurrent(eventGeneration), intent == .running, !cleanupPending else { return false }
        _ = advanceOutputEventRevision()
        return requestOutputRecovery()
    }

    @discardableResult
    public mutating func requestOutputRecovery() -> Bool {
        guard intent == .running, !cleanupPending else { return false }
        let isFirstPendingEvent = !outputChangePending
        outputChangePending = true
        if !isSleeping { phase = .recovering }
        return isFirstPendingEvent
    }

    public mutating func requestManualRecovery() -> Bool {
        guard intent != .quit, !cleanupPending, !isSleeping else { return false }
        intent = .running
        recoveryAttempts = 0
        outputChangePending = true
        outputEventRevision &+= 1
        phase = .recovering
        return true
    }

    /// Mark health only after aggregate-running is true and IOProc callback
    /// count has progressed across the model's consecutive health samples.
    @discardableResult
    public mutating func routeBecameHealthy(generation eventGeneration: Int) -> Bool {
        guard isCurrent(eventGeneration), intent == .running, !cleanupPending,
              !isSleeping, phase == .running else { return false }
        recoveryAttempts = 0
        outputChangePending = false
        pendingCleanupReason = nil
        return true
    }

    public mutating func recoveryAttemptFailed(generation eventGeneration: Int, cleanupSucceeded: Bool) -> Bool {
        guard isCurrent(eventGeneration), intent == .running else { return false }
        if cleanupSucceeded {
            phase = recoveryExhausted ? .failed : .recovering
        } else {
            cleanupPending = true
            pendingCleanupReason = .outputRecovery
            phase = .cleanupPending
        }
        return !recoveryExhausted && cleanupSucceeded
    }

    public mutating func requestStop() {
        guard intent != .quit else { return }
        intent = .stopped
        outputChangePending = false
        recoveryAttempts = 0
        if cleanupPending { pendingCleanupReason = .userStop }
        phase = cleanupPending ? .cleanupPending : .stopping
    }

    public mutating func requestQuit() {
        intent = .quit
        outputChangePending = false
        if cleanupPending { pendingCleanupReason = .quit }
        phase = cleanupPending ? .cleanupPending : .stopping
    }

    public mutating func beginCleanup(reason: CleanupReason) {
        pendingCleanupReason = reason
        phase = cleanupPending ? .cleanupPending : .stopping
    }

    public mutating func cleanupSucceeded(reason explicitReason: CleanupReason? = nil) -> SessionCleanupDecision {
        let reason = explicitReason ?? pendingCleanupReason
        cleanupPending = false
        pendingCleanupReason = nil
        if intent == .quit {
            phase = .stopped
            outputChangePending = false
            return .quit
        }
        guard intent == .running, !isSleeping else {
            phase = isSleeping ? .sleeping : .stopped
            outputChangePending = false
            return .stopped
        }
        if reason == .outputRecovery || outputChangePending {
            phase = .recovering
            return .recover
        }
        if reason == .applyChanges {
            phase = .stopped
            return .restart
        }
        phase = .stopped
        return .stopped
    }

    public mutating func cleanupFailed(reason: CleanupReason? = nil) {
        cleanupPending = true
        if intent == .quit { pendingCleanupReason = .quit }
        else if intent == .stopped { pendingCleanupReason = .userStop }
        else if let reason { pendingCleanupReason = reason }
        phase = .cleanupPending
    }

    public mutating func sleepBegan() {
        isSleeping = true
        generation &+= 1
        phase = .sleeping
    }

    public mutating func wakeCompleted() {
        isSleeping = false
        if cleanupPending { phase = .cleanupPending }
        else if intent == .quit { phase = .stopping }
        else if intent == .running { phase = .recovering }
        else { phase = .stopped }
    }

    public func isCurrent(_ eventGeneration: Int) -> Bool { generation == eventGeneration }
}
