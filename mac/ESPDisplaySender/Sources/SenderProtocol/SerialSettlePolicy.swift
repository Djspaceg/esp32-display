import Foundation

/// When to talk to a board again after it has been reset, and which device node to
/// talk to.
///
/// THIS EXISTS BECAUSE THE PORT PATH IS NOT THE BOARD. The same physical board was
/// observed on this machine at /dev/cu.usbmodem1101 and then, after esptool's hard
/// resets, at /dev/cu.usbmodem101. So a flow that flashes a board and then writes
/// to the path it flashed can be writing to a path that no longer exists, or - if
/// something else was plugged in meanwhile - to a different board. Every step
/// re-enumerates and decides again.
///
/// AND THE NODE COMING BACK IS NOT THE FIRMWARE BEING READY. Three things happen
/// in sequence after `--after hard-reset`: the chip resets, the new firmware boots
/// and brings up USB CDC, and only then does it start reading serial lines.
/// display_stream.ino brings up the panel, the WiFi stack and mDNS in `setup()`
/// before its loop reaches `processConfigLine`, and its own WiFi attempt is a
/// bounded 30-second wait (display_stream.ino:1832). A CFGWIFI written into the
/// node the instant it appears has nothing listening for it. So the caller's loop
/// is: wait, choose a node, ask CFGSHOW, and only treat an answer as proof.
///
/// THE BUDGET IS WALL-CLOCK. Each look that finds a node spends up to three
/// seconds on CFGSHOW, so a budget counted in attempts said "about twenty
/// seconds" and could wait ninety. The caller stops at `budgetSeconds` of real
/// time whatever the attempt count, and `attempts` is only a backstop. What is
/// measured is that the node name changed across a reset, and that a board which
/// booted with nobody reading answers its first CFGSHOW behind a truncated log
/// backlog (see `ConfigCommands.reply(in:)`). The budget covers the firmware's
/// own bounded 30-second WiFi wait in `setup()` plus boot.
public enum SerialSettlePolicy {

    /// What to do on this attempt.
    public enum Step: Equatable, Sendable {
        /// Talk to this node.
        case use(port: String)
        /// Nothing usable yet. Sleep this long and ask again.
        case waitAndRetry(seconds: Double)
        /// Several candidates and no way to tell which is the board that was just
        /// written. Refuses rather than picking, for the same reason esptool is
        /// never run without `--port`.
        case ambiguous(ports: [String])
        /// Several candidates, and the board's hardware ID is known: ask each
        /// one and take the one that reports it. CFGSHOW only reads.
        case identify(ports: [String])
        /// The budget is spent.
        case giveUp
    }

    /// How long to wait before the first look, whatever the node list says.
    ///
    /// The node from before the reset can still be present for a moment after it,
    /// so looking immediately can find a path that is about to go away. Waiting
    /// first is what makes the first answer meaningful.
    public static let initialWait = 2.0

    /// Between attempts after that.
    public static let retryWait = 0.75

    /// A backstop on looks at the device list; `budgetSeconds` is what ends a
    /// wait in practice.
    public static let attempts = 80

    /// The whole wait, in seconds of real time from the restart.
    public static let budgetSeconds = 45.0

    /// Decide.
    ///
    /// `attempt` counts from 0. `flashedPort` is the node the board was on before
    /// the reset, which is a hint and never an assumption; `ports` is a fresh
    /// enumeration.
    /// `canIdentify` says the caller knows the board's hardware ID, which is what
    /// makes asking several candidates safe instead of a guess.
    public static func step(
        attempt: Int, flashedPort: String, ports: [String], canIdentify: Bool = false
    ) -> Step {
        guard attempt >= 0 else { return .waitAndRetry(seconds: initialWait) }
        guard attempt < attempts else { return .giveUp }
        // Always wait once before believing anything, including on a machine where
        // the node never disappeared.
        if attempt == 0 { return .waitAndRetry(seconds: initialWait) }
        if ports.contains(flashedPort) { return .use(port: flashedPort) }
        // The path moved, which is the measured behaviour. One candidate is the
        // board.
        if ports.count == 1 { return .use(port: ports[0]) }
        if ports.isEmpty { return .waitAndRetry(seconds: retryWait) }
        return canIdentify ? .identify(ports: ports) : .ambiguous(ports: ports)
    }

