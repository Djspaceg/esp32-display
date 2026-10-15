import CoreAudio
import Foundation

/// Where this Mac's sound plays, chosen once for every display: the Mac has
/// one default output, so a choice per display could contradict itself.
enum MacAudioRoute: String, Codable, CaseIterable, Identifiable, Sendable {
    /// This Mac and the displays: a process tap copies this Mac's sound to
    /// every display and the Mac's own output, volume keys included, is left
    /// alone. Needs the System Audio Recording permission and no driver.
    case copy
    /// The displays only, through ESPDisplayAudio.driver: the displays are the
    /// Mac's output and its own speakers go quiet.
    case displaysOnly

    var id: String { rawValue }

    /// The menu asks where sound plays, so each label is a place.
    var label: String {
        switch self {
        case .copy: return "This Mac and the displays"
        case .displaysOnly: return "The displays only"
        }
    }

    /// One plain line under the menu: what the choice does.
    var explanation: String {
        switch self {
        case .copy:
            return "The displays get a copy of what this Mac plays."
        case .displaysOnly:
            return "Sound goes only to the displays; this Mac's speakers stay quiet."
        }
    }

    var usesDriver: Bool { self == .displaysOnly }

    /// "mirror", a third choice in earlier builds, played through the Mac and
    /// the displays together, which is what the copy does, so it loads as the
    /// copy. Anything else unknown fails, and the settings file falls back.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "mirror" {
            self = .copy
        } else if let route = MacAudioRoute(rawValue: raw) {
            self = route
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "unknown route \(raw)"))
        }
    }
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

    static let waitingNote = "Waiting for a display's output device to appear in macOS."
    /// The Multi-Output device earlier builds made for their "mirror" choice.
    /// Nothing makes it now; it is still recognised as this app's, so one left
    /// behind is removed rather than mistaken for the Mac's own output.
    static let legacyMirrorUID = "com.espdisplay.sender.mirror"
    static let displaysUID = "com.espdisplay.sender.displays"

    static func make(
        chosen: MacAudioRoute,
        driver: DisplayAudioDriverAvailability,
        presentDisplayUIDs present: [String]
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
                note: "Playing on the displays only needs the display audio driver, "
                    + "which is not installed, so this Mac and the displays both "
                    + "play for now. Click Install Audio Driver below; the displays "
                    + "switch over once macOS has loaded it.")
        case .incompatible(let version):
            let found = version.map { "version \($0)" } ?? "an unreadable version"
            return MacAudioRoutePlan(
                chosen: chosen, effective: .copy, target: .restore,
                note: "The installed display audio driver is \(found), and this app "
                    + "needs version \(DisplayAudioDriverProtocol.version), so this "
                    + "Mac and the displays both play for now. Click Reinstall Audio "
                    + "Driver below.")
        }
        guard !present.isEmpty else {
            return MacAudioRoutePlan(
                chosen: chosen, effective: chosen, target: .restore,
                note: waitingNote)
        }
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
    }

    /// Devices and aggregates this app makes, which are never "the Mac's own
    /// output".
    static func isOurs(uid: String) -> Bool {
        uid.hasPrefix(DisplayAudioDeviceSpec.uidPrefix)
            || uid == legacyMirrorUID || uid == displaysUID
            || SystemAudioTapIdentity.isOwnAggregate(uid: uid)
    }
}

/// Keeps the displays' devices registered with the driver and the Mac's
/// default output where the chosen route says.
///
/// The default output is changed only when the route or the display devices
/// themselves change (one appears, goes, or comes back as a new device), never
/// on every tick, and never because the user picked another output: a pick
/// made in Sound settings afterwards stands until something changes.
@MainActor
final class MacAudioRouter {
    private let bridge: DisplayAudioDriverBridge
    private let system: MacOutputSystem
    private var registered = false
    /// What the default output was last set for. Nil until set, or after a
    /// change that did not take, so the next pass tries again.
    private var applied: Trigger?
    /// The device the last change that took made the default (nil when it
    /// gave the Mac its own output back).
    private var appliedDefaultUID: String?
    /// The display devices present at the last pass, by UID.
    private(set) var presentDevices: [String: AudioObjectID] = [:]
    /// Passes in a row that found the driver full with a display missing.
    private var fullPasses = 0
    /// The displays those passes were for.
    private var countedDisplays: [String] = []
    /// The members each Multi-Output device of ours was built with, so one
    /// that already matches is reused rather than rebuilt.
    private var built: [String: [String]] = [:]
    /// The output the Mac played through before one of ours took over.
    private(set) var macOutputUID: String?

