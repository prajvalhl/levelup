import Foundation

/// Coordinates signals and a startup deadline without tearing down Core Audio
/// objects while a synchronous startup call is still using them.
/// Every mutable field is protected by `lock`, including reads from the audio
/// startup queue and stop/timeout requests from UI or signal queues.
public final class StartupControl: @unchecked Sendable {
    private let lock = NSLock()
    private var startupFinished = false
    private var cleanupScheduled = false
    private var stopReason: String?

    public init() {}

    /// Returns true once when the caller should begin cleanup immediately.
    /// During startup, the reason is saved and the startup thread cleans up at
    /// its next cancellation checkpoint.
    @discardableResult
    public func requestStop(_ reason: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stopReason == nil { stopReason = reason }
        guard startupFinished, !cleanupScheduled else { return false }
        cleanupScheduled = true
        return true
    }

    /// Returns nil if startup has already completed; otherwise indicates
    /// whether this invocation established the startup-deadline cancellation.
    public func requestStartupTimeout() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard !startupFinished else { return nil }
        guard stopReason == nil else { return stopReason == "startup deadline expired" }
        stopReason = "startup deadline expired"
        return true
    }

    /// Marks startup complete and returns a pending stop reason once, if the
    /// startup thread must perform the cleanup itself.
    public func completeStartup() -> String? {
        lock.lock()
        defer { lock.unlock() }
        startupFinished = true
        guard stopReason != nil, !cleanupScheduled else { return nil }
        cleanupScheduled = true
        return stopReason
    }

    public func cancellationReason() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stopReason
    }
}
