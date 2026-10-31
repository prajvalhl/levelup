import AppKit
import CoreAudio
import LevelUpDSP
import PrototypeSupport
import SwiftUI

enum LevelUpModeChoice: String, CaseIterable, Identifiable {
    case bypass
    case gentle
    case balanced
    case strong
    case custom

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var dspMode: DSPMode {
        switch self {
        case .bypass: return .bypass
        case .gentle: return .preset(.gentle)
        case .balanced: return .preset(.balanced)
        case .strong: return .preset(.strong)
        case .custom: return .custom(compressor: DSPPreset.balanced.compressor,
                                     limiter: DSPPreset.balanced.limiter)
        }
    }
}

@MainActor
final class LevelUpModel: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case recovering
        case waitingForOutput
        case connecting(String)
        case stopping
        case recoveryFailed(String)
        case error(String)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var selectedMode: LevelUpModeChoice = .bypass
    @Published private(set) var customCompressor = DSPPreset.balanced.compressor
    @Published private(set) var customLimiter = DSPPreset.balanced.limiter
    @Published private(set) var startupTimedOut = false
    @Published private(set) var showStartConfirmation = false
    @Published private(set) var routeHasCallbacks = false
    @Published private(set) var callbackCount: UInt64 = 0

    private let audioQueue = DispatchQueue(label: "com.levelup.menu-bar-audio-control", qos: .userInitiated)
    private let listenerDeliveryQueue = DispatchQueue(label: "com.levelup.output-listener-delivery", qos: .utility)
    private var engine: AudioTapEngine?
    private var startupControl: StartupControl?
    private var activeMode: DSPMode?
    private var lifecycle = SessionLifecycleReducer()
    private var cleanupPending: Bool { lifecycle.cleanupPending }
    private var generation: Int { lifecycle.generation }
    private var routeMonitor: DispatchSourceTimer?
    private var outputCheckGate = OutputCheckGate()
    private lazy var outputListeners = CoreAudioOutputListeners(operationQueue: audioQueue,
                                                                 deliveryQueue: listenerDeliveryQueue) { [weak self] sessionEpoch, routeGeneration, token, event in
        DispatchQueue.main.async { [weak self] in
            self?.receiveOutputNotification(event,
                                             sessionEpoch: sessionEpoch,
                                             routeGeneration: routeGeneration,
                                             listenerToken: token)
        }
    }
    private var listenerSessionEpoch: UInt64 = 0
    private var listenerSessionActive = false
    private var activeDeviceListenerToken: UUID?
    private var recoveryWorkItem: DispatchWorkItem?
    private var recoveryIsActive = false
    private var cleanupInFlight = false
    private var outputStabilityGate = OutputDeviceStabilityGate()
    private var routeHealthGate = RouteHealthGate(requiredProgressSamples: 2)
    private var recoverySettleStartNanoseconds: UInt64 = 0
    private var recoverySnapshot: OutputDeviceSnapshot?
    private var recoveryAttemptGeneration: Int?
    private var recoveryQueriesInFlight: Set<String> = []
    private var recoveryFailureMessage = "The current default output could not be restored."
    private var isRecoveryStart = false
    private let recoveryBackoff: [TimeInterval] = [0.5, 1.0, 2.0, 4.0]
    private let outputSettleInterval: TimeInterval = 0.4
    private let outputSettleBudget: TimeInterval = 4.0
    private var routeMonitorStartNanoseconds: UInt64 = 0
    private var lastCallbackProgressNanoseconds: UInt64 = 0
    private var lastObservedCallbackCount: UInt64 = 0
    private var routeFailureAfterStop: String?

    var isBusy: Bool {
        switch state {
        case .starting, .recovering, .waitingForOutput, .connecting, .stopping: return true
        default: return false
        }
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var hasPendingChanges: Bool {
        guard isRunning, let activeMode else { return false }
        return activeMode != selectedDSPMode
    }

    var selectedDSPMode: DSPMode {
        if selectedMode == .custom {
            return .custom(compressor: customCompressor, limiter: customLimiter)
        }
        return selectedMode.dspMode
    }

    var stateTitle: String {
        switch state {
        case .stopped: return "Stopped"
        case .starting: return startupTimedOut ? "Starting · waiting for Core Audio" : "Starting"
        case .recovering: return "Recovering audio…"
        case .waitingForOutput: return "Waiting for a usable output…"
        case let .connecting(name): return "Connecting to \(name)…"
        case .running:
            if !routeHasCallbacks { return "Waiting for audio callbacks" }
            if hasPendingChanges { return "Running · changes pending" }
            if case .bypass = activeMode { return "Enabled · Bypass" }
            if case let .preset(preset) = activeMode { return "Running · \(preset.rawValue.capitalized)" }
            if case .custom = activeMode { return "Running · Custom" }
            return "Running"
        case .stopping: return "Stopping"
        case .recoveryFailed: return "Recovery failed"
        case .error: return "Needs attention"
        }
    }

    var stateSymbol: String {
        switch state {
        case .stopped: return "power"
        case .starting: return "ellipsis.circle"
        case .recovering, .waitingForOutput, .connecting: return "arrow.triangle.2.circlepath"
        case .running: return selectedMode == .bypass ? "waveform" : "waveform.circle.fill"
        case .stopping: return "stop.circle"
        case .recoveryFailed, .error: return "exclamationmark.triangle.fill"
        }
    }

    var stateColor: Color {
        switch state {
        case .stopped: return .secondary
        case .starting, .recovering, .waitingForOutput, .connecting, .stopping: return .orange
        case .running: return .green
        case .recoveryFailed, .error: return .red
        }
    }

    var errorMessage: String? {
        switch state {
        case let .error(message), let .recoveryFailed(message): return message
        default: return nil
        }
    }

    var recoveryIntentPending: Bool {
        lifecycle.intent == .running && lifecycle.outputChangePending
    }

    var runningIntentPendingCleanup: Bool {
        cleanupPending && lifecycle.intent == .running
    }

    func selectMode(_ mode: LevelUpModeChoice) {
        guard !isBusy, !cleanupPending else { return }
        selectedMode = mode
    }

    func updateCompressor(threshold: Float? = nil,
                          ratio: Float? = nil,
                          attack: Float? = nil,
                          release: Float? = nil,
                          makeup: Float? = nil) {
        guard !isBusy, !cleanupPending else { return }
        customCompressor = CompressorParameters(
            thresholdDBFS: threshold ?? customCompressor.thresholdDBFS,
            ratio: ratio ?? customCompressor.ratio,
            attackMilliseconds: attack ?? customCompressor.attackMilliseconds,
            releaseMilliseconds: release ?? customCompressor.releaseMilliseconds,
            makeupGainDB: makeup ?? customCompressor.makeupGainDB
        )
        selectedMode = .custom
    }

    func updateLimiter(ceiling: Float? = nil, release: Float? = nil) {
        guard !isBusy, !cleanupPending else { return }
        customLimiter = LimiterParameters(
            ceilingDBFS: ceiling ?? customLimiter.ceilingDBFS,
            releaseMilliseconds: release ?? customLimiter.releaseMilliseconds
        )
        selectedMode = .custom
    }

    func start() {
        guard !isBusy, !cleanupPending else { return }
        if case .running = state { return }
        recoveryIsActive = false
        beginStart()
    }

    func requestStart() {
        guard !isBusy, !cleanupPending else { return }
        showStartConfirmation = true
    }

    func confirmStart() {
        showStartConfirmation = false
        start()
    }

    func dismissStartConfirmation() {
        showStartConfirmation = false
    }

    private func beginStart() {
        guard let operation = lifecycle.beginStart() else { return }
        startEngine(operation: operation, expectedOutput: nil, recovery: false)
    }

    private func beginRecoveryAttempt() {
        guard let operation = lifecycle.beginRecoveryAttempt() else {
            if lifecycle.recoveryExhausted { failRecovery(recoveryFailureMessage) }
            return
        }
        recoveryAttemptGeneration = operation
        recoverySettleStartNanoseconds = DispatchTime.now().uptimeNanoseconds
        recoverySnapshot = nil
        outputStabilityGate.invalidate(revision: lifecycle.outputEventRevision)
        state = .waitingForOutput
        resolveOutputForRecovery(operation: operation, revision: lifecycle.outputEventRevision)
    }

    private func startEngine(operation: Int,
                             expectedOutput: OutputDeviceSnapshot?,
                             recovery: Bool) {
        isRecoveryStart = recovery
        let requestedMode = selectedDSPMode
        let control = StartupControl()
        let route = AudioTapEngine(dspMode: requestedMode,
                                   expectedOutputIdentity: expectedOutput?.identity,
                                   startupCancellationReason: { control.cancellationReason() })
        startupControl = control
        engine = route
        activeMode = nil
        startupTimedOut = false
        routeHasCallbacks = false
        callbackCount = 0
        routeFailureAfterStop = nil
        state = recovery ? (expectedOutput.map { .connecting($0.name) } ?? .waitingForOutput) : .starting

        if !listenerSessionActive {
            listenerSessionEpoch &+= 1
            listenerSessionActive = true
        }
        let listenerSession = listenerSessionEpoch
        let listeners = outputListeners

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(30)) { [weak self] in
            guard control.requestStartupTimeout() == true else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == operation else { return }
                self.startupTimedOut = true
            }
        }

        audioQueue.async { [weak self] in
            var failure: String?
            do {
                listeners.installSystemListeners(sessionEpoch: listenerSession)
                if let expectedOutput {
                    let token = listeners.installActiveDeviceListener(AudioDeviceID(expectedOutput.identity.deviceID),
                                                                      sessionEpoch: listenerSession,
                                                                      routeGeneration: operation)
                    DispatchQueue.main.async { [weak self] in self?.activeDeviceListenerToken = token }
                }
                try route.start()
                if expectedOutput == nil {
                    let token = listeners.installActiveDeviceListener(route.outputDeviceID,
                                                                      sessionEpoch: listenerSession,
                                                                      routeGeneration: operation)
                    DispatchQueue.main.async { [weak self] in self?.activeDeviceListenerToken = token }
                }
            } catch {
                failure = String(describing: error)
            }
            let pendingStop = control.completeStartup()
            if failure != nil || pendingStop != nil {
                let cleanupSucceeded = route.stop()
                DispatchQueue.main.async {
                    self?.finishStart(operation: operation,
                                      failure: failure,
                                      pendingStop: pendingStop,
                                      cleanupSucceeded: cleanupSucceeded,
                                      cleanupFailure: route.lastCleanupFailure)
                }
            } else {
                DispatchQueue.main.async {
                    self?.finishSuccessfulStart(operation: operation, mode: requestedMode, route: route)
                }
            }
        }
    }

    private func finishSuccessfulStart(operation: Int, mode: DSPMode, route: AudioTapEngine) {
        guard generation == operation else { return }
        guard lifecycle.startupSucceeded(generation: operation) else {
            // Stop or Quit can arrive after Core Audio startup returns but
            // before this main-queue transition. The route is already live,
            // so hand it to the serialized cleanup path instead of dropping it.
            guard engine === route, !cleanupPending else { return }
            lifecycle.beginCleanup(reason: lifecycle.outputChangePending ? .outputRecovery : .userStop)
            state = .stopping
            performCleanup(route: route, operation: operation, reason: lifecycle.pendingCleanupReason ?? .userStop)
            return
        }
        startupTimedOut = false
        activeMode = mode
        isRecoveryStart = false
        state = .running
        routeHealthGate.reset()
        startRouteMonitor(route: route, operation: operation)
    }

    private func startRouteMonitor(route: AudioTapEngine, operation: Int) {
        stopRouteMonitor()
        let now = DispatchTime.now().uptimeNanoseconds
        routeMonitorStartNanoseconds = now
        lastCallbackProgressNanoseconds = now
        lastObservedCallbackCount = route.callbackCount
        callbackCount = lastObservedCallbackCount
        routeHasCallbacks = callbackCount > 0
        routeHealthGate.reset()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self, weak route] in
            guard let self, let route, self.generation == operation, self.isRunning else { return }
            let callbacks = route.callbackCount
            self.callbackCount = callbacks
            let now = DispatchTime.now().uptimeNanoseconds
            if callbacks != self.lastObservedCallbackCount {
                self.lastObservedCallbackCount = callbacks
                self.lastCallbackProgressNanoseconds = now
            }
            if callbacks > 0 { self.routeHasCallbacks = true }

            let failure: String?
            if callbacks == 0 && Self.elapsedMilliseconds(since: self.routeMonitorStartNanoseconds, now: now) >= 5_000 {
                failure = "No audio callbacks arrived within five seconds. The route may still be waiting for tap audio; output recovery is being attempted safely."
            } else if callbacks > 0 && Self.elapsedMilliseconds(since: self.lastCallbackProgressNanoseconds, now: now) >= 5_000 {
                failure = "Audio callbacks stopped progressing for five seconds. Output recovery is being attempted safely."
            } else {
                failure = nil
            }
            if let failure {
                self.beginOutputRecovery(route: route, operation: operation, message: failure)
                return
            }
            self.reconcileOutput(route: route, operation: operation)
        }
        routeMonitor = timer
        timer.resume()
    }

    private static func elapsedMilliseconds(since start: UInt64, now: UInt64) -> Double {
        Double(now &- start) / 1_000_000
    }

    private func stopRouteMonitor() {
        routeMonitor?.setEventHandler {}
        routeMonitor?.cancel()
        routeMonitor = nil
    }

    /// Reconciliation queries run on the serialized control queue. Notifications
    /// and the periodic monitor use this same path.
    private func reconcileOutput(route: AudioTapEngine, operation: Int) {
        guard generation == operation, isRunning, outputCheckGate.begin(generation: operation) else { return }
        let revision = lifecycle.outputEventRevision
        audioQueue.async { [weak self] in
            let snapshot = try? resolveDefaultOutputSnapshot().snapshot
            let aggregateRunning = route.aggregateIsRunning()
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.outputCheckGate.complete(generation: operation, currentGeneration: self.generation),
                      self.isRunning else { return }
                guard revision == self.lifecycle.outputEventRevision else {
                    self.reconcileOutput(route: route, operation: operation)
                    return
                }
                guard let activeIdentity = route.outputIdentity,
                      let snapshot,
                      !snapshot.requiresRouteReplacement(comparedTo: activeIdentity),
                      snapshot.identity.deviceID == route.outputDeviceID else {
                    self.beginOutputRecovery(route: route,
                                             operation: operation,
                                             message: "The macOS default output changed or became unavailable.")
                    return
                }
                let callbacks = route.callbackCount
                if self.routeHealthGate.observe(aggregateRunning: aggregateRunning == true,
                                                callbackCount: callbacks) {
                    self.recoveryIsActive = false
                    self.recoveryAttemptGeneration = nil
                    _ = self.lifecycle.routeBecameHealthy(generation: operation)
                    self.routeHasCallbacks = true
                }
            }
        }
    }

    private func receiveOutputNotification(_ event: CoreAudioOutputEvent,
                                           sessionEpoch: UInt64,
                                           routeGeneration: Int?,
                                           listenerToken: UUID) {
        guard listenerSessionActive, sessionEpoch == listenerSessionEpoch else { return }
        if case .activeDeviceAliveChanged = event {
            guard listenerToken == activeDeviceListenerToken,
                  routeGeneration == generation else { return }
        }
        _ = lifecycle.advanceOutputEventRevision()
        if recoveryIsActive {
            outputStabilityGate.invalidate(revision: lifecycle.outputEventRevision)
            if case .starting = state, isRecoveryStart {
                _ = startupControl?.requestStop("output changed during recovery")
            } else if case .connecting = state {
                _ = startupControl?.requestStop("output changed during recovery")
            } else if case .waitingForOutput = state, let recoveryAttemptGeneration {
                scheduleRecoveryResolution(operation: recoveryAttemptGeneration,
                                           revision: lifecycle.outputEventRevision,
                                           after: outputSettleInterval)
            } else if isRunning, let route = engine {
                reconcileOutput(route: route, operation: generation)
            }
            return
        }
        guard case .recoveryFailed = state else {
            if isRunning, let route = engine {
                reconcileOutput(route: route, operation: generation)
            } else if case .starting = state, event == .defaultOutputChanged {
                _ = lifecycle.requestOutputRecovery()
                recoveryIsActive = true
                recoveryFailureMessage = "The default output changed during startup."
                _ = startupControl?.requestStop("default output changed during startup")
                state = .recovering
            }
            return
        }
        // Exhaustion is terminal until the user explicitly retries.
    }

    private func beginOutputRecovery(route: AudioTapEngine, operation: Int, message: String) {
        guard generation == operation, isRunning else { return }
        _ = lifecycle.advanceOutputEventRevision()
        _ = lifecycle.requestOutputRecovery()
        recoveryFailureMessage = message
        recoveryIsActive = true
        isRecoveryStart = false
        stopRouteMonitor()
        _ = startupControl?.requestStop("menu-bar route health failure")
        lifecycle.beginCleanup(reason: .outputRecovery)
        state = .recovering
        performCleanup(route: route, operation: operation, reason: .outputRecovery)
    }

    private func resolveOutputForRecovery(operation: Int, revision: UInt64) {
        guard recoveryIsActive, lifecycle.isCurrent(operation), !cleanupPending,
              lifecycle.intent == .running, !lifecycle.quitRequested else { return }
        state = .waitingForOutput
        let queryKey = "\(operation):\(revision)"
        guard recoveryQueriesInFlight.insert(queryKey).inserted else { return }
        audioQueue.async { [weak self] in
            let result: Result<OutputDeviceSnapshot, Error>
            do { result = .success(try resolveDefaultOutputSnapshot().snapshot) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                self?.recoveryQueriesInFlight.remove(queryKey)
                self?.handleRecoverySnapshot(result, operation: operation, revision: revision)
            }
        }
    }

    private func handleRecoverySnapshot(_ result: Result<OutputDeviceSnapshot, Error>,
                                        operation: Int,
                                        revision: UInt64) {
        guard recoveryIsActive, lifecycle.isCurrent(operation), lifecycle.intent == .running,
              !lifecycle.quitRequested, !cleanupPending else { return }
        guard revision == lifecycle.outputEventRevision else {
            outputStabilityGate.invalidate(revision: lifecycle.outputEventRevision)
            resolveOutputForRecovery(operation: operation, revision: lifecycle.outputEventRevision)
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Self.elapsedMilliseconds(since: recoverySettleStartNanoseconds, now: now)
        guard elapsed < outputSettleBudget * 1_000 else {
            failRecoveryAttempt(operation: operation, message: recoveryFailureMessage)
            return
        }
        switch result {
        case let .failure(error):
            recoveryFailureMessage = "Waiting for a usable output: \(error)"
            outputStabilityGate.invalidate(revision: revision)
            scheduleRecoveryResolution(operation: operation, revision: revision, after: outputSettleInterval)
        case let .success(snapshot):
            guard snapshot.isUsable else {
                recoveryFailureMessage = snapshot.unavailableReason ?? "The output is not ready."
                outputStabilityGate.invalidate(revision: revision)
                scheduleRecoveryResolution(operation: operation, revision: revision, after: outputSettleInterval)
                return
            }
            if outputStabilityGate.observe(snapshot, revision: revision) {
                guard outputStabilityGate.accepts(revision: revision),
                      revision == lifecycle.outputEventRevision else { return }
                recoverySnapshot = snapshot
                state = .connecting(snapshot.name)
                startEngine(operation: operation, expectedOutput: snapshot, recovery: true)
            } else {
                recoverySnapshot = snapshot
                scheduleRecoveryResolution(operation: operation, revision: revision, after: outputSettleInterval)
            }
        }
    }

    private func scheduleRecoveryResolution(operation: Int, revision: UInt64, after delay: TimeInterval) {
        recoveryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.resolveOutputForRecovery(operation: operation, revision: revision)
        }
        recoveryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleNextRecoveryAttempt() {
        guard recoveryIsActive, lifecycle.intent == .running, !cleanupPending,
              !lifecycle.quitRequested else { return }
        guard !lifecycle.recoveryExhausted else {
            failRecovery(recoveryFailureMessage)
            return
        }
        let delayIndex = min(lifecycle.recoveryAttempts, recoveryBackoff.count - 1)
        recoveryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.beginRecoveryAttempt() }
        recoveryWorkItem = work
        state = .recovering
        DispatchQueue.main.asyncAfter(deadline: .now() + recoveryBackoff[delayIndex], execute: work)
    }

    private func failRecoveryAttempt(operation: Int, message: String) {
        guard lifecycle.isCurrent(operation), recoveryIsActive else { return }
        recoveryFailureMessage = message
        let mayRetry = lifecycle.recoveryAttemptFailed(generation: operation, cleanupSucceeded: true)
        if mayRetry { scheduleNextRecoveryAttempt() }
        else { failRecovery(message) }
    }

    private func failRecovery(_ message: String) {
        recoveryWorkItem?.cancel()
        recoveryWorkItem = nil
        recoveryIsActive = false
        recoveryAttemptGeneration = nil
        state = .recoveryFailed(message)
    }

    func retryRecovery() {
        guard lifecycle.requestManualRecovery() else { return }
        recoveryIsActive = true
        recoveryFailureMessage = "Waiting for a usable output."
        outputStabilityGate.invalidate(revision: lifecycle.outputEventRevision)
        scheduleNextRecoveryAttempt()
    }

    private func finishStart(operation: Int,
                             failure: String?,
                             pendingStop: String?,
                             cleanupSucceeded: Bool,
                             cleanupFailure: String?) {
        guard generation == operation else { return }
        startupTimedOut = false
        let wasRecoveryAttempt = isRecoveryStart
        isRecoveryStart = false
        _ = lifecycle.startupFailed(generation: operation, cleanupSucceeded: cleanupSucceeded)
        if cleanupSucceeded {
            let listeners = outputListeners
            listeners.removeActiveDeviceListener()
            activeDeviceListenerToken = nil
            engine = nil
            startupControl = nil
            activeMode = nil
        } else {
            lifecycle.cleanupFailed(reason: lifecycle.outputChangePending || wasRecoveryAttempt
                                    ? .outputRecovery : .startupFailure)
        }
        if cleanupSucceeded && lifecycle.quitRequested {
            _ = lifecycle.cleanupSucceeded(reason: .quit)
            removeListenerSession()
            NSApp.terminate(nil)
        } else if lifecycle.intent == .stopped && cleanupSucceeded {
            _ = lifecycle.cleanupSucceeded(reason: .userStop)
            removeListenerSession()
            state = .stopped
        } else if cleanupSucceeded && (wasRecoveryAttempt || lifecycle.outputChangePending) {
            if wasRecoveryAttempt {
                if lifecycle.recoveryAttemptFailed(generation: operation, cleanupSucceeded: true) {
                    recoveryFailureMessage = failure ?? pendingStop.map { "Recovery was interrupted: \($0)." } ?? recoveryFailureMessage
                    scheduleNextRecoveryAttempt()
                } else {
                    failRecovery(failure ?? recoveryFailureMessage)
                }
            } else {
                recoveryIsActive = true
                scheduleNextRecoveryAttempt()
            }
        } else if pendingStop == "user requested stop" {
            state = cleanupSucceeded ? .stopped : .error(cleanupIncompleteMessage(cleanupFailure))
        } else if pendingStop == "user requested quit" {
            state = cleanupSucceeded ? .stopped : .error("Quit is waiting for Core Audio cleanup to complete. \(cleanupIncompleteMessage(cleanupFailure))")
        } else if pendingStop == "startup deadline expired" {
            state = .error(cleanupSucceeded
                ? "Startup exceeded 30 seconds and was stopped safely. You can try again."
                : "Startup exceeded 30 seconds. \(cleanupIncompleteMessage(cleanupFailure))")
        } else if let failure {
            if !cleanupSucceeded {
                state = .error("Could not start audio: \(failure). \(cleanupIncompleteMessage(cleanupFailure))")
                return
            }
            removeListenerSession()
            state = .error(cleanupSucceeded
                ? "Could not start audio: \(failure)"
                : "Could not start audio: \(failure). \(cleanupIncompleteMessage(cleanupFailure))")
        } else {
            if !cleanupSucceeded {
                state = .error(cleanupIncompleteMessage(cleanupFailure))
                return
            }
            removeListenerSession()
            state = cleanupSucceeded ? .stopped : .error(cleanupIncompleteMessage(cleanupFailure))
        }
    }

    private func cleanupIncompleteMessage(_ detail: String?) -> String {
        let operation = detail ?? "Core Audio did not confirm that all resources were released."
        return "Cleanup incomplete: \(operation). Resources remain retained. Retry Cleanup before starting again. Log: \(DiagnosticLog.path)"
    }

    func stop() {
        if case .recoveryFailed = state {
            recoveryWorkItem?.cancel()
            lifecycle.requestStop()
            recoveryIsActive = false
            _ = lifecycle.cleanupSucceeded(reason: .userStop)
            removeListenerSession()
            state = .stopped
            return
        }
        if case .starting = state {
            recoveryWorkItem?.cancel()
            recoveryIsActive = false
            lifecycle.requestStop()
            _ = startupControl?.requestStop("user requested stop")
            state = .stopping
            return
        }
        if case .connecting = state {
            recoveryWorkItem?.cancel()
            recoveryIsActive = false
            lifecycle.requestStop()
            _ = startupControl?.requestStop("user requested stop during recovery startup")
            state = .stopping
            return
        }
        if case .running = state {
            guard let route = engine else { state = .error("Audio engine state was unavailable."); return }
            lifecycle.requestStop()
            stopRouteMonitor()
            _ = startupControl?.requestStop("user requested stop")
            state = .stopping
            lifecycle.beginCleanup(reason: .userStop)
            performCleanup(route: route, operation: generation, reason: .userStop)
            return
        }
        if case .stopping = state {
            // A Stop during Apply Changes cleanup cancels its pending restart.
            // If cleanup already belongs to recovery, this also cancels the
            // recovery intent while allowing the in-flight cleanup to finish.
            recoveryWorkItem?.cancel()
            recoveryIsActive = false
            lifecycle.requestStop()
            return
        }
        if isBusy, state != .stopping {
            recoveryWorkItem?.cancel()
            recoveryIsActive = false
            lifecycle.requestStop()
            if let route = engine {
                stopRouteMonitor()
                lifecycle.beginCleanup(reason: .userStop)
                state = .stopping
                performCleanup(route: route, operation: generation, reason: .userStop)
            } else {
                _ = lifecycle.cleanupSucceeded(reason: .userStop)
                removeListenerSession()
                state = .stopped
            }
            return
        }
        if cleanupPending, let route = engine {
            recoveryWorkItem?.cancel()
            lifecycle.requestStop()
            state = .stopping
            lifecycle.beginCleanup(reason: .userStop)
            performCleanup(route: route, operation: generation, reason: .userStop)
        }
    }

    func retryCleanup() {
        guard cleanupPending, let route = engine else { return }
        let reason = lifecycle.pendingCleanupReason ?? .userStop
        state = lifecycle.intent == .running && reason == .outputRecovery ? .recovering : .stopping
        performCleanup(route: route, operation: generation, reason: reason)
    }

    private func removeListenerSession(epoch: UInt64? = nil) {
        let registeredEpoch = epoch ?? listenerSessionEpoch
        guard listenerSessionActive else { return }
        listenerSessionActive = false
        listenerSessionEpoch &+= 1
        activeDeviceListenerToken = nil
        let listeners = outputListeners
        audioQueue.async { listeners.removeSessionListeners(sessionEpoch: registeredEpoch) }
    }

    func applyChanges() {
        guard isRunning, hasPendingChanges, let route = engine else { return }
        lifecycle.beginCleanup(reason: .applyChanges)
        stopRouteMonitor()
        _ = startupControl?.requestStop("apply updated DSP settings")
        state = .stopping
        performCleanup(route: route, operation: generation, reason: .applyChanges)
    }

    private func performCleanup(route: AudioTapEngine,
                                operation: Int,
                                reason: SessionLifecycleReducer.CleanupReason) {
        guard !cleanupInFlight else { return }
        cleanupInFlight = true
        let listeners = outputListeners
        let sessionEpoch = listenerSessionEpoch
        audioQueue.async { [weak self] in
            let success = route.stop()
            if success && (reason == .outputRecovery || reason == .userStop || reason == .quit) {
                listeners.removeActiveDeviceListener()
            }
            DispatchQueue.main.async {
                guard let self, self.generation == operation else { return }
                self.cleanupInFlight = false
                if success {
                    self.engine = nil
                    self.startupControl = nil
                    self.activeMode = nil
                    switch self.lifecycle.cleanupSucceeded(reason: reason) {
                    case .quit:
                        self.removeListenerSession(epoch: sessionEpoch)
                        NSApp.terminate(nil)
                    case .restart:
                        self.beginStart()
                    case .recover:
                        self.activeDeviceListenerToken = nil
                        self.recoveryIsActive = true
                        self.scheduleNextRecoveryAttempt()
                    case .stopped:
                        self.activeDeviceListenerToken = nil
                        if reason == .userStop || reason == .quit || self.lifecycle.intent == .stopped {
                            self.removeListenerSession(epoch: sessionEpoch)
                        }
                        if let routeFailure = self.routeFailureAfterStop {
                            self.routeFailureAfterStop = nil
                            self.state = .error(routeFailure)
                        } else {
                            self.state = .stopped
                        }
                    }
                } else {
                    self.lifecycle.cleanupFailed(reason: reason)
                    self.state = .error(self.cleanupIncompleteMessage(route.lastCleanupFailure))
                }
            }
        }
    }

    func quit() {
        lifecycle.requestQuit()
        recoveryWorkItem?.cancel()
        recoveryIsActive = false
        switch state {
        case .stopped:
            _ = lifecycle.cleanupSucceeded(reason: .quit)
            removeListenerSession()
            NSApp.terminate(nil)
        case .starting, .connecting:
            _ = startupControl?.requestStop("user requested quit")
            state = .stopping
        case .running:
            stop()
        case .recovering, .waitingForOutput, .stopping:
            if cleanupInFlight { break }
            if let route = engine {
                lifecycle.beginCleanup(reason: .quit)
                state = .stopping
                performCleanup(route: route, operation: generation, reason: .quit)
            } else {
                _ = lifecycle.cleanupSucceeded(reason: .quit)
                removeListenerSession()
                NSApp.terminate(nil)
            }
        case .error:
            if cleanupPending, let route = engine {
                state = .stopping
                lifecycle.beginCleanup(reason: .quit)
                performCleanup(route: route, operation: generation, reason: .quit)
            } else {
                removeListenerSession()
                NSApp.terminate(nil)
            }
        case .recoveryFailed:
            _ = lifecycle.cleanupSucceeded(reason: .quit)
            removeListenerSession()
            NSApp.terminate(nil)
        }
    }
}

