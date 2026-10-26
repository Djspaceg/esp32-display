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
        /// Which build of `firmwareVersion` is running, when the board names
        /// one. Only ever used to say which bundled revision is already on it;
        /// the upgrade/reinstall/downgrade verb stays a version comparison, so
        /// every revision remains installable whatever this says.
        var firmwareSource: FirmwareSourceIdentity? = nil
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
        /// The USB device is this record's board, but its firmware has not
        /// identified it (`usbDownloadModeDevice`): the write reads the board
        /// in download mode instead, and esptool's MAC is the proof.
        var usbIdentityFromEsptool = false
        /// The family, and for a carrier family the board, the person chose
        /// in the sheet because the record names none.
        var chosenFamily: String? = nil
        var chosenProfile: String? = nil
        /// The chip that family runs on, which esptool must then read.
        var chosenChip: String? = nil

        /// What the record says, or else what was chosen.
        var familyForUpdate: String? { target ?? chosenFamily }
        var profileForUpdate: String? { profile ?? chosenProfile }

        init(
            serviceName: String, displayName: String, hardwareID: String,
            address: String?, chip: String?, target: String? = nil,
            profile: String? = nil, partition: String? = nil,
            firmwareVersion: String?,
            firmwareSource: FirmwareSourceIdentity? = nil,
            usbDevice: WifiConfigUI.USBDeviceOption? = nil,
            usbPathGeneration: Int? = nil,
            usbAllowsLegacyIdentity: Bool = false,
            usbIdentityFromEsptool: Bool = false
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
            self.firmwareSource = firmwareSource
            self.usbDevice = usbDevice
            self.usbPathGeneration = usbPathGeneration
            self.usbAllowsLegacyIdentity = usbAllowsLegacyIdentity
            self.usbIdentityFromEsptool = usbIdentityFromEsptool
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
    /// resolved address. USB uses one connected device on its own terms: it must
    /// name its family, chip, profile, partition and hardware ID itself, and a
    /// record with no identity of its own borrows the device's, because that
    /// reported identity is exactly what esptool is checked against before a
    /// write. A remembered IP or serial path is never enough. A board whose
    /// firmware does not identify it at all is still offered over USB, matched
    /// by `usbDownloadModeDevice` and proven by esptool's MAC at write time.
    func firmwareUpdateReadiness(_ serviceName: String) -> FirmwareUpdateReadiness {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }) else {
            return .notReady("This device is not known yet.")
        }
        let usbCandidate = usbUpdateDevice(for: serviceName)
        let identifiedDevice = usbCandidate.flatMap {
            Self.usbDeviceIdentifiesItselfForFlashing($0) ? $0 : nil
        }
        // A board on USB is never left without an update: when its firmware
        // does not identify it, the write reads it in download mode instead.
        let downloadModeDevice = identifiedDevice == nil
            ? usbDownloadModeDevice(for: serviceName) : nil
        let usbDevice = identifiedDevice ?? downloadModeDevice
        guard let hardwareID = stableHardwareID(of: panel)
                ?? identifiedDevice?.hardwareID
        else {
            return .notReady(
                "This device has not reported its hardware ID yet, so an update "
                    + "cannot be tied to the right board over USB.")
        }
        let version =
            panel.firmwareVersion ?? usbCandidate?.serialStatus?.firmwareVersion

        let otaReason = controlUnavailableReason(serviceName, capability: .ota)
        // Without a running version the sheet cannot honestly classify an OTA
        // update. A self-identified USB device can still install any selected
        // version because the board identity, target, chip and partition are
        // rechecked before esptool writes anything.
        let address =
            version != nil && otaReason == nil
            ? sessions[serviceName]?.resolvedAddress : nil
        let usbGeneration = usbDevice.map { usbPathGeneration($0.path) }

        guard address != nil || usbDevice != nil else {
            if usbCandidate != nil {
                return .notReady(
                    "USB is connected, but the app cannot verify the board family, "
                        + "chip, profile, and partition safely.")
            }
            if version == nil {
                return .notReady(
                    "This device has not reported its firmware version yet, so "
                        + "there is nothing to compare a bundle against.")
            }
            if otaReason == nil {
                return .notReady(
                    "This board's live network address has not been resolved yet, "
                        + "and no connected USB device is positively matched to it.")
            }
            return .notReady(
                operationUnavailableReason(
                    serviceName, operation: .firmwareUpdate)
                    ?? otaReason
                    ?? "Connect this device over USB or let it rejoin WiFi.")
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
            firmwareSource: panel.firmwareVersion != nil
                ? panel.currentFirmwareSource
                : usbCandidate?.serialStatus?.firmwareSource,
            usbDevice: usbDevice,
            usbPathGeneration: usbGeneration,
            usbAllowsLegacyIdentity: false,
            usbIdentityFromEsptool: identifiedDevice == nil && downloadModeDevice != nil))
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
                "This device no longer has a live resolved address. Choose USB, "
                    + "or wait for it to reconnect and try again.")
        }
        if let panel = panels.first(where: { $0.serviceName == target.serviceName }),
           panel.capabilities.contains(.streamUpdate),
           let session = sessions[target.serviceName] {
            return await pushFirmwareOverStream(
                image: image, filename: filename, to: target, address: address,
                password: password, session: session, progress: progress)
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

    /// The stream-channel push, for a panel advertising `streamUpdate`: the
    /// image goes over this session's own link, so nothing has to connect back
    /// to this Mac. Frames to this panel stop for the transfer and resume after
    /// it; every other panel keeps streaming.
    private func pushFirmwareOverStream(
        image: Data, filename: String, to target: FirmwareUpdateTarget,
        address: String, password: String, session: DeviceSession,
        progress: @escaping @Sendable (FirmwarePusher.Progress) -> Void
    ) async -> OperationOutcome {
        session.setFirmwareUpdateHold(true)
        defer { session.setFirmwareUpdateHold(false) }
        let pusher = StreamFirmwarePusher(link: session.firmwareUpdateLink)
        do {
            let measured = try await pusher.push(
                image: image, filename: filename, to: address,
                password: password, progress: progress)
            return .success(
                "Update sent",
                "\(target.displayName) checked the image's SHA-256, activated it and "
                    + "is restarting onto it. Sent \(measured.summary). Streaming "
                    + "reconnects by itself; the version in the Firmware section "
                    + "updates when it reports in.")
        } catch {
            return .failure("Update failed", error.localizedDescription)
        }
    }

    /// The failure to report when the board that answered after a USB write is
    /// not running what was written, or nil when it is (or cannot be told).
    ///
    /// The version is compared first, as it always was. The build is compared
    /// only when both sides name a clean one, which is what makes reinstalling
    /// the same version provable: before builds were reported, a board that
    /// rebooted into its old 1.5.0 after "reinstalling" 1.5.0 looked like success.
    /// Firmware that does not report a build, and bundles that did not record
    /// one, keep the version-only check.
    nonisolated static func restartedIntoOtherFirmware(
        bundle: FirmwareBundle, board: UsbOnboarder.SettledBoard
    ) -> OperationOutcome? {
        if let running = board.firmwareVersion,
           FirmwareVersion.compare(running, to: bundle.firmwareVersion) != .same {
            var outcome = OperationOutcome.failure(
                "The board restarted into the old firmware",
                "\(bundle.firmwareVersion) was written, but after restarting the board "
                    + "reports \(running) on \(board.port).")
            outcome.nextAction = "Run the USB update again. If it comes back on "
                + "\(running) a second time, copy the transcript from Details and "
                + "report it."
            return outcome
        }
        // A clean bundle is written; anything else answering - another commit,
        // or any build with uncommitted changes - is not what was written.
        guard let written = FirmwareSourceIdentity(bundle: bundle), !written.dirty
        else { return nil }
        guard let running = board.firmwareSource else {
            // Silence proves something only when the image written would have
            // named itself: one that carries its commit reports it as src=.
            // Then a board answering without src= is still on older firmware.
            let commit = Data(written.commit.utf8)
            let writtenNamesItself = bundle.images.contains { image in
                image.targets.contains {
                    bundle.payload(forTarget: $0)?.range(of: commit) != nil
                }
            }
            guard writtenNamesItself else { return nil }
            var outcome = OperationOutcome.failure(
                "The board restarted into the old firmware",
                "Build \(written.shortCommit) of \(bundle.firmwareVersion) was "
                    + "written, but after restarting the board on \(board.port) "
                    + "does not report a build, which only older firmware does.")
            outcome.nextAction = "Run the USB update again. If it comes back the same "
                + "way a second time, copy the transcript from Details and report it."
            return outcome
        }
        guard running.dirty || running.commit != written.commit else { return nil }
        var outcome = OperationOutcome.failure(
            "The board restarted into a different build",
            "Build \(written.shortCommit) of \(bundle.firmwareVersion) was written, "
                + "but after restarting the board reports build "
                + "\(running.summary) on \(board.port).")
        outcome.nextAction = "Run the USB update again. If it comes back on build "
            + "\(running.shortCommit) a second time, copy the transcript from "
            + "Details and report it."
        return outcome
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
        /// The board was read in download mode and its firmware never said
        /// which layout it boots with; the whole layout is written anyway.
        case layoutNotRead
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
                return "The board did not report its chip; this bundle requires \(expected)."
            case .chipMismatch(let reported, let expected):
                return "The board reported chip \(reported), but this bundle requires \(expected)."
            case .missingProfile(let accepted):
                return "The board did not report its board profile; this bundle accepts "
                    + "\(accepted.joined(separator: ", "))."
            case .profileMismatch(let reported, let accepted):
                return "The board reported board profile \(reported), but this bundle accepts "
                    + "\(accepted.joined(separator: ", "))."
            case .missingPartition:
                return "The board did not report its partition layout."
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
                "No connected USB device was positively matched to this board.")
        }
        let path = device.path
        let expectedID = ConfigCommands.canonicalHardwareID(target.hardwareID)
        guard let expectedID else {
            return .failure(
                "USB identity unavailable",
                "This device's hardware ID is not a six-byte MAC address, so the "
                    + "app cannot prove which connected board is safe to write.")
        }
        beginUSBFlash(hardwareID: expectedID)
        var wroteFlash = false
        defer { finishUSBFlash(hardwareID: expectedID, wroteFlash: wroteFlash) }
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
                || (currentID == nil
                    && (target.usbAllowsLegacyIdentity || target.usbIdentityFromEsptool))
        else {
            return .failure(
                "USB device mismatch",
                "The connected USB device reports a different hardware ID, so "
                    + "nothing was written.")
        }

        progress(.phase(.findingBoard))
        var cfgTarget: String?
        var cfgBoard: String?
        var cfgChip: String?
        var cfgPartition: String?
        switch await probeUSBDevice(path, timeout: 3) {
        case .unavailable(let reason):
            // Not a dead end: a board whose firmware does not answer - one it
            // does not recognise, a silent one, one in flashing mode - is read
            // in download mode, and esptool's MAC is the proof. A port that
            // changed meanwhile is not read at all: esptool would reset
            // whatever is on it now.
            guard usbPathGeneration(path) == expectedGeneration else {
                return .failure(
                    "USB device changed",
                    "The serial device changed while it was being checked, so "
                        + "nothing was written.")
            }
            progress(.log(.app, "The board's firmware did not identify it ("
                + (UsbBoardCheck.plainReason(reason) ?? "no usable answer")
                + "), so it is read in flashing mode instead."))
            return await flashInDownloadMode(
                bundle: bundle, target: target, path: path, expectedID: expectedID,
                expectedGeneration: expectedGeneration, wroteFlash: &wroteFlash,
                progress: progress)
        case .identified(let identity)
            where target.usbIdentityFromEsptool
                && !Self.identityIsCompleteForFlashing(identity, expectedID: expectedID):
            // What it did say still counts: another board's ID or another
            // family is refused, and its own family and board name the image.
            if let reportedID = ConfigCommands.canonicalHardwareID(identity.hardwareID),
               reportedID != expectedID {
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
                    "This board reported target \(liveTarget) before, but over USB it "
                        + "now reports \(reportedTarget). Nothing was written.")
            }
            var evidence = target
            if target.target == nil, let reported = identity.target, !reported.isEmpty {
                evidence.chosenFamily = reported
            }
            if target.profile == nil, let reported = identity.board, !reported.isEmpty {
                evidence.chosenProfile = reported
            }
            progress(.log(.app, "The board's firmware answered without saying all of "
                + "what it is, so it is read in flashing mode instead."))
            return await flashInDownloadMode(
                bundle: bundle, target: evidence, path: path, expectedID: expectedID,
                expectedGeneration: expectedGeneration, wroteFlash: &wroteFlash,
                progress: progress)
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
                    "Over the network, the device reports target \(liveTarget), but "
                        + "over USB it now reports \(reportedTarget). Nothing was written.")
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
                    + "\(firstIssue.message) Asking the board again.")
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
                        "Over the network, the device reports target \(liveTarget), but "
                            + "over USB it now reports \(reportedTarget). Nothing was written.")
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

        let detection = await UsbOnboarder.detectChip(
            port: path, tool: tool, onProgress: progress)
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
                "The board reports physical board \(physicalBoard) with target "
                    + "\(reportedTarget), which is not a supported composition. "
                    + "Nothing was written.")
        }
        if let expectedChip = target.chip,
           !expectedChip.isEmpty,
           expectedChip != ServiceMetadata.unknownChip,
           expectedChip != detectedChip {
            return .failure(
                "USB chip mismatch",
                "The device reported \(expectedChip), but esptool read "
                    + "\(detectedChip). Nothing was written.")
        }
        let exactTarget = cfgTarget ?? target.target
        guard let exactTarget else {
            return .failure(
                "Firmware family unavailable",
                "The board did not report a firmware family, so nothing was written.")
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

        wroteFlash = true
        return await writeOverUSB(
            bundle: bundle, writes: writes, chip: detectedChip, path: path, tool: tool,
            expectedID: expectedID, target: target, layout: partitionCompatibility,
            progress: progress)
    }


    /// Write, wait for the board, and prove it booted what was written. The
    /// caller has verified the board and set its own `wroteFlash`.
    private func writeOverUSB(
        bundle: FirmwareBundle, writes: [FirmwareBundle.FlashWrite], chip detectedChip: String,
        path: String, tool: EsptoolCommand.Tool, expectedID: String,
        target: FirmwareUpdateTarget, layout partitionCompatibility: USBPartitionCompatibility,
        progress: @escaping @Sendable (UsbOnboarder.Progress) -> Void
    ) async -> OperationOutcome {
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
        // Written is not the same as running. The board is waited for exactly as
        // onboarding waits for it, and the version it then reports is the proof
        // that the new image is the one that booted.
        let answered: UsbOnboarder.SettledBoard
        switch await UsbOnboarder.settle(
            flashedPort: path, expectedHardwareID: expectedID, onProgress: progress)
        {
        case .success(let board):
            answered = board
        case .failure(let failure)
            where failure.title == "Stopped" || failure.boardNotRecognised:
            return .failure(failure)
        case .failure:
            return .failure(
                "Written, but the board did not answer",
                "\(bundle.firmwareVersion) was written to \(target.displayName), "
                    + "but the board did not answer over USB with its hardware ID "
                    + "within \(Int(SerialSettlePolicy.budgetSeconds)) seconds of "
                    + "restarting.")
        }
        refreshUSBPorts()
        if let outcome = Self.restartedIntoOtherFirmware(
            bundle: bundle, board: answered) {
            return outcome
        }
        if case .fullFlashMigration(let oldLayout, let newLayout) =
            partitionCompatibility {
            return .success(
                "Firmware written over USB",
                "\(bundle.firmwareVersion) was written to \(target.displayName). "
                    + "The board had the old \(oldLayout) layout, which needed a "
                    + "full USB write; this installed \(newLayout) and its new "
                    + "partition table without erasing saved settings. It answered "
                    + "on \(answered.port) after restarting.")
        }
        if partitionCompatibility == .layoutNotRead {
            return .success(
                "Firmware written over USB",
                "\(bundle.firmwareVersion) was written to \(target.displayName) "
                    + "in flashing mode, with its partition table, and the board "
                    + "answered on \(answered.port) after restarting. Nothing was "
                    + "erased; if its storage layout changed, it may need its WiFi "
                    + "set again.")
        }
        return .success(
            "Firmware written over USB",
            "\(bundle.firmwareVersion) was written to \(target.displayName) "
                + "without erasing the chip, and the board answered on "
                + "\(answered.port) after restarting. Its saved WiFi, name, screen "
                + "settings and OTA password remain.")
    }

    /// Whether a CFGSHOW answer says enough to take the normal USB path.
    nonisolated static func identityIsCompleteForFlashing(
        _ identity: WifiConfigUI.USBIdentity, expectedID: String
    ) -> Bool {
        ConfigCommands.canonicalHardwareID(identity.hardwareID) == expectedID
            && identity.target?.isEmpty == false
            && identity.board?.isEmpty == false
            && identity.chip?.isEmpty == false
            && identity.partition?.isEmpty == false
    }

    /// The USB update for a board whose firmware did not identify it: read in
    /// download mode, matched to an image by chip, flash size and what the
    /// record knows or the person chose, then written whole.
    private func flashInDownloadMode(
        bundle: FirmwareBundle, target: FirmwareUpdateTarget, path: String,
        expectedID: String, expectedGeneration: Int, wroteFlash: inout Bool,
        progress: @escaping @Sendable (UsbOnboarder.Progress) -> Void
    ) async -> OperationOutcome {
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
        let identity: DownloadModeIdentity
        switch await Self.readDownloadModeIdentity(
            port: path, expectedID: expectedID, tool: tool, progress: progress)
        {
        case .success(let read): identity = read
        case .failure(let failure): return .failure(failure)
        }
        if let expectedChip = target.chip, !expectedChip.isEmpty,
           expectedChip != ServiceMetadata.unknownChip, expectedChip != identity.chip {
            return .failure(
                "USB chip mismatch",
                "This board reported \(expectedChip) before, but esptool read "
                    + "\(identity.chip). Nothing was written.")
        }
        let exactTarget: String
        switch Self.downloadModeImage(
            in: bundle, for: identity, family: target.familyForUpdate,
            profile: target.profileForUpdate)
        {
        case .success(let chosen): exactTarget = chosen
        case .failure(let failure): return .failure(failure)
        }
        guard usbPathGeneration(path) == expectedGeneration,
              usbDevices.contains(where: { $0.path == path && $0.isConnected })
        else {
            return .failure(
                "USB device changed",
                "The serial device changed while the board was being read, so "
                    + "nothing was written.")
        }
        guard let writes = bundle.flashPlan(forTarget: exactTarget) else {
            return .failure(
                "Bundle is OTA-only",
                "The \(exactTarget) image does not include the bootloader, partition "
                    + "table and boot_app0 required for a safe USB write. Nothing was "
                    + "written.")
        }
        let required = bundle.image(forTarget: exactTarget)?.partition
        let layout: USBPartitionCompatibility
        if let reported = target.partition, let required {
            layout = Self.usbPartitionCompatibility(reported: reported, required: required)
        } else {
            layout = .layoutNotRead
        }
        progress(.log(.app, "Writing the \(exactTarget) image of "
            + "\(bundle.firmwareVersion) to \(identity.summary)."))
        wroteFlash = true
        return await writeOverUSB(
            bundle: bundle, writes: writes, chip: identity.chip, path: path, tool: tool,
            expectedID: expectedID, target: target, layout: layout, progress: progress)
    }
}
