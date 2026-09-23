import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct CoreAudioDevice {
    let id: AudioDeviceID
    let option: AudioDeviceOption
}

struct CoreAudioRouteSnapshot: Equatable {
    let options: [AudioDeviceOption]
    let defaultInputUID: String?
    let defaultOutputUID: String?

    static let empty = CoreAudioRouteSnapshot(
        options: [],
        defaultInputUID: nil,
        defaultOutputUID: nil)
}

enum CoreAudioDeviceCatalog {
    static func options() -> [AudioDeviceOption] {
        devices().map(\.option)
    }

    static func devices() -> [CoreAudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size) == noErr
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kAudio_ParamError }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                baseAddress)
        }
        guard status == noErr else { return [] }
        return ids.compactMap { id in
            guard let uid = stringProperty(
                id, selector: kAudioDevicePropertyDeviceUID),
                let name = stringProperty(
                    id, selector: kAudioObjectPropertyName)
            else { return nil }
            let input = hasStreams(id, scope: kAudioDevicePropertyScopeInput)
            let output = hasStreams(id, scope: kAudioDevicePropertyScopeOutput)
            guard input || output else { return nil }
            return CoreAudioDevice(
                id: id,
                option: AudioDeviceOption(
                    uid: uid,
                    name: name,
                    supportsInput: input,
                    supportsOutput: output))
        }
        .sorted {
            $0.option.name.localizedCaseInsensitiveCompare($1.option.name)
                == .orderedAscending
        }
    }

    static func routeSnapshot() -> CoreAudioRouteSnapshot {
        let devices = devices()
        return CoreAudioRouteSnapshot(
            options: devices.map(\.option),
            defaultInputUID: defaultDeviceUID(
                for: .input, in: devices),
            defaultOutputUID: defaultDeviceUID(
                for: .output, in: devices))
    }

    static func deviceID(
        for uid: String?,
        direction: AudioDeviceDirection,
        in devices: [CoreAudioDevice]
    ) -> AudioDeviceID? {
        guard let uid else { return nil }
        return devices.first {
            $0.option.uid == uid && $0.option.supports(direction)
        }?.id
    }

    static func setDevice(
        _ deviceID: AudioDeviceID?,
        on node: AVAudioIONode
    ) throws {
        guard var deviceID else { return }
        guard let audioUnit = node.audioUnit else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(kAudio_ParamError),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "CoreAudio did not expose an audio unit for device selection."
                ])
        }
        let status = withUnsafePointer(to: &deviceID) { pointer in
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                pointer,
                UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        guard status == noErr else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "CoreAudio could not select device \(deviceID)."
                ])
        }
    }

    private static func defaultDeviceUID(
        for direction: AudioDeviceDirection,
        in devices: [CoreAudioDevice]
    ) -> String? {
        guard let id = defaultDeviceID(for: direction) else { return nil }
        return devices.first(where: { $0.id == id })?.option.uid
    }

    private static func defaultDeviceID(
        for direction: AudioDeviceDirection
    ) -> AudioDeviceID? {
        let selector: AudioObjectPropertySelector
        switch direction {
        case .input:
            selector = kAudioHardwarePropertyDefaultInputDevice
        case .output:
            selector = kAudioHardwarePropertyDefaultOutputDevice
        }
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &value) == noErr,
            value != AudioDeviceID(kAudioObjectUnknown)
        else { return nil }
        return value
    }

    private static func hasStreams(
        _ id: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(
            id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func stringProperty(
        _ id: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr,
            let value
        else { return nil }
        return value.takeUnretainedValue() as String
    }
}

extension PanelManager {
    func refreshAudioDevices() {
        let refreshed = CoreAudioDeviceCatalog.routeSnapshot()
        guard refreshed != audioRouteSnapshot else { return }
        audioRouteSnapshot = refreshed
        audioDevices = refreshed.options
        for session in sessions.values {
            session.audioDevicesChanged()
        }
    }
}