    private struct Trigger: Equatable {
        let chosen: MacAudioRoute
        let effective: MacAudioRoute
        /// Each present display device by UID, with the object ID it has now:
        /// a device the driver dropped and made again is a change.
        let devices: [String: AudioObjectID]
    }

    init(bridge: DisplayAudioDriverBridge, system: MacOutputSystem) {
        self.bridge = bridge
        self.system = system
    }

    @discardableResult
    func update(route: MacAudioRoute, displays: [DisplayAudioDeviceSpec]) -> MacAudioRoutePlan {
        let availability = route.usesDriver ? bridge.availability() : .absent
        let driving = route.usesDriver && availability == .ready && !displays.isEmpty
        var refused = false
        if driving {
            let accepted = bridge.register(displays)
            refused = !accepted
            registered = accepted || registered
        } else if registered {
            bridge.register([])
            registered = false
        }
        let outputs = system.outputDevices()
        rememberMacOutput(outputs: outputs)
        // A device counts only if this app owns it: one another process
        // claimed first would get whatever the Mac is routed to send it.
        var present: [String: AudioObjectID] = [:]
        var claimed: [DisplayAudioDeviceSpec] = []
        var missing: [DisplayAudioDeviceSpec] = []
        if driving {
            for display in displays {
                // Another owner's device for this display carries that
                // owner's UID suffix, so it is not found by ours.
                guard let id = bridge.deviceID(uid: display.uid) else {
                    // From the device list this pass already read: another
                    // read per missing display, every two seconds, on the
                    // main thread, would be all cost and no news.
                    let mine = bridge.deviceUID(for: display.uid)
                    if outputs.contains(where: {
                        $0.uid != mine
                            && DisplayAudioDriverProtocol.isDeviceUID($0.uid, of: display.uid)
                    }) {
                        claimed.append(display)
                    } else {
                        missing.append(display)
                    }
                    continue
                }
                if bridge.owns(device: id) {
                    present[display.uid] = id
                } else {
                    claimed.append(display)
                }
            }
        }
        let plan = MacAudioRoutePlan.make(
            chosen: route,
            driver: route.usesDriver ? availability : .ready,
            presentDisplayUIDs: displays.map(\.uid).filter { present[$0] != nil }
                .map { bridge.deviceUID(for: $0) })
        presentDevices = present
        let trigger = Trigger(chosen: route, effective: plan.effective, devices: present)
        if trigger != applied {
            if apply(plan.target, outputs: outputs) {
                applied = trigger
                appliedDefaultUID = Self.defaultUID(of: plan.target)
            } else {
                applied = nil
                appliedDefaultUID = nil
            }
        }
        // The count is trusted only once two passes in a row, with the same
        // displays and an accepted registration, agree: the driver updates
        // its list after each registration, so a pass right after one can
        // read the old count.
        let displayUIDs = displays.map(\.uid)
        if refused || displayUIDs != countedDisplays { fullPasses = 0 }
        countedDisplays = displayUIDs
        // Past this point the driver is in use, so the plan's own note can
        // only be the generic "waiting", which any specific note below says
        // better: the notes that do not involve the driver (not installed,
        // another version) come with nothing driving.
        if refused {
            let why = "The display audio driver refused this app's displays. It "
                + "takes up to \(DisplayAudioDriverProtocol.maxClients) apps at "
                + "once, so other apps on this Mac may be using every place; "
                + "quit them, or restart the Mac."
            return MacAudioRoutePlan(
                chosen: plan.chosen, effective: plan.effective, target: plan.target,
                note: why)
        }
        var notes: [String] = []
        // Registered, yet no device: a driver whose every device is held
        // makes none.
        let held = missing.isEmpty ? nil : bridge.deviceCount()
        let full = held.map { $0 >= DisplayAudioDriverProtocol.maxDevices } ?? false
        fullPasses = full ? fullPasses + 1 : 0
        if let held, fullPasses >= 2 {
            let names = missing.map { "\"\($0.name)\"" }.joined(separator: ", ")
            let capacity = DisplayAudioDriverProtocol.maxDevices
            let others = Swift.max(0, held - present.count)
            let why = others == 0
                ? "this app already uses all \(capacity) of its devices, the most it "
                    + "makes. Remove a display from this app to free one."
                : "\(others) of its \(capacity) devices are in use by other apps on this "
                    + "Mac. Quit some of them; the display gets its device once one "
                    + "is free."
            notes.append("The display audio driver has no room for \(names): " + why)
        }
        if !claimed.isEmpty {
            let names = claimed.map { "\"\($0.name)\"" }.joined(separator: ", ")
            notes.append("Another app on this Mac has claimed the output device for "
                + "\(names), so this app does not send the Mac's sound to it. "
                + "The device comes back to this app once that app lets go of it.")
        }
        // Everything that applies is said together: these, or else the plan's
        // own note, then an output picked elsewhere.
        let picked = noteAnOutputPickedElsewhere(plan, outputs: outputs).note
        var all = notes
        if notes.isEmpty, let note = plan.note { all.append(note) }
        if plan.note == nil, let picked { all.append(picked) }
        return MacAudioRoutePlan(
            chosen: plan.chosen, effective: plan.effective, target: plan.target,
            note: all.isEmpty ? nil : all.joined(separator: " "))
    }

