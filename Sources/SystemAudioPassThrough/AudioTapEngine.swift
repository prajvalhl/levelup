import AudioMetrics
import Accelerate
import CoreAudio
import Darwin
import Foundation
import LevelUpDSP
import PrototypeSupport

private final class AudioCallbackContext {
    let pointer: OpaquePointer
    var dspProcessor: DSPProcessor

    init(mode: DSPMode, sampleRate: Double, channelCount: Int) throws {
        guard let pointer = audio_metrics_create() else {
            throw AudioDeviceError.osStatus("allocate audio metrics", -1)
        }
        do {
            dspProcessor = try DSPProcessor(mode: mode, sampleRate: sampleRate, channelCount: channelCount)
        } catch {
            audio_metrics_destroy(pointer)
            throw error
        }
        self.pointer = pointer
    }

    deinit { audio_metrics_destroy(pointer) }
}

/// The UI owns each engine on one serial control queue. Startup cancellation is
/// synchronized by `StartupControl`, and callback storage is retained until
/// Core Audio confirms IOProc destruction, so crossings between those queues
/// preserve the engine's lifecycle invariants.
final class AudioTapEngine: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var callbackContext: AudioCallbackContext?
    private var cleanupLifecycle = AudioCleanupLifecycle()
    private var startupStartNanoseconds: UInt64 = 0
    private var audioDeviceStartAttemptNanoseconds: UInt64 = 0
    private var defaultOutputID = AudioDeviceID(kAudioObjectUnknown)
    private let dspMode: DSPMode
    private let startupCancellationReason: () -> String?
    private let expectedOutputIdentity: OutputDeviceIdentity?

    private(set) var deviceName = ""
    private(set) var deviceUID = ""
    private(set) var rate: Double = 0
    private(set) var outputFormatDescription = ""
    private(set) var bufferFrames: UInt32 = 0
    private(set) var tapDescription = ""
    private(set) var tapUID = ""
    private(set) var outputIdentity: OutputDeviceIdentity?
    private(set) var started = false
    private(set) var lastCleanupFailure: String?

    init(dspMode: DSPMode = .bypass,
         expectedOutputIdentity: OutputDeviceIdentity? = nil,
         startupCancellationReason: @escaping () -> String? = { nil }) {
        self.dspMode = dspMode
        self.expectedOutputIdentity = expectedOutputIdentity
        self.startupCancellationReason = startupCancellationReason
    }

    func start() throws {
        guard !started else { return }
        startupStartNanoseconds = DispatchTime.now().uptimeNanoseconds
        DiagnosticLog.write("startup stage begin: engine start; pid=\(getpid())")
        DiagnosticLog.write("DSP mode selected: \(dspMode.name)")

        do {
            // Resolve the destination before creating a muted tap. If there is
            // no usable default output, fail without muting any source process.
            let resolvedOutput = try resolveDefaultOutputSnapshot()
            let output = AudioDeviceID(resolvedOutput.snapshot.identity.deviceID)
            if let expectedOutputIdentity, expectedOutputIdentity != resolvedOutput.snapshot.identity {
                throw AudioDeviceError.startupCancelled("the default output changed after it was validated")
            }
            outputIdentity = resolvedOutput.snapshot.identity
            defaultOutputID = output
            deviceName = resolvedOutput.snapshot.name
            deviceUID = resolvedOutput.snapshot.identity.uid
            rate = resolvedOutput.snapshot.nominalSampleRate
            let physicalFormat = resolvedOutput.format
            guard physicalFormat.mChannelsPerFrame > 0,
                  (physicalFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
                  physicalFormat.mBitsPerChannel == 32 else {
                throw AudioDeviceError.osStatus("default output must expose Float32 PCM with channels", -1)
            }
            outputFormatDescription = formatSummary(physicalFormat)
            DiagnosticLog.write("OUTPUT VALIDATED before tap: deviceID=\(output) name=\(deviceName) UID=\(deviceUID) nominalRate=\(rate) physicalFormat={\(outputFormatDescription)}")
            markStartupStage("default output and physical output format validated")
            try checkStartupCancellation("after default-output validation")

            let processAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var processIDs: [AudioObjectID] = []
            var processBytes: UInt32 = 0
            var processAddressCopy = processAddress
            let processSizeStatus = AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &processAddressCopy, 0, nil, &processBytes
            )
            DiagnosticLog.write("CoreAudio process-list size: \(statusDescription(processSizeStatus)); bytes=\(processBytes)")
            try check(processSizeStatus, "read process list size")
            processIDs = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: Int(processBytes) / MemoryLayout<AudioObjectID>.size)
            if processBytes > 0 {
                let processListStatus = processIDs.withUnsafeMutableBufferPointer { buffer in
                    AudioObjectGetPropertyData(
                        AudioObjectID(kAudioObjectSystemObject), &processAddressCopy, 0, nil, &processBytes, buffer.baseAddress!
                    )
                }
                DiagnosticLog.write("CoreAudio process-list data: \(statusDescription(processListStatus)); bytes=\(processBytes), processObjectIDs=\(processIDs)")
                try check(processListStatus, "read process list")
            }
            let ownPID = getpid()
            let ownProcess = processIDs.first { processID in
                var pid = pid_t(0)
                var size = UInt32(MemoryLayout<pid_t>.size)
                let result = AudioObjectGetPropertyData(processID, &pidAddress, 0, nil, &size, &pid)
                DiagnosticLog.write("CoreAudio process PID property objectID=\(processID): \(statusDescription(result)); dataSize=\(size), pid=\(pid)")
                return result == noErr && pid == ownPID
            }
            guard let ownProcess else { throw AudioDeviceError.osStatus("find this process in Core Audio", -1) }
            DiagnosticLog.write("own process resolved: pid=\(ownPID), AudioObjectID=\(ownProcess)")
            markStartupStage("own Core Audio process object resolved")
            try checkStartupCancellation("before process-tap creation")

            let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
            tap.name = "LevelUp Pass Through Proof of Concept"
            tap.isPrivate = true
            tap.muteBehavior = .muted
            DiagnosticLog.write("capture authorization status=indeterminate; requesting system-audio capture by invoking AudioHardwareCreateProcessTap; the OS prompt may be asynchronous and no supported permission-status query is available here")
            let tapBeginMilliseconds = startupElapsedMilliseconds
            DiagnosticLog.write(String(format: "CoreAudio AudioHardwareCreateProcessTap begin; elapsedMs=%.3f; captureAuthorization=indeterminate", tapBeginMilliseconds))
            let tapStatus = AudioHardwareCreateProcessTap(tap, &tapID)
            DiagnosticLog.write(String(format: "CoreAudio AudioHardwareCreateProcessTap returned %@; elapsedMs=%.3f; tapID=%u UUID=%@; captureAuthorization=indeterminate (object creation does not prove authorization)", statusDescription(tapStatus), startupElapsedMilliseconds, tapID, tap.uuid.uuidString))
            if tapID != AudioObjectID(kAudioObjectUnknown) { cleanupLifecycle.tapCreated() }
            try check(tapStatus, "create muted system-audio tap")
            try checkStartupCancellation("after process-tap creation")
            tapUID = try stringProperty(kAudioTapPropertyUID, on: tapID, name: "tap UID")
            DiagnosticLog.write("tap identity: objectID=\(tapID), CATapDescription.uuid=\(tap.uuid.uuidString), kAudioTapPropertyUID=\(tapUID)")
            guard tapUID.caseInsensitiveCompare(tap.uuid.uuidString) == .orderedSame else {
                throw AudioDeviceError.osStatus("tap UUID differs from the tap object's reported UID", -1)
            }
            logTapDescription()

            let format = try tapFormat(of: tapID)
            tapDescription = formatSummary(format)
            guard (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
                  format.mBitsPerChannel == 32,
                  format.mChannelsPerFrame > 0 else {
                throw AudioDeviceError.osStatus("unsupported tap format (expected Float32 PCM)", -1)
            }
            callbackContext = try AudioCallbackContext(mode: dspMode,
                                                       sampleRate: format.mSampleRate,
                                                       channelCount: Int(format.mChannelsPerFrame))
            DiagnosticLog.write("DSP callback context allocated before IOProc: mode=\(dspMode.name), sampleRate=\(format.mSampleRate), channels=\(format.mChannelsPerFrame)")
            markStartupStage("callback context and DSP processor allocated")
            markStartupStage("muted process tap created and format validated")

            let aggregateUID = "com.levelup.prototyper.aggregate.\(UUID().uuidString)"
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "LevelUp Pass Through Proof of Concept",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            DiagnosticLog.write("aggregate creation requested: name=LevelUp Pass Through Proof of Concept, UID=\(aggregateUID), outputDeviceUID=\(deviceUID), tapUID=\(tapUID), tapAutoStart=true (installed SDK: start waits for the first tap receiving audio)")
            DiagnosticLog.write("CoreAudio AudioHardwareCreateAggregateDevice begin; monotonicNs=\(DispatchTime.now().uptimeNanoseconds); elapsedMs=\(startupElapsedMilliseconds); requestedUID=\(aggregateUID)")
            let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
            DiagnosticLog.write("CoreAudio AudioHardwareCreateAggregateDevice returned \(statusDescription(aggregateStatus)); monotonicNs=\(DispatchTime.now().uptimeNanoseconds); elapsedMs=\(startupElapsedMilliseconds); aggregateDeviceID=\(aggregateID); requestedUID=\(aggregateUID)")
            if aggregateID != AudioObjectID(kAudioObjectUnknown) { cleanupLifecycle.aggregateCreated() }
            try check(aggregateStatus, "create private aggregate device")
            try checkStartupCancellation("after aggregate-device creation")
            markStartupStage("private aggregate device created")

            try validateAggregateMembership(aggregateID,
                                            physicalOutputID: output,
                                            physicalOutputUID: deviceUID,
                                            tapID: tapID,
                                            tapUID: tapUID)
            markStartupStage("aggregate membership and stream formats validated")
            try checkStartupCancellation("after aggregate membership validation")

            var frameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var frameSize = UInt32(MemoryLayout<UInt32>.size)
            let frameStatus = AudioObjectGetPropertyData(aggregateID, &frameAddress, 0, nil, &frameSize, &bufferFrames)
            DiagnosticLog.write("CoreAudio aggregate buffer-size query aggregateID=\(aggregateID): \(statusDescription(frameStatus)); dataSize=\(frameSize), frames=\(bufferFrames)")
            try check(frameStatus, "read aggregate buffer size")
            try checkStartupCancellation("after aggregate buffer-size query")

            guard let callbackContext else { throw AudioDeviceError.osStatus("callback context unavailable", -1) }
            DiagnosticLog.write(String(format: "CoreAudio AudioDeviceCreateIOProcIDWithBlock begin; elapsedMs=%.3f; aggregateID=%u; callbackContextRetained=true", startupElapsedMilliseconds, aggregateID))
            let ioProcCreateStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, DispatchQueue(label: "com.levelup.prototype.audio", qos: .userInteractive)) {
                _, input, _, output, _ in
                let callbackStartTicks = audio_metrics_callback_begin()
                let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                let outputs = UnsafeMutableAudioBufferListPointer(output)
                var inputPeak: Float = 0
                var outputPeak: Float = 0

                for inBuffer in inputs {
                    guard let inData = inBuffer.mData else { continue }
                    let count = Int(inBuffer.mDataByteSize) / MemoryLayout<Float>.size
                    if count > 0 {
                        var bufferPeak: Float = 0
                        vDSP_maxmgv(inData.assumingMemoryBound(to: Float.self), 1, &bufferPeak, vDSP_Length(count))
                        inputPeak = max(inputPeak, bufferPeak)
                    }
                }

                if inputs.count == 1, outputs.count == 1,
                   let inData = inputs[0].mData, let outData = outputs[0].mData,
                   Int(inputs[0].mNumberChannels) == callbackContext.dspProcessor.channelCount,
                   Int(outputs[0].mNumberChannels) == callbackContext.dspProcessor.channelCount {
                    let bytes = min(Int(inputs[0].mDataByteSize), Int(outputs[0].mDataByteSize))
                    if callbackContext.dspProcessor.mode == .bypass {
                        // Keep the validated passthrough path byte-for-byte as a reference.
                        memcpy(outData, inData, bytes)
                    } else {
                        let frameBytes = callbackContext.dspProcessor.channelCount * MemoryLayout<Float>.size
                        let frameCount = bytes / frameBytes
                        if frameCount > 0 {
                            callbackContext.dspProcessor.process(
                                input: inData.assumingMemoryBound(to: Float.self),
                                output: outData.assumingMemoryBound(to: Float.self),
                                frameCount: frameCount
                            )
                            let processedBytes = frameCount * frameBytes
                            if processedBytes < Int(outputs[0].mDataByteSize) {
                                memset(outData.advanced(by: processedBytes), 0, Int(outputs[0].mDataByteSize) - processedBytes)
                            }
                        } else {
                            memset(outData, 0, Int(outputs[0].mDataByteSize))
                        }
                    }
                    let outputSamples = bytes / MemoryLayout<Float>.size
                    if outputSamples > 0 {
                        var bufferPeak: Float = 0
                        vDSP_maxmgv(outData.assumingMemoryBound(to: Float.self), 1, &bufferPeak, vDSP_Length(outputSamples))
                        outputPeak = bufferPeak
                    }
                    if Int(outputs[0].mDataByteSize) > bytes {
                        memset(outData.advanced(by: bytes), 0, Int(outputs[0].mDataByteSize) - bytes)
                    }
                } else {
                    for outIndex in outputs.indices {
                        guard let outData = outputs[outIndex].mData else { continue }
                        memset(outData, 0, Int(outputs[outIndex].mDataByteSize))
                    }
                }
                audio_metrics_record(callbackContext.pointer, inputPeak, outputPeak, callbackStartTicks)
            }
            DiagnosticLog.write(String(format: "CoreAudio AudioDeviceCreateIOProcIDWithBlock returned %@; elapsedMs=%.3f; aggregateID=%u; IOProcID=%@", statusDescription(ioProcCreateStatus), startupElapsedMilliseconds, aggregateID, String(describing: ioProcID)))
            if ioProcID != nil { cleanupLifecycle.ioProcCreated() }
            try check(ioProcCreateStatus, "create aggregate IO callback")
            try checkStartupCancellation("after IOProc creation")

            guard let ioProcID else { throw AudioDeviceError.osStatus("create aggregate IO callback", -1) }
            DiagnosticLog.write("CoreAudio IOProc confirmed created: aggregateID=\(aggregateID), IOProcID=\(String(describing: ioProcID))")
            markStartupStage("IOProc registered on aggregate device")
            if let expectedOutputIdentity {
                let latest = try resolveDefaultOutputSnapshot()
                guard latest.snapshot.identity == expectedOutputIdentity else {
                    throw AudioDeviceError.startupCancelled("the default output changed before AudioDeviceStart")
                }
            }
            audioDeviceStartAttemptNanoseconds = DispatchTime.now().uptimeNanoseconds
            logAggregateRunningState(stage: "immediately before AudioDeviceStart")
            DiagnosticLog.write(String(format: "CoreAudio AudioDeviceStart begin; elapsedMs=%.3f; aggregateID=%u; IOProcID=%@; captureAuthorization=indeterminate", startupElapsedMilliseconds, aggregateID, String(describing: ioProcID)))
            cleanupLifecycle.ioProcStartAttempted()
            let startStatus = AudioDeviceStart(aggregateID, ioProcID)
            DiagnosticLog.write(String(format: "CoreAudio AudioDeviceStart returned %@; elapsedMs=%.3f; aggregateID=%u; captureAuthorization=indeterminate", statusDescription(startStatus), startupElapsedMilliseconds, aggregateID))
            logAggregateRunningState(stage: "immediately after AudioDeviceStart")
            try check(startStatus, "start aggregate audio")
            cleanupLifecycle.ioProcStarted()
            started = true
            try checkStartupCancellation("after AudioDeviceStart")
            DiagnosticLog.write("engine marked running")
            markStartupStage("AudioDeviceStart returned success")
        } catch {
            DiagnosticLog.write("engine startup failed: \(error); beginning ordered cleanup")
            let complete = stop()
            DiagnosticLog.write("startup cleanup complete=\(complete)")
            throw error
        }
    }

    private func markStartupStage(_ stage: String) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- startupStartNanoseconds) / 1_000_000
        DiagnosticLog.write(String(format: "startup stage complete: %@; elapsedMs=%.3f", stage, elapsed))
    }

    private func checkStartupCancellation(_ stage: String) throws {
        guard let reason = startupCancellationReason() else { return }
        DiagnosticLog.write("startup cancellation observed; monotonicNs=\(DispatchTime.now().uptimeNanoseconds); stage=\(stage); reason=\(reason); expectedOutput=\(String(describing: expectedOutputIdentity)); resolvedOutput=\(String(describing: outputIdentity)); beginning ordered cleanup")
        throw AudioDeviceError.startupCancelled(reason)
    }

    var startupElapsedMilliseconds: Double {
        guard startupStartNanoseconds != 0 else { return -1 }
        return Double(DispatchTime.now().uptimeNanoseconds &- startupStartNanoseconds) / 1_000_000
    }

    func logAggregateRunningState(stage: String) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &dataSize, &running)
        let runningValue: String
        if status == noErr && dataSize == UInt32(MemoryLayout<UInt32>.size) {
            runningValue = String(running)
        } else if status == noErr {
            runningValue = "unavailable (unexpected data size)"
        } else {
            runningValue = "unavailable"
        }
        let elapsedMilliseconds: Double
        if audioDeviceStartAttemptNanoseconds != 0 {
            elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds &- audioDeviceStartAttemptNanoseconds) / 1_000_000
        } else {
            elapsedMilliseconds = -1
        }
        DiagnosticLog.write(String(format: "CoreAudio aggregate running-state query stage=%@ aggregateID=%u: %@; dataSize=%u; running=%@; elapsedSinceAudioDeviceStartAttemptMs=%.3f; callbacks=%llu", stage, aggregateID, statusDescription(status), dataSize, runningValue, elapsedMilliseconds, callbackCount))
    }

    func aggregateIsRunning() -> Bool? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunning,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &running)
        guard status == noErr, size == UInt32(MemoryLayout<UInt32>.size), running <= 1 else {
            DiagnosticLog.write("CoreAudio aggregate health query kAudioDevicePropertyDeviceIsRunning aggregateID=\(aggregateID): \(statusDescription(status)); dataSize=\(size); value=\(running); callbacks=\(callbackCount)")
            return nil
        }
        DiagnosticLog.write("CoreAudio aggregate health query kAudioDevicePropertyDeviceIsRunning aggregateID=\(aggregateID): \(statusDescription(status)); dataSize=\(size); value=\(running); callbacks=\(callbackCount)")
        return running == 1
    }

    /// Reads the tap's actual description through Apple's throwing AudioHardwareTap
    /// getter where that API is available. This diagnostic never mutates the tap.
    private func logTapDescription() {
        guard #available(macOS 26.0, *) else {
            DiagnosticLog.write("CoreAudio kAudioTapPropertyDescription readback unavailable: AudioHardwareTap.description requires macOS 26.0; tapID=\(tapID)")
            return
        }

        do {
            let actual = try AudioHardwareTap(id: tapID).description
            let processIDs = actual.processes.map(String.init).joined(separator: ",")
            let deviceUID = actual.deviceUID ?? "<none>"
            let scope = actual.deviceUID == nil ? "global" : "device-scoped"
            let muteBehavior: String
            switch actual.muteBehavior {
            case .unmuted: muteBehavior = "unmuted"
            case .muted: muteBehavior = "muted"
            case .mutedWhenTapped: muteBehavior = "mutedWhenTapped"
            @unknown default: muteBehavior = "unknown(\(actual.muteBehavior.rawValue))"
            }
            DiagnosticLog.write("CoreAudio kAudioTapPropertyDescription readback: success; tapID=\(tapID); processes=[\(processIDs)]; isExclusive=\(actual.isExclusive); scope=\(scope); deviceUID=\(deviceUID); isPrivate=\(actual.isPrivate); muteBehavior=\(muteBehavior)")
        } catch {
            let error = error as NSError
            DiagnosticLog.write("CoreAudio kAudioTapPropertyDescription readback failed; tapID=\(tapID); errorDomain=\(error.domain); errorCode=\(error.code); description=\(error.localizedDescription)")
        }
    }

    @discardableResult
    func stop() -> Bool {
        DiagnosticLog.write("engine stop requested; ioProcID=\(String(describing: ioProcID)), aggregateID=\(aggregateID), tapID=\(tapID)")
        while true {
            switch cleanupLifecycle.nextAction {
            case .stopIOProc:
                guard let ioProcID else {
                    lastCleanupFailure = "AudioDeviceStop was required but the IOProc ID is unavailable"
                    DiagnosticLog.write("CLEANUP INCOMPLETE: lifecycle says IOProc may be active but IOProcID is unavailable; retaining callback context and dependencies")
                    return false
                }
                let status = AudioDeviceStop(aggregateID, ioProcID)
                DiagnosticLog.write("CoreAudio AudioDeviceStop: \(statusDescription(status)); aggregateID=\(aggregateID); IOProcID=\(String(describing: ioProcID))")
                guard status == noErr else {
                    lastCleanupFailure = "AudioDeviceStop returned \(statusDescription(status))"
                    cleanupLifecycle.operationFailed(.stopIOProc)
                    DiagnosticLog.write("CLEANUP INCOMPLETE: AudioDeviceStop failed; IOProc remains potentially active; retaining IOProc, callback context, aggregate, and tap for retry")
                    return false
                }
                cleanupLifecycle.ioProcStopSucceeded()

            case .destroyIOProc:
                guard let ioProcID else {
                    lastCleanupFailure = "AudioDeviceDestroyIOProcID was required but the IOProc ID is unavailable"
                    DiagnosticLog.write("CLEANUP INCOMPLETE: lifecycle has a registered IOProc but its ID is unavailable; retaining callback context and dependencies")
                    return false
                }
                let status = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                DiagnosticLog.write("CoreAudio AudioDeviceDestroyIOProcID: \(statusDescription(status)); aggregateID=\(aggregateID); IOProcID=\(String(describing: ioProcID))")
                guard status == noErr else {
                    lastCleanupFailure = "AudioDeviceDestroyIOProcID returned \(statusDescription(status))"
                    cleanupLifecycle.operationFailed(.destroyIOProc)
                    DiagnosticLog.write("CLEANUP INCOMPLETE: IOProc destruction failed; callback context and aggregate/tap resources remain retained; will retry")
                    return false
                }
                self.ioProcID = nil
                callbackContext = nil
                cleanupLifecycle.ioProcDestroyed()

            case .destroyAggregate:
                let id = aggregateID
                guard id != AudioObjectID(kAudioObjectUnknown) else {
                    lastCleanupFailure = "Aggregate destruction was required but the aggregate ID is unavailable"
                    DiagnosticLog.write("CLEANUP INCOMPLETE: aggregate is retained in lifecycle state but its ID is unavailable")
                    return false
                }
                DiagnosticLog.write("CoreAudio AudioHardwareDestroyAggregateDevice begin; monotonicNs=\(DispatchTime.now().uptimeNanoseconds); aggregateID=\(id)")
                let status = AudioHardwareDestroyAggregateDevice(id)
                DiagnosticLog.write("CoreAudio AudioHardwareDestroyAggregateDevice returned \(statusDescription(status)); monotonicNs=\(DispatchTime.now().uptimeNanoseconds); aggregateID=\(id)")
                guard status == noErr else {
                    lastCleanupFailure = "AudioHardwareDestroyAggregateDevice returned \(statusDescription(status))"
                    cleanupLifecycle.operationFailed(.destroyAggregate)
                    DiagnosticLog.write("CLEANUP INCOMPLETE: aggregate destruction failed; tap remains retained; will retry")
                    return false
                }
                aggregateID = AudioObjectID(kAudioObjectUnknown)
                cleanupLifecycle.aggregateDestroyed()

            case .destroyTap:
                let id = tapID
                guard id != AudioObjectID(kAudioObjectUnknown) else {
                    lastCleanupFailure = "Process-tap destruction was required but the tap ID is unavailable"
                    DiagnosticLog.write("CLEANUP INCOMPLETE: tap is retained in lifecycle state but its ID is unavailable")
                    return false
                }
                let status = AudioHardwareDestroyProcessTap(id)
                DiagnosticLog.write("CoreAudio AudioHardwareDestroyProcessTap: \(statusDescription(status)); tapID=\(id)")
                guard status == noErr else {
                    lastCleanupFailure = "AudioHardwareDestroyProcessTap returned \(statusDescription(status))"
                    cleanupLifecycle.operationFailed(.destroyTap)
                    DiagnosticLog.write("CLEANUP INCOMPLETE: process tap destruction failed; will retry")
                    return false
                }
                tapID = AudioObjectID(kAudioObjectUnknown)
                tapUID = ""
                cleanupLifecycle.tapDestroyed()

            case .complete:
                started = false
                lastCleanupFailure = nil
                DiagnosticLog.write("engine stopped; resources cleared")
                return true
            }
        }
    }

    var dspModeName: String { dspMode.name }
    var callbackCount: UInt64 { audio_metrics_callbacks(callbackContext?.pointer) }
    var silentCallbacks: UInt64 { audio_metrics_silent_callbacks(callbackContext?.pointer) }
    var inputPeak: Float { audio_metrics_input_peak(callbackContext?.pointer) }
    var outputPeak: Float { audio_metrics_output_peak(callbackContext?.pointer) }
    var millisecondsSinceLastCallback: Double { audio_metrics_elapsed_since_callback_ms(callbackContext?.pointer) }
    var firstCallbackElapsedMilliseconds: Double { audio_metrics_first_callback_elapsed_ms(callbackContext?.pointer) }
    var averageCallbackMilliseconds: Double { audio_metrics_average_callback_ms(callbackContext?.pointer) }
    var maximumCallbackMilliseconds: Double { audio_metrics_max_callback_ms(callbackContext?.pointer) }
    var callbackBudgetMilliseconds: Double {
        guard rate > 0, bufferFrames > 0 else { return 0 }
        return Double(bufferFrames) / rate * 1_000
    }

    func isStillOnDefaultOutput() -> Bool {
        guard let output = try? resolveDefaultOutputSnapshot() else {
            return false
        }
        return output.snapshot.identity.deviceID == defaultOutputID &&
            output.snapshot.identity.uid == deviceUID && output.snapshot.isAlive
    }

    var outputDeviceID: AudioDeviceID { defaultOutputID }

    deinit { stop() }
}
