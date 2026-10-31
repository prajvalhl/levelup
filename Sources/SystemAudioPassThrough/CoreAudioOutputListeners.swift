import CoreAudio
import Foundation
import PrototypeSupport

enum CoreAudioOutputEvent: Equatable {
    case defaultOutputChanged
    case deviceListChanged
    case activeDeviceAliveChanged(AudioDeviceID)
}

private struct ListenerRemovalError: Error, CustomStringConvertible {
    let description: String
}

/// Owns only Core Audio listener registrations. It makes no lifecycle or
/// routing decisions; LevelUpModel remains the sole session owner.
final class CoreAudioOutputListeners: @unchecked Sendable {
    private enum Kind: Equatable { case defaultOutput, deviceList, activeAlive }
    private struct Registration {
        let kind: Kind
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
        let sessionEpoch: UInt64
        let routeGeneration: Int?
        let token: UUID
        let listener: AudioObjectPropertyListenerBlock
    }

    private let operationQueue: DispatchQueue
    private let deliveryQueue: DispatchQueue
    private let sink: (UInt64, Int?, UUID, CoreAudioOutputEvent) -> Void
    private var registrations = ListenerRegistrationStore<UUID, Registration>()
    private(set) var currentActiveToken: UUID?

    init(operationQueue: DispatchQueue,
         deliveryQueue: DispatchQueue,
         sink: @escaping (UInt64, Int?, UUID, CoreAudioOutputEvent) -> Void) {
        self.operationQueue = operationQueue
        self.deliveryQueue = deliveryQueue
        self.sink = sink
    }

    var activeDeviceID: AudioDeviceID? {
        guard let currentActiveToken else { return nil }
        return registrations.values.first(where: { $0.token == currentActiveToken }).map { AudioDeviceID($0.objectID) }
    }

    func installSystemListeners(sessionEpoch: UInt64) {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        _ = install(kind: .defaultOutput,
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDefaultOutputDevice,
                sessionEpoch: sessionEpoch,
                routeGeneration: nil,
                event: .defaultOutputChanged)
        _ = install(kind: .deviceList,
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDevices,
                sessionEpoch: sessionEpoch,
                routeGeneration: nil,
                event: .deviceListChanged)
    }

    func installActiveDeviceListener(_ deviceID: AudioDeviceID,
                                     sessionEpoch: UInt64,
                                     routeGeneration: Int) throws -> UUID? {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        if let failure = removeActiveDeviceListener() {
            throw ListenerRemovalError(description: failure)
        }
        currentActiveToken = install(kind: .activeAlive,
                                     objectID: AudioObjectID(deviceID),
                                     selector: kAudioDevicePropertyDeviceIsAlive,
                                     sessionEpoch: sessionEpoch,
                                     routeGeneration: routeGeneration,
                                     event: .activeDeviceAliveChanged(deviceID))
        return currentActiveToken
    }

    @discardableResult
    func removeActiveDeviceListener() -> String? {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        let failures = remove(where: { $0.kind == .activeAlive })
        currentActiveToken = nil
        return failures.first
    }

    @discardableResult
    func removeSessionListeners(sessionEpoch: UInt64) -> [String] {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        return remove(where: { $0.sessionEpoch == sessionEpoch })
    }

    private func install(kind: Kind,
                         objectID: AudioObjectID,
                         selector: AudioObjectPropertySelector,
                         sessionEpoch: UInt64,
                         routeGeneration: Int?,
                         event: CoreAudioOutputEvent) -> UUID? {
        if registrations.contains(where: {
            $0.kind == kind && $0.objectID == objectID && $0.sessionEpoch == sessionEpoch &&
            $0.routeGeneration == routeGeneration
        }) {
            return registrations.values.first(where: {
                $0.kind == kind && $0.objectID == objectID && $0.sessionEpoch == sessionEpoch &&
                $0.routeGeneration == routeGeneration
            })?.token
        }

        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let token = UUID()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Listener callbacks only enqueue a tokenized event. They perform
            // no Core Audio queries, logging, cleanup, construction or UI work.
            self?.sink(sessionEpoch, routeGeneration, token, event)
        }
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, deliveryQueue, listener)
        DiagnosticLog.write("CoreAudio AudioObjectAddPropertyListenerBlock kind=\(kind) objectID=\(objectID) selector=\(selector): \(statusDescription(status))")
        guard status == noErr else { return nil }
        registrations.insert(Registration(kind: kind,
                                           objectID: objectID,
                                           address: address,
                                           sessionEpoch: sessionEpoch,
                                           routeGeneration: routeGeneration,
                                           token: token,
                                           listener: listener),
                             forKey: token)
        return token
    }

    private func remove(where predicate: (Registration) -> Bool) -> [String] {
        let candidates = registrations.values.filter(predicate)
        var failures: [String] = []
        for registration in candidates {
            var address = registration.address
            let status = AudioObjectRemovePropertyListenerBlock(registration.objectID,
                                                                &address,
                                                                deliveryQueue,
                                                                registration.listener)
            DiagnosticLog.write("CoreAudio AudioObjectRemovePropertyListenerBlock kind=\(registration.kind) objectID=\(registration.objectID) selector=\(address.mSelector): \(statusDescription(status)); token=\(registration.token)")
            registrations.removeValue(forKey: registration.token, removalSucceeded: status == noErr)
            if status != noErr {
                failures.append("AudioObjectRemovePropertyListenerBlock for \(registration.kind) returned \(statusDescription(status))")
            }
            // On failure keep the exact block, queue, object and address so a
            // later removal can be retried and late events remain identifiable.
        }
        return failures
    }
}
