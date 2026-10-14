import CoreAudio
import Foundation

/// Where this Mac's sound goes, chosen once for every display: the Mac has
/// one default output, so a choice per display could contradict itself (one
/// display "only", another "mirrored").
enum MacAudioRoute: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The route there was before the driver: a process tap copies this Mac's
    /// sound to every display and the Mac's own output is left alone. Needs
    /// the System Audio Recording permission and no driver.
    case copy
    /// ESPDisplayAudio.driver: the Mac's own output and every display play
    /// together, through a Multi-Output device the app makes.
    case mirror
    /// ESPDisplayAudio.driver: the displays are the Mac's only output.
    case displaysOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .copy: return "Copy this Mac's sound"
        case .mirror: return "Mirror to the displays"
        case .displaysOnly: return "Displays only"
        }
    }

    var usesDriver: Bool { self != .copy }
}

/// One output device as macOS lists it.
struct MacOutputDevice: Equatable, Sendable {
    let uid: String
    let name: String
    let isBuiltIn: Bool
}

/// The parts of CoreAudio the router changes. Injectable so tests never move
/// the default output of whoever runs them.
@MainActor
protocol MacOutputSystem: AnyObject {
    func outputDevices() -> [MacOutputDevice]
    func defaultOutputUID() -> String?
    @discardableResult
    func setDefaultOutput(uid: String) -> Bool
    /// A public stacked aggregate, what Audio MIDI Setup calls a Multi-Output
    /// Device, clocked by `mainUID`. Replaces one with the same UID.
    @discardableResult
    func createMultiOutput(uid: String, name: String, mainUID: String, members: [String]) -> Bool
    func destroyAggregate(uid: String)
}

/// What the default output should be.
enum MacAudioRouteTarget: Equatable, Sendable {
    /// Back to the Mac's own output if one of ours is the default, with any
    /// Multi-Output device of ours removed.
    case restore
    case device(uid: String)
    case multiOutput(uid: String, name: String, mainUID: String, members: [String])
}

/// The route in effect, worked out from the choice and what exists. Pure, so
/// every combination is tested without CoreAudio.
struct MacAudioRoutePlan: Equatable, Sendable {
    let chosen: MacAudioRoute
    /// What the displays are fed by: `.copy` when the driver cannot be used.
    let effective: MacAudioRoute
    let target: MacAudioRouteTarget
    /// Why the choice is not, or not yet, fully in effect. Shown as selectable
    /// text under the picker and added to each display's audio detail.
    let note: String?

    static let mirrorUID = "com.espdisplay.sender.mirror"
    static let displaysUID = "com.espdisplay.sender.displays"

    static let installCommand =
        "sudo mac/AudioDriver/install-driver.sh"

