import Foundation
import SenderProtocol

/// The I/O half of bringing up a board over USB: spawning esptool, staging the
/// payloads it needs on disk, and pushing credentials down the cable afterwards.
///
/// Every decision this makes is made somewhere else and asked for here -
/// `FirmwareBundle.flashPlan` for what gets written where, `EsptoolCommand` for
/// the argv, `UsbOnboardingPlan` for whether to start at all, and
/// `SerialSettlePolicy` for when the board is ready to be spoken to again. What is
/// left is processes, files and a serial write, none of which a test can exercise
/// without a board.
///
/// UNVERIFIED END TO END: no board has been flashed by this app. The attached
/// ESP32-S3 is the user's only one and still carries its factory firmware, and a
/// flash would destroy it, so it was probed read-only and never written. What is
/// tested is every computation this drives; what is not is a write to hardware.
enum UsbOnboarder {

    /// Where onboarding has got to. Coarse, because the expensive step reports its
    /// own progress from esptool's output.
    enum Progress: Equatable, Sendable {
        /// Asking the board what chip it is.
        case readingChip
        /// esptool is writing. `percent` is nil when its output carried none.
        case writing(percent: Int?, status: String)
        /// The board is restarting and the serial device is coming back.
        case waitingForBoard
        /// A configuration line is going down the cable.
        case configuring(String)
    }

    /// What a completed onboarding did, for the outcome alert.
    struct Completion: Equatable, Sendable {
        /// nil when nothing was written, which is the configure-only path.
        var flashedVersion: String?
        var chip: String?
        var mac: String?
        var ssid: String
        var appliedName: String?
        /// The port the last command actually went to, which is not necessarily
        /// the one the flash went to.
        var finalPort: String
    }

    // MARK: - reading the board

