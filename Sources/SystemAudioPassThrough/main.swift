import Darwin
import Foundation
import LevelUpDSP
import PrototypeSupport

func runCommandLinePrototype(arguments: [String]) {
let requiredArgument = "--i-understand-system-audio-will-be-muted"
let parsedArguments: LaunchArguments
do {
    parsedArguments = try LaunchArguments(arguments, flags: [requiredArgument])
} catch {
    DiagnosticLog.configure(requestedPath: nil)
    DiagnosticLog.write("argument parsing failed: \(error); pid=\(getpid()); bundleID=\(Bundle.main.bundleIdentifier ?? "<missing>"); executable=\(Bundle.main.executableURL?.path ?? CommandLine.arguments[0]); effectiveLogPath=\(DiagnosticLog.path)")
    exit(64)
}

DiagnosticLog.configure(requestedPath: parsedArguments["--log-path"])
let bundleID = Bundle.main.bundleIdentifier ?? "<missing>"
guard parsedArguments.contains(requiredArgument) else {
    DiagnosticLog.write("missing required mute acknowledgement; pid=\(getpid()), bundleID=\(bundleID), executable=\(Bundle.main.executableURL?.path ?? CommandLine.arguments[0]), effectiveLogPath=\(DiagnosticLog.path)")
    exit(64)
}
guard let launchMethod = parsedArguments["--launch-method"] else {
    DiagnosticLog.write("missing required --launch-method; pid=\(getpid()), bundleID=\(bundleID), effectiveLogPath=\(DiagnosticLog.path)")
    exit(64)
}
let requestedDSPMode = parsedArguments["--dsp-mode"] ?? "bypass"
guard let dspMode = DSPMode(argument: requestedDSPMode) else {
    DiagnosticLog.write("invalid --dsp-mode value '\(requestedDSPMode)'; expected bypass, gentle, balanced, or strong; pid=\(getpid()), bundleID=\(bundleID), effectiveLogPath=\(DiagnosticLog.path)")
    exit(64)
}

DiagnosticLog.write("application launch: pid=\(getpid()), bundleID=\(bundleID), executable=\(Bundle.main.executableURL?.path ?? CommandLine.arguments[0]), launchMethod=\(launchMethod), dspMode=\(dspMode.name), effectiveLogPath=\(DiagnosticLog.path), arguments=\(CommandLine.arguments.dropFirst().joined(separator: " "))")
DiagnosticLog.write("capture authorization status=indeterminate at launch; this prototype has no supported direct query for the system-audio capture grant")

let engineControl = StartupControl()
let engine = AudioTapEngine(dspMode: dspMode, startupCancellationReason: { engineControl.cancellationReason() })
var cleanupInProgress = false
var cleanupRetryAttempt = 0
let cleanupLock = NSLock()

func finishWhenCleanupCompletes(exitCode: Int, retrying: Bool = false) {
    cleanupLock.lock()
    let shouldRun = retrying || !cleanupInProgress
    cleanupInProgress = true
    cleanupLock.unlock()
    guard shouldRun else { return }
    if engine.stop() {
        DiagnosticLog.write("orderly cleanup complete; exitCode=\(exitCode), defaultOutputUIDUnchanged=\(engine.isStillOnDefaultOutput())")
        exit(Int32(exitCode))
    }
    cleanupRetryAttempt += 1
    let retryDelaySeconds: Int
    switch cleanupRetryAttempt {
    case 1: retryDelaySeconds = 1
    case 2: retryDelaySeconds = 2
    case 3: retryDelaySeconds = 4
    default: retryDelaySeconds = 8
    }
    DiagnosticLog.write("cleanup still incomplete; callback context and dependent resources remain retained; retryAttempt=\(cleanupRetryAttempt), retryDelaySeconds=\(retryDelaySeconds)")
    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(retryDelaySeconds)) {
        finishWhenCleanupCompletes(exitCode: exitCode, retrying: true)
    }
}

// Install signal delivery before starting any Core Audio operation that can
// create resources. During startup, handlers request cancellation only; the
// engine observes it after each synchronous Core Audio call and cleans up on
// the startup thread, avoiding concurrent teardown of partially built state.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let signals = DispatchQueue(label: "com.levelup.prototype.signals")
let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signals)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signals)
let signalHandler: (String) -> Void = { reason in
    DiagnosticLog.write("orderly shutdown requested: \(reason); pid=\(getpid())")
    if engineControl.requestStop(reason) {
        finishWhenCleanupCompletes(exitCode: 0)
    } else {
        DiagnosticLog.write("shutdown request recorded during startup; cleanup will run after the current Core Audio operation returns")
    }
}
intSource.setEventHandler { signalHandler("SIGINT") }
termSource.setEventHandler { signalHandler("SIGTERM") }
intSource.resume()
termSource.resume()

let startupTimeoutSeconds = 30
let startupTimeout = DispatchSource.makeTimerSource(queue: signals)
startupTimeout.schedule(deadline: .now() + .seconds(startupTimeoutSeconds))
startupTimeout.setEventHandler {
    guard engineControl.requestStartupTimeout() == true else { return }
    DiagnosticLog.write("STARTUP TIMEOUT: no completed route after \(startupTimeoutSeconds)s; cancellation recorded. Core Audio synchronous calls cannot be force-cancelled safely; ordered cleanup will begin as soon as the current call returns")
}
startupTimeout.resume()