    static func make(
        chosen: MacAudioRoute,
        driver: DisplayAudioDriverAvailability,
        presentDisplayUIDs present: [String],
        macOutputUID: String?
    ) -> MacAudioRoutePlan {
        guard chosen.usesDriver else {
            return MacAudioRoutePlan(chosen: chosen, effective: .copy, target: .restore, note: nil)
        }
        switch driver {
        case .ready:
            break
        case .absent:
            return MacAudioRoutePlan(
                chosen: chosen, effective: .copy, target: .restore,
                note: "The display audio driver is not installed, so the displays "
                    + "copy this Mac's sound instead. To install it, run "
                    + "\(installCommand) from the esp32-display source folder in "
                    + "Terminal, then choose this again.")
        case .incompatible(let version):
            let found = version.map { "version \($0)" } ?? "an unreadable version"
            return MacAudioRoutePlan(
                chosen: chosen, effective: .copy, target: .restore,
                note: "The installed display audio driver is \(found), and this app "
                    + "needs version \(DisplayAudioDriverProtocol.version), so the "
                    + "displays copy this Mac's sound instead. Rebuild and reinstall "
                    + "it with mac/AudioDriver/build-driver.sh, then "
                    + "\(installCommand).")
        }
        guard !present.isEmpty else {
            return MacAudioRoutePlan(
                chosen: chosen, effective: chosen, target: .restore,
                note: "Waiting for a display's output device to appear in macOS.")
        }
        switch chosen {
        case .displaysOnly:
            if present.count == 1 {
                return MacAudioRoutePlan(
                    chosen: chosen, effective: chosen,
                    target: .device(uid: present[0]), note: nil)
            }
            return MacAudioRoutePlan(
                chosen: chosen, effective: chosen,
                target: .multiOutput(
                    uid: displaysUID, name: "ESPDisplay Displays",
                    mainUID: present[0], members: present),
                note: nil)
        case .mirror, .copy:
            guard let macOutputUID else {
                return MacAudioRoutePlan(
                    chosen: chosen, effective: chosen, target: .restore,
                    note: "This Mac has no output of its own to mirror; the "
                        + "displays play only when an app picks them directly.")
            }
            return MacAudioRoutePlan(
                chosen: chosen, effective: chosen,
                target: .multiOutput(
                    uid: mirrorUID, name: "Mac and ESPDisplay Displays",
                    mainUID: macOutputUID, members: [macOutputUID] + present),
                note: nil)
        }
    }

    /// Devices and aggregates this app makes, which are never "the Mac's own
    /// output".
    static func isOurs(uid: String) -> Bool {
        uid.hasPrefix(DisplayAudioDeviceSpec.uidPrefix)
            || uid == mirrorUID || uid == displaysUID
            || SystemAudioTapIdentity.isOwnAggregate(uid: uid)
    }
}

/// Keeps the displays' devices registered with the driver and the Mac's
/// default output where the chosen route says.
///
/// The default output is changed only when the route or the set of display
/// devices changes, never on every tick: a user who picks another output in
/// Sound settings afterwards is not overruled until something changes.
@MainActor
final class MacAudioRouter {
    private let bridge: DisplayAudioDriverBridge
    private let system: MacOutputSystem
    private var registered = false
    private var appliedTarget: MacAudioRouteTarget?
    /// The output the Mac played through before one of ours took over.
    private(set) var macOutputUID: String?

    init(bridge: DisplayAudioDriverBridge, system: MacOutputSystem) {
        self.bridge = bridge
        self.system = system
    }

    @discardableResult
    func update(route: MacAudioRoute, displays: [DisplayAudioDeviceSpec]) -> MacAudioRoutePlan {
        let availability = route.usesDriver ? bridge.availability() : .absent
        let driving = route.usesDriver && availability == .ready && !displays.isEmpty
        if driving {
            registered = bridge.register(displays) || registered
        } else if registered {
            bridge.register([])
            registered = false
        }
        let outputs = system.outputDevices()
        rememberMacOutput(outputs: outputs)
        let present = driving
            ? displays.map(\.uid).filter { bridge.deviceID(uid: $0) != nil }
            : []
        let plan = MacAudioRoutePlan.make(
            chosen: route,
            driver: route.usesDriver ? availability : .ready,
            presentDisplayUIDs: present,
            macOutputUID: macOutputUID)
        // A target that did not take, such as a device CoreAudio does not
        // list yet, is tried again on the next pass.
        if plan.target != appliedTarget {
            appliedTarget = apply(plan.target, outputs: outputs) ? plan.target : nil
        }
        return plan
    }

    /// Put the Mac's own output back and remove every device of ours. Called
    /// when the app quits, so a quit never leaves the Mac playing to nothing.
    func shutdown() {
        _ = apply(.restore, outputs: system.outputDevices())
        appliedTarget = .restore
        if registered {
            bridge.register([])
            registered = false
        }
    }