    private static func defaultUID(of target: MacAudioRouteTarget) -> String? {
        switch target {
        case .restore: return nil
        case .device(let uid): return uid
        case .multiOutput(let uid, _, _, _): return uid
        }
    }

    /// The route's own change stands until something changes, so an output
    /// picked in Sound settings, or one macOS switched to by itself (AirPods
    /// connecting), is left alone; the note says so and how to go back.
    private func noteAnOutputPickedElsewhere(
        _ plan: MacAudioRoutePlan, outputs: [MacOutputDevice]
    ) -> MacAudioRoutePlan {
        guard plan.note == nil, plan.effective.usesDriver,
              let wanted = appliedDefaultUID, wanted == Self.defaultUID(of: plan.target),
              let current = system.defaultOutputUID(), current != wanted
        else { return plan }
        func name(_ uid: String) -> String {
            outputs.first(where: { $0.uid == uid })?.name ?? uid
        }
        return MacAudioRoutePlan(
            chosen: plan.chosen, effective: plan.effective, target: plan.target,
            note: "This Mac now plays through \"\(name(current))\", picked outside "
                + "this app. To send its sound to the displays again, choose "
                + "\"\(name(wanted))\" in Sound settings.")
    }

    /// Put the Mac's own output back and remove every device of ours. Called
    /// when the app quits, so a quit never leaves the Mac playing to nothing.
    func shutdown() {
        _ = apply(.restore, outputs: system.outputDevices())
        applied = nil
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
        let aggregates = [MacAudioRoutePlan.legacyMirrorUID, MacAudioRoutePlan.displaysUID]
            .filter { uid in outputs.contains { $0.uid == uid } }
        switch target {
        case .restore:
            // Done only once the Mac is off our devices and they are gone. With
            // no output of its own to go back to yet, each pass retries, which
            // costs nothing until one appears.
            if let current = system.defaultOutputUID(), MacAudioRoutePlan.isOurs(uid: current) {
                guard let macOutputUID, system.setDefaultOutput(uid: macOutputUID) else {
                    return false
                }
            }
            return removeAggregates(aggregates, keeping: nil)
        case .device(let uid):
            guard system.setDefaultOutput(uid: uid) else { return false }
            return removeAggregates(aggregates, keeping: nil)
        case .multiOutput(let uid, let name, let mainUID, let members):
            let signature = [mainUID] + members
            if aggregates.contains(uid), built[uid] == signature {
                return system.setDefaultOutput(uid: uid)
                    && removeAggregates(aggregates, keeping: uid)
            }
            // Destroying the default would hand the choice of output to the
            // HAL, so the Mac is parked on the new device's clock, the first
            // display, first.
            if let current = system.defaultOutputUID(), aggregates.contains(current) {
                guard system.setDefaultOutput(uid: mainUID) else { return false }
            }
            guard removeAggregates(aggregates, keeping: nil),
                  system.createMultiOutput(
                      uid: uid, name: name, mainUID: mainUID, members: members)
            else { return false }
            built[uid] = signature
            return system.setDefaultOutput(uid: uid)
        }
    }

    /// Never the current default: that would hand the choice to the HAL.
    private func removeAggregates(_ aggregates: [String], keeping keep: String?) -> Bool {
        let current = system.defaultOutputUID()
        var removedAll = true
        for uid in aggregates where uid != keep {
            if uid == current {
                removedAll = false
                continue
            }
            system.destroyAggregate(uid: uid)
            built[uid] = nil
        }
        return removedAll
    }
}

/// The real system: the HAL's default output and aggregate devices.
@MainActor
final class CoreAudioMacOutputSystem: MacOutputSystem {
    private var created: [String: AudioObjectID] = [:]

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
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &device) == noErr,
              device != AudioObjectID(kAudioObjectUnknown)
        else { return false }
        // The HAL can take a moment to list a new aggregate by UID; until it
        // does, its ID is known from here.
        created[uid] = device
        return true
    }

    func destroyAggregate(uid: String) {
        guard let device = deviceID(uid: uid) else { return }
        AudioHardwareDestroyAggregateDevice(device)
        created[uid] = nil
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
        guard status == noErr, device != AudioDeviceID(kAudioObjectUnknown) else {
            return created[uid]
        }
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
