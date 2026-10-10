import Foundation
import SenderProtocol

/// Writing Quake's data (id1/pak0.pak, the user's own file) to a board over USB:
/// the app's counterpart of `tools/espdisp.py write-data quake_pak`.
///
/// The board is identified exactly as `flashFirmwareOverUSB` identifies it
/// before anything is written - path generation, CFGSHOW hardware ID, esptool's
/// MAC and chip - and the destination is decided by `QuakePak.plan` from the
/// partition table the board itself boots with, never from this repo's.
extension PanelManager {
    // MARK: readiness

    /// The same target the firmware sheet gathers, but only with a matched USB
    /// device: there is no WiFi path for the data.
    func quakeDataReadiness(_ serviceName: String) -> FirmwareUpdateReadiness {
        let noUSB = "Quake's data is written over USB. Connect this display to "
            + "this Mac with a data cable."
        switch firmwareUpdateReadiness(serviceName) {
        case .ready(let target) where target.usbDevice != nil:
            return .ready(target)
        case .ready:
            return .notReady(noUSB)
        case .notReady(let reason):
            // A connected device that could not be verified, or a panel with no
            // hardware ID, is the firmware path's own reason; otherwise the one
            // thing missing is the cable.
            return .notReady(usbUpdateDevice(for: serviceName) != nil ? reason : noUSB)
        }
    }

    func beginQuakeDataInstall(_ serviceName: String) -> FirmwareUpdateTarget? {
        switch quakeDataReadiness(serviceName) {
        case .ready(let target):
            return target
        case .notReady(let reason):
            operationOutcome = .failure("Quake data unavailable", reason)
            return nil
        }
    }

    func quakeDataUnavailableReason(_ serviceName: String) -> String? {
        if case .notReady(let reason) = quakeDataReadiness(serviceName) {
            return reason
        }
        return nil
    }

    // MARK: the write

    /// Validate the file, re-verify the board, read its table (and on an S3 its
    /// flash size), write the pak in one esptool run, check the table did not
    /// change, and wait for the board to answer again. No erase, so the board's
    /// firmware and settings are untouched.
    func writeQuakeDataOverUSB(
        fileURL: URL,
        to target: FirmwareUpdateTarget,
        progress: @escaping @Sendable (UsbOnboarder.Progress) -> Void
    ) async -> OperationOutcome {
        // The bytes that are validated are the bytes that are written, not
        // whatever the path holds by the time esptool opens it.
        let loaded: QuakeDataStep<(Data, QuakePak.Validated)> =
            await Task.detached(priority: .userInitiated) {
                do {
                    let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                    return .done((data, try QuakePak.validate(data)))
                } catch let error as QuakePak.ValidationError {
                    return .stop(.failure(
                        "Not a Quake pack", error.localizedDescription))
                } catch {
                    return .stop(.failure(
                        "Could not read the file", error.localizedDescription))
                }
            }.value
        let payload: Data
        let validated: QuakePak.Validated
        switch loaded {
        case .done(let read):
            (payload, validated) = read
        case .stop(let outcome):
            return outcome
        }

        guard let device = target.usbDevice,
              let expectedGeneration = target.usbPathGeneration,
              !device.path.isEmpty
        else {
            return .failure(
                "USB unavailable",
                "No connected USB device was positively matched to this display.")
        }
        let path = device.path
        guard let expectedID = ConfigCommands.canonicalHardwareID(target.hardwareID) else {
            return .failure(
                "USB identity unavailable",
                "This display's hardware ID is not a six-byte MAC address, so the "
                    + "app cannot prove which connected board is safe to write.")
        }
        beginUSBFlash(hardwareID: expectedID)
        var wroteFlash = false
        defer { finishUSBFlash(hardwareID: expectedID, wroteFlash: wroteFlash) }
        guard usbPathGeneration(path) == expectedGeneration,
              let current = usbDevices.first(where: { $0.path == path && $0.isConnected })
        else {
            return .failure(
                "USB device changed",
                "The serial device was unplugged, renumbered, or reused after the "
                    + "window opened. Refresh the USB device and try again.")
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

        progress(.phase(.findingBoard))
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
                "Writing over USB uses the esptool included with the Arduino esp32 "
                    + "core. It was not found under \(searched.joined(separator: " or ")).")
        }

