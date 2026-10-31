import Dispatch
import Foundation

/// Result of stopping a startup attempt and removing its active-device
/// listener. Listener removal is required before a replacement attempt starts.
public struct StartupAttemptCleanupResult: Equatable, Sendable {
    public let routeStopped: Bool
    public let activeListenerRemoved: Bool
    public let failure: String?

    public var isComplete: Bool { routeStopped && activeListenerRemoved }

    public init(routeStopped: Bool, activeListenerRemoved: Bool, failure: String?) {
        self.routeStopped = routeStopped
        self.activeListenerRemoved = activeListenerRemoved
        self.failure = failure
    }
}

/// Runs startup-failure cleanup on the serialized Core Audio control queue and
/// publishes its result on the main actor. Listener removal is skipped unless
/// route cleanup succeeds.
public enum StartupAttemptCleanup {
    public static func enqueue(on controlQueue: DispatchQueue,
                               stopRoute: @escaping () -> (succeeded: Bool, failure: String?),
                               removeActiveListener: @escaping () -> String?,
                               completion: @escaping @MainActor (StartupAttemptCleanupResult) -> Void) {
        controlQueue.async {
            dispatchPrecondition(condition: .onQueue(controlQueue))
            let routeResult = stopRoute()
            let result: StartupAttemptCleanupResult
            if !routeResult.succeeded {
                result = StartupAttemptCleanupResult(routeStopped: false,
                                                     activeListenerRemoved: false,
                                                     failure: routeResult.failure ?? "Route cleanup failed")
            } else if let listenerFailure = removeActiveListener() {
                result = StartupAttemptCleanupResult(routeStopped: true,
                                                     activeListenerRemoved: false,
                                                     failure: listenerFailure)
            } else {
                result = StartupAttemptCleanupResult(routeStopped: true,
                                                     activeListenerRemoved: true,
                                                     failure: nil)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }
}

/// Small generic store used by the listener registry. A record is discarded
/// only after the corresponding Core Audio removal call succeeds.
public struct ListenerRegistrationStore<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]

    public init() {}

    public var values: [Value] { Array(storage.values) }
    public var count: Int { storage.count }

    public func contains(where predicate: (Value) -> Bool) -> Bool {
        storage.values.contains(where: predicate)
    }

    public mutating func insert(_ value: Value, forKey key: Key) {
        storage[key] = value
    }

    public mutating func removeValue(forKey key: Key, removalSucceeded: Bool) {
        guard removalSucceeded else { return }
        storage.removeValue(forKey: key)
    }
}

public enum ListenerRemovalDisposition: Equatable, Sendable {
    case removed
    case retiredConfirmedAbsentPhysicalDevice
    case retainForRetry
}

/// A narrowly scoped exception for active physical-device listeners: Core
/// Audio's bad-object result permits retirement only when the object is also
/// confirmed absent from the current device list. System listeners never use
/// this exception.
public enum ListenerRemovalPolicy {
    public static func disposition(removalSucceeded: Bool,
                                   isActivePhysicalDeviceListener: Bool,
                                   returnedBadObjectError: Bool,
                                   deviceConfirmedAbsent: Bool) -> ListenerRemovalDisposition {
        if removalSucceeded { return .removed }
        if isActivePhysicalDeviceListener && returnedBadObjectError && deviceConfirmedAbsent {
            return .retiredConfirmedAbsentPhysicalDevice
        }
        return .retainForRetry
    }
}

/// Pure token validation shared by the model and regression tests.
public enum ListenerEventGate {
    public static func accepts(sessionActive: Bool,
                               eventSessionEpoch: UInt64,
                               currentSessionEpoch: UInt64,
                               isActiveDeviceEvent: Bool,
                               eventToken: UUID,
                               activeDeviceToken: UUID?,
                               eventRouteGeneration: Int?,
                               currentRouteGeneration: Int) -> Bool {
        guard sessionActive, eventSessionEpoch == currentSessionEpoch else { return false }
        guard isActiveDeviceEvent else { return true }
        return eventToken == activeDeviceToken && eventRouteGeneration == currentRouteGeneration
    }
}
