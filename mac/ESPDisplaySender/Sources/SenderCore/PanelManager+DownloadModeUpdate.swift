import Foundation
import SenderProtocol

/// A USB firmware update for a board whose firmware cannot say who it is: it
/// does not recognise its board, it is silent, or the board is sitting in
/// flashing mode. Such a board is still on USB and must never be left
/// unflashable.
///
/// Its identity comes from two places instead of CFGSHOW. What esptool reads in
/// download mode - chip, MAC, flash size, packaged PSRAM - is the proof that
/// this port is this record's board and which images can run on it. What the
/// app already knows about the record - the family, chip and board it reported
/// before, and the USB serial it answered behind - narrows that to one image.
/// When neither names the family, the update sheet asks the person to choose
/// it (`FirmwareFamilyChoice`), and for a family whose image drives carrier
/// pins (P4) to choose the board, the same rule the CLI applies.
extension PanelManager {

    // MARK: finding the board

    /// The connected USB device that is this record's board even though its
    /// firmware has not identified itself, or nil. In order of strength:
    /// a port that reported this record's hardware ID, one behind a USB serial
    /// this record's board answered behind before, and one whose USB serial is
    /// the record's MAC (a native USB port reports it). Each must be unique:
    /// two ports reporting the ID is not a write target, and two behind one
    /// learned serial falls to the MAC. esptool's MAC is checked against
    /// the record before anything is written, so a wrong guess here writes
    /// nothing.
    func usbDownloadModeDevice(
        for serviceName: String
    ) -> WifiConfigUI.USBDeviceOption? {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }),
              let expectedID = stableHardwareID(of: panel)
        else { return nil }
        let connected = usbDevices.filter { $0.isConnected && !$0.path.isEmpty }
        func unique(
            _ matches: (WifiConfigUI.USBDeviceOption) -> Bool
        ) -> WifiConfigUI.USBDeviceOption?? {
            let found = connected.filter(matches)
            if found.count == 1 { return .some(found[0]) }
            return found.isEmpty ? nil : .some(nil)
        }
        // A port that answered with another board's ID is never this one.
        let answeredAsOther: (WifiConfigUI.USBDeviceOption) -> Bool = {
            guard let reported = ConfigCommands.canonicalHardwareID($0.hardwareID)
            else { return false }
            return reported != expectedID
        }
        if let byID = unique({
            ConfigCommands.canonicalHardwareID($0.hardwareID) == expectedID
        }) { return byID }
        // Bridge chips often share one serial: several ports claiming the
        // learned one is no answer, but not a refusal either.
        if !panel.usbSerialNumbers.isEmpty, let bySerial = unique({
            !answeredAsOther($0)
                && $0.usbSerial.map(panel.usbSerialNumbers.contains) == true
        }), let bySerial { return bySerial }
        if let byMAC = unique({
            !answeredAsOther($0)
                && ConfigCommands.canonicalHardwareID($0.usbSerial) == expectedID
        }) { return byMAC }
        return nil
    }

    // MARK: reading it in download mode

    /// What esptool read from the board in download mode.
    struct DownloadModeIdentity: Equatable, Sendable {
        var chip: String
        var mac: String
        /// nil when `flash-id` could not say; the write goes ahead without it.
        var flashBytes: Int?
        /// Packaged PSRAM from eFuse; nil when the chip names none.
        var psramBytes: Int?

        var summary: String {
            var parts = [chip, "MAC \(mac)"]
            parts.append(flashBytes.map { "\($0 / 0x100000) MB flash" }
                ?? "flash size not read")
            if let psramBytes { parts.append("\(psramBytes / 0x100000) MB PSRAM") }
            return parts.joined(separator: ", ")
        }
    }

    /// Read the chip, MAC and PSRAM with `chip-id`, then the flash size with
    /// `flash-id`, leaving the chip in flashing mode between them so the only
    /// reset after the first is the write's own. Every run must name
    /// `expectedID`: a different board answering is refused, not written.
    nonisolated static func readDownloadModeIdentity(
        port: String, expectedID: String, tool: EsptoolCommand.Tool,
        progress: @escaping @Sendable (UsbOnboarder.Progress) -> Void
    ) async -> Result<DownloadModeIdentity, WifiConfigUI.ConfigFailure> {
        func refused(_ title: String, _ message: String)
            -> Result<DownloadModeIdentity, WifiConfigUI.ConfigFailure> {
            .failure(WifiConfigUI.ConfigFailure(title: title, message: message))
        }
        progress(.log(.app, "Reading the board on \(port) in flashing mode, because "
            + "its firmware did not say what it is."))
        let chipRead: EsptoolRunner.Outcome
        do {
            // Left in flashing mode: every reset can drop a native USB port
            // for a moment, and the write that follows resets it anyway.
            let command = try EsptoolCommand.chipID(
                tool: tool, port: port, after: EsptoolCommand.noReset)
            chipRead = try await EsptoolRunner.run(command) { line in
                progress(.log(.esptool, line))
            }
        } catch {
            return refused("Could not read the USB board", error.localizedDescription)
        }
        guard let chip = EsptoolOutput.chipToken(in: chipRead.output) else {
            return refused(
                "Could not read the USB board",
                (EsptoolOutput.failureSummary(in: chipRead.output)
                    ?? "esptool did not name the chip.") + " Nothing was written.")
        }
        guard let mac = ConfigCommands.canonicalHardwareID(
            EsptoolOutput.macAddress(in: chipRead.output))
        else {
            return refused(
                "Could not read the USB board",
                "esptool read the chip on \(port) but not its MAC, so it cannot be "
                    + "tied to this board. Nothing was written.")
        }
        guard mac == expectedID else {
            return refused(
                "USB device mismatch",
                "esptool read MAC \(mac) on \(port), not this board's "
                    + "\(expectedID), so nothing was written.")
        }
        var identity = DownloadModeIdentity(
            chip: chip, mac: mac, flashBytes: nil,
            psramBytes: EsptoolOutput.embeddedPSRAMBytes(in: chipRead.output))
        if let command = try? EsptoolCommand.flashID(
               tool: tool, chip: chip, port: port,
               after: EsptoolCommand.noReset, before: EsptoolCommand.noReset),
           let flashRead = try? await EsptoolRunner.run(command, onLine: { line in
               progress(.log(.esptool, line))
           }) {
            let named = ConfigCommands.canonicalHardwareID(
                EsptoolOutput.macAddress(in: flashRead.output))
            if let named, named != expectedID {
                return refused(
                    "USB device mismatch",
                    "The flash size was read from MAC \(named) on \(port), not this "
                        + "board's \(expectedID), so nothing was written.")
            }
            if named == expectedID {
                identity.flashBytes = EsptoolOutput.detectedFlashBytes(in: flashRead.output)
            }
        }
        progress(.log(.app, "Read in flashing mode: \(identity.summary)."))
        return .success(identity)
    }

    // MARK: choosing the image

    /// What `downloadModeImage` needs to know about one image of a bundle.
    struct DownloadModeCandidate: Equatable, Sendable {
        var chip: String
        var targets: [String]
        /// Runtime profiles a current family image accepts; empty for a
        /// historical image built for one board.
        var profiles: [String]
        var flashSizes: [Int]
        /// The targets this image can be written whole over USB for.
        var writableTargets: [String]

        init(
            chip: String, targets: [String], profiles: [String], flashSizes: [Int],
            writableTargets: [String]
        ) {
            self.chip = chip
            self.targets = targets
            self.profiles = profiles
            self.flashSizes = flashSizes
            self.writableTargets = writableTargets
        }

        init(_ image: FirmwareBundle.Image, in bundle: FirmwareBundle) {
            self.init(
                chip: image.chip, targets: image.targets, profiles: image.profiles,
                flashSizes: image.flashSizes,
                writableTargets: image.targets.filter { bundle.flashPlan(forTarget: $0) != nil })
        }

        /// A historical image is built for exactly the boards its targets name.
        var isHistorical: Bool { profiles.isEmpty }

        /// Whether its image drives carrier pins, under any of its names.
        var drivesCarrierPins: Bool {
            targets.contains { target in
                GeneratedBoardCatalog.carrierEvidenceFamilies.contains {
                    $0 == target
                        || GeneratedBoardCatalog.universalFamilyAliases[$0]?.contains(target) == true
                }
            }
        }

        /// The boards it is known to run, for a named board to be checked against.
        func acceptedProfiles(for target: String) -> Set<String> {
            profiles.isEmpty
                ? GeneratedBoardCatalog.profilesByTarget[target] ?? []
                : Set(profiles)
        }
    }

    /// Which image of `bundle` a board read in download mode gets, or why none.
    nonisolated static func downloadModeImage(
        in bundle: FirmwareBundle, for identity: DownloadModeIdentity,
        family: String?, profile: String?
    ) -> Result<String, WifiConfigUI.ConfigFailure> {
        downloadModeImage(
            candidates: bundle.images.map { DownloadModeCandidate($0, in: bundle) },
            version: bundle.firmwareVersion, for: identity, family: family,
            profile: profile)
    }

    /// The same choice over plain facts, so every branch can be tested.
    ///
    /// `family` and `profile` are what the record reported before, or what the
    /// person chose in the sheet. The chip esptool read decides first: only
    /// images for it that can be written whole over USB, and that support the
    /// flash size read, are candidates.
    ///
    /// - A named family must match an image: its own target, or for a current
    ///   family image, any legacy name of that family. A named family that
    ///   matches none is refused, never swapped for another image.
    /// - With no family named, only a single current family image is taken.
    ///   A historical image is built for one board and is written only when
    ///   that board's target is named.
    /// - A named board the image does not run is refused, because it would boot
    ///   to the same blank screen; an image that drives carrier pins (P4) is
    ///   written only once the board is named.
    nonisolated static func downloadModeImage(
        candidates: [DownloadModeCandidate], version: String,
        for identity: DownloadModeIdentity, family: String?, profile: String?
    ) -> Result<String, WifiConfigUI.ConfigFailure> {
        func refused(_ title: String, _ message: String)
            -> Result<String, WifiConfigUI.ConfigFailure> {
            .failure(WifiConfigUI.ConfigFailure(
                title: title, message: message + " Nothing was written."))
        }
        let chipName = chipDisplayName(identity.chip)
        let writable = candidates.filter {
            $0.chip == identity.chip && !$0.writableTargets.isEmpty
        }
        guard !writable.isEmpty else {
            return refused(
                "No firmware here for this chip",
                "The board is an \(chipName), and this firmware has nothing for it "
                    + "that can be written over USB.")
        }
        let fits = writable.filter { image in
            guard let bytes = identity.flashBytes, !image.flashSizes.isEmpty
            else { return true }
            return image.flashSizes.contains(bytes)
        }
        guard !fits.isEmpty else {
            let size = identity.flashBytes.map { "\($0 / 0x100000) MB" } ?? "its"
            return refused(
                "This firmware does not fit this board",
                "The board has \(size) of flash, which no \(chipName) firmware here "
                    + "supports.")
        }

        let image: DownloadModeCandidate
        let exactTarget: String
        if let family {
            // Its own target first, then a current family image that answers
            // to this legacy name.
            if let exact = fits.first(where: { $0.writableTargets.contains(family) }) {
                image = exact
                exactTarget = family
            } else if let universal = fits.first(where: { candidate in
                !candidate.isHistorical && candidate.writableTargets.contains { target in
                    GeneratedBoardCatalog.universalFamilyAliases[target]?.contains(family)
                        == true
                }
            }), let target = universal.writableTargets.first(where: {
                GeneratedBoardCatalog.universalFamilyAliases[$0]?.contains(family) == true
            }) {
                image = universal
                exactTarget = target
            } else {
                return refused(
                    "This firmware has nothing for this board's family",
                    "The board takes the \(family) firmware, and this file has none. "
                        + "Choose firmware that includes it.")
            }
        } else {
            let current = fits.filter { !$0.isHistorical }
            guard current.count == 1, let target = current[0].writableTargets.first else {
                if current.isEmpty {
                    return refused(
                        "Choose the firmware family",
                        "This firmware is built for particular \(chipName) boards. "
                            + "Choose which one this board is.")
                }
                return refused(
                    "Choose the firmware family",
                    "This firmware has \(current.count) \(chipName) images. Choose "
                        + "which one this board takes.")
            }
            image = current[0]
            exactTarget = target
        }

        let accepted = image.acceptedProfiles(for: exactTarget)
        if let profile {
            if !accepted.isEmpty, !accepted.contains(profile) {
                let board = GeneratedBoardCatalog.boardNameByProfile[profile] ?? "this board"
                return refused(
                    "This firmware version does not support this board",
                    "\(version) does not support the \(board), so it would not start "
                        + "its screen. Choose a version that supports it.")
            }
        } else if image.drivesCarrierPins {
            return refused(
                "Choose which board this is",
                "This firmware drives pins that differ between \(chipName) boards, "
                    + "so it is only written once the board is named.")
        }
        return .success(exactTarget)
    }

    // MARK: when nothing names the family

    /// One thing the update sheet can offer when the record does not name the
    /// firmware family: a family, or for a family whose image drives carrier
    /// pins, one board of it.
    struct FirmwareFamilyChoice: Equatable, Hashable, Identifiable, Sendable {
        var family: String
        var profile: String?
        var chip: String
        var label: String
        var id: String { profile.map { "\(family)/\($0)" } ?? family }
    }

    /// The choices for a record, from the bundled catalog: every family, or
    /// only those for the chip or family the record knows, each P4 board on
    /// its own row.
    nonisolated static func firmwareFamilyChoices(
        catalog: FirmwareReleaseCatalog, chip: String?, family: String? = nil
    ) -> [FirmwareFamilyChoice] {
        let knownChip = usableChip(chip)
        var choices: [FirmwareFamilyChoice] = []
        for entry in catalog.families.values.sorted(by: { $0.family < $1.family })
        where (knownChip == nil || entry.chip == knownChip)
            && family.map({ isSameFamily($0, as: entry.family) }) ?? true {
            let chipName = chipDisplayName(entry.chip)
            if GeneratedBoardCatalog.carrierEvidenceFamilies.contains(entry.family) {
                for profile in entry.profiles {
                    let board = GeneratedBoardCatalog.boardNameByProfile[profile] ?? profile
                    choices.append(FirmwareFamilyChoice(
                        family: entry.family, profile: profile, chip: entry.chip,
                        label: board))
                }
            } else {
                choices.append(FirmwareFamilyChoice(
                    family: entry.family, profile: nil, chip: entry.chip,
                    label: "\(chipName) boards"))
            }
        }
        return choices
    }

    /// The choices for a record from a firmware file the person opened: one
    /// row per current family image, one per board a historical image was
    /// built for, and each board of an image that drives carrier pins.
    nonisolated static func firmwareFamilyChoices(
        candidates: [DownloadModeCandidate], chip: String?, family: String? = nil
    ) -> [FirmwareFamilyChoice] {
        let knownChip = usableChip(chip)
        var choices: [FirmwareFamilyChoice] = []
        for image in candidates
        where (knownChip == nil || image.chip == knownChip) && !image.writableTargets.isEmpty {
            let chipName = chipDisplayName(image.chip)
            for target in image.isHistorical ? image.writableTargets : [image.writableTargets[0]]
            where family.map({ isSameFamily($0, as: target) || image.targets.contains($0) }) ?? true {
                let boards = image.acceptedProfiles(for: target).sorted()
                if image.drivesCarrierPins || (image.isHistorical && boards.count == 1) {
                    for profile in boards {
                        choices.append(FirmwareFamilyChoice(
                            family: target, profile: profile, chip: image.chip,
                            label: GeneratedBoardCatalog.boardNameByProfile[profile] ?? profile))
                    }
                } else if image.isHistorical {
                    choices.append(FirmwareFamilyChoice(
                        family: target, profile: nil, chip: image.chip,
                        label: "\(chipName) (\(target))"))
                } else {
                    choices.append(FirmwareFamilyChoice(
                        family: target, profile: nil, chip: image.chip,
                        label: "\(chipName) boards"))
                }
            }
        }
        return choices
    }

    /// Whether a file the person opened leaves the image to them: what the
    /// record knows - its chip, family and board - does not settle it.
    nonisolated static func downloadModeNeedsChoice(
        candidates: [DownloadModeCandidate], chip: String?, family: String?,
        profile: String?
    ) -> Bool {
        let named = candidates.filter { candidate in
            family.map { family in
                candidate.targets.contains { $0 == family || isSameFamily(family, as: $0) }
            } ?? true
        }
        let chips = usableChip(chip).map { [$0] } ?? Array(Set(named.map(\.chip)))
        let titles: Set<String> = ["Choose the firmware family", "Choose which board this is"]
        // Settled only when every chip it could be resolves the same way.
        return chips.count != 1 || chips.contains { chip in
            let identity = DownloadModeIdentity(
                chip: chip, mac: "", flashBytes: nil, psramBytes: nil)
            if case .failure(let failure) = downloadModeImage(
                candidates: candidates, version: "", for: identity,
                family: family, profile: profile) {
                return titles.contains(failure.title)
            }
            return false
        }
    }

    /// `legacy` is `family` itself, or one of its legacy names.
    nonisolated static func isSameFamily(_ legacy: String, as family: String) -> Bool {
        legacy == family
            || GeneratedBoardCatalog.universalFamilyAliases[family]?.contains(legacy) == true
    }

    nonisolated static func usableChip(_ chip: String?) -> String? {
        chip.flatMap { $0.isEmpty || $0 == ServiceMetadata.unknownChip ? nil : $0 }
    }

    /// "ESP32-S3" for `esp32s3`.
    nonisolated static func chipDisplayName(_ chip: String) -> String {
        guard chip.hasPrefix("esp32") else { return chip }
        let suffix = chip.dropFirst("esp32".count)
        return suffix.isEmpty ? "ESP32" : "ESP32-" + suffix.uppercased()
    }
}