@MainActor
struct LevelUpPopover: View {
    @ObservedObject var model: LevelUpModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            modePicker
            dspDetails
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            controls
            Divider()
            HStack {
                Text("Audio stays on this Mac")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { model.quit() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 350)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("Start LevelUp audio routing?", isPresented: Binding(
            get: { model.showStartConfirmation },
            set: { if !$0 { model.dismissStartConfirmation() } }
        ), titleVisibility: .visible) {
            Button("Start Routing", role: .destructive) { model.confirmStart() }
            Button("Cancel", role: .cancel) { model.dismissStartConfirmation() }
        } message: {
            Text("Start audio playback in another app before enabling LevelUp; the aggregate may wait for tap audio before callbacks begin. LevelUp temporarily mutes original app audio while routing it through this Mac. Stop LevelUp to restore normal playback. Audio is not recorded or sent anywhere.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(LinearGradient(colors: [.indigo, .blue], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text("LevelUp").font(.system(size: 16, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(model.stateColor).frame(width: 6, height: 6)
                    Text(model.stateTitle).font(.system(size: 11, weight: .medium)).foregroundStyle(model.stateColor)
                }
                if model.isRunning && model.routeHasCallbacks {
                    Text("Audio callbacks: \(model.callbackCount)")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.startupTimedOut {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("PROCESSING MODE")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Picker("Processing mode", selection: Binding(
                get: { model.selectedMode },
                set: { model.selectMode($0) }
            )) {
                ForEach(LevelUpModeChoice.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isBusy || model.cleanupPendingForUI)
        }
    }

    @ViewBuilder
    private var dspDetails: some View {
        if model.selectedMode == .custom {
            customControls
        } else if model.selectedMode == .bypass {
            infoCard(title: "Transparent bypass", detail: "Audio passes through unchanged. No compression or limiting is applied.")
        } else {
            presetCard
        }
    }

    private var presetCard: some View {
        let preset = DSPPreset(rawValue: model.selectedMode.rawValue) ?? .balanced
        let comp = preset.compressor
        let limiter = preset.limiter
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(preset.rawValue.capitalized) profile")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("STEREO LINKED")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                parameter("Threshold", String(format: "%.0f dBFS", comp.thresholdDBFS))
                parameter("Ratio", String(format: "%.1f:1", comp.ratio))
                parameter("Attack", String(format: "%.0f ms", comp.attackMilliseconds))
            }
            HStack(spacing: 0) {
                parameter("Release", String(format: "%.0f ms", comp.releaseMilliseconds))
                parameter("Makeup", String(format: "+%.0f dB", comp.makeupGainDB))
                parameter("Ceiling", String(format: "%.0f dBFS", limiter.ceilingDBFS))
            }
            Text("Sample-peak limiter · no lookahead")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var customControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("CUSTOM DSP")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            slider("Threshold", value: floatBinding(get: { model.customCompressor.thresholdDBFS }, set: { model.updateCompressor(threshold: $0) }), range: -60...0, format: "%.0f dBFS")
            slider("Ratio", value: floatBinding(get: { model.customCompressor.ratio }, set: { model.updateCompressor(ratio: $0) }), range: 1...20, format: "%.1f:1")
            slider("Attack", value: floatBinding(get: { model.customCompressor.attackMilliseconds }, set: { model.updateCompressor(attack: $0) }), range: 0.1...2_000, format: "%.1f ms")
            slider("Release", value: floatBinding(get: { model.customCompressor.releaseMilliseconds }, set: { model.updateCompressor(release: $0) }), range: 1...5_000, format: "%.0f ms")
            slider("Makeup gain", value: floatBinding(get: { model.customCompressor.makeupGainDB }, set: { model.updateCompressor(makeup: $0) }), range: 0...24, format: "+%.1f dB")
            slider("Limiter ceiling", value: floatBinding(get: { model.customLimiter.ceilingDBFS }, set: { model.updateLimiter(ceiling: $0) }), range: -12...0, format: "%.1f dBFS")
            slider("Limiter release", value: floatBinding(get: { model.customLimiter.releaseMilliseconds }, set: { model.updateLimiter(release: $0) }), range: 1...5_000, format: "%.0f ms")
            Text("Edits are staged. Apply them to restart the route safely.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var controls: some View {
        VStack(spacing: 9) {
            if model.isRunning && model.hasPendingChanges {
                Button { model.applyChanges() } label: {
                    Label("Apply Changes", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            }

            switch model.state {
            case .stopped:
                Button { model.requestStart() } label: {
                    Label("Start LevelUp", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            case .starting:
                Button { model.stop() } label: {
                    Label("Cancel Start", systemImage: "xmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            case .running:
                Button { model.stop() } label: {
                    Label("Stop LevelUp", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            case .recovering, .waitingForOutput, .connecting:
                Button { model.stop() } label: {
                    Label("Stop Recovery", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            case .stopping:
                HStack {
                    ProgressView("Stopping safely…")
                    Spacer()
                    Button("Stop") { model.stop() }
                        .buttonStyle(.bordered)
                }
            case .recoveryFailed:
                HStack {
                    Button { model.stop() } label: {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button { model.retryRecovery() } label: {
                        Label("Retry Recovery", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                }
            case .error:
                if model.cleanupPendingForUI {
                    HStack {
                        if model.runningIntentPendingCleanup {
                            Button { model.stop() } label: {
                                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        Button { model.retryCleanup() } label: {
                            Label("Retry Cleanup", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                } else {
                    Button { model.requestStart() } label: {
                        Label("Try Again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                }
            }
        }
        .controlSize(.large)
    }

    private func parameter(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
        .disabled(model.isBusy || model.cleanupPendingForUI)
    }

    private func floatBinding(get: @escaping () -> Float, set: @escaping (Float) -> Void) -> Binding<Double> {
        Binding(get: { Double(get()) }, set: { set(Float($0)) })
    }

    private func infoCard(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
private extension LevelUpModel {
    var cleanupPendingForUI: Bool { cleanupPending }
}

@MainActor
final class LevelUpAppDelegate: NSObject, NSApplicationDelegate {
    private let model = LevelUpModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticLog.configure(requestedPath: "/private/tmp/levelup-menu-bar-\(getpid()).log")
        DiagnosticLog.write("menu-bar application launched: pid=\(getpid()); bundleID=\(Bundle.main.bundleIdentifier ?? "<missing>"); capture remains local-only")
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "LevelUp audio control")
            button.title = " LevelUp"
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.setAccessibilityLabel("LevelUp audio control")
        }
        statusItem = item
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: LevelUpPopover(model: model))
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

@MainActor
func launchMenuBarApplication() {
    let application = NSApplication.shared
    let delegate = LevelUpAppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) {
        application.run()
    }
}
