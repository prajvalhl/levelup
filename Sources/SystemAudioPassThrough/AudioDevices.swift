import CoreAudio
import CoreFoundation
import Darwin
import Foundation
import PrototypeSupport

enum AudioDeviceError: Error, CustomStringConvertible {
    case osStatus(String, OSStatus)
    case unknownDefaultOutput(processID: pid_t)
    case noOutputStreams
    case outputFormatFailure(OSStatus)
    case missingStringProperty(String)
    case startupCancelled(String)

    var description: String {
        switch self {
        case let .osStatus(operation, status): return "\(operation) failed (\(statusDescription(status)))"
        case let .unknownDefaultOutput(processID):
            return "Core Audio returned kAudioObjectUnknown (0) for kAudioHardwarePropertyDefaultOutputDevice in process PID \(processID); this process did not receive a default-output device ID"
        case .noOutputStreams: return "The default output device has no output streams"
        case let .outputFormatFailure(status): return "Could not read a default-output stream format (OSStatus \(status))"
        case let .missingStringProperty(name): return "Could not read audio-device property \(name)"
        case let .startupCancelled(reason): return "Startup cancelled: \(reason)"
        }
    }
}

func statusDescription(_ status: OSStatus) -> String {
    String(format: "OSStatus %d (0x%08X)", status, UInt32(bitPattern: status))
}

func check(_ status: OSStatus, _ operation: String) throws {
    DiagnosticLog.write("CoreAudio \(operation): \(statusDescription(status))")
    guard status == noErr else { throw AudioDeviceError.osStatus(operation, status) }
}

func defaultOutputDevice() throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
    )
    DiagnosticLog.write("CoreAudio AudioObjectGetPropertyData(kAudioHardwarePropertyDefaultOutputDevice, global/main): \(statusDescription(status)); dataSize=\(size), deviceID=\(device), processPID=\(getpid())")
    try check(status, "read default output device")
    guard device != AudioDeviceID(kAudioObjectUnknown) else {
        throw AudioDeviceError.unknownDefaultOutput(processID: getpid())
    }
    return device
}

struct ResolvedOutputDevice {
    let snapshot: OutputDeviceSnapshot
    let format: AudioStreamBasicDescription
}

func allAudioDeviceIDs() throws -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var byteCount: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount),
              "read Core Audio device-list size")
    guard byteCount % UInt32(MemoryLayout<AudioDeviceID>.size) == 0 else {
        throw AudioDeviceError.osStatus("Core Audio device list has invalid size \(byteCount)", -1)
    }
    guard byteCount > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown),
                              count: Int(byteCount) / MemoryLayout<AudioDeviceID>.size)
    let allocatedBytes = byteCount
    let status = ids.withUnsafeMutableBufferPointer { buffer in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, buffer.baseAddress!)
    }
    try check(status, "read Core Audio device list")
    guard byteCount <= allocatedBytes, byteCount % UInt32(MemoryLayout<AudioDeviceID>.size) == 0 else {
        throw AudioDeviceError.osStatus("Core Audio returned invalid device-list size \(byteCount)", -1)
    }
    return Array(ids.prefix(Int(byteCount) / MemoryLayout<AudioDeviceID>.size))
}

func deviceIsAlive(_ deviceID: AudioDeviceID) throws -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(AudioObjectID(deviceID), &address) else {
        throw AudioDeviceError.osStatus("default output does not expose kAudioDevicePropertyDeviceIsAlive", kAudioHardwareUnknownPropertyError)
    }
    var alive: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(deviceID), &address, 0, nil, &size, &alive)
    DiagnosticLog.write("CoreAudio kAudioDevicePropertyDeviceIsAlive deviceID=\(deviceID): \(statusDescription(status)); dataSize=\(size); value=\(alive)")
    try check(status, "read output device alive state")
    guard size == UInt32(MemoryLayout<UInt32>.size), alive <= 1 else {
        throw AudioDeviceError.osStatus("kAudioDevicePropertyDeviceIsAlive returned invalid size/value (size=\(size), value=\(alive))", -1)
    }
    return alive == 1
}

