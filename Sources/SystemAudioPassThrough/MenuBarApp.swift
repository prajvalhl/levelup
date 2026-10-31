import AppKit
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
        case stopping
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
    private var engine: AudioTapEngine?
    private var startupControl: StartupControl?
    private var activeMode: DSPMode?
    private var lifecycle = SessionLifecycleReducer()
    private var cleanupPending: Bool { lifecycle.cleanupPending }
    private var generation: Int { lifecycle.generation }
    private var routeMonitor: DispatchSourceTimer?
    private var outputCheckGate = OutputCheckGate()
    private var routeMonitorStartNanoseconds: UInt64 = 0
    private var lastCallbackProgressNanoseconds: UInt64 = 0
    private var lastObservedCallbackCount: UInt64 = 0
    private var routeFailureAfterStop: String?

    var isBusy: Bool {
        switch state {
        case .starting, .stopping: return true
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
        case .running:
            if !routeHasCallbacks { return "Waiting for audio callbacks" }
            if hasPendingChanges { return "Running · changes pending" }
            if case .bypass = activeMode { return "Enabled · Bypass" }
            if case let .preset(preset) = activeMode { return "Running · \(preset.rawValue.capitalized)" }
            if case .custom = activeMode { return "Running · Custom" }
            return "Running"
        case .stopping: return "Stopping"
        case .error: return "Needs attention"
        }
    }

    var stateSymbol: String {
        switch state {
        case .stopped: return "power"
        case .starting: return "ellipsis.circle"
        case .running: return selectedMode == .bypass ? "waveform" : "waveform.circle.fill"
        case .stopping: return "stop.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var stateColor: Color {
        switch state {
        case .stopped: return .secondary
        case .starting, .stopping: return .orange
        case .running: return .green
        case .error: return .red
        }
    }

    var errorMessage: String? {
        guard case let .error(message) = state else { return nil }
        return message
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
        let requestedMode = selectedDSPMode
        let control = StartupControl()
        let route = AudioTapEngine(dspMode: requestedMode,
                                   startupCancellationReason: { control.cancellationReason() })
        startupControl = control
        engine = route
        activeMode = nil
        startupTimedOut = false
        routeHasCallbacks = false
        callbackCount = 0
        routeFailureAfterStop = nil
        state = .starting

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
                try route.start()
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
            lifecycle.beginCleanup()
            state = .stopping
            performCleanup(route: route, operation: operation, restartAfter: false)
            return
        }
        startupTimedOut = false
        activeMode = mode
        state = .running
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
                failure = "No audio callbacks arrived within five seconds. This alone does not prove Core Audio failed; the tap may still be waiting for audio. The route was stopped safely. Start playback before trying again."
            } else if callbacks > 0 && Self.elapsedMilliseconds(since: self.lastCallbackProgressNanoseconds, now: now) >= 5_000 {
                failure = "Audio callbacks stopped for five seconds. The route was stopped safely. You can try again."
            } else {
                failure = nil
            }
            if let failure {
                self.failRunningRoute(route: route, operation: operation, message: failure)
                return
            }
            self.checkDefaultOutputOffMain(route: route, operation: operation)
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

    /// Core Audio property queries and their diagnostic logging run on the
    /// serialized control queue, never on the UI queue or IOProc callback.
    private func checkDefaultOutputOffMain(route: AudioTapEngine, operation: Int) {
        guard generation == operation, isRunning, outputCheckGate.begin(generation: operation) else { return }
        audioQueue.async { [weak self] in
            let unchanged = route.isStillOnDefaultOutput()
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.outputCheckGate.complete(generation: operation, currentGeneration: self.generation),
                      self.isRunning else { return }
                if !unchanged {
                    self.failRunningRoute(route: route,
                                          operation: operation,
                                          message: "The default output changed or could not be verified while LevelUp was running. The route was stopped safely.")
                }
            }
        }
    }

    private func failRunningRoute(route: AudioTapEngine, operation: Int, message: String) {
        guard generation == operation, isRunning else { return }
        routeFailureAfterStop = message
        stopRouteMonitor()
        _ = startupControl?.requestStop("menu-bar route health failure")
        state = .stopping
        performCleanup(route: route, operation: operation, restartAfter: false)
    }

    private func finishStart(operation: Int,
                             failure: String?,
                             pendingStop: String?,
                             cleanupSucceeded: Bool,
                             cleanupFailure: String?) {
        guard generation == operation else { return }
        startupTimedOut = false
        _ = lifecycle.startupFailed(generation: operation, cleanupSucceeded: cleanupSucceeded)
        if cleanupSucceeded {
            engine = nil
            startupControl = nil
            activeMode = nil
        }
        if cleanupSucceeded && lifecycle.quitRequested {
            _ = lifecycle.cleanupSucceeded(restartAfter: false)
            NSApp.terminate(nil)
        } else if pendingStop == "user requested stop" {
            state = cleanupSucceeded ? .stopped : .error(cleanupIncompleteMessage(cleanupFailure))
        } else if pendingStop == "user requested quit" {
            state = cleanupSucceeded ? .stopped : .error("Quit is waiting for Core Audio cleanup to complete. \(cleanupIncompleteMessage(cleanupFailure))")
        } else if pendingStop == "startup deadline expired" {
            state = .error(cleanupSucceeded
                ? "Startup exceeded 30 seconds and was stopped safely. You can try again."
                : "Startup exceeded 30 seconds. \(cleanupIncompleteMessage(cleanupFailure))")
        } else if let failure {
            state = .error(cleanupSucceeded
                ? "Could not start audio: \(failure)"
                : "Could not start audio: \(failure). \(cleanupIncompleteMessage(cleanupFailure))")
        } else {
            state = cleanupSucceeded ? .stopped : .error(cleanupIncompleteMessage(cleanupFailure))
        }
    }

    private func cleanupIncompleteMessage(_ detail: String?) -> String {
        let operation = detail ?? "Core Audio did not confirm that all resources were released."
        return "Cleanup incomplete: \(operation). Resources remain retained. Retry Cleanup before starting again. Log: \(DiagnosticLog.path)"
    }

    func stop() {
        if case .starting = state {
            lifecycle.requestStop()
            _ = startupControl?.requestStop("user requested stop")
            state = .stopping
            return
        }
        if case .running = state {
            guard let route = engine else { state = .error("Audio engine state was unavailable."); return }
            lifecycle.requestStop()
            stopRouteMonitor()
            _ = startupControl?.requestStop("user requested stop")
            state = .stopping
            performCleanup(route: route, operation: generation, restartAfter: false)
            return
        }
        if cleanupPending, let route = engine {
            lifecycle.requestStop()
            state = .stopping
            lifecycle.beginCleanup()
            performCleanup(route: route, operation: generation, restartAfter: false)
        }
    }

    func applyChanges() {
        guard isRunning, hasPendingChanges, let route = engine else { return }
        lifecycle.beginCleanup()
        stopRouteMonitor()
        _ = startupControl?.requestStop("apply updated DSP settings")
        state = .stopping
        performCleanup(route: route, operation: generation, restartAfter: true)
    }

    private func performCleanup(route: AudioTapEngine, operation: Int, restartAfter: Bool) {
        audioQueue.async { [weak self] in
            let success = route.stop()
            DispatchQueue.main.async {
                guard let self, self.generation == operation else { return }
                if success {
                    self.engine = nil
                    self.startupControl = nil
                    self.activeMode = nil
                    switch self.lifecycle.cleanupSucceeded(restartAfter: restartAfter) {
                    case .quit:
                        NSApp.terminate(nil)
                    case .restart:
                        self.beginStart()
                    case .stopped:
                        if let routeFailure = self.routeFailureAfterStop {
                            self.routeFailureAfterStop = nil
                            self.state = .error(routeFailure)
                        } else {
                            self.state = .stopped
                        }
                    }
                } else {
                    self.lifecycle.cleanupFailed()
                    self.state = .error(self.cleanupIncompleteMessage(route.lastCleanupFailure))
                }
            }
        }
    }

    func quit() {
        lifecycle.requestQuit()
        switch state {
        case .stopped:
            _ = lifecycle.cleanupSucceeded(restartAfter: false)
            NSApp.terminate(nil)
        case .starting:
            _ = startupControl?.requestStop("user requested quit")
            state = .stopping
        case .running:
            stop()
        case .stopping:
            break
        case .error:
            if cleanupPending, let route = engine {
                state = .stopping
                lifecycle.beginCleanup()
                performCleanup(route: route, operation: generation, restartAfter: false)
            } else {
                NSApp.terminate(nil)
            }
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
            case .stopping:
                ProgressView("Stopping safely…").frame(maxWidth: .infinity)
            case .error:
                if model.cleanupPendingForUI {
                    Button { model.stop() } label: {
                        Label("Retry Cleanup", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
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
        .disabled(model.isBusy)
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
