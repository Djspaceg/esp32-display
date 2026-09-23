import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

enum AudioDeviceDirection: Sendable {
    case input
    case output
}

struct AudioDevicePreferences: Codable, Equatable, Sendable {
    var inputUID: String?
    var outputUID: String?

    init(inputUID: String? = nil, outputUID: String? = nil) {
        self.inputUID = inputUID
        self.outputUID = outputUID
    }
}

/// Stable CoreAudio identity shown by the settings dropdowns.
struct AudioDeviceOption: Identifiable, Equatable, Sendable {
    var id: String { uid }

    let uid: String
    let name: String
    let supportsInput: Bool
    let supportsOutput: Bool

    func supports(_ direction: AudioDeviceDirection) -> Bool {
        switch direction {
        case .input: return supportsInput
        case .output: return supportsOutput
        }
    }
}

struct AudioDeviceResolution: Equatable, Sendable {
    let uid: String?
    let name: String
    let missingPreferredUID: String?

    var usedFallback: Bool { missingPreferredUID != nil }
}

/// Pure preference resolution. CoreAudio enumeration is deliberately outside
/// this type so vanished-device behavior is unit-testable without hardware.
enum AudioDeviceResolver {
    static let systemDefaultName = "System Default"

    static func resolve(
        preferredUID: String?,
        direction: AudioDeviceDirection,
        devices: [AudioDeviceOption]
    ) -> AudioDeviceResolution {
        guard let preferredUID, !preferredUID.isEmpty else {
            return AudioDeviceResolution(
                uid: nil, name: systemDefaultName, missingPreferredUID: nil)
        }
        if let device = devices.first(where: {
            $0.uid == preferredUID && $0.supports(direction)
        }) {
            return AudioDeviceResolution(
                uid: device.uid, name: device.name, missingPreferredUID: nil)
        }
        return AudioDeviceResolution(
            uid: nil,
            name: systemDefaultName,
            missingPreferredUID: preferredUID)
    }
}

struct CoreAudioDevice {
    let id: AudioDeviceID
    let option: AudioDeviceOption
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
            AudioObjectGetPropertyData(
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

    static func deviceID(
        for uid: String?,
        direction: AudioDeviceDirection,
        in devices: [CoreAudioDevice]
    ) -> AudioDeviceID? {
        if let uid {
            return devices.first {
                $0.option.uid == uid && $0.option.supports(direction)
            }?.id
        }
        return defaultDeviceID(for: direction)
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
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
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
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(
            id, &address, 0, nil, &size, &value) == noErr,
            let value
        else { return nil }
        return value as String
    }
}