func resolveDefaultOutputSnapshot() throws -> ResolvedOutputDevice {
    let deviceID = try defaultOutputDevice()
    let devices = try allAudioDeviceIDs()
    let alive = try deviceIsAlive(deviceID)
    let name = try stringProperty(kAudioObjectPropertyName, on: AudioObjectID(deviceID), name: "output device name")
    let uid = try stringProperty(kAudioDevicePropertyDeviceUID, on: AudioObjectID(deviceID), name: "output device UID")
    let rate = try sampleRate(of: AudioObjectID(deviceID))
    let streams = try streamIDs(of: AudioObjectID(deviceID), scope: kAudioDevicePropertyScopeOutput, direction: "physical output")
    guard let format = try outputStreamFormat(streams) else { throw AudioDeviceError.noOutputStreams }
    let fingerprint = "\(format.mSampleRate)|\(format.mFormatID)|\(format.mFormatFlags)|\(format.mChannelsPerFrame)|\(format.mBitsPerChannel)"
    let snapshot = OutputDeviceSnapshot(identity: OutputDeviceIdentity(deviceID: deviceID,
                                                                       uid: uid,
                                                                       formatFingerprint: fingerprint),
                                        name: name,
                                        isInDeviceList: devices.contains(deviceID),
                                        isAlive: alive,
                                        outputStreamCount: streams.count,
                                        nominalSampleRate: rate,
                                        channelCount: format.mChannelsPerFrame,
                                        isFloatPCM: format.mFormatID == kAudioFormatLinearPCM &&
                                            (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
                                        bitsPerChannel: format.mBitsPerChannel)
    guard snapshot.isUsable else {
        throw AudioDeviceError.osStatus(snapshot.unavailableReason ?? "default output is unavailable", -1)
    }
    DiagnosticLog.write("resolved default output snapshot: ID=\(deviceID), UID=\(uid), name=\(name), alive=\(alive), streams=\(streams), nominalRate=\(rate), format={\(formatSummary(format))}")
    return ResolvedOutputDevice(snapshot: snapshot, format: format)
}

func outputStreamFormat(_ streams: [AudioStreamID]) throws -> AudioStreamBasicDescription? {
    guard !streams.isEmpty else { return nil }
    var lastStatus: OSStatus = noErr
    for stream in streams {
        var address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        lastStatus = AudioObjectGetPropertyData(AudioObjectID(stream), &address, 0, nil, &size, &format)
        DiagnosticLog.write("CoreAudio output stream format streamID=\(stream): \(statusDescription(lastStatus)); dataSize=\(size); format={\(formatSummary(format))}")
        if lastStatus == noErr {
            guard size == UInt32(MemoryLayout<AudioStreamBasicDescription>.size) else {
                throw AudioDeviceError.osStatus("output stream returned invalid format size \(size)", -1)
            }
            return format
        }
    }
    throw AudioDeviceError.outputFormatFailure(lastStatus)
}

func stringProperty(_ selector: AudioObjectPropertySelector, on object: AudioObjectID, name: String) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    DiagnosticLog.write("CoreAudio \(name) selector=\(selector) global/main objectID=\(object): \(statusDescription(status)); dataSize=\(size)")
    try check(status, "read \(name)")
    guard let result = value?.takeUnretainedValue() as String? else {
        throw AudioDeviceError.missingStringProperty(name)
    }
    return result
}

func sampleRate(of device: AudioObjectID) throws -> Double {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var rate: Double = 0
    var size = UInt32(MemoryLayout<Double>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
    DiagnosticLog.write("CoreAudio nominal sample rate deviceID=\(device): \(statusDescription(status)); dataSize=\(size), rate=\(rate)")
    try check(status, "read sample rate")
    return rate
}

func outputFormat(of device: AudioDeviceID) throws -> AudioStreamBasicDescription {
    var streamsAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var streamBytes: UInt32 = 0
    let streamSizeStatus = AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &streamBytes)
    DiagnosticLog.write("CoreAudio AudioObjectGetPropertyDataSize(kAudioDevicePropertyStreams, output scope) deviceID=\(device): \(statusDescription(streamSizeStatus)); bytes=\(streamBytes)")
    try check(streamSizeStatus, "read output stream-list size")
    guard streamBytes >= UInt32(MemoryLayout<AudioStreamID>.size) else {
        throw AudioDeviceError.noOutputStreams
    }
    var streams = [AudioStreamID](repeating: AudioStreamID(kAudioObjectUnknown),
                                  count: Int(streamBytes) / MemoryLayout<AudioStreamID>.size)
    let streamListStatus = streams.withUnsafeMutableBufferPointer { buffer in
        AudioObjectGetPropertyData(device, &streamsAddress, 0, nil, &streamBytes, buffer.baseAddress!)
    }
    DiagnosticLog.write("CoreAudio AudioObjectGetPropertyData(kAudioDevicePropertyStreams, output scope) deviceID=\(device): \(statusDescription(streamListStatus)); bytes=\(streamBytes), streams=\(streams)")
    try check(streamListStatus, "read output stream list")

    var lastStatus: OSStatus = noErr
    for stream in streams {
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var formatBytes = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        lastStatus = AudioObjectGetPropertyData(stream, &formatAddress, 0, nil, &formatBytes, &format)
        DiagnosticLog.write("CoreAudio AudioObjectGetPropertyData(kAudioStreamPropertyVirtualFormat, global/main) streamID=\(stream): \(statusDescription(lastStatus)); bytes=\(formatBytes), format=\(formatSummary(format))")
        if lastStatus == noErr { return format }
    }
    throw AudioDeviceError.outputFormatFailure(lastStatus)
}

