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
        /// Nil for firmware that predates USB version reporting. That state may
        /// update only over a fully verified USB path.
        let firmwareVersion: String?
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
            firmwareVersion: String?,
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
        let verifiedUSBDevice = verifiedUSBDevice(for: serviceName)
        let version =
            panel.firmwareVersion
                ?? verifiedUSBDevice?.serialStatus?.firmwareVersion

        let otaReason = controlUnavailableReason(serviceName, capability: .ota)
        // Without a running version the sheet cannot honestly classify an OTA
        // update. A complete USB match can still bootstrap current firmware
        // because the board identity, target, chip and partition are rechecked
        // before esptool writes anything.
        let address =
            version != nil && otaReason == nil
            ? sessions[serviceName]?.resolvedAddress : nil
        let usbDevice: WifiConfigUI.USBDeviceOption?
        if let device = verifiedUSBDevice,
           device.target?.isEmpty == false,
           device.board?.isEmpty == false,
           device.chip?.isEmpty == false,
           device.partition?.isEmpty == false {
            usbDevice = device
        } else {
            usbDevice = nil
        }
        let usbGeneration = usbDevice.map { usbPathGeneration($0.path) }

        guard address != nil || usbDevice != nil else {
            if verifiedUSBDevice != nil {
                return .notReady(
                    "USB is connected, but the app cannot verify the board family, "
                        + "chip, profile, and partition safely.")
            }
            if version == nil {
                return .notReady(
                    "This panel has not reported its firmware version yet, so "
                        + "there is nothing to compare a bundle against.")
            }
            if otaReason == nil {
                return .notReady(
                    "This panel's live network address has not been resolved yet, "
                        + "and no connected USB device is positively matched to it.")
            }
            return .notReady(
                operationUnavailableReason(
                    serviceName, operation: .firmwareUpdate)
                    ?? otaReason
                    ?? "Connect this display over USB or let it rejoin WiFi.")
        }

        return .ready(FirmwareUpdateTarget(
            serviceName: serviceName,
            displayName: panel.displayName,
            hardwareID: hardwareID,
            address: address,
            chip: panel.chip ?? usbDevice?.chip,
            target: panel.target ?? usbDevice?.target,
            profile: panel.profile ?? usbDevice?.board,
            partition: panel.partition ?? usbDevice?.partition,
            firmwareVersion: version,
            usbDevice: usbDevice,
            usbPathGeneration: usbGeneration,
            usbAllowsLegacyIdentity: false))
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
        GeneratedBoardCatalog.profilesByTarget[target]?.contains(board) == true
    }

    enum USBPartitionCompatibility: Equatable, Sendable {
        case exact
        case fullFlashMigration(from: String, to: String)
    }

    enum USBCompatibilityIdentityIssue: Equatable, Sendable {
        case missingChip(expected: String)
        case chipMismatch(reported: String, expected: String)
        case missingProfile(accepted: [String])
        case profileMismatch(reported: String, accepted: [String])
        case missingPartition
        case bundlePartitionMissing

        var message: String {
            switch self {
            case .missingChip(let expected):
                return "CFGSHOW did not report a chip; this bundle requires \(expected)."
            case .chipMismatch(let reported, let expected):
                return "CFGSHOW reported chip \(reported), but this bundle requires \(expected)."
            case .missingProfile(let accepted):
                return "CFGSHOW did not report a board profile; this bundle accepts "
                    + "\(accepted.joined(separator: ", "))."
            case .profileMismatch(let reported, let accepted):
                return "CFGSHOW reported board profile \(reported), but this bundle accepts "
                    + "\(accepted.joined(separator: ", "))."
            case .missingPartition:
                return "CFGSHOW did not report the board's partition layout."
            case .bundlePartitionMissing:
                return "The selected current-family image does not declare its required "
                    + "partition layout."
            }
        }
    }

    nonisolated static func usbCompatibilityIdentityIssue(
        reportedChip: String?,
        reportedProfile: String?,
        reportedPartition: String?,
        expectedChip: String,
        acceptedProfiles: [String],
        requiredPartition: String?
    ) -> USBCompatibilityIdentityIssue? {
        guard !acceptedProfiles.isEmpty else { return nil }
        guard let reportedChip else {
            return .missingChip(expected: expectedChip)
        }
        guard reportedChip == expectedChip else {
            return .chipMismatch(reported: reportedChip, expected: expectedChip)
        }
        guard let reportedProfile else {
            return .missingProfile(accepted: acceptedProfiles)
        }
        guard acceptedProfiles.contains(reportedProfile) else {
            return .profileMismatch(
                reported: reportedProfile, accepted: acceptedProfiles)
        }
        guard reportedPartition != nil else { return .missingPartition }
        guard requiredPartition != nil else { return .bundlePartitionMissing }
        return nil
    }

    /// A full USB write replaces the partition table and application together,
    /// so a layout mismatch is a migration after family, chip, and profile have
    /// already been verified by the caller.
    nonisolated static func usbPartitionCompatibility(
        reported: String, required: String
    ) -> USBPartitionCompatibility {
        if reported == required { return .exact }
        return .fullFlashMigration(from: reported, to: required)
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
        if let exactTarget = cfgTarget ?? target.target,
           let selectedImage = bundle.image(forTarget: exactTarget),
           let firstIssue = Self.usbCompatibilityIdentityIssue(
               reportedChip: cfgChip,
               reportedProfile: cfgBoard,
               reportedPartition: cfgPartition,
               expectedChip: selectedImage.chip,
               acceptedProfiles: selectedImage.profiles,
               requiredPartition: selectedImage.partition
           ) {
            print(
                "USB firmware compatibility probe incomplete: "
                    + "\(firstIssue.message) Retrying CFGSHOW.")
            switch await probeUSBDevice(path, timeout: 3) {
            case .unavailable(let reason):
                print("USB firmware compatibility retry failed: \(reason)")
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
                if let liveTarget = target.target,
                   let reportedTarget = identity.target,
                   liveTarget != reportedTarget {
                    return .failure(
                        "USB target mismatch",
                        "The live panel reports target \(liveTarget), but CFGSHOW now "
                            + "reports \(reportedTarget). Nothing was written.")
                }
                cfgTarget = identity.target
                cfgBoard = identity.board
                cfgChip = identity.chip
                cfgPartition = identity.partition
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
        var partitionCompatibility = USBPartitionCompatibility.exact
        if !selectedImage.profiles.isEmpty {
            if let issue = Self.usbCompatibilityIdentityIssue(
                reportedChip: cfgChip,
                reportedProfile: cfgBoard,
                reportedPartition: cfgPartition,
                expectedChip: detectedChip,
                acceptedProfiles: selectedImage.profiles,
                requiredPartition: selectedImage.partition
            ) {
                return .failure(
                    "USB compatibility identity mismatch",
                    issue.message + " Nothing was written.")
            }
            guard let cfgPartition,
                  let requiredPartition = selectedImage.partition
            else {
                return .failure(
                    "USB compatibility identity mismatch",
                    "The partition identity could not be retained after validation. "
                        + "Nothing was written.")
            }
            partitionCompatibility = Self.usbPartitionCompatibility(
                reported: cfgPartition, required: requiredPartition)
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
        if case .fullFlashMigration(let oldLayout, let newLayout) =
            partitionCompatibility {
            return .success(
                "Firmware written over USB",
                "\(bundle.firmwareVersion) was written to \(target.displayName). "
                    + "The board had the old \(oldLayout) layout, which needed a "
                    + "full USB write; this installed \(newLayout) and its new "
                    + "partition table without erasing saved settings.")
        }
        return .success(
            "Firmware written over USB",
            "\(bundle.firmwareVersion) was written to \(target.displayName) "
                + "without erasing the chip, and the display is restarting. Its "
                + "saved WiFi, name, display settings and OTA password remain.")
    }

}
