import CoreGraphics
import CoreMediaIO
import CoreAudio
import FromoCore
import Foundation

struct ProbeReadResult {
    var snapshot: ProbeSnapshot
    var errors: [String]
}

enum EnvironmentProbes {
    static func read() -> ProbeReadResult {
        var errors: [String] = []
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                              eventType: CGEventType(rawValue: UInt32.max)!)
        let idle: Int
        if seconds.isFinite && seconds >= 0 && seconds < Double(Int.max) { idle = Int(seconds) }
        else { idle = Int.max; errors.append("Idle probe returned an invalid value.") }
        return ProbeReadResult(snapshot: ProbeSnapshot(idleSeconds: idle, cameraInUse: camera(errors: &errors),
                                                       microphoneInUse: microphone(errors: &errors)), errors: errors)
    }

    private static func camera(errors: inout [String]) -> Bool {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: 0)
        var size: UInt32 = 0
        let sized = CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size)
        guard sized == noErr else { errors.append("Camera device list: OSStatus \(sized)."); return false }
        guard size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        let listed = devices.withUnsafeMutableBytes {
            CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, $0.baseAddress!)
        }
        guard listed == noErr else { errors.append("Camera device list read: OSStatus \(listed)."); return false }
        devices = Array(devices.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
        var running = false
        for device in devices {
            var status = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                   mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: 0)
            var value: UInt32 = 0
            var used: UInt32 = 0
            let result = CMIOObjectGetPropertyData(device, &status, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value)
            if result == noErr { running = running || value != 0 }
            else { errors.append("Camera running status: OSStatus \(result).") }
        }
        return running
    }

    private static func microphone(errors: inout [String]) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDevices),
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var size: UInt32 = 0
        let sized = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard sized == noErr else { errors.append("Microphone device list: OSStatus \(sized)."); return false }
        guard size > 0 else { return false }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let listed = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard listed == noErr else { errors.append("Microphone device list read: OSStatus \(listed)."); return false }
        devices = Array(devices.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
        var running = false
        for device in devices {
            var input = AudioObjectPropertyAddress(mSelector: AudioObjectPropertySelector(kAudioDevicePropertyStreams),
                                                   mScope: kAudioObjectPropertyScopeInput, mElement: 0)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &input, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }
            var status = AudioObjectPropertyAddress(mSelector: AudioObjectPropertySelector(kAudioDevicePropertyDeviceIsRunningSomewhere),
                                                    mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let result = AudioObjectGetPropertyData(device, &status, 0, nil, &size, &value)
            if result == noErr { running = running || value != 0 }
            else { errors.append("Microphone running status: OSStatus \(result).") }
        }
        return running
    }
}