        let detectedChip: String
        let detectedMAC: String?
        switch await UsbOnboarder.detectChip(port: path, tool: tool, onProgress: progress) {
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
        if let expectedChip = target.chip,
           !expectedChip.isEmpty,
           expectedChip != ServiceMetadata.unknownChip,
           expectedChip != detectedChip {
            return .failure(
                "USB chip mismatch",
                "The display reported \(expectedChip), but esptool read "
                    + "\(detectedChip). Nothing was written.")
        }
        // Refused before any more esptool runs: the plan would refuse it too.
        if case .refuse(let title, let message)? = QuakePak.chipRefusal(detectedChip) {
            return .failure(title, message)
        }

        let table: Data
        switch await Self.readQuakePartitionTable(
            port: path, chip: detectedChip, expectedID: expectedID, tool: tool,
            progress: progress) {
        case .done(let read): table = read
        case .stop(let outcome): return outcome
        }
        var flashBytes: Int?
        if detectedChip == QuakePak.s3Chip {
            switch await Self.readFlashBytes(
                port: path, chip: detectedChip, expectedID: expectedID, tool: tool,
                progress: progress) {
            case .done(let bytes): flashBytes = bytes
            case .stop(let outcome): return outcome
            }
        }
        let address: Int
        switch QuakePak.plan(
            chip: detectedChip, partitionTable: table, flashBytes: flashBytes,
            payloadBytes: payload.count) {
        case .write(let planned):
            address = planned
        case .refuse(let title, let message):
            return .failure(title, message)
        }
        guard usbPathGeneration(path) == expectedGeneration,
              usbDevices.contains(where: { $0.path == path && $0.isConnected })
        else {
            return .failure(
                "USB device changed",
                "The serial device changed after the board was read, so nothing "
                    + "was written.")
        }

        let addressText = "0x" + String(address, radix: 16, uppercase: true)
        progress(.log(.app, "Writing \(fileURL.lastPathComponent) (\(validated.byteCount) "
            + "bytes, sha256 \(validated.sha256)"
            + (validated.isShareware ? ", the shareware pak0.pak" : "")
            + ") to \(QuakePak.flashRole) at \(addressText)."))
        wroteFlash = true
        do {
            try await UsbOnboarder.flash(
                writes: [QuakePak.flashWrite(
                    payload: payload, address: address,
                    filename: fileURL.lastPathComponent, sha256: validated.sha256)],
                chip: detectedChip, port: path, tool: tool,
                eraseAll: false, onProgress: progress)
        } catch let failure as WifiConfigUI.ConfigFailure {
            return .failure(failure)
        } catch {
            return .failure("Writing failed", error.localizedDescription)
        }

        // A flash or esptool that wrapped addresses past 16 MiB would land the
        // top of the pack on the bootloader and table, and its digest check
        // would wrap the same way. The table is the cheap tell.
        switch await Self.readQuakePartitionTable(
            port: path, chip: detectedChip, expectedID: expectedID, tool: tool,
            progress: progress) {
        case .done(let after) where after == table:
            break
        case .done:
            var outcome = OperationOutcome.failure(
                "The partition table changed",
                "The partition table on \(path) changed while Quake's data was "
                    + "being written, so the board's firmware may no longer start.")
            outcome.nextAction = "Update the board's firmware over USB, which "
                + "rewrites its partition table, before writing Quake's data again."
            return outcome
        case .stop(let failure):
            var outcome = OperationOutcome.failure(
                "Written, but not checked",
                "Quake's data was written, but the partition table could not be "
                    + "read back to confirm it is unchanged: \(failure.message)")
            outcome.nextAction = "Unplug the board and plug it back in, then write "
                + "Quake's data again; rewriting is safe."
            return outcome
        }
        refreshUSBPorts()

        let answered: UsbOnboarder.SettledBoard
        switch await UsbOnboarder.settle(
            flashedPort: path, expectedHardwareID: expectedID, onProgress: progress)
        {
        case .success(let board):
            answered = board
        case .failure(let failure) where failure.title == "Stopped":
            return .failure(failure)
        case .failure:
            var outcome = OperationOutcome.failure(
                "Written, but the board did not answer",
                "Quake's data was written to \(target.displayName) and the partition "
                    + "table is unchanged, but the board did not answer CFGSHOW with "
                    + "its hardware ID within \(Int(SerialSettlePolicy.budgetSeconds)) "
                    + "seconds of restarting.")
            outcome.nextAction = "Quake's data is written. Unplug the board and plug "
                + "it back in; it should answer within a minute."
            return outcome
        }
        refreshUSBPorts()
        return .success(
            "Quake data written over USB",
            "\(fileURL.lastPathComponent) (\(Self.quakeByteText(validated.byteCount))"
                + (validated.isShareware ? ", the shareware pak0.pak" : "")
                + ") was written to \(target.displayName) at \(addressText). esptool "
                + "verified it, the partition table is unchanged, and the board "
                + "answered on \(answered.port). Its boot menu offers QUAKE when its "
                + "firmware carries Quake.")
    }

