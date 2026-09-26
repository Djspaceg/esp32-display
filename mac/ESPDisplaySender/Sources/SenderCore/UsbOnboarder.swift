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

    /// Where a run has got to, and every line worth keeping for its transcript.
    /// The phases and their wording live in `UsbFlashPhase`.
    typealias Progress = UsbFlashEvent

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
        port: String, tool: EsptoolCommand.Tool,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async -> UsbOnboarding.ChipDetection {
        let command: EsptoolCommand
        do {
            command = try EsptoolCommand.chipID(tool: tool, port: port)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
        do {
            let outcome = try await EsptoolRunner.run(command) { line in
                onProgress?(.log(.esptool, line))
            }
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
        probe(port: port).existing
    }

    /// What one CFGSHOW on a port found: the answer, the firmware version it
    /// reported, and the last line the port produced when it did not answer.
    struct PortAnswer: Equatable, Sendable {
        var existing: UsbOnboarding.ExistingFirmware
        var firmwareVersion: String?
        var lastLine: String?
    }

    static func probe(
        port: String, log: WifiConfigUI.SerialLog? = nil
    ) -> PortAnswer {
        let lastLine = LastLine()
        let tee: WifiConfigUI.SerialLog = { source, text in
            if source == .received { lastLine.set(text) }
            log?(source, text)
        }
        switch WifiConfigUI.probePort(port, timeout: 3, log: tee) {
        case .identified(let identity):
            return PortAnswer(
                existing: .answered(name: identity.name, hardwareID: identity.hardwareID),
                firmwareVersion: identity.status?.firmwareVersion)
        case .unavailable(let reason):
            return PortAnswer(existing: .silent, lastLine: lastLine.value ?? reason)
        }
    }

    private final class LastLine: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        func set(_ line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            lock.withLock { stored = trimmed }
        }
        var value: String? { lock.withLock { stored } }
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
        onProgress(.phase(.enteringDownloadMode))
        let tracker = TrackerBox(EsptoolFlashTracker(parts: writes.map {
            EsptoolFlashTracker.Part(
                role: $0.role, address: $0.address, size: $0.payload.count)
        }))
        let outcome = try await EsptoolRunner.run(command) { line in
            onProgress(.log(.esptool, line))
            if let phase = tracker.consume(line) { onProgress(.phase(phase)) }
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
    ///
    /// A LINE THAT GOT NO REPLY IS SENT ONCE MORE. Every step here is idempotent
    /// (the same name, the same network), and a reply lost to a board that was
    /// still coming up is otherwise a failed onboarding of a board that is fine.
    /// A CFGERR is a refusal and is never retried.
    static func sendConfiguration(
        steps: [UsbOnboarding.ConfigStep],
        flashedPort: String,
        expectedHardwareID: String? = nil,
        io: SettleIO = .live,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async -> Result<String, WifiConfigUI.ConfigFailure> {
        var port = flashedPort
        for step in steps {
            var tries = 0
            while true {
                tries += 1
                switch await settle(
                    flashedPort: port, expectedHardwareID: expectedHardwareID,
                    io: io, onProgress: onProgress)
                {
                case .success(let board):
                    port = board.port
                case .failure(let failure):
                    return .failure(failure)
                }
                onProgress(.phase(.configuring(step.label)))
                let result = io.send(step.command, port) { source, text in
                    onProgress(.log(source, text))
                }
                switch result {
                case .success:
                    break
                case .failure(let reason) where !reason.hasPrefix("CFGERR") && tries < 2:
                    onProgress(.log(.app, "No reply to \(step.label.lowercased()) "
                        + "(\(reason)); waiting for the board and sending it again."))
                    continue
                case .failure(let reason):
                    return .failure(WifiConfigUI.ConfigFailure(
                        title: "Could not finish setting up the board",
                        message: "The firmware is on it, and \(step.label.lowercased()) "
                            + "did not go through: \(reason)"))
                }
                break
            }
        }
        return .success(port)
    }

    static func matchesExpectedHardwareID(
        _ existing: UsbOnboarding.ExistingFirmware,
        expectedHardwareID: String?
    ) -> Bool {
        guard let expected = ConfigCommands.canonicalHardwareID(expectedHardwareID)
        else {
            if case .answered = existing { return true }
            return false
        }
        guard case .answered(_, let reported) = existing else { return false }
        return ConfigCommands.canonicalHardwareID(reported) == expected
    }

    /// The board, found again after a restart.
    struct SettledBoard: Equatable, Sendable {
        var port: String
        var firmwareVersion: String?
    }

    /// Everything `settle` touches outside itself, so a test can drive it with a
    /// virtual clock and fake ports.
    struct SettleIO: Sendable {
        var ports: @Sendable () -> [String]
        var probe: @Sendable (String, WifiConfigUI.SerialLog?) -> PortAnswer
        var send: @Sendable (String, String, WifiConfigUI.SerialLog?) -> WifiConfigUI.CommandResult
        var sleep: @Sendable (Double) async -> Void
        var now: @Sendable () -> Double
        var isCancelled: @Sendable () -> Bool

        static let live = SettleIO(
            ports: { WifiConfigUI.candidatePorts() },
            probe: { port, log in UsbOnboarder.probe(port: port, log: log) },
            send: { command, port, log in
                WifiConfigUI.sendCommand(command, port: port, log: log, acceptInfo: false)
            },
            sleep: { seconds in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            },
            now: { ProcessInfo.processInfo.systemUptime },
            isCancelled: { Task.isCancelled })
    }

    /// Find the board again and prove it is listening.
    ///
    /// A DEVICE NODE IS NOT AN ANSWER. `SerialSettlePolicy` decides which node to
    /// try; what makes an attempt successful is CFGSHOW replying with the expected
    /// hardware ID, because the node reappears seconds before the firmware is
    /// reading lines. It recovers on its own from the two things measured to
    /// happen - the node being renamed, and a slow first answer - and stops at
    /// `SerialSettlePolicy.budgetSeconds` of real time, reporting each look as it
    /// goes so the sheet can say what it is waiting for.
    static func settle(
        flashedPort: String,
        expectedHardwareID: String? = nil,
        io: SettleIO = .live,
        onProgress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async -> Result<SettledBoard, WifiConfigUI.ConfigFailure> {
        let expectedHardwareID = ConfigCommands.canonicalHardwareID(expectedHardwareID)
        let budget = SerialSettlePolicy.budgetSeconds
        let started = io.now()
        var lastSeen: String?
        var announcedMove = false
        /// Nodes that answered as some other board: not asked again.
        var otherBoards: Set<String> = []
        let log: WifiConfigUI.SerialLog = { source, text in onProgress(.log(source, text)) }

        func report(_ target: SettleWait.Target, attempt: Int) {
            onProgress(.phase(.waitingForBoard(SettleWait(
                target: target, attempt: attempt, elapsed: io.now() - started,
                budget: budget, lastSeen: lastSeen))))
        }

        /// Ask one port; the board if it answers as the expected one.
        func ask(_ port: String) -> SettledBoard? {
            let answer = io.probe(port, log)
            if matchesExpectedHardwareID(answer.existing, expectedHardwareID: expectedHardwareID) {
                return SettledBoard(port: port, firmwareVersion: answer.firmwareVersion)
            }
            if case .answered(_, let reported) = answer.existing {
                otherBoards.insert(port)
                lastSeen = "a different board (ID \(reported ?? "unknown")) answered on \(port)"
            } else {
                lastSeen = answer.lastLine.map { "\(port): \($0)" }
                    ?? "no answer from \(port) within 3 s"
            }
            return nil
        }

        for attempt in 0...SerialSettlePolicy.attempts {
            if io.isCancelled() { break }
            if io.now() - started >= budget { break }
            let ports = io.ports()
            let step = SerialSettlePolicy.step(
                attempt: attempt, flashedPort: flashedPort, ports: ports,
                canIdentify: expectedHardwareID != nil)
            switch step {
            case .waitAndRetry(let seconds):
                report(.reappear(flashedPort: flashedPort), attempt: attempt + 1)
                await io.sleep(seconds)
            case .use(let port):
                report(.answer(port: port), attempt: attempt + 1)
                if port != flashedPort, !announcedMove {
                    announcedMove = true
                    onProgress(.log(.app, "The board moved from \(flashedPort) to \(port)."))
                }
                if let board = ask(port) { return .success(board) }
                await io.sleep(SerialSettlePolicy.retryWait)
            case .identify(let candidates):
                report(.identify(ports: candidates), attempt: attempt + 1)
                // Each silent node costs three seconds, so the budget and Stop
                // are checked per node, not per look.
                for port in candidates where !otherBoards.contains(port) {
                    if io.isCancelled() || io.now() - started >= budget { break }
                    if let board = ask(port) {
                        onProgress(.log(.app, "\(port) reported this board's ID."))
                        return .success(board)
                    }
                }
                await io.sleep(SerialSettlePolicy.retryWait)
            case .ambiguous, .giveUp:
                return .failure(WifiConfigUI.ConfigFailure(
                    title: "The board did not come back",
                    message: SerialSettlePolicy.explain(step, flashedPort: flashedPort)
                        ?? "The board did not answer after restarting."))
            }
        }
        if io.isCancelled() {
            return .failure(WifiConfigUI.ConfigFailure(
                title: "Stopped", message: "Waiting for the board was stopped."))
        }
        return .failure(WifiConfigUI.ConfigFailure(
            title: "The board did not come back",
            message: (SerialSettlePolicy.explain(.giveUp, flashedPort: flashedPort)
                ?? "The board did not answer after restarting.")
                + (lastSeen.map { " Last seen: \($0)." } ?? "")))
    }
}

/// The tracker, shared with esptool's line callback, which runs on another queue.
private final class TrackerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker: EsptoolFlashTracker
    init(_ tracker: EsptoolFlashTracker) { self.tracker = tracker }
    func consume(_ line: String) -> UsbFlashPhase? {
        lock.withLock { tracker.consume(line) }
    }
}
