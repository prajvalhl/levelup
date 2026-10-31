import Foundation

/// Output notifications have different implications during recovery startup.
/// Device-list changes invalidate settling, but do not alone prove that the
/// selected physical output changed.
public enum RecoveryOutputEventKind: Equatable, Sendable {
    case defaultOutputChanged
    case deviceListChanged
    case activeDeviceAliveChanged
}

public enum RecoveryOutputEventPolicy {
    public static func cancelsConnectingStartup(for event: RecoveryOutputEventKind) -> Bool {
        switch event {
        case .defaultOutputChanged, .activeDeviceAliveChanged:
            return true
        case .deviceListChanged:
            return false
        }
    }
}

public struct OutputDeviceIdentity: Equatable, Sendable {
    public let deviceID: UInt32
    public let uid: String
    public let formatFingerprint: String

    public init(deviceID: UInt32, uid: String, formatFingerprint: String) {
        self.deviceID = deviceID
        self.uid = uid
        self.formatFingerprint = formatFingerprint
    }
}

public struct OutputDeviceSnapshot: Equatable, Sendable {
    public let identity: OutputDeviceIdentity
    public let name: String
    public let isInDeviceList: Bool
    public let isAlive: Bool
    public let outputStreamCount: Int
    public let nominalSampleRate: Double
    public let channelCount: UInt32
    public let isFloatPCM: Bool
    public let bitsPerChannel: UInt32

    public init(identity: OutputDeviceIdentity,
                name: String,
                isInDeviceList: Bool,
                isAlive: Bool,
                outputStreamCount: Int,
                nominalSampleRate: Double,
                channelCount: UInt32,
                isFloatPCM: Bool,
                bitsPerChannel: UInt32) {
        self.identity = identity
        self.name = name
        self.isInDeviceList = isInDeviceList
        self.isAlive = isAlive
        self.outputStreamCount = outputStreamCount
        self.nominalSampleRate = nominalSampleRate
        self.channelCount = channelCount
        self.isFloatPCM = isFloatPCM
        self.bitsPerChannel = bitsPerChannel
    }

    public var unavailableReason: String? {
        guard identity.deviceID != 0 else { return "No default output device is selected." }
        guard !identity.uid.isEmpty else { return "The default output UID is unavailable." }
        guard !name.isEmpty else { return "The default output name is unavailable." }
        guard isInDeviceList else { return "The default output is not present in Core Audio's device list." }
        guard isAlive else { return "The default output device is not currently available." }
        guard outputStreamCount > 0 else { return "The default output device has no output streams." }
        guard nominalSampleRate.isFinite, nominalSampleRate > 0 else { return "The default output sample rate is not available." }
        guard channelCount > 0 else { return "The default output has no usable channels." }
        guard isFloatPCM, bitsPerChannel == 32 else { return "The default output format is not supported Float32 PCM." }
        return nil
    }

    public var isUsable: Bool { unavailableReason == nil }

    public func requiresRouteReplacement(comparedTo activeIdentity: OutputDeviceIdentity) -> Bool {
        !isUsable || identity != activeIdentity
    }
}

/// Requires two matching valid snapshots at the same event revision. The
/// caller schedules the observations apart; this type makes the comparison
/// deterministic and rejects results from superseded output events.
public struct OutputDeviceStabilityGate: Equatable, Sendable {
    private var observedRevision: UInt64?
    private var firstIdentity: OutputDeviceIdentity?
    private var stable = false

    public init() {}

    public mutating func observe(_ snapshot: OutputDeviceSnapshot, revision: UInt64) -> Bool {
        if observedRevision != revision {
            observedRevision = revision
            firstIdentity = nil
            stable = false
        }
        guard snapshot.isUsable else {
            firstIdentity = nil
            stable = false
            return false
        }
        if firstIdentity == snapshot.identity {
            stable = true
        } else {
            firstIdentity = snapshot.identity
            stable = false
        }
        return stable
    }

    public mutating func invalidate(revision: UInt64) {
        observedRevision = revision
        firstIdentity = nil
        stable = false
    }

    public func accepts(revision: UInt64) -> Bool {
        stable && observedRevision == revision
    }
}

/// A route is healthy only when the aggregate reports running and callbacks
/// advance in two consecutive samples. No captured-sample amplitude is used.
public struct RouteHealthGate: Equatable, Sendable {
    private var lastCallbackCount: UInt64?
    private var consecutiveProgressSamples = 0
    public let requiredProgressSamples: Int

    public init(requiredProgressSamples: Int = 2) {
        self.requiredProgressSamples = max(1, requiredProgressSamples)
    }

    public mutating func observe(aggregateRunning: Bool, callbackCount: UInt64) -> Bool {
        let progressed = lastCallbackCount.map { callbackCount > $0 } ?? (callbackCount > 0)
        lastCallbackCount = callbackCount
        guard aggregateRunning, progressed else {
            consecutiveProgressSamples = 0
            return false
        }
        consecutiveProgressSamples += 1
        return consecutiveProgressSamples >= requiredProgressSamples
    }

    public mutating func reset() {
        lastCallbackCount = nil
        consecutiveProgressSamples = 0
    }
}