    // MARK: esptool reads

    /// The partition table the board boots with, read from 0x8000.
    nonisolated private static func readQuakePartitionTable(
        port: String, chip: String, expectedID: String, tool: EsptoolCommand.Tool,
        progress: @escaping @Sendable (UsbOnboarder.Progress) -> Void
    ) async -> QuakeDataStep<Data> {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("espdisp-table-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("partitions.bin")
        let output: String
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let command = try EsptoolCommand.readFlash(
                tool: tool, chip: chip, port: port,
                address: QuakePak.partitionTableAddress,
                byteCount: QuakePak.partitionTableBytes, outputPath: file.path)
            progress(.log(.app, "Reading the partition table on \(port)."))
            let outcome = try await EsptoolRunner.run(command) { line in
                progress(.log(.esptool, line))
            }
            output = outcome.output
            guard outcome.succeeded else {
                return .stop(.failure(
                    "Could not read the partition table",
                    EsptoolOutput.failureSummary(in: outcome.output)
                        ?? "esptool exited with status \(outcome.exitCode)."))
            }
        } catch {
            return .stop(.failure(
                "Could not read the partition table", error.localizedDescription))
        }
        if let outcome = macMismatch(in: output, port: port, expectedID: expectedID) {
            return .stop(outcome)
        }
        guard let table = try? Data(contentsOf: file), !table.isEmpty else {
            return .stop(.failure(
                "Could not read the partition table",
                "esptool finished but left no partition table to read."))
        }
        return .done(table)
    }

    /// The chip's flash size, from `flash-id`.
    nonisolated private static func readFlashBytes(
        port: String, chip: String, expectedID: String, tool: EsptoolCommand.Tool,
        progress: @escaping @Sendable (UsbOnboarder.Progress) -> Void
    ) async -> QuakeDataStep<Int> {
        let outcome: EsptoolRunner.Outcome
        do {
            let command = try EsptoolCommand.flashID(tool: tool, chip: chip, port: port)
            progress(.log(.app, "Reading the flash size of \(port)."))
            outcome = try await EsptoolRunner.run(command) { line in
                progress(.log(.esptool, line))
            }
        } catch {
            return .stop(.failure(
                "Could not read the flash size", error.localizedDescription))
        }
        if let mismatch = macMismatch(in: outcome.output, port: port, expectedID: expectedID) {
            return .stop(mismatch)
        }
        guard outcome.succeeded,
              let bytes = EsptoolOutput.detectedFlashBytes(in: outcome.output)
        else {
            return .stop(.failure(
                "Could not read the flash size",
                EsptoolOutput.failureSummary(in: outcome.output)
                    ?? "esptool did not report the flash size."))
        }
        return .done(bytes)
    }

    /// Each esptool run resets the board, and a reset can renumber its port.
    /// Each run must name the MAC it connected to, and it must still be this
    /// board; a run that names none is refused like a different one.
    nonisolated private static func macMismatch(
        in output: String, port: String, expectedID: String
    ) -> OperationOutcome? {
        guard let mac = EsptoolOutput.macAddress(in: output) else {
            return .failure(
                "USB device unconfirmed",
                "esptool did not report which board it read on \(port), so "
                    + "nothing more was done.")
        }
        guard ConfigCommands.canonicalHardwareID(mac) != expectedID
        else { return nil }
        return .failure(
            "USB device mismatch",
            "esptool read \(mac) from \(port) rather than this display's board, so "
                + "nothing more was done.")
    }

    nonisolated static func quakeByteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// One step of the Quake write: its value, or the outcome that ends the run.
/// Not a `Result`, because an `OperationOutcome` is not an `Error`.
enum QuakeDataStep<Value: Sendable>: Sendable {
    case done(Value)
    case stop(OperationOutcome)
}