    private func rememberMacOutput(outputs: [MacOutputDevice]) {
        if let current = system.defaultOutputUID(), !MacAudioRoutePlan.isOurs(uid: current) {
            macOutputUID = current
            return
        }
        // The remembered one is gone, or nothing was remembered because the
        // app started while one of ours was the default: the built-in output,
        // else the first that is not ours.
        if let macOutputUID, outputs.contains(where: { $0.uid == macOutputUID }) { return }
        let candidates = outputs.filter { !MacAudioRoutePlan.isOurs(uid: $0.uid) }
        macOutputUID = (candidates.first(where: \.isBuiltIn) ?? candidates.first)?.uid
    }

    /// Whether the default output is now where `target` says.
    private func apply(_ target: MacAudioRouteTarget, outputs: [MacOutputDevice]) -> Bool {
        switch target {
        case .restore:
            if let current = system.defaultOutputUID(), MacAudioRoutePlan.isOurs(uid: current),
               let macOutputUID {
                system.setDefaultOutput(uid: macOutputUID)
            }
            removeAggregates(except: nil, outputs: outputs)
            return true
        case .device(let uid):
            guard system.setDefaultOutput(uid: uid) else { return false }
            removeAggregates(except: nil, outputs: outputs)
            return true
        case .multiOutput(let uid, let name, let mainUID, let members):
            // Off the old one first, so destroying it never strands the Mac
            // on nothing.
            if system.defaultOutputUID() == uid, let macOutputUID {
                system.setDefaultOutput(uid: macOutputUID)
            }
            removeAggregates(except: nil, outputs: outputs)
            return system.createMultiOutput(
                uid: uid, name: name, mainUID: mainUID, members: members)
                && system.setDefaultOutput(uid: uid)
        }
    }

    private func removeAggregates(except keep: String?, outputs: [MacOutputDevice]) {
        for uid in [MacAudioRoutePlan.mirrorUID, MacAudioRoutePlan.displaysUID]
        where uid != keep && outputs.contains(where: { $0.uid == uid }) {
            system.destroyAggregate(uid: uid)
        }
    }
}

/// The real system: the HAL's default output and aggregate devices.
@MainActor
final class CoreAudioMacOutputSystem: MacOutputSystem {
    func outputDevices() -> [MacOutputDevice] {
        CoreAudioDeviceCatalog.devices(includingOwnDevices: true)
            .filter(\.option.supportsOutput)
            .map {
                MacOutputDevice(
                    uid: $0.option.uid, name: $0.option.name,
                    isBuiltIn: transportType($0.id) == kAudioDeviceTransportTypeBuiltIn)
            }
    }

    func defaultOutputUID() -> String? {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
            device != AudioDeviceID(kAudioObjectUnknown)
        else { return nil }
        return CoreAudioDeviceCatalog.uid(of: device)
    }

    func setDefaultOutput(uid: String) -> Bool {
        guard var device = deviceID(uid: uid) else { return false }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &device) == noErr
    }

    func createMultiOutput(uid: String, name: String, mainUID: String, members: [String]) -> Bool {
        destroyAggregate(uid: uid)
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceIsPrivateKey: 0,
            kAudioAggregateDeviceIsStackedKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: mainUID,
            kAudioAggregateDeviceSubDeviceListKey: members.map {
                [
                    kAudioSubDeviceUIDKey: $0,
                    kAudioSubDeviceDriftCompensationKey: $0 == mainUID ? 0 : 1,
                ] as [String: Any]
            },
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        return AudioHardwareCreateAggregateDevice(description as CFDictionary, &device) == noErr
    }

    func destroyAggregate(uid: String) {
        guard let device = deviceID(uid: uid) else { return }
        AudioHardwareDestroyAggregateDevice(device)
    }

    private func deviceID(uid: String) -> AudioDeviceID? {
        var address = Self.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) {
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        guard status == noErr, device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return device
    }

    private func transportType(_ device: AudioDeviceID) -> UInt32 {
        var address = Self.address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value
    }

    private static func address(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
}
