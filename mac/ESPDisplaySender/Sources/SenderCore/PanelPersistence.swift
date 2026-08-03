import Foundation

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

    init(snapshot: PanelSnapshot) {
        serviceName = snapshot.serviceName
        displayName = snapshot.displayName
        hardwareID = snapshot.hardwareID
        usbPort = snapshot.usbPort
        address = snapshot.address
        lastSeen = snapshot.lastSeen
    }

    /// Rebuild a runtime snapshot. Everything not persisted starts at its
    /// default, so a freshly loaded panel reads as offline with no telemetry
    /// until the device actually reports in.
    var snapshot: PanelSnapshot {
        PanelSnapshot(
            serviceName: serviceName,
            displayName: displayName,
            hardwareID: hardwareID,
            address: address,
            usbPort: usbPort,
            lastSeen: lastSeen)
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
