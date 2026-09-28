import Foundation
import SenderProtocol

extension PanelManager {

    // MARK: repairing a board that drops off USB

    /// The rescue image the app carries for a family, embedded by
    /// embed-firmware-bundle.sh from firmware-rescue/<family>/.
    nonisolated static func rescueImageDirectory(
        for family: UsbRescue.Family, in bundle: Bundle = .main
    ) -> URL? {
        bundle.resourceURL?.appendingPathComponent("rescue/\(family.key)", isDirectory: true)
    }

    func holdUSBProbes() {
        usbProbeHolds += 1
    }

    func releaseUSBProbes() {
        usbProbeHolds = max(0, usbProbeHolds - 1)
        guard usbProbeHolds == 0 else { return }
        refreshUSBPorts()
        identifyUSBPorts(usbSerialPorts)
    }

    /// Catch a board in its brief USB window and write the family's rescue
    /// image, then ask the rescue image what board it found.
    ///
    /// Background CFGSHOW probes are held for the whole run, so nothing but the
    /// waiting esptool opens the board.
    func rescueUSBBoard(
        family: UsbRescue.Family,
        carrier: String? = nil,
        progress: @escaping @Sendable (UsbFlashEvent) -> Void
    ) async -> Result<UsbRescuer.RescuedBoard, WifiConfigUI.ConfigFailure> {
        // The CLI's carrier guard: a family whose image drives carrier pins
        // (P4) gets nothing written until one of its carriers is named.
        if GeneratedBoardCatalog.carrierEvidenceFamilies.contains(family.key),
           !(GeneratedBoardCatalog.expected[family.key]?.profiles ?? [])
               .contains(carrier ?? "") {
            return .failure(WifiConfigUI.ConfigFailure(
                title: "Choose the board first",
                message: "\(family.displayName) images drive the display pins of "
                    + "whatever board they land on, so name which board this is "
                    + "before anything is written."))
        }
        let regions: [UsbRescue.Region]
        do {
            guard let directory = Self.rescueImageDirectory(for: family) else {
                throw UsbRescue.ImageError.missing(family: family.key, reason: "no resources")
            }
            regions = try UsbRescue.loadImage(family: family, directory: directory)
        } catch {
            return .failure(WifiConfigUI.ConfigFailure(
                title: "No rescue firmware", message: error.localizedDescription))
        }
        guard case .installed(let toolPath) = EsptoolInstallation.locate() else {
            return .failure(WifiConfigUI.ConfigFailure(
                title: "The esp32 core is not installed",
                message: "Repair uses the esptool included with the Arduino esp32 core."))
        }
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("espdisp-rescue-\(family.key)-" + UUID().uuidString)
        progress(.log(.app, "Rescue image for \(family.displayName): " + regions.map {
            "\($0.role)@\(EsptoolCommand.hexAddress($0.address))"
        }.joined(separator: ", ")))

        holdUSBProbes()
        defer { releaseUSBProbes() }
        // Off the main actor: the loop polls every 10 ms and stopping esptool
        // waits for its process group to go.
        let run = Task.detached { () -> Result<UsbRescuer.RescuedBoard, WifiConfigUI.ConfigFailure> in
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                try FileManager.default.createDirectory(
                    at: work, withIntermediateDirectories: true)
                let spawn = try UsbRescuer.spawner(
                    family: family, regions: regions, work: work,
                    tool: EsptoolCommand.Tool(path: toolPath))
                let io = UsbRescuer.IO(
                    ports: { WifiConfigUI.candidatePorts() },
                    identify: { UsbRescuer.usbDevices() },
                    identifyPort: { UsbRescuer.usbDevice(forPort: $0) },
                    spawn: spawn,
                    now: { ProcessInfo.processInfo.systemUptime },
                    sleep: { try? await Task.sleep(for: .seconds($0)) },
                    isCancelled: { Task.isCancelled })
                let port = try await UsbRescuer.run(
                    family: family, regions: regions, io: io, onProgress: progress)
                progress(.log(.app, "Done. The board is running the rescue image on \(port)."))
                guard var board = await UsbRescuer.readRescuedBoard(
                    port: port, family: family, onProgress: progress)
                else {
                    return .failure(WifiConfigUI.ConfigFailure(
                        title: "The rescue image did not answer",
                        message: "The rescue firmware was written to the board on \(port), "
                            + "but it did not say which board it is on."))
                }
                board.carrier = carrier
                progress(.phase(.rescue(.rescued(port: board.port))))
                return .success(board)
            } catch let failure as WifiConfigUI.ConfigFailure {
                return .failure(failure)
            } catch {
                return .failure(WifiConfigUI.ConfigFailure(
                    title: "Repair failed", message: error.localizedDescription))
            }
        }
        return await withTaskCancellationHandler {
            await run.value
        } onCancel: {
            run.cancel()
        }
    }

    /// Send `CFGBOARD auto` to the rescue image, which removes only the stored
    /// board override, and read the board again.
    func clearRescueOverride(
        on board: UsbRescuer.RescuedBoard,
        progress: @escaping @Sendable (UsbFlashEvent) -> Void
    ) async -> Result<UsbRescuer.RescuedBoard, WifiConfigUI.ConfigFailure> {
        holdUSBProbes()
        defer { releaseUSBProbes() }
        let port = board.port
        let run = Task.detached { () -> Result<UsbRescuer.RescuedBoard, WifiConfigUI.ConfigFailure> in
            let log: WifiConfigUI.SerialLog = { source, text in progress(.log(source, text)) }
            if case .failure(let reason) = WifiConfigUI.sendCommand(
                UsbRescue.clearOverrideCommand, port: port, timeout: 3, log: log,
                acceptInfo: false) {
                return .failure(WifiConfigUI.ConfigFailure(
                    title: "Could not clear the stored board override", message: reason))
            }
            // The send itself cannot be interrupted; a Stop during it is
            // honoured here, and says what already happened.
            if Task.isCancelled {
                return .failure(WifiConfigUI.ConfigFailure(
                    title: "Stopped",
                    message: "The stored board override was cleared; the board was "
                        + "not read again."))
            }
            guard var reread = await UsbRescuer.readRescuedBoard(
                port: port, family: board.family, onProgress: progress)
            else {
                return .failure(WifiConfigUI.ConfigFailure(
                    title: "The rescue image did not answer",
                    message: "The override was cleared, but the board did not answer again."))
            }
            reread.carrier = board.carrier
            progress(.phase(.rescue(.rescued(port: reread.port))))
            return .success(reread)
        }
        return await withTaskCancellationHandler {
            await run.value
        } onCancel: {
            run.cancel()
        }
    }

    /// Why a rescued board gets no install offer.
    enum RepairInstallError: Error, LocalizedError, Equatable {
        case boardNotIdentified(family: String, profile: String?, target: String?)
        case carrierMismatch(chosen: String?, reported: String)

        var errorDescription: String? {
            switch self {
            case .boardNotIdentified(let family, let profile, let target):
                return "The rescue image could not identify this board (it reported "
                    + "profile \(profile ?? "none") and target \(target ?? "none")), so "
                    + "no firmware is installed. \(family) was chosen, but the chip "
                    + "family alone does not say which display this is."
            case .carrierMismatch(let chosen, let reported):
                guard let chosen else {
                    return "No board was named for this chip family, so no firmware is "
                        + "installed. The rescue image reports \(reported)."
                }
                return "You named \(chosen), but the rescue image reports \(reported), "
                    + "so no firmware is installed. Check which board this is, then "
                    + "repair it again naming that board."
            }
        }
    }

    /// Which bundled image a rescued board takes, from what the rescue image
    /// reported: the same resolver a USB update uses, so a board whose family,
    /// chip and profile are all known gets exactly its family's image.
    ///
    /// A board the rescue image's detector did not identify reports
    /// `profile=auto target=unknown` (variantToken and targetToken of an
    /// unknown variant). That is refused rather than guessed from the family
    /// the user chose: nothing then says which display the board drives, and
    /// the real firmware's own detection is what failed on it before.
    nonisolated static func repairInstallSelection(
        for board: UsbRescuer.RescuedBoard, releases: BundledFirmware.ReleaseSet
    ) throws -> BundledFirmware.UpdateResolution {
        func known(_ value: String?) -> String? {
            guard let value, !value.isEmpty, value != ServiceMetadata.unknownChip,
                  value != "auto"
            else { return nil }
            return value
        }
        let identity = board.identity
        guard let profile = known(identity.board), let target = known(identity.target) else {
            throw RepairInstallError.boardNotIdentified(
                family: board.family.displayName, profile: identity.board,
                target: identity.target)
        }
        // The CLI's carrier guard: a family whose image drives carrier pins
        // installs only onto the carrier the user named, and only when the
        // rescue image's own detection agrees.
        if GeneratedBoardCatalog.carrierEvidenceFamilies.contains(board.family.key),
           board.carrier != profile {
            throw RepairInstallError.carrierMismatch(
                chosen: board.carrier, reported: profile)
        }
        return try releases.resolveUpdate(
            family: target, chip: known(identity.chip) ?? board.family.chip,
            profile: profile, partition: known(identity.partition), transport: .usb)
    }

    /// Install the real firmware on a board the rescue image is running on,
    /// then wait for it to answer as that same board.
    ///
    /// The checks a USB update makes, in the same order: the rescue image's
    /// hardware ID, then esptool's chip and MAC, then the write, then CFGSHOW.
    /// No whole-chip erase, so saved WiFi, name and settings stay. Returns the
    /// port the board answered on.
    func installFirmwareAfterRepair(
        on board: UsbRescuer.RescuedBoard,
        progress: @escaping @Sendable (UsbFlashEvent) -> Void
    ) async -> Result<String, WifiConfigUI.ConfigFailure> {
        func fail(_ title: String, _ message: String) -> Result<String, WifiConfigUI.ConfigFailure> {
            .failure(WifiConfigUI.ConfigFailure(title: title, message: message))
        }
        guard let hardwareID = board.identity.hardwareID else {
            return fail("Could not identify this board",
                        "The rescue image did not report a hardware ID, so nothing was written.")
        }
        guard board.storedOverride == nil else {
            return fail("Clear the stored board override first",
                        "The real firmware would force \(board.storedOverride ?? "it") again at boot.")
        }
        guard case .ready(let releases) = BundledFirmware.load() else {
            return fail("No firmware in this copy of the app",
                        "The app was packaged without its firmware releases.")
        }
        let resolution: BundledFirmware.UpdateResolution
        do {
            resolution = try Self.repairInstallSelection(for: board, releases: releases)
        } catch {
            return fail("No firmware for this board", error.localizedDescription)
        }
        let target = resolution.canonicalTarget
        let bundle = resolution.selection.bundle
        guard let image = bundle.image(forTarget: target),
              let writes = bundle.flashPlan(forTarget: target)
        else {
            return fail("No firmware for this board",
                        "The bundled \(target) firmware has no complete USB image.")
        }
        guard case .installed(let toolPath) = EsptoolInstallation.locate() else {
            return fail("The esp32 core is not installed",
                        "Installing uses the esptool included with the Arduino esp32 core.")
        }
        let tool = EsptoolCommand.Tool(path: toolPath)
        let port = board.port

        holdUSBProbes()
        defer { releaseUSBProbes() }
        beginUSBFlash(hardwareID: hardwareID)
        var wroteFlash = false
        defer { finishUSBFlash(hardwareID: hardwareID, wroteFlash: wroteFlash) }

        progress(.log(.app, "Installing \(bundle.firmwareVersion) (\(target), "
            + "\(image.chip)) on \(port)."))
        progress(.phase(.findingBoard))
        let detection = await UsbOnboarder.detectChip(port: port, tool: tool, onProgress: progress)
        guard case .detected(let chip, let mac) = detection else {
            if case .failed(let reason) = detection {
                return fail("Could not read the USB board", reason)
            }
            return fail("Could not read the USB board", "esptool did not read the chip.")
        }
        guard ConfigCommands.canonicalHardwareID(mac) == hardwareID, chip == image.chip else {
            return fail("USB device mismatch",
                        "esptool read \(chip) \(mac ?? "with no MAC") on \(port), not the "
                            + "\(image.chip) \(hardwareID) the rescue image reported, so "
                            + "nothing was written.")
        }
        wroteFlash = true
        do {
            try await UsbOnboarder.flash(
                writes: writes, chip: chip, port: port, tool: tool, onProgress: progress)
        } catch let failure as WifiConfigUI.ConfigFailure {
            return .failure(failure)
        } catch {
            return fail("Flashing failed", error.localizedDescription)
        }
        switch await UsbOnboarder.settle(
            flashedPort: port, expectedHardwareID: hardwareID, onProgress: progress)
        {
        case .success(let settled):
            // The rescue image answers CFGSHOW with the same ID but never with
            // a firmware version, so a version is what proves the real one runs.
            guard settled.firmwareVersion != nil else {
                return fail("The board is still on the rescue firmware",
                            "It answered on \(settled.port) without a firmware version.")
            }
            progress(.log(.app, "The board answered on \(settled.port) running "
                + "\(settled.firmwareVersion ?? bundle.firmwareVersion)."))
            return .success(settled.port)
        case .failure(let failure):
            return .failure(failure)
        }
    }
}
