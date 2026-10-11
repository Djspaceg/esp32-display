import Foundation
import SenderProtocol

/// A recovery that outlives the sheet and the app: written at Start and at each
/// stage after it, removed when the real firmware answers or when nothing was
/// written. With it, the app takes a board up again where the run stopped,
/// found on USB by its own serial number, so the one physical action the
/// recovery needed is never asked for twice.
struct UsbRecoveryRecord: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable {
        /// Start was pressed; nothing has reached the board.
        case waiting
        /// esptool was pointed at the board: the rescue image may be part-written.
        case caught
        /// The rescue image is on and answered.
        case rescued
        /// The real firmware is being written over the rescue image.
        case installing
    }

    /// What the rescue image said about the board, for installing on it later.
    struct Board: Codable, Equatable, Sendable {
        var name: String
        var hardwareID: String?
        var target: String?
        var board: String?
        var chip: String?
        var partition: String?
        var storedOverride: String?
    }

    var stage: Stage
    var family: String
    var carrier: String?
    /// The ports attached when Start was pressed.
    var baseline: [String]
    /// Where the board was last reached, and the USB device behind it.
    var port: String?
    var usbSerial: String?
    var usbLocation: Int?
    var board: Board?

    /// The rescued board as the install wants it, on the recorded port.
    var rescuedBoard: UsbRescuer.RescuedBoard? {
        guard let board, let port, let family = UsbRescue.Family.named(family) else { return nil }
        return UsbRescuer.RescuedBoard(
            port: port, family: family,
            identity: WifiConfigUI.USBIdentity(
                name: board.name, hardwareID: board.hardwareID, target: board.target,
                board: board.board, chip: board.chip, partition: board.partition),
            storedOverride: board.storedOverride, carrier: carrier)
    }
}

/// The one recovery record, beside the app's settings.
struct UsbRecoveryStore: Sendable {
    let url: URL

    static var defaultURL: URL? {
        PanelStore.defaultURL?
            .deletingLastPathComponent()
            .appendingPathComponent("usb-recovery.json")
    }

    /// nil when there is none, or when the file cannot be read: a record that
    /// cannot be understood cannot be resumed either.
    func load() -> UsbRecoveryRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(UsbRecoveryRecord.self, from: data)
    }

    func save(_ record: UsbRecoveryRecord) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Every decision about the record: what each stage keeps, where the board is
/// now, and what Resume does with it.
enum UsbRecovery {
    /// What Resume does with a record and what is on USB now.
    enum Plan: Equatable {
        /// Nothing reached the board: an ordinary start, with the ports that
        /// appeared since it began marked for the person to choose from.
        case choose(newPorts: [String])
        /// esptool reached the board but the rescue image may not be whole:
        /// write it again on that port, which esptool resets over USB.
        case adopt(String)
        /// The rescue image is on: ask it again on that port.
        case read(String)
        /// The real firmware was being written: install it again.
        case install(UsbRescuer.RescuedBoard)
        /// The board is not on USB, so it has to be caught again.
        case waitForBoard
    }

    static func started(family: String, carrier: String?, baseline: [String]) -> UsbRecoveryRecord {
        UsbRecoveryRecord(
            stage: .waiting, family: family, carrier: carrier, baseline: baseline.sorted())
    }

    static func caught(
        _ record: UsbRecoveryRecord, port: String, device: UsbRescue.USBIdentity?
    ) -> UsbRecoveryRecord {
        var next = record
        next.stage = .caught
        next.port = port
        next.usbSerial = device.map(\.serial).flatMap { $0.isEmpty ? nil : $0 }
        next.usbLocation = device?.location
        return next
    }

    static func rescued(
        _ record: UsbRecoveryRecord, board: UsbRescuer.RescuedBoard,
        device: UsbRescue.USBIdentity?
    ) -> UsbRecoveryRecord {
        var next = caught(record, port: board.port, device: device)
        // A device the registry could not name keeps what was learned before.
        if device == nil {
            next.usbSerial = record.usbSerial
            next.usbLocation = record.usbLocation
        }
        next.stage = .rescued
        next.carrier = board.carrier ?? record.carrier
        next.board = .init(
            name: board.identity.name, hardwareID: board.identity.hardwareID,
            target: board.identity.target, board: board.identity.board,
            chip: board.identity.chip, partition: board.identity.partition,
            storedOverride: board.storedOverride)
        return next
    }

    static func installing(_ record: UsbRecoveryRecord) -> UsbRecoveryRecord {
        var next = record
        next.stage = .installing
        return next
    }

    /// The port the recorded board is on now. Its USB serial is the board
    /// wherever it is plugged (a native-USB ESP32 reports its MAC, a bridge its
    /// own serial); with no serial, the same socket is. A name alone is never
    /// trusted: macOS reuses names for other devices.
    static func locate(
        _ record: UsbRecoveryRecord, ports: [String],
        device: (String) -> UsbRescue.USBIdentity?
    ) -> String? {
        let devices = ports.map { ($0, device($0)) }
        if let serial = record.usbSerial {
            return devices.first { $0.1?.serial == serial }?.0
        }
        if let location = record.usbLocation {
            return devices.first { $0.1?.location == location }?.0
        }
        return nil
    }

    /// Whether a board answering with this hardware ID is the recorded one:
    /// by what the rescue image reported, or by a native-USB serial, which is
    /// the chip's MAC.
    static func isRecordedBoard(_ record: UsbRecoveryRecord, hardwareID: String) -> Bool {
        let id = ConfigCommands.canonicalHardwareID(hardwareID)
        guard let id else { return false }
        return record.board?.hardwareID == id
            || ConfigCommands.canonicalHardwareID(record.usbSerial) == id
    }

    /// The record a run starts with. A run Resume begins on a board it had
    /// already reached keeps that record as it is - its stage, port and serial
    /// - so a Stop or a quit in the seconds before esptool reaches the board
    /// again loses nothing. Any other run starts a new one.
    static func atStart(
        existing: UsbRecoveryRecord?, resuming: Bool,
        family: String, carrier: String?, baseline: [String]
    ) -> UsbRecoveryRecord {
        if resuming, let existing, existing.stage != .waiting, existing.family == family {
            return existing
        }
        return started(family: family, carrier: carrier, baseline: baseline)
    }

    static func plan(_ record: UsbRecoveryRecord, located: String?, present: [String]) -> Plan {
        switch record.stage {
        case .waiting:
            // Marked, never chosen: the baseline may be from an earlier launch,
            // and what appeared since may be another board.
            return .choose(newPorts: Set(present).subtracting(record.baseline).sorted())
        case .caught:
            return located.map(Plan.adopt) ?? .waitForBoard
        case .rescued:
            return located.map(Plan.read) ?? .waitForBoard
        case .installing:
            guard let located, var board = record.rescuedBoard else { return .waitForBoard }
            board.port = located
            return .install(board)
        }
    }
}
