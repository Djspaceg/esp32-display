import Foundation
import SenderProtocol

/// What to tell the person when the board on a USB port did not answer the
/// check made before reading or writing it, as words rather than as the
/// commands behind them.
enum UsbBoardCheck {
    /// The board sits in ROM download mode: it is reachable by esptool but
    /// runs no firmware, so it cannot answer. `restartPort` lets the sheet
    /// offer to restart it.
    static func flashingMode(path: String, nothingDone: String) -> OperationOutcome {
        var outcome = OperationOutcome.failure(
            "The board is in flashing mode",
            "The board on \(path) is waiting to be flashed instead of running its "
                + "firmware, so it could not be checked and \(nothingDone). Restart it "
                + "to go back to its firmware, then try again.")
        outcome.restartPort = path
        outcome.nextAction = "Press Restart the board, or its reset button, then try "
            + "again. Nothing on the board was changed."
        return outcome
    }

    /// Nothing answered, and the board is not in flashing mode either.
    static func unanswered(path: String, reason: String, nothingDone: String) -> OperationOutcome {
        let plain = plainReason(reason).map { " (\($0))" } ?? ""
        var outcome = OperationOutcome.failure(
            "The board did not answer over USB",
            "The board on \(path) did not answer\(plain), so \(nothingDone). Check "
                + "that it is on and running its firmware, then try again.")
        outcome.nextAction = "Restart the board with its power or reset button, wait "
            + "for its screen, then try again."
        return outcome
    }

    /// The board answered, but its firmware does not recognise the board it
    /// is on, so it refuses to say who it is. Not silence, and not fixed by a
    /// restart; its own refusal names firmware commands, so it is not shown.
    static func unrecognised(nothingDone: String) -> OperationOutcome {
        let explanation = SerialSettlePolicy.unrecognisedBoard(wroteFirmware: false)
        var outcome = OperationOutcome.failure(
            explanation.title,
            "The firmware on this board doesn't recognise it, so its screen, WiFi and "
                + "streaming are off. It could not be checked, so \(nothingDone).")
        outcome.nextAction = explanation.nextAction
        outcome.showsLastSeen = false
        return outcome
    }

    /// The probe's reason without the firmware's command and sketch names:
    /// a parenthetical naming one is dropped, and a reason still naming one
    /// is left out altogether.
    static func plainReason(_ reason: String) -> String? {
        let internalName = "CFG[A-Z]+|display_stream"
        let trimmed = reason
            .replacingOccurrences(
                of: "\\s*\\([^)]*(\(internalName))[^)]*\\)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.range(of: internalName, options: .regularExpression) == nil
        else { return nil }
        return trimmed
    }

    /// Whether a read-only esptool connect that left the chip as it was found
    /// the expected board waiting in download mode: it connected, and to that
    /// board's MAC. Running firmware does not answer esptool's sync.
    static func isInFlashingMode(_ outcome: EsptoolRunner.Outcome, expectedID: String) -> Bool {
        outcome.succeeded
            && ConfigCommands.canonicalHardwareID(EsptoolOutput.macAddress(in: outcome.output))
                == ConfigCommands.canonicalHardwareID(expectedID)
    }
}

extension PanelManager {

