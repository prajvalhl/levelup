/// Separates initial callback acquisition from callback loss on an active
/// route. Timestamps are monotonic nanoseconds supplied by the caller.
public struct RouteCallbackWatchdog: Equatable, Sendable {
    public enum Failure: Equatable, Sendable {
        case callbackAcquisitionTimedOut
        case callbackProgressStalled
    }

    public enum Observation: Equatable, Sendable {
        case waiting
        case stale
        case failed(Failure)
    }

    /// The three-second margin over the former five-second startup deadline
    /// covers the observed wake delay plus the monitor's one-second cadence.
    public let callbackAcquisitionTimeoutNanoseconds: UInt64
    public let callbackStallTimeoutNanoseconds: UInt64

    private var routeGeneration: Int?
    private var startedAtNanoseconds: UInt64 = 0
    private var lastProgressAtNanoseconds: UInt64 = 0
    private var lastCallbackCount: UInt64 = 0
    private var hasObservedCallbacks = false

    public init(callbackAcquisitionTimeoutNanoseconds: UInt64 = 8_000_000_000,
                callbackStallTimeoutNanoseconds: UInt64 = 5_000_000_000) {
        self.callbackAcquisitionTimeoutNanoseconds = max(1, callbackAcquisitionTimeoutNanoseconds)
        self.callbackStallTimeoutNanoseconds = max(1, callbackStallTimeoutNanoseconds)
    }

    public mutating func start(generation: Int,
                               nowNanoseconds: UInt64,
                               callbackCount: UInt64 = 0) {
        routeGeneration = generation
        startedAtNanoseconds = nowNanoseconds
        lastProgressAtNanoseconds = nowNanoseconds
        lastCallbackCount = callbackCount
        hasObservedCallbacks = callbackCount > 0
    }

    public mutating func cancel() {
        routeGeneration = nil
        startedAtNanoseconds = 0
        lastProgressAtNanoseconds = 0
        lastCallbackCount = 0
        hasObservedCallbacks = false
    }

    public mutating func observe(generation: Int,
                                 callbackCount: UInt64,
                                 nowNanoseconds: UInt64) -> Observation {
        guard routeGeneration == generation else { return .stale }

        if callbackCount > lastCallbackCount {
            hasObservedCallbacks = true
            lastCallbackCount = callbackCount
            lastProgressAtNanoseconds = nowNanoseconds
            return .waiting
        }

        if callbackCount < lastCallbackCount {
            // A reset/regression must not be mistaken for a long route stall.
            lastCallbackCount = callbackCount
            hasObservedCallbacks = callbackCount > 0
            startedAtNanoseconds = nowNanoseconds
            lastProgressAtNanoseconds = nowNanoseconds
            return .waiting
        }

        if hasObservedCallbacks {
            guard let elapsed = Self.elapsed(now: nowNanoseconds, since: lastProgressAtNanoseconds),
                  elapsed >= callbackStallTimeoutNanoseconds else { return .waiting }
            return .failed(.callbackProgressStalled)
        }

        guard let elapsed = Self.elapsed(now: nowNanoseconds, since: startedAtNanoseconds),
              elapsed >= callbackAcquisitionTimeoutNanoseconds else { return .waiting }
        return .failed(.callbackAcquisitionTimedOut)
    }

    private static func elapsed(now: UInt64, since start: UInt64) -> UInt64? {
        guard now >= start else { return nil }
        return now - start
    }
}