DiagnosticLog.write("startup deadline armed: \(startupTimeoutSeconds)s; SIGINT/SIGTERM cleanup handling is active before engine.start")
var startupError: Error?
do {
    try engine.start()
} catch {
    startupError = error
    DiagnosticLog.write("START FAILED: \(error); capture authorization remains indeterminate unless an explicit authorization result is exposed by Core Audio; ordered cleanup will retry until complete")
}

let pendingStopReason = engineControl.completeStartup()
startupTimeout.cancel()
if startupError != nil {
    let exitCode = pendingStopReason == "startup deadline expired" ? 2 : (pendingStopReason == nil ? 1 : 0)
    finishWhenCleanupCompletes(exitCode: exitCode)
    dispatchMain()
}

DiagnosticLog.write("route active: pid=\(getpid()), bundleID=\(bundleID), output=\(engine.deviceName), UID=\(engine.deviceUID), nominalRate=\(engine.rate), bufferFrames=\(engine.bufferFrames), physicalFormat={\(engine.outputFormatDescription)}, tapFormat={\(engine.tapDescription)}, dspMode=\(engine.dspModeName), startupElapsedMs=\(engine.startupElapsedMilliseconds), captureAuthorization=indeterminate (tap/device status and buffer contents are not a direct permission query)")
if let pendingStopReason {
    DiagnosticLog.write("startup completed after a pending shutdown request: \(pendingStopReason); cleaning up without entering the callback monitor")
    finishWhenCleanupCompletes(exitCode: pendingStopReason == "startup deadline expired" ? 2 : 0)
    dispatchMain()
}

var lastCallbackCount = engine.callbackCount
var lastCallbackProgress = Date()
var firstCallbackLogged = false
let timer = DispatchSource.makeTimerSource(queue: signals)
timer.schedule(deadline: .now() + 1, repeating: 1)
timer.setEventHandler {
    let now = Date()
    let callbacks = engine.callbackCount
    engine.logAggregateRunningState(stage: "active-route watchdog poll")
    if callbacks > 0 && !firstCallbackLogged {
        firstCallbackLogged = true
        DiagnosticLog.write(String(format: "first callback observed: elapsedSinceMetricsStartMs=%.3f callbacks=%llu inputPeak=%.6f outputPeak=%.6f; captureAuthorization=indeterminate (observed data is not a permission-status query)", engine.firstCallbackElapsedMilliseconds, callbacks, engine.inputPeak, engine.outputPeak))
    }
    if callbacks != lastCallbackCount {
        lastCallbackCount = callbacks
        lastCallbackProgress = now
    }
    let inputDB = engine.inputPeak > 0 ? 20 * log10(Double(engine.inputPeak)) : -120
    let outputDB = engine.outputPeak > 0 ? 20 * log10(Double(engine.outputPeak)) : -120
    let callbackBudget = engine.callbackBudgetMilliseconds
    let maxBudgetPercent = callbackBudget > 0 ? engine.maximumCallbackMilliseconds / callbackBudget * 100 : 0
    DiagnosticLog.write(String(format: "callback status: startupElapsedMs=%.1f callbacks=%llu silentInputStreak=%llu msSinceLastCallback=%.1f inputPeak=%.6f (%.1f dBFS) outputPeak=%.6f (%.1f dBFS) callbackAvgMs=%.4f callbackMaxMs=%.4f callbackBudgetMs=%.3f maxBudgetPercent=%.2f captureAuthorization=indeterminate", engine.startupElapsedMilliseconds, callbacks, engine.silentCallbacks, engine.millisecondsSinceLastCallback, engine.inputPeak, inputDB, engine.outputPeak, outputDB, engine.averageCallbackMilliseconds, engine.maximumCallbackMilliseconds, callbackBudget, maxBudgetPercent))

    if callbacks == 0 && now.timeIntervalSince(lastCallbackProgress) >= 5 {
        DiagnosticLog.write("ROUTE FAILURE: no callbacks observed for 5s (distinct from callbacks carrying silent input); stopping safely")
        _ = engineControl.requestStop("no callbacks watchdog")
        finishWhenCleanupCompletes(exitCode: 4)
        return
    }
    if callbacks > 0 && now.timeIntervalSince(lastCallbackProgress) >= 5 {
        DiagnosticLog.write("ROUTE FAILURE: callbacks started, then stopped for 5s; stopping safely")
        _ = engineControl.requestStop("callback-stopped watchdog")
        finishWhenCleanupCompletes(exitCode: 5)
        return
    }
    if !engine.isStillOnDefaultOutput() {
        DiagnosticLog.write("ROUTE FAILURE: default output changed while tap active; stopping safely")
        _ = engineControl.requestStop("default output changed")
        finishWhenCleanupCompletes(exitCode: 3)
        return
    }
    if callbacks > 0 && engine.silentCallbacks > 0 && Int(engine.startupElapsedMilliseconds / 1000) % 60 == 0 {
        DiagnosticLog.write("CAPTURE NOTE: callbacks continue but current input buffers are silent; capture authorization remains indeterminate (silence can also mean idle or unsupported content)")
    }
}
timer.resume()
dispatchMain()
}

let launchArguments = Array(CommandLine.arguments.dropFirst())
if launchArguments.isEmpty {
    MainActor.assumeIsolated {
        launchMenuBarApplication()
    }
} else {
    runCommandLinePrototype(arguments: launchArguments)
}