    /// Ask the board what chip it is, read-only.
    ///
    /// `chip-id` is what tools/espdisp.py `probe_chip()` runs, and this parses its
    /// output with the same rules. On an ESP32-S3 it also prints a MAC and says
    /// why: "Warning: ESP32-S3 has no chip ID. Reading MAC address instead." -
    /// which is measured output from the attached board, and is why the MAC is
    /// what gets shown as the board's identity.
    static func detectChip(
        port: String, tool: EsptoolCommand.Tool
    ) async -> UsbOnboarding.ChipDetection {
        let command: EsptoolCommand
        do {
            command = try EsptoolCommand.chipID(tool: tool, port: port)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
        do {
            let outcome = try await EsptoolRunner.run(command)
            guard let chip = EsptoolOutput.chipToken(in: outcome.output) else {
                let reason = EsptoolOutput.failureSummary(in: outcome.output)
                    ?? "it printed nothing at all."
                return .failed(reason: reason)
            }
            // A non-zero exit with a chip named anyway is still an answer: the S3's
            // chip-id ends in a warning about having no chip id. The chip token is
            // what was asked for, and it was found.
            return .detected(chip: chip, mac: EsptoolOutput.macAddress(in: outcome.output))
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    /// Ask a port whether it is already running this firmware.
    ///
    /// CFGSHOW answering at all is the proof, the same test
    /// `WifiConfigUI.probePort` applies. Blocking serial I/O, so this is called
    /// from a background task.
    static func probeExistingFirmware(port: String) -> UsbOnboarding.ExistingFirmware {
        switch WifiConfigUI.sendCommand("CFGSHOW", port: port, timeout: 3) {
        case .success(let info):
            return .answered(name: ConfigCommands.decodeField("name64=", from: info) ?? "")
        case .failure:
            return .silent
        }
    }

    // MARK: - writing the board

    /// Write every part a blank board needs, in one esptool run.
    ///
    /// ONE RUN, NOT FOUR, and that is load-bearing rather than an optimisation.
    /// The partition table is what says the application lives at 0x10000: a
    /// factory board read here had its own app at 0x110000 and nothing at 0x10000
    /// at all, so writing the app against the table that is already on the board
    /// would put an image inside a region that table calls NVS. The core's own
    /// recipe writes them together for the same reason (platform.txt:346).
    static func flash(
        writes: [FirmwareBundle.FlashWrite],
        chip: String,
        port: String,
        tool: EsptoolCommand.Tool,
        eraseAll: Bool = false,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        // esptool takes paths, not bytes on stdin, so the payloads the bundle is
        // holding have to become files. Its own directory, removed on every exit
        // path, because it holds two megabytes and the payloads are named after
        // flash addresses rather than after anything unique.
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("espdisp-flash-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var staged: [EsptoolCommand.StagedWrite] = []
        for (index, write) in writes.enumerated() {
            let url = staging.appendingPathComponent(
                EsptoolCommand.stagedFilename(index: index, role: write.role))
            try write.payload.write(to: url, options: .atomic)
            staged.append(EsptoolCommand.StagedWrite(
                role: write.role, address: write.address, path: url.path))
        }

        let command = try EsptoolCommand.writeFlash(
            tool: tool, chip: chip, port: port, writes: staged, eraseAll: eraseAll)
        onProgress(.writing(percent: nil, status: "Starting esptool…"))
        let outcome = try await EsptoolRunner.run(command) { line in
            onProgress(.writing(percent: EsptoolOutput.percentage(in: line), status: line))
        }
        guard outcome.succeeded else {
            throw WifiConfigUI.ConfigFailure(
                title: "Flashing failed",
                message: (EsptoolOutput.failureSummary(in: outcome.output)
                    ?? "esptool exited with status \(outcome.exitCode).")
                    + " The board keeps whatever was on it before the parts that "
                    + "did get written; run it again, or use tools/espdisp.py "
                    + "flash to see the whole transcript.")
        }
    }

    // MARK: - talking to it afterwards

    /// Wait for a board to come back after a reset and hand it one line at a time.
    ///
    /// The reset is not this code's choice: `--after hard-reset` is in the recipe
    /// because it is what leaves the board running what was written, and every
    /// CFG* handler in the firmware restarts as well. So this is the same wait
    /// three times over, and it is one function so the waiting rule cannot differ
    /// between them.
    static func sendConfiguration(
        steps: [UsbOnboarding.ConfigStep],
        flashedPort: String,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async -> Result<String, WifiConfigUI.ConfigFailure> {
        var port = flashedPort
        for step in steps {
            onProgress(.waitingForBoard)
            switch await settle(flashedPort: port) {
            case .success(let resolved):
                port = resolved
            case .failure(let failure):
                return .failure(failure)
            }
            onProgress(.configuring(step.label))
            switch WifiConfigUI.sendCommand(step.command, port: port) {
            case .success:
                continue
            case .failure(let reason):
                return .failure(WifiConfigUI.ConfigFailure(
                    title: "Could not finish setting up the board",
                    message: "The firmware is on it, and \(step.label.lowercased()) "
                        + "did not go through: \(reason)"))
            }
        }
        return .success(port)
    }

    /// Find the board again and prove it is listening.
    ///
    /// A DEVICE NODE IS NOT AN ANSWER. `SerialSettlePolicy` decides which node to
    /// try and when to give up; what makes an attempt successful is CFGSHOW
    /// replying, because the node reappears seconds before the firmware is reading
    /// lines.
    static func settle(
        flashedPort: String
    ) async -> Result<String, WifiConfigUI.ConfigFailure> {
        for attempt in 0...SerialSettlePolicy.attempts {
            let ports = WifiConfigUI.candidatePorts()
            let step = SerialSettlePolicy.step(
                attempt: attempt, flashedPort: flashedPort, ports: ports)
            switch step {
            case .waitAndRetry(let seconds):
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            case .use(let port):
                if case .answered = probeExistingFirmware(port: port) {
                    return .success(port)
                }
                try? await Task.sleep(
                    nanoseconds: UInt64(SerialSettlePolicy.retryWait * 1_000_000_000))
            case .ambiguous, .giveUp:
                return .failure(WifiConfigUI.ConfigFailure(
                    title: "The board did not come back",
                    message: SerialSettlePolicy.explain(step, flashedPort: flashedPort)
                        ?? "The board did not answer after restarting."))
            }
            if Task.isCancelled { break }
        }
        return .failure(WifiConfigUI.ConfigFailure(
            title: "The board did not come back",
            message: SerialSettlePolicy.explain(.giveUp, flashedPort: flashedPort)
                ?? "The board did not answer after restarting."))
    }
}
