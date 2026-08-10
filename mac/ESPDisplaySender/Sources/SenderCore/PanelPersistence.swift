import Foundation
import SenderProtocol

/// The durable half of a panel record.
///
/// Only identity and user-chosen settings live here. Everything the device
/// reports about itself — signal strength, uptime, free heap, pacing, frame
/// counters, brightness, flip, sleep, and pause state, plus the negotiated
/// protocol versions and capability bits — is deliberately excluded, because
/// restoring those from disk presents a reading taken minutes or weeks ago as
/// if it were current. A field belongs here only if the user set it or if it is
/// needed to recognise the same panel again.
struct PersistedPanel: Codable, Equatable {
    /// Bonjour service name. Still the live routing key, so it is stored to
    /// reattach a record to a session before EINF arrives with the hardware ID.
    var serviceName: String
    /// Shown in the UI, set by the device's own name or by an explicit rename.
    var displayName: String
    /// Stable across renames and re-flashes; the real identity of the panel.
    var hardwareID: String?
    /// Serial port the user assigned for USB configuration.
    var usbPort: String?
    /// Last known address, kept as a hint for the UI while offline.
    var address: String?
    /// When the panel was last heard from, so "last seen" survives a restart.
    var lastSeen: Date?
    /// What the user chose this panel should show, absent for automatic. Stored
    /// in the same shape as a `devices.json` entry.
    var source: SourceSpec?
    /// Lines the panel shows on its own status card while nothing is driving it.
    var idleText: String?
    /// Which gesture bindings the user chose, absent for the default. Absent
    /// rather than always written for the same reason `source` is: a record that
    /// only says "the default" is noise, and an older file that predates presets
    /// should load as the default rather than fail to decode.
    var gesturePreset: GesturePreset?

    init(snapshot: PanelSnapshot) {
        serviceName = snapshot.serviceName
        displayName = snapshot.displayName
        hardwareID = snapshot.hardwareID
        usbPort = snapshot.usbPort
        address = snapshot.address
        lastSeen = snapshot.lastSeen
        source = snapshot.source.spec
        idleText = snapshot.idleText.isEmpty ? nil : snapshot.idleText
        gesturePreset = snapshot.gesturePreset == .standard
            ? nil : snapshot.gesturePreset
    }

    /// Rebuild a runtime snapshot. Everything not persisted starts at its
    /// default, so a freshly loaded panel reads as offline with no telemetry
    /// until the device actually reports in.
    var snapshot: PanelSnapshot {
        var panel = PanelSnapshot(
            serviceName: serviceName,
            displayName: displayName,
            hardwareID: hardwareID,
            address: address,
            usbPort: usbPort,
            lastSeen: lastSeen)
        panel.source = PanelSource(source)
        panel.idleText = idleText ?? ""
        panel.gesturePreset = gesturePreset ?? .standard
        return panel
    }
}

/// Reading and writing the durable records. Split out from `PanelManager` so
/// the manager decides *when* to save while this decides *how*, and so failures
/// are returned rather than swallowed: the file holds the user's display names
/// and USB port assignments, and losing it silently is not acceptable.
enum PanelStore {
    static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ESPDisplaySender", isDirectory: true)
            .appendingPathComponent("panels.json")
    }

    /// A missing file is the normal first-run case and reports no failure. A
    /// file that exists but cannot be read or decoded does, because that means
    /// settings the user entered are about to be silently dropped.
    static func load(from url: URL?) -> (records: [PersistedPanel], failure: String?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return ([], nil)
        }
        do {
            let data = try Data(contentsOf: url)
            return (try JSONDecoder.espDisplay.decode([PersistedPanel].self, from: data), nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }

    static func save(_ records: [PersistedPanel], to url: URL) throws {
        let data = try JSONEncoder.espDisplay.encode(records)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    static var espDisplay: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    /// Files written before persistence was split still contain the full
    /// snapshot. Unknown keys are ignored during decoding, so those files load
    /// as `PersistedPanel` records without a migration step and the stale
    /// telemetry they carry is dropped on the way in.
    static var espDisplay: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
