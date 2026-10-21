import Foundation
import SenderProtocol

/// The one-line facts the detail pane's hero shows about a panel: what board it
/// is, where it is plugged in and what answered there, how to reach it, and how
/// long it has been up. Worked out here rather than in the view so each wording
/// is testable (`PanelDetailFactsTests`).
extension PanelSnapshot {
    /// The board model, from the runtime profile the panel reported, with the
    /// chip: `ESP32-C6-LCD-1.47 (ST7789) · esp32c6`. Falls back to whatever
    /// identity is known, and says so when none is.
    var boardModelDescription: String {
        let chipToken = chip.flatMap { $0 == ServiceMetadata.unknownChip ? nil : $0 }
        if let profile, let name = GeneratedBoardCatalog.boardNameByProfile[profile] {
            return [name, chipToken].compactMap { $0 }.joined(separator: " · ")
        }
        let parts = [profile, target.map { "\($0) family" }, chipToken]
            .compactMap { $0 }
        return parts.isEmpty ? "Not reported yet" : parts.joined(separator: " · ")
    }

    /// Address and signal on one line, for the hero.
    var networkSummary: String {
        switch (address, rssi) {
        case (let address?, _?): return "\(address) · \(signalDescription)"
        case (let address?, nil): return address
        case (nil, _?): return "Address not resolved · \(signalDescription)"
        case (nil, nil): return "Not on the network"
        }
    }

    /// The panel's picture shape as it is mounted: its own geometry, turned on
    /// its side by a quarter-turn rotation, or nil while the panel has not
    /// said what it is. Not `PixelConvert`'s 172x320, which is one board's.
    var mountedGeometry: PanelGeometry? {
        guard let geometry else { return nil }
        return rotation % 2 == 1
            ? PanelGeometry(width: geometry.height, height: geometry.width)
            : geometry
    }

    /// `466:466`, reduced to lowest terms where that is exact (`1:1`), for
    /// the region footer; nil when the shape is not known.
    var shapeDescription: String? {
        guard let shape = mountedGeometry, shape.width > 0, shape.height > 0 else {
            return nil
        }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let divisor = gcd(shape.width, shape.height)
        let reduced = (shape.width / divisor, shape.height / divisor)
        // A reduction to small numbers reads better (1:1, 3:4); otherwise the
        // pixel size itself is clearer than something like 43:80.
        return reduced.0 <= 16 && reduced.1 <= 16
            ? "\(reduced.0):\(reduced.1)" : "\(shape.width):\(shape.height)"
    }

    /// How long the board has been up, or that it has not said.
    var uptimeSummary: String {
        uptimeSeconds > 0 ? uptimeDescription : "Not reported yet"
    }
}

extension PanelManager {
    /// Which USB serial device a panel is on, and what answered there.
    struct USBAttachment: Equatable {
        /// The device node, when one is attributed to this panel.
        var port: String?
        /// `identified as "Desk Panel" (ID 02:00:00:12:34:56)`, or why not.
        var detail: String
        /// A current CFGSHOW from this path named this panel's hardware ID.
        var isVerified: Bool

        /// `cu.usbmodem1101 · identified as ...`, or just the detail.
        var summary: String {
            guard let port else { return detail }
            return "\((port as NSString).lastPathComponent) · \(detail)"
        }
    }

    /// Only a device that reports this panel's own hardware ID is attributed to
    /// it: a path remembered from an earlier session, or the only serial device
    /// that happens to be plugged in, is not evidence of which board is on it.
    func usbAttachment(for serviceName: String) -> USBAttachment {
        switch usbSerialState(for: serviceName) {
        case .verified(let device):
            return USBAttachment(
                port: device.path, detail: Self.identifiedDetail(device),
                isVerified: true)
        case .restarting:
            return USBAttachment(
                port: usbUpdateDevice(for: serviceName)?.path,
                detail: "restarting after a change", isVerified: false)
        case .ambiguous:
            return USBAttachment(
                port: nil,
                detail: "Two USB devices report this board's ID", isVerified: false)
        case .absent, .mismatch, .enumeratedUnverified:
            guard let panel = panels.first(where: { $0.serviceName == serviceName }),
                  let expected = stableHardwareID(of: panel),
                  let device = usbDevices.first(where: {
                      $0.isConnected && !$0.path.isEmpty
                          && ConfigCommands.canonicalHardwareID($0.hardwareID) == expected
                  })
            else {
                return USBAttachment(
                    port: nil, detail: "Not connected by USB", isVerified: false)
            }
            return USBAttachment(
                port: device.path,
                detail: "matched by ID, waiting for it to answer", isVerified: false)
        }
    }

    private static func identifiedDetail(
        _ device: WifiConfigUI.USBDeviceOption
    ) -> String {
        var detail = "identified as \u{201C}\(device.displayName)\u{201D}"
        if let id = device.hardwareID { detail += " (ID \(formattedHardwareID(id)))" }
        return detail
    }

    /// `020000123456` as `02:00:00:12:34:56`, the spelling esptool prints.
    static func formattedHardwareID(_ id: String) -> String {
        guard let canonical = ConfigCommands.canonicalHardwareID(id) else { return id }
        var pairs: [String] = []
        var index = canonical.startIndex
        while index < canonical.endIndex {
            let next = canonical.index(index, offsetBy: 2)
            pairs.append(String(canonical[index..<next]))
            index = next
        }
        return pairs.joined(separator: ":")
    }
}
