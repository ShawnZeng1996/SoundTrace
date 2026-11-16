import CoreAudio
import Foundation

struct AudioProcessSample {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let output: Bool
    let input: Bool
    let devices: [String]
}

struct AudioReadError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "无法读取系统音频状态（\(status)）" }
}

enum CoreAudioReader {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func processIDs() throws -> [AudioObjectID] {
        try objectIDs(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList)
    }

    static func sample(_ object: AudioObjectID) -> AudioProcessSample? {
        guard let pid = integer(object: object, selector: kAudioProcessPropertyPID), pid > 0,
              let output = integer(object: object, selector: kAudioProcessPropertyIsRunningOutput),
              let input = integer(object: object, selector: kAudioProcessPropertyIsRunningInput) else { return nil }
        let scope = output != 0 ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
        let devices = (try? objectIDs(object: object, selector: kAudioProcessPropertyDevices, scope: scope)) ?? []
        return AudioProcessSample(objectID: object, pid: pid_t(pid),
                                  bundleID: string(object: object, selector: kAudioProcessPropertyBundleID),
                                  output: output != 0, input: input != 0,
                                  devices: devices.compactMap { string(object: $0, selector: kAudioObjectPropertyName) })
    }

    static func defaultOutputName() -> String {
        guard let device = integer(object: AudioObjectID(kAudioObjectSystemObject),
                                   selector: kAudioHardwarePropertyDefaultOutputDevice), device != 0 else { return "无输出设备" }
        return string(object: device, selector: kAudioObjectPropertyName) ?? "未知输出设备"
    }

    private static func integer(object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var property = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { return nil }
        return value
    }

    private static func string(object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func objectIDs(object: AudioObjectID, selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var property = address(selector, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size)
        guard status == noErr else { throw AudioReadError(status: status) }
        guard size > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = values.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { throw AudioReadError(status: status) }
        return Array(values.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
}
