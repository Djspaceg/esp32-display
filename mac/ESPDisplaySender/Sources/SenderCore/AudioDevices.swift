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

    /// What the display speaker's tap depends on: the output devices and the
    /// default output. Inputs are left out, because nothing captures one, so
    /// plugging in a microphone does not restart every display's audio.
    var outputRoute: OutputRoute {
        OutputRoute(
            outputs: options.filter(\.supportsOutput),
            defaultOutputUID: defaultOutputUID)
    }

    struct OutputRoute: Equatable {
        let outputs: [AudioDeviceOption]
        let defaultOutputUID: String?
    }
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
                !SystemAudioTapIdentity.isOwnAggregate(uid: uid),
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

    static func uid(of device: AudioDeviceID) -> String? {
        stringProperty(device, selector: kAudioDevicePropertyDeviceUID)
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
        // CoreAudio hands back a retained string; the caller releases it.
        return value.takeRetainedValue() as String
    }
}

extension PanelManager {
    func refreshAudioDevices() {
        let refreshed = CoreAudioDeviceCatalog.routeSnapshot()
        guard refreshed != audioRouteSnapshot else { return }
        let outputChanged = refreshed.outputRoute != audioRouteSnapshot.outputRoute
        audioRouteSnapshot = refreshed
        guard outputChanged else { return }
        for session in sessions.values {
            session.audioDevicesChanged()
        }
    }
}
