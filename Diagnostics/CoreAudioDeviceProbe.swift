// Read-only Core Audio inventory probe. It does not create taps, aggregates,
// IOProcs, or change any Core Audio property.
import CoreAudio
import Foundation

func statusText(_ status: OSStatus) -> String {
    String(format: "OSStatus %d (0x%08X)", status, UInt32(bitPattern: status))
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func readString(_ selector: AudioObjectPropertySelector, object: AudioObjectID) -> (String?, OSStatus, UInt32) {
    var property = address(selector)
    var ref: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(object, &property, 0, nil, &size, &ref)
    return (ref?.takeUnretainedValue() as String?, status, size)
}

func readDefaultOutput() {
    var property = address(kAudioHardwarePropertyDefaultOutputDevice)
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device
    )
    print("default-output query: \(statusText(status)); dataSize=\(size); deviceID=\(device)")
    if status == noErr, device != AudioDeviceID(kAudioObjectUnknown) {
        let (name, nameStatus, nameSize) = readString(kAudioObjectPropertyName, object: device)
        let (uid, uidStatus, uidSize) = readString(kAudioDevicePropertyDeviceUID, object: device)
        print("default-output name: \(name ?? "<unavailable>") [\(statusText(nameStatus)), size=\(nameSize)]")
        print("default-output UID: \(uid ?? "<unavailable>") [\(statusText(uidStatus)), size=\(uidSize)]")
    }
}

func enumerateDevices() {
    var property = address(kAudioHardwarePropertyDevices)
    var bytes: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &bytes
    )
    print("device-list size query: \(statusText(sizeStatus)); dataSize=\(bytes)")
    guard sizeStatus == noErr else { return }
    guard bytes > 0 else { print("device list is empty"); return }

    var devices = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown),
                                  count: Int(bytes) / MemoryLayout<AudioDeviceID>.size)
    let listStatus = devices.withUnsafeMutableBufferPointer { buffer in
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &bytes, buffer.baseAddress!
        )
    }
    print("device-list data query: \(statusText(listStatus)); dataSize=\(bytes); count=\(devices.count)")
    guard listStatus == noErr else { return }

    for device in devices {
        let (name, nameStatus, _) = readString(kAudioObjectPropertyName, object: device)
        let (uid, uidStatus, _) = readString(kAudioDevicePropertyDeviceUID, object: device)

        var outputStreamsAddress = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
        var outputStreamBytes: UInt32 = 0
        let streamSizeStatus = AudioObjectGetPropertyDataSize(
            device, &outputStreamsAddress, 0, nil, &outputStreamBytes
        )
        let outputStreamCount = streamSizeStatus == noErr
            ? Int(outputStreamBytes) / MemoryLayout<AudioStreamID>.size
            : -1

        var configAddress = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput)
        var configBytes: UInt32 = 0
        let configSizeStatus = AudioObjectGetPropertyDataSize(device, &configAddress, 0, nil, &configBytes)
        var outputChannels = 0
        var configStatus: OSStatus = configSizeStatus
        if configSizeStatus == noErr, configBytes >= UInt32(MemoryLayout<AudioBufferList>.size) {
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(configBytes), alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { raw.deallocate() }
            configStatus = AudioObjectGetPropertyData(
                device, &configAddress, 0, nil, &configBytes, raw
            )
            if configStatus == noErr {
                let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
                outputChannels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
            }
        }

        var isAlive: UInt32 = 0
        var aliveAddress = address(kAudioDevicePropertyDeviceIsAlive)
        var aliveBytes = UInt32(MemoryLayout<UInt32>.size)
        let aliveStatus = AudioObjectGetPropertyData(device, &aliveAddress, 0, nil, &aliveBytes, &isAlive)

        print("device ID=\(device) name=\(name ?? "<unavailable>") [\(statusText(nameStatus))]")
        print("  UID=\(uid ?? "<unavailable>") [\(statusText(uidStatus))]")
        print("  output streams=\(outputStreamCount) [\(statusText(streamSizeStatus)), bytes=\(outputStreamBytes)]")
        print("  output channels=\(outputChannels) [\(statusText(configStatus)), bytes=\(configBytes)]")
        print("  alive=\(isAlive != 0) [\(statusText(aliveStatus))]")
    }
}

print("Core Audio read-only device probe")
readDefaultOutput()
enumerateDevices()
