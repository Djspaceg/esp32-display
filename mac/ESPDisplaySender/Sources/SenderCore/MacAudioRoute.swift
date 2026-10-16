import CoreAudio
import Foundation

/// What plays on the displays, chosen once for every display.
enum MacAudioRoute: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Follow the Mac's Sound setting: each display has an output device of
    /// its own (ESPDisplayAudio.driver) and plays only while that device is
    /// the Mac's output, or part of a Multi-Output device made in Audio MIDI
    /// Setup; otherwise it is quiet. The app never picks the Mac's output and
    /// never taps its sound.
    case followMac
    /// Also copy the Mac's sound to the displays: a process tap copies what
    /// the Mac plays, wherever it plays it, to every display. Needs the System
    /// Audio Recording permission and no driver.
    case copy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .followMac: return "Follow the Mac's Sound setting"
        case .copy: return "Also copy the Mac's sound to the devices"
        }
    }

    /// One plain line under the menu: what the choice does.
    var explanation: String {
        switch self {
        case .followMac:
            return "An ESP device plays only while it is chosen as the output in "
                + "Sound settings; otherwise it stays quiet."
        case .copy:
            return "The ESP devices play whatever this Mac plays, wherever the Mac "
                + "sends it."
        }
    }

    var usesDriver: Bool { self == .followMac }

    /// Choices of earlier builds: "displaysOnly" already played on a display
    /// only through its own device, so it follows the Mac now; "mirror"
    /// played on the Mac and the displays together, as the copy does.
    /// Anything else unknown fails, and the settings file falls back.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "displaysOnly": self = .followMac
        case "mirror": self = .copy
        default:
            guard let route = MacAudioRoute(rawValue: raw) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath, debugDescription: "unknown route \(raw)"))
            }
            self = route
        }
    }
}

/// One output device as macOS lists it.
struct MacOutputDevice: Equatable, Sendable {
    let uid: String
    let name: String
    let isBuiltIn: Bool
}

/// What the router reads from CoreAudio. Read only: the app never changes
/// the Mac's output. Injectable so tests list devices of their own.
@MainActor
protocol MacOutputSystem: AnyObject {
    func outputDevices() -> [MacOutputDevice]
}

/// The route in effect, worked out from the choice and what exists. Pure, so
/// every combination is tested without CoreAudio.
struct MacAudioRoutePlan: Equatable, Sendable {
    let chosen: MacAudioRoute
    /// What the displays are fed by. Never `.copy` unless `.copy` was chosen:
    /// following the Mac without its driver leaves the displays quiet rather
    /// than copying the Mac's sound.
    let effective: MacAudioRoute
    /// Why the choice is not, or not yet, fully in effect. Shown as selectable
    /// text under the menu.
    let note: String?

    static let waitingNote = "Waiting for the ESP devices' outputs to appear in "
        + "Sound settings."

    static func make(
        chosen: MacAudioRoute,
        driver: DisplayAudioDriverAvailability,
        presentDisplayUIDs present: [String]
    ) -> MacAudioRoutePlan {
        guard chosen.usesDriver else {
            return MacAudioRoutePlan(chosen: chosen, effective: .copy, note: nil)
        }
        switch driver {
        case .ready:
            break
        case .absent:
            return MacAudioRoutePlan(
                chosen: chosen, effective: chosen,
                note: "Following the Mac's Sound setting needs the audio driver, "
                    + "which is not installed, so the ESP devices stay quiet. Click "
                    + "Install Audio Driver below; each device then appears in Sound "
                    + "settings.")
        case .incompatible(let version):
            let found = version.map { "version \($0)" } ?? "an unreadable version"
            return MacAudioRoutePlan(
                chosen: chosen, effective: chosen,
                note: "The installed audio driver is \(found), and this app "
                    + "needs version \(DisplayAudioDriverProtocol.version), so the "
                    + "ESP devices stay quiet. Click Reinstall Audio Driver below.")
        }
        return MacAudioRoutePlan(
            chosen: chosen, effective: chosen, note: present.isEmpty ? waitingNote : nil)
    }
}

/// Keeps the displays' devices registered with the driver while the app
/// follows the Mac's Sound setting, and says why one is missing. It reads
/// the Mac's devices and never changes its output: whether a display plays
/// is the Sound setting's choice alone.
@MainActor
final class MacAudioRouter {
    private let bridge: DisplayAudioDriverBridge
    private let system: MacOutputSystem
    private var registered = false
    /// The display devices present at the last pass, by UID.
    private(set) var presentDevices: [String: AudioObjectID] = [:]
    /// Passes in a row that found the driver full with a display missing.
    private var fullPasses = 0
    /// The displays those passes were for.
    private var countedDisplays: [String] = []

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
        // A device counts only if this app owns it: one another process
        // claimed first would get whatever the Mac sends it.
        var present: [String: AudioObjectID] = [:]
        var claimed: [DisplayAudioDeviceSpec] = []
        var missing: [DisplayAudioDeviceSpec] = []
        if driving {
            let outputs = system.outputDevices()
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
            presentDisplayUIDs: displays.map(\.uid).filter { present[$0] != nil })
        presentDevices = present
        // The count is trusted only once two passes in a row, with the same
        // displays and an accepted registration, agree: the driver updates
        // its list after each registration, so a pass right after one can
        // read the old count.
        let displayUIDs = displays.map(\.uid)
        if refused || displayUIDs != countedDisplays { fullPasses = 0 }
        countedDisplays = displayUIDs
        // The refusal and the notes below come only while the driver is in
        // use, when the plan's own note can only be the generic "waiting",
        // which they say better; the plan's other notes (not installed,
        // another version) come with nothing driving, and stand alone.
        if refused {
            return MacAudioRoutePlan(
                chosen: plan.chosen, effective: plan.effective,
                note: "The audio driver refused this app's ESP devices. It "
                    + "takes up to \(DisplayAudioDriverProtocol.maxClients) apps at "
                    + "once, so other apps on this Mac may be using every place; "
                    + "quit them, or restart the Mac.")
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
                ? "this app already uses all \(capacity) of its outputs, the most it "
                    + "makes. Remove a device from this app to free one."
                : "\(others) of its \(capacity) outputs are in use by other apps on this "
                    + "Mac. Quit some of them; the device gets its output once one "
                    + "is free."
            notes.append("The audio driver has no room for \(names): " + why)
        }
        if !claimed.isEmpty {
            let names = claimed.map { "\"\($0.name)\"" }.joined(separator: ", ")
            notes.append("Another app on this Mac has claimed the output for "
                + "\(names), so this app does not play what the Mac sends it. "
                + "The device comes back to this app once that app lets go of it.")
        }
        if notes.isEmpty, let note = plan.note { notes.append(note) }
        return MacAudioRoutePlan(
            chosen: plan.chosen, effective: plan.effective,
            note: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    /// Withdraws this app's devices when it quits. The Mac's output is left
    /// to macOS, which moves it off a device that goes away.
    func shutdown() {
        if registered {
            bridge.register([])
            registered = false
        }
    }
}

/// The real system: the devices the HAL lists.
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

    private func transportType(_ device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value
    }
}
