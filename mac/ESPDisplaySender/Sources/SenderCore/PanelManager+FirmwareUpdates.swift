import AppKit
import Foundation
import Network
import ScreenCaptureKit
import SenderProtocol

/// Firmware updates: readiness preflight (OTA and USB), the gathered
/// FirmwareUpdateTarget snapshot, remembered OTA passwords, and both
/// push paths.
extension PanelManager {
    // MARK: firmware updates

    enum FirmwareUpdateTransport: String, CaseIterable, Identifiable, Sendable {
        case wifi
        case usb

        var id: String { rawValue }
        var label: String {
            switch self {
            case .wifi: return "Over WiFi (OTA)"
            case .usb: return "Over USB"
            }
        }
    }

    /// Everything an update sheet needs about one panel, gathered as one coherent
    /// snapshot so it cannot silently switch addresses or USB identities while a
    /// write is being confirmed. The sheet may explicitly replace transport fields
    /// after the user refreshes its USB-device row.
    struct FirmwareUpdateTarget: Equatable, Identifiable, Sendable {
        var id: String { serviceName }

        let serviceName: String
        let displayName: String
        /// Stable 6-byte EINF/CFGSHOW identity. It keys the OTA password and is
        /// also what a USB device must match before esptool may write it.
        let hardwareID: String
        /// Live session address. Nil when OTA is unavailable but USB is safe.
        var address: String?
        let chip: String?
        /// Firmware family plus independent runtime compatibility evidence.
        let target: String?
        let profile: String?
        let partition: String?
        let firmwareVersion: String
        /// A currently connected, positively identity-matched USB device.
        var usbDevice: WifiConfigUI.USBDeviceOption?
        /// Generation of that path when the sheet opened. A removal/reuse makes
        /// it stale and the preflight refuses before invoking esptool.
        var usbPathGeneration: Int?
        /// True only for a current-session explicit choice or one unique exact
        /// CFGSHOW name match on firmware predating the id= field. A nil CFGSHOW
        /// ID may pass the read-only preflight in this case, but esptool's MAC
        /// must still equal `hardwareID` before any write.
        var usbAllowsLegacyIdentity: Bool

        init(
            serviceName: String, displayName: String, hardwareID: String,
            address: String?, chip: String?, target: String? = nil,
            profile: String? = nil, partition: String? = nil,
            firmwareVersion: String,
            usbDevice: WifiConfigUI.USBDeviceOption? = nil,
            usbPathGeneration: Int? = nil,
            usbAllowsLegacyIdentity: Bool = false
        ) {
            self.serviceName = serviceName
            self.displayName = displayName
            self.hardwareID = hardwareID
            self.address = address
            self.chip = chip
            self.target = target
            self.profile = profile
            self.partition = partition
            self.firmwareVersion = firmwareVersion
            self.usbDevice = usbDevice
            self.usbPathGeneration = usbPathGeneration
            self.usbAllowsLegacyIdentity = usbAllowsLegacyIdentity
        }

        var transports: [FirmwareUpdateTransport] {
            var result: [FirmwareUpdateTransport] = []
            if address != nil { result.append(.wifi) }
            if usbDevice != nil { result.append(.usb) }
            return result
        }
    }

    enum FirmwareUpdateReadiness: Equatable {
        case ready(FirmwareUpdateTarget)
        case notReady(String)
    }

    func beginFirmwareUpdate(_ serviceName: String) -> FirmwareUpdateTarget? {
        switch firmwareUpdateReadiness(serviceName) {
        case .ready(let target):
            return target
        case .notReady(let reason):
            operationOutcome = .failure("Firmware updates unavailable", reason)
            return nil
        }
    }

    func canBeginFirmwareUpdate(_ serviceName: String) -> Bool {
        if case .ready = firmwareUpdateReadiness(serviceName) { return true }
        return false
    }

    func firmwareUpdateUnavailableReason(_ serviceName: String) -> String? {
        if case .notReady(let reason) = firmwareUpdateReadiness(serviceName) {
            return reason
        }
        return nil
    }