    /// What to tell the user when the budget runs out, or when the answer is
    /// ambiguous. Written here so the sheet and any other caller say the same
    /// thing. `wroteFirmware` is false for a WiFi-only run, where nothing was
    /// written and saying "the firmware was written" would be false.
    public static func explain(
        _ step: Step, flashedPort: String, wroteFirmware: Bool = true,
        sentName: Bool = false
    ) -> String? {
        switch step {
        case .use, .waitAndRetry, .identify:
            return nil
        case .ambiguous(let ports):
            return "After the restart, \(ports.count) USB serial devices were "
                + "connected and \(flashedPort) was not one of them, so there is "
                + "no way to tell which one is this board. Unplug the others and "
                + "try again, or set the network from the board's own "
                + "Connection section once it appears."
        case .giveUp where !wroteFirmware && sentName:
            return "The board did not answer within "
                + "\(Int(budgetSeconds.rounded())) seconds of the restart. Its "
                + "name was saved, but its WiFi network was not sent."
        case .giveUp where !wroteFirmware:
            return "The board did not answer as this firmware within "
                + "\(Int(budgetSeconds.rounded())) seconds, so nothing was sent "
                + "and nothing was written. If it is blank or runs other "
                + "firmware, choose \"Flash firmware and set up WiFi\"."
        case .giveUp:
            return "The board did not answer within "
                + "\(Int(budgetSeconds.rounded())) seconds of the restart. The "
                + "firmware was written\(sentName ? " and the name was saved" : "")"
                + ", but its WiFi network was not sent."
        }
    }

    /// What to do after a give-up that `explain` does not already say: the way
    /// back to sending the WiFi network. Never a replug, because a board on a
    /// battery keeps running when unplugged. A WiFi-only run that does not
    /// hear the board reads its chip with esptool before sending anything,
    /// and esptool restarts it after that read. The run needs esptool for a
    /// board that does not answer, and says so when it is missing.
    public static func nextAction(
        afterGivingUp wroteFirmware: Bool, sentName: Bool
    ) -> String? {
        if wroteFirmware { return restartAndResend }
        return sentName ? resendWifiOnly : nil
    }

    /// From a run that flashed: switch to the WiFi-only run.
    public static let restartAndResend =
        "Choose \"Set up WiFi only\" and press Set Up WiFi: if the board is "
        + "still not answering, the app restarts it over USB before sending "
        + "anything."

    /// From a WiFi-only run: the same run again.
    public static let resendWifiOnly =
        "Press Set Up WiFi again: if the board is still not answering, the app "
        + "restarts it over USB before sending anything."

    // MARK: - a board its firmware does not recognise

    /// Whether a line from the board says its firmware found no profile for
    /// the board it is running on. Such a board keeps its panel, network and
    /// streaming off and refuses every configuration command until told which
    /// board it is, so the wait for it to answer is over: it has answered.
    ///
    /// Two lines say it: the refusal every command gets
    /// (serial_config.cpp, `CFGERR profile unresolved; ...`), and the boot
    /// line before it (display_stream.ino, `board: FATAL no unique compatible
    /// profile; ...`). Searched for rather than matched at the start, for the
    /// truncated-backlog reason `ConfigCommands.reply(in:)` gives.
    public static func isUnrecognisedBoard(_ line: String) -> Bool {
        line.contains("CFGERR profile unresolved")
            || line.contains("board: profile unresolved")
            || line.contains("board: FATAL no unique compatible profile")
    }

    /// What to tell the person about a board its firmware does not recognise,
    /// in words: no command, sketch or setting names. `wroteFirmware` is false
    /// when this run installed nothing, where "installed fine" would be false.
    public struct Explanation: Equatable, Sendable {
        public var title: String
        public var message: String
        public var nextAction: String
    }

    public static func unrecognisedBoard(wroteFirmware: Bool) -> Explanation {
        Explanation(
            title: "This firmware doesn't recognise this board",
            message: wroteFirmware
                ? "The firmware installed fine, but this firmware version doesn't "
                    + "recognise this board, so its screen, WiFi and streaming stay off."
                : "The firmware on it doesn't recognise this board, so its screen, "
                    + "WiFi and streaming are off.",
            nextAction: "Install a firmware version that supports this board. Until "
                + "then it stays as it is; it is not harmed, and it can be written "
                + "again at any time.")
    }
}