func tapFormat(of tap: AudioObjectID) throws -> AudioStreamBasicDescription {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
    DiagnosticLog.write("CoreAudio tap format query tapID=\(tap): \(statusDescription(status)); dataSize=\(size), format=\(formatSummary(format))")
    try check(status, "read tap format")
    return format
}

func aggregateCFStringList(_ selector: AudioObjectPropertySelector, on aggregate: AudioObjectID, name: String) throws -> [String] {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var bytes: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(aggregate, &address, 0, nil, &bytes)
    DiagnosticLog.write("CoreAudio aggregate property size \(name) selector=\(selector) aggregateID=\(aggregate): \(statusDescription(sizeStatus)); bytes=\(bytes)")
    try check(sizeStatus, "read aggregate \(name) size")
    guard bytes >= UInt32(MemoryLayout<Unmanaged<CFArray>?>.size) else {
        throw AudioDeviceError.osStatus("aggregate \(name) property has invalid size \(bytes)", -1)
    }
    var result: Unmanaged<CFArray>?
    var returnedBytes = bytes
    let dataStatus = AudioObjectGetPropertyData(aggregate, &address, 0, nil, &returnedBytes, &result)
    let values = result?.takeRetainedValue() as? [String] ?? []
    DiagnosticLog.write("CoreAudio aggregate property data \(name) selector=\(selector) aggregateID=\(aggregate): \(statusDescription(dataStatus)); bytes=\(returnedBytes), values=\(values)")
    try check(dataStatus, "read aggregate \(name)")
    return values
}

func aggregateObjectIDList(_ selector: AudioObjectPropertySelector, on aggregate: AudioObjectID, name: String) throws -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var bytes: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(aggregate, &address, 0, nil, &bytes)
    DiagnosticLog.write("CoreAudio aggregate property size \(name) selector=\(selector) aggregateID=\(aggregate): \(statusDescription(sizeStatus)); bytes=\(bytes)")
    try check(sizeStatus, "read aggregate \(name) size")
    guard bytes % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else {
        throw AudioDeviceError.osStatus("aggregate \(name) property has invalid size \(bytes)", -1)
    }
    guard bytes > 0 else {
        DiagnosticLog.write("CoreAudio aggregate property data \(name): OSStatus 0 (empty list); bytes=0, values=[]")
        return []
    }
    var values = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: Int(bytes) / MemoryLayout<AudioObjectID>.size)
    var returnedBytes = bytes
    let dataStatus = values.withUnsafeMutableBufferPointer { buffer in
        AudioObjectGetPropertyData(aggregate, &address, 0, nil, &returnedBytes, buffer.baseAddress!)
    }
    DiagnosticLog.write("CoreAudio aggregate property data \(name) selector=\(selector) aggregateID=\(aggregate): \(statusDescription(dataStatus)); bytes=\(returnedBytes), values=\(values)")
    try check(dataStatus, "read aggregate \(name)")
    return values
}