    /// Gather every currently safe transport. OTA uses only the live session's
    /// resolved address; USB uses only one connected device whose reported ID
    /// matches this panel. A remembered IP or serial path is never enough.
    func firmwareUpdateReadiness(_ serviceName: String) -> FirmwareUpdateReadiness {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }) else {
            return .notReady("This display is not known yet.")
        }
        guard let hardwareID = stableHardwareID(of: panel) else {
            return .notReady(
                "This panel has not reported its hardware ID yet, so an update "
                    + "cannot be tied to the correct device.")
        }
        guard let version = panel.firmwareVersion else {
            return .notReady(
                "This panel has not reported its firmware version yet, so there "
                    + "is nothing to compare a bundle against.")
        }

        let otaReason = controlUnavailableReason(serviceName, capability: .ota)
        let address = otaReason == nil ? sessions[serviceName]?.resolvedAddress : nil

        let expectedUSBID = ConfigCommands.canonicalHardwareID(
            panel.usbHardwareID ?? hardwareID)
        let stableMatches = usbDevices.filter { device in
            device.isConnected && !device.path.isEmpty
                && ConfigCommands.canonicalHardwareID(device.hardwareID)
                    == expectedUSBID
        }
        var usbDevice = stableMatches.count == 1 ? stableMatches[0] : nil
        var usbAllowsLegacyIdentity = false

        // Legacy CFGSHOW has a name but no id=. Stable-ID matching remains the
        // authority; only when it finds nothing may one current-session explicit
        // path or one unique exact name match enter the read-only preflight.
        if stableMatches.isEmpty {
            if let explicit = explicitLegacyUSBSelections[serviceName],
               explicit.generation == usbPathGeneration(explicit.path),
               let candidate = usbDevices.first(where: {
                   $0.path == explicit.path && $0.isConnected
                       && $0.hardwareID == nil
               }) {
                usbDevice = candidate
                usbAllowsLegacyIdentity = true
            } else {
                let nameMatches = usbDevices.filter {
                    $0.isConnected && !$0.path.isEmpty && $0.hardwareID == nil
                        && $0.name == panel.displayName
                }
                if nameMatches.count == 1 {
                    usbDevice = nameMatches[0]
                    usbAllowsLegacyIdentity = true
                }
            }
        }
        let usbGeneration = usbDevice.map { usbPathGeneration($0.path) }

        guard address != nil || usbDevice != nil else {
            if otaReason == nil {
                return .notReady(
                    "This panel's live network address has not been resolved yet, "
                        + "and no connected USB device is positively matched to it.")
            }
            if !usbDevices.isEmpty {
                return .notReady(
                    otaReason! + " A USB device is connected, but none reports "
                        + "this display's hardware ID; refresh or select the correct "
                        + "device under Connection.")
            }
            return .notReady(otaReason!)
        }

        return .ready(FirmwareUpdateTarget(
            serviceName: serviceName,
            displayName: panel.displayName,
            hardwareID: hardwareID,
            address: address,
            chip: panel.chip,
            target: panel.target,
            profile: panel.profile,
            partition: panel.partition,
            firmwareVersion: version,
            usbDevice: usbDevice,
            usbPathGeneration: usbGeneration,
            usbAllowsLegacyIdentity: usbAllowsLegacyIdentity))
    }

    func rememberedOTAPassword(for hardwareID: String) -> String? {
        otaPasswords.password(forHardwareID: hardwareID)
    }

    func setRememberedOTAPassword(
        _ password: String?, for hardwareID: String
    ) -> String? {
        do {
            if let password, !password.isEmpty {
                try otaPasswords.store(password, forHardwareID: hardwareID)
            } else {
                try otaPasswords.remove(forHardwareID: hardwareID)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Run OTA and return its result to the sheet that owns the operation. The
    /// manager-window alert is deliberately not touched here: it sits behind the
    /// sheet and would otherwise be deferred until the sheet closed.
    func pushFirmware(
        image: Data,
        filename: String,
        to target: FirmwareUpdateTarget,
        password: String,
        progress: @escaping @Sendable (FirmwarePusher.Progress) -> Void
    ) async -> OperationOutcome {
        guard let address = target.address else {
            return .failure(
                "WiFi update unavailable",
                "This panel no longer has a live resolved address. Choose USB, "
                    + "or wait for it to reconnect and try again.")
        }
        let pusher = FirmwarePusher()
        do {
            try await pusher.push(
                image: image, filename: filename, to: address,
                password: password, progress: progress)
            return .success(
                "Update sent",
                "\(target.displayName) has the new firmware and is restarting "
                    + "onto it. Streaming reconnects by itself; the version in "
                    + "the Firmware section updates when it reports in.")
        } catch {
            return .failure("Update failed", error.localizedDescription)
        }
    }

    /// Whether CFGSHOW's physical panel/controller profile belongs to an exact
    /// firmware target. This is independent of the esptool chip check: `board=`
    /// is `st77916`/`co5300`/etc., not `esp32s3`.
    nonisolated static func physicalBoard(
        _ board: String, isCompatibleWith target: String
    ) -> Bool {
        switch target {
        case "c6":
            return board == "st7789" || board == "jd9853"
        case "s3":
            return board == "gc9107" || board == "st7789-154"
                || board == "co5300" || board == "st77916"
        case "p4":
            return board == "st7703-4b"
        // Historical exact-target bundles remain readable for manual recovery.
        case "s3-085":
            return board == "gc9107"
        case "s3-154":
            return board == "st7789-154"
        case "s3-175":
            return board == "co5300"
        case "s3-185":
            return board == "st77916"
        case "p4-4b":
            return board == "st7703-4b"
        default:
            // A future app can teach this build the new composition. Treating an
            // unknown pair as compatible would turn missing knowledge into proof.
            return false
        }
    }

    /// Write a current bundle over USB after re-verifying every fact
    /// that makes the selected serial path safe. No whole-chip erase is issued,
    /// so NVS credentials, name, brightness, orientation and OTA password remain.
    func flashFirmwareOverUSB(
        bundle: FirmwareBundle,
        to target: FirmwareUpdateTarget,
        progress: @escaping @Sendable (UsbOnboarder.Progress) -> Void
    ) async -> OperationOutcome {
        guard let device = target.usbDevice,
              let expectedGeneration = target.usbPathGeneration,
              !device.path.isEmpty
        else {
            return .failure(
                "USB update unavailable",
                "No connected USB device was positively matched to this display.")
        }
        let path = device.path
        let expectedID = ConfigCommands.canonicalHardwareID(target.hardwareID)
        guard let expectedID else {
            return .failure(
                "USB identity unavailable",
                "This display's hardware ID is not a six-byte MAC address, so the "
                    + "app cannot prove which connected board is safe to write.")
        }
        guard usbPathGeneration(path) == expectedGeneration,
              let current = usbDevices.first(where: {
                  $0.path == path && $0.isConnected
              })
        else {
            return .failure(
                "USB device changed",
                "The serial device was unplugged, renumbered, or reused after the "
                    + "update window opened. Refresh the USB device and try again.")
        }
        let currentID = ConfigCommands.canonicalHardwareID(current.hardwareID)
        guard currentID == expectedID
                || (currentID == nil && target.usbAllowsLegacyIdentity)
        else {
            return .failure(
                "USB device mismatch",
                "The connected USB device reports a different hardware ID, so "
                    + "nothing was written.")
        }

        progress(.readingChip)
        var cfgTarget: String?
        var cfgBoard: String?
        var cfgChip: String?
        var cfgPartition: String?
        switch await probeUSBDevice(path, timeout: 3) {
        case .unavailable(let reason):
            return .failure(
                "Could not verify the USB display",
                "CFGSHOW did not verify \(path): \(reason)")
        case .identified(let identity):
            let reportedID = ConfigCommands.canonicalHardwareID(identity.hardwareID)
            guard reportedID == expectedID
                    || (reportedID == nil && target.usbAllowsLegacyIdentity)
            else {
                return .failure(
                    "USB device mismatch",
                    "The device at \(path) did not report \(target.hardwareID), "
                        + "so nothing was written.")
            }
            cfgTarget = identity.target
            cfgBoard = identity.board
            cfgChip = identity.chip
            cfgPartition = identity.partition
            if let liveTarget = target.target,
               let reportedTarget = identity.target,
               liveTarget != reportedTarget {
                return .failure(
                    "USB target mismatch",
                    "The live panel reports target \(liveTarget), but CFGSHOW now "
                        + "reports \(reportedTarget). Nothing was written.")
            }
        }
        guard usbPathGeneration(path) == expectedGeneration else {
            return .failure(
                "USB device changed",
                "The serial device changed while it was being verified, so "
                    + "nothing was written.")
        }

        let tool: EsptoolCommand.Tool
        switch EsptoolInstallation.locate() {
        case .installed(let path):
            tool = EsptoolCommand.Tool(path: path)
        case .missing(let searched):
            return .failure(
                "The esp32 core is not installed",
                "USB updating uses the esptool included with the Arduino esp32 "
                    + "core. It was not found under \(searched.joined(separator: " or ")).")
        }

        let detection = await UsbOnboarder.detectChip(port: path, tool: tool)
        let detectedChip: String
        let detectedMAC: String?
        switch detection {
        case .detected(let chip, let mac):
            detectedChip = chip
            detectedMAC = ConfigCommands.canonicalHardwareID(mac)
        case .failed(let reason):
            return .failure("Could not read the USB board", reason)
        case .notAttempted:
            return .failure(
                "Could not read the USB board",
                "esptool did not attempt chip detection, so nothing was written.")
        }
        guard detectedMAC == expectedID else {
            return .failure(
                "USB device mismatch",
                "esptool read \(detectedMAC ?? "no MAC address") from \(path), "
                    + "not \(target.hardwareID), so nothing was written.")
        }
        if let reportedTarget = cfgTarget,
           let physicalBoard = cfgBoard,
           !Self.physicalBoard(physicalBoard, isCompatibleWith: reportedTarget) {
            return .failure(
                "USB board profile mismatch",
                "CFGSHOW reports physical board \(physicalBoard) with target "
                    + "\(reportedTarget), which is not a supported composition. "
                    + "Nothing was written.")
        }
        if let expectedChip = target.chip,
           !expectedChip.isEmpty,
           expectedChip != ServiceMetadata.unknownChip,
           expectedChip != detectedChip {
            return .failure(
                "USB chip mismatch",
                "The display reported \(expectedChip), but esptool read "
                    + "\(detectedChip). Nothing was written.")
        }
        let exactTarget = cfgTarget ?? target.target
        guard let exactTarget else {
            return .failure(
                "Firmware family unavailable",
                "CFGSHOW did not report a firmware family, so nothing was written.")
        }
        guard let selectedImage = bundle.image(forTarget: exactTarget) else {
            return .failure(
                "Wrong firmware bundle",
                "This bundle has no image for exact target \(exactTarget).")
        }
        guard selectedImage.chip == detectedChip else {
            return .failure(
                "USB chip mismatch",
                "The \(exactTarget) image is for \(selectedImage.chip), but esptool "
                    + "read \(detectedChip). Nothing was written.")
        }
        if !selectedImage.profiles.isEmpty {
            guard cfgChip == detectedChip,
                  let cfgBoard, selectedImage.profiles.contains(cfgBoard),
                  let cfgPartition, cfgPartition == selectedImage.partition
            else {
                return .failure(
                    "USB compatibility identity incomplete",
                    "Current family firmware requires matching CFGSHOW family, chip, "
                        + "profile, and partition metadata before a write. Nothing was written.")
            }
        }
        guard usbPathGeneration(path) == expectedGeneration,
              usbDevices.contains(where: { $0.path == path && $0.isConnected })
        else {
            return .failure(
                "USB device changed",
                "The serial device changed after chip detection, so nothing was written.")
        }
        guard let writes = bundle.flashPlan(forTarget: exactTarget) else {
            return .failure(
                "Bundle is OTA-only",
                "The \(exactTarget) image does not include the bootloader, partition "
                    + "table and boot_app0 required for a safe USB write. Choose a "
                    + "current format-3 bundle.")
        }

        do {
            try await UsbOnboarder.flash(
                writes: writes, chip: detectedChip, port: path, tool: tool,
                eraseAll: false, onProgress: progress)
        } catch let failure as WifiConfigUI.ConfigFailure {
            return .failure(failure)
        } catch {
            return .failure("Flashing failed", error.localizedDescription)
        }
        refreshUSBPorts()
        return .success(
            "Firmware written over USB",
            "\(bundle.firmwareVersion) was written to \(target.displayName) "
                + "without erasing the chip, and the display is restarting. Its "
                + "saved WiFi, name, display settings and OTA password remain.")
    }

}
