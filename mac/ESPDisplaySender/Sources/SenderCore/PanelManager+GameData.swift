import Foundation
import SenderProtocol

/// Reading and writing a board's game store over USB: the Doom WADs and Quake
/// paks the Game data section installs, in the game data area
/// `GameStore.area` finds.
///
/// The board is identified exactly as `flashFirmwareOverUSB` identifies it
/// before anything is read or written - path generation, CFGSHOW hardware ID,
/// esptool's MAC and chip - and every esptool run after that must name the
/// same MAC. Where the area is comes from the partition table the board itself
/// boots with, never from this repo's. Nothing is erased, so the board's
/// firmware, settings and bundled doom1.wad are untouched.
extension PanelManager {
    // MARK: readiness

    /// The same target the firmware sheet gathers, but only with a matched USB
    /// device: there is no WiFi path for the data.
    func gameDataReadiness(_ serviceName: String) -> FirmwareUpdateReadiness {
        let noUSB = "Game data is written over USB. Connect this device to "
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

    func beginGameDataInstall(_ serviceName: String) -> FirmwareUpdateTarget? {
        switch gameDataReadiness(serviceName) {
        case .ready(let target):
            return target
        case .notReady(let reason):
            operationOutcome = .failure("Game data unavailable", reason)
            return nil
        }
    }

    func gameDataUnavailableReason(_ serviceName: String) -> String? {
        if case .notReady(let reason) = gameDataReadiness(serviceName) {
            return reason
        }
        return nil
    }

    // MARK: the board

    /// Where a board's game data area is and what it holds.
    struct GameDataRead: Sendable {
        let area: GameStore.Area
        let contents: GameStore.Contents
    }

    /// A verified board and what its game data area holds.
    struct GameDataBoard: Sendable {
        let path: String
        let chip: String
        let expectedID: String
        let tool: EsptoolCommand.Tool
        let table: Data
        let area: GameStore.Area
        let contents: GameStore.Contents
    }

    /// Verify the board, then read its table, (on an S3) its flash size, and
    /// its game store. Read-only. The caller must already hold the USB flash
    /// guard (`beginUSBFlash`).
    private func connectGameDataBoard(
        to target: FirmwareUpdateTarget,
        progress: @escaping @Sendable (UsbOnboarder.Progress) -> Void
    ) async -> GameDataStep<GameDataBoard> {
        guard let device = target.usbDevice,
              let expectedGeneration = target.usbPathGeneration,
              !device.path.isEmpty,
              let expectedID = ConfigCommands.canonicalHardwareID(target.hardwareID)
        else {
            return .stop(.failure(
                "USB unavailable",
                "No connected USB device was positively matched to this board."))
        }
        let path = device.path
        guard usbPathGeneration(path) == expectedGeneration,
              let current = usbDevices.first(where: { $0.path == path && $0.isConnected })
        else {
            return .stop(.failure(
                "USB device changed",
                "The serial device was unplugged, renumbered, or reused after the "
                    + "window opened. Refresh the USB device and try again."))
        }
        let currentID = ConfigCommands.canonicalHardwareID(current.hardwareID)
        guard currentID == expectedID
                || (currentID == nil && target.usbAllowsLegacyIdentity)
        else {
            return .stop(.failure(
                "USB device mismatch",
                "The connected USB device reports a different hardware ID, so "
                    + "nothing was read or written."))
        }

        progress(.phase(.findingBoard))
        switch await probeUSBDevice(path, timeout: 3) {
        case .unavailable(let reason):
            return .stop(await explainUnansweredBoard(
                path: path, expectedID: expectedID, reason: reason,
                nothingDone: "nothing was read or written"))
        case .identified(let identity):
            let reportedID = ConfigCommands.canonicalHardwareID(identity.hardwareID)
            guard reportedID == expectedID
                    || (reportedID == nil && target.usbAllowsLegacyIdentity)
            else {
                return .stop(.failure(
                    "USB device mismatch",
                    "The device at \(path) did not report \(target.hardwareID), "
                        + "so nothing was read or written."))
            }
        }
        guard usbPathGeneration(path) == expectedGeneration else {
            return .stop(.failure(
                "USB device changed",
                "The serial device changed while it was being verified, so "
                    + "nothing was read or written."))
        }

        let tool: EsptoolCommand.Tool
        switch EsptoolInstallation.locate() {
        case .installed(let path):
            tool = EsptoolCommand.Tool(path: path)
        case .missing(let searched):
            return .stop(.failure(
                "The esp32 core is not installed",
                "Reading and writing over USB uses the esptool included with the "
                    + "Arduino esp32 core. It was not found under "
                    + "\(searched.joined(separator: " or "))."))
        }

        let detectedChip: String
        let detectedMAC: String?
        switch await UsbOnboarder.detectChip(port: path, tool: tool, onProgress: progress) {
        case .detected(let chip, let mac):
            detectedChip = chip
            detectedMAC = ConfigCommands.canonicalHardwareID(mac)
        case .failed(let reason):
            return .stop(.failure("Could not read the USB board", reason))
        case .notAttempted:
            return .stop(.failure(
                "Could not read the USB board",
                "esptool did not attempt chip detection, so nothing was read or written."))
        }
        guard detectedMAC == expectedID else {
            return .stop(.failure(
                "USB device mismatch",
                "esptool read \(detectedMAC ?? "no MAC address") from \(path), "
                    + "not \(target.hardwareID), so nothing was read or written."))
        }
        if let expectedChip = target.chip,
           !expectedChip.isEmpty,
           expectedChip != ServiceMetadata.unknownChip,
           expectedChip != detectedChip {
            return .stop(.failure(
                "USB chip mismatch",
                "The device reported \(expectedChip), but esptool read "
                    + "\(detectedChip). Nothing was read or written."))
        }
        guard detectedChip == QuakePak.p4Chip || detectedChip == QuakePak.s3Chip else {
            return .stop(.failure(
                "No games on this board",
                "Doom and Quake run only on ESP32-S3 and ESP32-P4 boards; esptool read "
                    + "\(detectedChip). Nothing was read or written."))
        }

        let table: Data
        switch await Self.readGameFlash(
            "the partition table", port: path, chip: detectedChip, expectedID: expectedID,
            tool: tool, address: QuakePak.partitionTableAddress,
            byteCount: QuakePak.partitionTableBytes, progress: progress) {
        case .done(let read): table = read
        case .stop(let outcome): return .stop(outcome)
        }
        var flashBytes: Int?
        if detectedChip == QuakePak.s3Chip {
            switch await Self.readFlashBytes(
                port: path, chip: detectedChip, expectedID: expectedID, tool: tool,
                progress: progress) {
            case .done(let bytes): flashBytes = bytes
            case .stop(let outcome): return .stop(outcome)
            }
        }
        let area: GameStore.Area
        switch GameStore.area(chip: detectedChip, partitionTable: table, flashBytes: flashBytes) {
        case .area(let found): area = found
        case .refuse(let title, let message): return .stop(.failure(title, message))
        }

        let sector: Data
        switch await Self.readGameFlash(
            "the game store directory", port: path, chip: detectedChip,
            expectedID: expectedID, tool: tool, address: area.directoryAddress,
            byteCount: GameStore.sectorBytes, progress: progress) {
        case .done(let read): sector = read
        case .stop(let outcome): return .stop(outcome)
        }
        let contents: GameStore.Contents
        do {
            if let directory = try GameStore.decode(sector: sector, areaBytes: area.byteCount) {
                contents = .directory(directory)
            } else {
                // No directory: the legacy layout, a raw pak0.pak or nothing.
                switch await Self.readGameFlash(
                    "the start of the game data area", port: path, chip: detectedChip,
                    expectedID: expectedID, tool: tool, address: area.address,
                    byteCount: GameStore.sectorBytes, progress: progress) {
                case .done(let first):
                    if let directory = GameStore.legacyPakDirectory(
                        firstBytes: first, areaBytes: area.byteCount) {
                        // Measured as the firmware measures it: to the end of
                        // its directory or its furthest file, whichever is last.
                        switch await Self.readGameFlash(
                            "the old pak0.pak's directory", port: path, chip: detectedChip,
                            expectedID: expectedID, tool: tool,
                            address: area.address + directory.lowerBound,
                            byteCount: directory.count, progress: progress) {
                        case .done(let entries):
                            contents = .legacy(legacyPak0Bytes: GameStore.legacyPakBytes(
                                directory: directory, entries: entries,
                                areaBytes: area.byteCount))
                        case .stop(let outcome):
                            return .stop(outcome)
                        }
                    } else {
                        contents = .legacy(legacyPak0Bytes: nil)
                    }
                case .stop(let outcome):
                    return .stop(outcome)
                }
            }
        } catch let error as GameStore.DecodeError {
            if case .newerVersion = error {
                return .stop(.failure("Game store too new", error.localizedDescription))
            }
            // A damaged directory names nothing usable; the next write replaces
            // it, keeping nothing that was on the board.
            progress(.log(.app, error.localizedDescription))
            contents = .directory(GameStore.Directory(
                areaBytes: area.byteCount, generation: 0, entries: []))
        } catch {
            return .stop(.failure("Could not read the game store", error.localizedDescription))
        }
        progress(.log(.app, "Game data area: \(area.description), \(area.byteCount) bytes at "
            + "0x\(String(area.address, radix: 16, uppercase: true)); "
            + Self.contentsSummary(contents)))
        return .done(GameDataBoard(
            path: path, chip: detectedChip, expectedID: expectedID, tool: tool,
            table: table, area: area, contents: contents))
    }

    static func contentsSummary(_ contents: GameStore.Contents) -> String {
        switch contents {
        case .legacy(nil):
            return "empty."
        case .legacy(let bytes?):
            return "a pak0.pak of \(bytes) bytes written before the game store."
        case .directory(let directory) where directory.entries.isEmpty:
            return "an empty game store."
        case .directory(let directory):
            return directory.entries.map(\.name).joined(separator: ", ") + "."
        }
    }

    /// What the board holds now, for the sheet's "on the board" column.
    /// Read-only; every esptool run restarts the board, which comes back as it
    /// was.
    func readGameDataOverUSB(
        from target: FirmwareUpdateTarget,
        progress: @escaping @Sendable (UsbOnboarder.Progress) -> Void
    ) async -> GameDataStep<GameDataRead> {
        guard let expectedID = ConfigCommands.canonicalHardwareID(target.hardwareID) else {
            return .stop(.failure(
                "USB identity unavailable",
                "This device's hardware ID is not a six-byte MAC address, so the "
                    + "app cannot prove which connected board to read."))
        }
        beginUSBFlash(hardwareID: expectedID)
        defer { finishUSBFlash(hardwareID: expectedID, wroteFlash: false) }
        switch await connectGameDataBoard(to: target, progress: progress) {
        case .stop(let outcome):
            return .stop(outcome)
        case .done(let board):
            refreshUSBPorts()
            return .done(GameDataRead(area: board.area, contents: board.contents))
        }
    }

    // MARK: the write

    /// Write the checked games' files, keeping whatever already sits right.
    ///
    /// The files are read and checked again here, and those bytes are the ones
    /// written. The board is verified and its store read; the write is planned
    /// against that (`GameStore.plan`); a directory naming only what stays is
    /// written first when anything moves or goes; then the files and the final
    /// directory in one esptool run, which verifies each. Afterwards the table
    /// must be unchanged and the directory must read back as written.
    func writeGameDataOverUSB(
        _ selection: GameDataSelection,
        to target: FirmwareUpdateTarget,
        progress: @escaping @Sendable (UsbOnboarder.Progress) -> Void
    ) async -> OperationOutcome {
        // Every file the app might write, read and checked once.
        let local = selection.items.filter { $0.url != nil && $0.isChecked
            && selection.isGameChecked($0.kind) }
        let loaded: GameDataStep<[String: Data]> = await Task.detached(priority: .userInitiated) {
            var payloads: [String: Data] = [:]
            for item in local {
                guard let url = item.url else { continue }
                do {
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    let again = try GameData.identify(
                        data, filename: url.lastPathComponent, kind: item.kind)
                    guard again.sha256 == item.identified.sha256 else {
                        return .stop(.failure(
                            "\(url.lastPathComponent) changed",
                            "The file changed after it was chosen. Choose it again."))
                    }
                    payloads[item.id] = data
                } catch let error as GameData.IdentifyError {
                    return .stop(.failure(
                        "\(url.lastPathComponent) is not usable", error.localizedDescription))
                } catch {
                    return .stop(.failure(
                        "Could not read \(url.lastPathComponent)", error.localizedDescription))
                }
            }
            return .done(payloads)
        }.value
        let payloads: [String: Data]
        switch loaded {
        case .done(let read): payloads = read
        case .stop(let outcome): return outcome
        }

        guard let expectedID = ConfigCommands.canonicalHardwareID(target.hardwareID) else {
            return .failure(
                "USB identity unavailable",
                "This device's hardware ID is not a six-byte MAC address, so the "
                    + "app cannot prove which connected board is safe to write.")
        }
        beginUSBFlash(hardwareID: expectedID)
        var wroteFlash = false
        defer { finishUSBFlash(hardwareID: expectedID, wroteFlash: wroteFlash) }

        let board: GameDataBoard
        switch await connectGameDataBoard(to: target, progress: progress) {
        case .done(let connected): board = connected
        case .stop(let outcome): return outcome
        }
        let plan: GameStore.Plan
        switch GameStore.plan(
            current: board.contents, desired: selection.desiredFiles(board: board.contents),
            area: board.area) {
        case .success(let planned): plan = planned
        case .failure(let failure):
            return .failure("The selection does not fit", failure.localizedDescription)
        }
        if plan.writes.isEmpty, case .directory(let current) = board.contents,
           current.entries == plan.final.entries {
            refreshUSBPorts()
            return .success(
                "Nothing to write",
                "\(target.displayName) already holds exactly the checked game data.")
        }
        guard let expectedGeneration = target.usbPathGeneration,
              usbPathGeneration(board.path) == expectedGeneration,
              usbDevices.contains(where: { $0.path == board.path && $0.isConnected })
        else {
            return .failure(
                "USB device changed",
                "The serial device changed after the board was read, so nothing "
                    + "was written.")
        }

        // The bytes of each file the plan places, keyed as the selection is.
        var writes: [FirmwareBundle.FlashWrite] = []
        for entry in plan.writes {
            guard let item = local.first(where: {
                $0.kind == entry.kind && $0.identified.storedName == entry.name
            }), let payload = payloads[item.id] else {
                return .failure(
                    "Missing file",
                    "The app has no copy of \(entry.name) to write, so nothing was written.")
            }
            writes.append(GameStore.flashWrite(
                role: entry.name, address: board.area.address + entry.offset,
                payload: payload, sha256: entry.sha256))
        }
        let finalSector = GameStore.encode(plan.final)
        writes.append(directoryWrite(finalSector, area: board.area))

        if let interim = plan.interim {
            progress(.log(.app, "Clearing what moves or goes from the game store directory "
                + "before writing (it keeps "
                + (interim.entries.isEmpty
                    ? "nothing" : interim.entries.map(\.name).joined(separator: ", "))
                + ")."))
            wroteFlash = true
            do {
                try await UsbOnboarder.flash(
                    writes: [directoryWrite(GameStore.encode(interim), area: board.area)],
                    chip: board.chip, port: board.path, tool: board.tool,
                    eraseAll: false, onProgress: progress)
            } catch let failure as WifiConfigUI.ConfigFailure {
                return .failure(failure)
            } catch {
                return .failure("Writing failed", error.localizedDescription)
            }
            // That run reset the board, and a reset can renumber its port: it
            // must still be the same device, answering with the same MAC,
            // before the files go out.
            guard usbPathGeneration(board.path) == expectedGeneration,
                  usbDevices.contains(where: { $0.path == board.path && $0.isConnected })
            else {
                return .failure(
                    "USB device changed",
                    "The serial device changed after the game store directory was "
                        + "cleared, so no game files were written. Write again to finish.")
            }
            switch await UsbOnboarder.detectChip(
                port: board.path, tool: board.tool, onProgress: progress) {
            case .detected(let chip, let mac)
                where chip == board.chip
                    && ConfigCommands.canonicalHardwareID(mac) == board.expectedID:
                break
            case .detected(_, let mac):
                return .failure(
                    "USB device mismatch",
                    "esptool read \(mac ?? "no MAC address") from \(board.path) after the "
                        + "directory was cleared, which is not this board's MAC address, so no game "
                        + "files were written.")
            case .failed(let reason):
                return .failure("Could not read the USB board", reason)
            case .notAttempted:
                return .failure(
                    "Could not read the USB board",
                    "esptool did not attempt chip detection, so no game files were written.")
            }
        }

        for entry in plan.writes {
            progress(.log(.app, "Writing \(entry.name) (\(entry.length) bytes, sha256 "
                + "\(entry.sha256)) at 0x"
                + String(board.area.address + entry.offset, radix: 16, uppercase: true) + "."))
        }
        wroteFlash = true
        do {
            try await UsbOnboarder.flash(
                writes: writes, chip: board.chip, port: board.path, tool: board.tool,
                eraseAll: false, onProgress: progress)
        } catch let failure as WifiConfigUI.ConfigFailure {
            return .failure(failure)
        } catch {
            return .failure("Writing failed", error.localizedDescription)
        }

        // A flash or esptool that wrapped addresses past 16 MiB would land on
        // the bootloader and table; the table is the cheap tell. The directory
        // must read back exactly as written.
        switch await Self.readGameFlash(
            "the partition table", port: board.path, chip: board.chip,
            expectedID: board.expectedID, tool: board.tool,
            address: QuakePak.partitionTableAddress,
            byteCount: QuakePak.partitionTableBytes, progress: progress) {
        case .done(let after) where after == board.table:
            break
        case .done:
            var outcome = OperationOutcome.failure(
                "The partition table changed",
                "The partition table on \(board.path) changed while game data was being "
                    + "written, so the board's firmware may no longer start.")
            outcome.nextAction = "Update the board's firmware over USB, which rewrites its "
                + "partition table, before writing game data again."
            return outcome
        case .stop(let failure):
            return writtenButUnchecked(failure)
        }
        switch await Self.readGameFlash(
            "the game store directory", port: board.path, chip: board.chip,
            expectedID: board.expectedID, tool: board.tool,
            address: board.area.directoryAddress, byteCount: GameStore.sectorBytes,
            progress: progress) {
        case .done(let after) where after == finalSector:
            break
        case .done:
            var outcome = OperationOutcome.failure(
                "The game store did not read back",
                "The directory read back from \(board.path) is not the one written.")
            outcome.nextAction = "Restart the board with its power or reset button, then write "
                + "its game data again; rewriting is safe."
            return outcome
        case .stop(let failure):
            return writtenButUnchecked(failure)
        }
        refreshUSBPorts()

        let answered: UsbOnboarder.SettledBoard
        // Game data is not firmware: a board whose firmware does not recognise
        // it is told so without saying this run installed any.
        switch await UsbOnboarder.settle(
            flashedPort: board.path, expectedHardwareID: board.expectedID,
            wroteFirmware: false, onProgress: progress)
        {
        case .success(let settled):
            answered = settled
        case .failure(let failure)
            where failure.title == "Stopped" || failure.boardNotRecognised:
            return .failure(failure)
        case .failure:
            var outcome = OperationOutcome.failure(
                "Written, but the board did not answer",
                "The game data was written to \(target.displayName) and checked, but the "
                    + "board did not answer over USB with its hardware ID within "
                    + "\(Int(SerialSettlePolicy.budgetSeconds)) seconds of restarting.")
            outcome.nextAction = "The game data is written. Restart the board with its power "
                + "or reset button; it should answer within a minute."
            return outcome
        }
        refreshUSBPorts()
        let written = plan.writes.map(\.name)
        let kept = plan.final.entries.map(\.name).filter { !written.contains($0) }
        return .success(
            "Game data written over USB",
            "Wrote " + (written.isEmpty ? "the game store directory" : written.joined(
                separator: ", ")) + " to \(target.displayName)"
                + (kept.isEmpty ? "" : ", keeping " + kept.joined(separator: ", "))
                + ". esptool verified every part, the partition table is unchanged, the "
                + "directory read back as written, and the board answered on "
                + "\(answered.port). Its boot menu lists each WAD by name, and QUAKE, "
                + "on firmware that reads the game store.")
    }

    private func directoryWrite(_ sector: Data, area: GameStore.Area) -> FirmwareBundle.FlashWrite {
        GameStore.flashWrite(role: "game_store", address: area.directoryAddress, payload: sector)
    }

    private func writtenButUnchecked(_ failure: OperationOutcome) -> OperationOutcome {
        var outcome = OperationOutcome.failure(
            "Written, but not checked",
            "The game data was written, but the board could not be read back to confirm "
                + "it: \(failure.message)")
        outcome.nextAction = "Restart the board with its power or reset button, then write its "
            + "game data again; rewriting is safe."
        return outcome
    }

    // MARK: esptool reads

    /// `byteCount` bytes of flash from `address`, read with read-flash.
    nonisolated private static func readGameFlash(
        _ what: String, port: String, chip: String, expectedID: String,
        tool: EsptoolCommand.Tool, address: Int, byteCount: Int,
        progress: @escaping @Sendable (UsbOnboarder.Progress) -> Void
    ) async -> GameDataStep<Data> {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("espdisp-read-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("read.bin")
        let output: String
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let command = try EsptoolCommand.readFlash(
                tool: tool, chip: chip, port: port, address: address,
                byteCount: byteCount, outputPath: file.path)
            progress(.log(.app, "Reading \(what) on \(port)."))
            let outcome = try await EsptoolRunner.run(command) { line in
                progress(.log(.esptool, line))
            }
            output = outcome.output
            guard outcome.succeeded else {
                return .stop(.failure(
                    "Could not read \(what)",
                    EsptoolOutput.failureSummary(in: outcome.output)
                        ?? "esptool exited with status \(outcome.exitCode)."))
            }
        } catch {
            return .stop(.failure("Could not read \(what)", error.localizedDescription))
        }
        if let outcome = macMismatch(in: output, port: port, expectedID: expectedID) {
            return .stop(outcome)
        }
        guard let read = try? Data(contentsOf: file), read.count == byteCount else {
            return .stop(.failure(
                "Could not read \(what)",
                "esptool finished but left \(what) incomplete."))
        }
        return .done(read)
    }

    /// The chip's flash size, from `flash-id`.
    nonisolated private static func readFlashBytes(
        port: String, chip: String, expectedID: String, tool: EsptoolCommand.Tool,
        progress: @escaping @Sendable (UsbOnboarder.Progress) -> Void
    ) async -> GameDataStep<Int> {
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
            "esptool read \(mac) from \(port) rather than this board's MAC address, so "
                + "nothing more was done.")
    }
}

/// One step of a game data read or write: its value, or the outcome that ends
/// the run. Not a `Result`, because an `OperationOutcome` is not an `Error`.
enum GameDataStep<Value: Sendable>: Sendable {
    case done(Value)
    case stop(OperationOutcome)
}