func streamIDs(of device: AudioObjectID, scope: AudioObjectPropertyScope, direction: String) throws -> [AudioStreamID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var bytes: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &bytes)
    DiagnosticLog.write("CoreAudio stream-list size direction=\(direction) deviceID=\(device): \(statusDescription(sizeStatus)); bytes=\(bytes)")
    try check(sizeStatus, "read \(direction) stream-list size")
    guard bytes % UInt32(MemoryLayout<AudioStreamID>.size) == 0 else {
        throw AudioDeviceError.osStatus("\(direction) stream-list has invalid size \(bytes)", -1)
    }
    guard bytes > 0 else {
        DiagnosticLog.write("CoreAudio stream-list data direction=\(direction) deviceID=\(device): OSStatus 0 (empty list); bytes=0, streams=[]")
        return []
    }
    var streams = [AudioStreamID](repeating: AudioStreamID(kAudioObjectUnknown), count: Int(bytes) / MemoryLayout<AudioStreamID>.size)
    var returnedBytes = bytes
    let dataStatus = streams.withUnsafeMutableBufferPointer { buffer in
        AudioObjectGetPropertyData(device, &address, 0, nil, &returnedBytes, buffer.baseAddress!)
    }
    DiagnosticLog.write("CoreAudio stream-list data direction=\(direction) deviceID=\(device): \(statusDescription(dataStatus)); bytes=\(returnedBytes), streams=\(streams)")
    try check(dataStatus, "read \(direction) stream list")
    return streams
}

func validateAggregateMembership(_ aggregate: AudioObjectID,
                                 physicalOutputID: AudioDeviceID,
                                 physicalOutputUID: String,
                                 tapID: AudioObjectID,
                                 tapUID: String) throws {
    let fullSubdevices = try aggregateCFStringList(kAudioAggregateDevicePropertyFullSubDeviceList, on: aggregate, name: "full subdevice list")
    let activeSubdevices = try aggregateObjectIDList(kAudioAggregateDevicePropertyActiveSubDeviceList, on: aggregate, name: "active subdevice list")
    let tapUIDs = try aggregateCFStringList(kAudioAggregateDevicePropertyTapList, on: aggregate, name: "tap list")
    let activeSubtaps = try aggregateObjectIDList(kAudioAggregateDevicePropertySubTapList, on: aggregate, name: "active subtap list")

    guard fullSubdevices.contains(physicalOutputUID), activeSubdevices.contains(physicalOutputID) else {
        throw AudioDeviceError.osStatus("aggregate does not contain the expected physical output UID/ID", -1)
    }
    guard tapUIDs.contains(where: { $0.caseInsensitiveCompare(tapUID) == .orderedSame }), !activeSubtaps.isEmpty else {
        throw AudioDeviceError.osStatus("aggregate does not contain the expected tap UID or has no active subtap", -1)
    }
    // The active-subtap property returns sub-tap object IDs (not tap UIDs).
    // The aggregate tap-list property above is the authoritative UUID check.
    _ = tapID

    let inputs = try streamIDs(of: aggregate, scope: kAudioDevicePropertyScopeInput, direction: "input")
    let outputs = try streamIDs(of: aggregate, scope: kAudioDevicePropertyScopeOutput, direction: "output")
    guard !inputs.isEmpty, !outputs.isEmpty else {
        throw AudioDeviceError.osStatus("aggregate must expose both tap input and physical output streams", -1)
    }
    for (direction, streams) in [("input", inputs), ("output", outputs)] {
        for stream in streams {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var format = AudioStreamBasicDescription()
            var bytes = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioObjectGetPropertyData(stream, &address, 0, nil, &bytes, &format)
            DiagnosticLog.write("CoreAudio aggregate \(direction) virtual format streamID=\(stream): \(statusDescription(status)); bytes=\(bytes), format=\(formatSummary(format))")
            try check(status, "read aggregate \(direction) stream format")
        }
    }
    DiagnosticLog.write("aggregate membership validated: physicalOutputUID=\(physicalOutputUID), physicalOutputID=\(physicalOutputID), tapUID=\(tapUID), tapID=\(tapID), activeSubtaps=\(activeSubtaps)")
}

func formatSummary(_ format: AudioStreamBasicDescription) -> String {
    let floatPCM = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    return String(
        format: "%.0f Hz, %u channel(s), %@, %@ %@",
        format.mSampleRate,
        format.mChannelsPerFrame,
        nonInterleaved ? "non-interleaved" : "interleaved",
        floatPCM ? "Float" : "non-Float",
        format.mBitsPerChannel == 0 ? "unknown bit depth" : "\(format.mBitsPerChannel)-bit"
    )
}