    /// Why the board on `path` did not answer its check: in flashing mode, or
    /// silent. Asks with one read-only esptool connect that neither resets
    /// the chip before nor after, so a board in download mode stays there and
    /// one running firmware is not restarted.
    func explainUnansweredBoard(
        path: String, expectedID: String, reason: String, nothingDone: String
    ) async -> OperationOutcome {
        if SerialSettlePolicy.isUnrecognisedBoard(reason) {
            return UsbBoardCheck.unrecognised(nothingDone: nothingDone)
        }
        guard case .installed(let toolPath) = EsptoolInstallation.locate(),
              let command = try? EsptoolCommand.chipID(
                  tool: EsptoolCommand.Tool(path: toolPath), port: path, connectAttempts: 1,
                  before: EsptoolCommand.noReset, after: EsptoolCommand.noReset)
        else { return UsbBoardCheck.unanswered(path: path, reason: reason, nothingDone: nothingDone) }
        let outcome = try? await Task.detached { try await EsptoolRunner.run(command) }.value
        if let outcome, UsbBoardCheck.isInFlashingMode(outcome, expectedID: expectedID) {
            return UsbBoardCheck.flashingMode(path: path, nothingDone: nothingDone)
        }
        // esptool's sync packets hold no newline, so firmware that is running
        // keeps them at the head of its command line and ignores the next
        // command behind them. One empty line clears them.
        _ = await Task.detached {
            WifiConfigUI.sendCommand("", port: path, timeout: 0.3, log: nil)
        }.value
        return UsbBoardCheck.unanswered(path: path, reason: reason, nothingDone: nothingDone)
    }

    /// Take a board out of flashing mode and back to its firmware, writing
    /// nothing. First a connect that resets nothing proves the board on
    /// `port` is this one, in flashing mode, on the same USB device the
    /// failure saw (`expectedGeneration`); only then a second connect hard
    /// resets it. Then its firmware is asked whether it is back.
    func restartBoardFromFlashingMode(
        port: String, hardwareID: String, expectedGeneration: Int?
    ) async -> OperationOutcome {
        func refusal(_ message: String) -> OperationOutcome {
            .failure("Could not restart the board", message)
        }
        guard let expectedID = ConfigCommands.canonicalHardwareID(hardwareID) else {
            return refusal("This board has no hardware ID to check the restart against.")
        }
        guard usbPathGeneration(port) == expectedGeneration else {
            return refusal("The USB device on \(port) changed since the board was checked, so "
                + "nothing was done. Try again to check it afresh.")
        }
        let tool: EsptoolCommand.Tool
        guard case .installed(let toolPath) = EsptoolInstallation.locate() else {
            return refusal("Restarting over USB uses the esptool included with the Arduino "
                + "esp32 core, and it was not found.")
        }
        tool = EsptoolCommand.Tool(path: toolPath)
        guard let check = try? EsptoolCommand.chipID(
                  tool: tool, port: port, connectAttempts: 2,
                  before: EsptoolCommand.noReset, after: EsptoolCommand.noReset),
              let reset = try? EsptoolCommand.chipID(
                  tool: tool, port: port, connectAttempts: 2,
                  before: EsptoolCommand.noReset, after: EsptoolCommand.afterReset)
        else { return refusal("The restart command could not be built for \(port).") }
        beginUSBFlash(hardwareID: expectedID)
        defer {
            finishUSBFlash(hardwareID: expectedID, wroteFlash: false)
            refreshUSBPorts()
        }
        let checked = try? await Task.detached { try await EsptoolRunner.run(check) }.value
        guard let checked, UsbBoardCheck.isInFlashingMode(checked, expectedID: expectedID) else {
            return refusal("The board on \(port) is not in flashing mode, or is not this board, "
                + "so it was left as it is. Try again to check it afresh.")
        }
        let restarted = try? await Task.detached { try await EsptoolRunner.run(reset) }.value
        guard let restarted, restarted.succeeded else {
            return refusal("esptool could not restart the board on \(port). "
                + (restarted.flatMap { EsptoolOutput.failureSummary(in: $0.output) } ?? ""))
        }
        // Its firmware needs a few seconds before it answers on USB again.
        for _ in 0..<4 {
            try? await Task.sleep(for: .seconds(2))
            refreshUSBPorts()
            guard usbDevices.contains(where: { $0.path == port }) else { continue }
            if case .identified(let identity) = await probeUSBDevice(port, timeout: 2),
               ConfigCommands.canonicalHardwareID(identity.hardwareID) == expectedID {
                return .success("The board restarted", "It is running its firmware again; "
                    + "try again.")
            }
        }
        return .success("The board restarted", "It has not answered yet. Wait for its screen, "
            + "then try again.")
    }

}
