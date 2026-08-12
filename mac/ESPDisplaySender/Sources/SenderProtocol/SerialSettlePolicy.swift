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
/// UNVERIFIED: no board has been flashed from this app, so the timings below are
/// chosen from the sequence rather than measured against it. What IS measured is
/// that the node name changed across a reset, which is the property the policy is
/// shaped around. The budget is generous for that reason - being slow costs a few
/// seconds on a path a user runs once per board, and being early costs a board
/// that came up with the wrong credentials and no obvious way to tell.
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

    /// Attempts, including the initial wait. 24 attempts at 0.75s after a 2s wait
    /// is about twenty seconds, which covers a board that boots, initialises a
    /// panel and starts servicing serial.
    public static let attempts = 24

    /// The whole budget, for a message that says how long it waited.
    public static var budgetSeconds: Double {
        initialWait + Double(attempts - 1) * retryWait
    }

    /// Decide.
    ///
    /// `attempt` counts from 0. `flashedPort` is the node the board was on before
    /// the reset, which is a hint and never an assumption; `ports` is a fresh
    /// enumeration.
    public static func step(
        attempt: Int, flashedPort: String, ports: [String]
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
        return .ambiguous(ports: ports)
    }

    /// What to tell the user when the budget runs out, or when the answer is
    /// ambiguous. Written here so the sheet and any other caller say the same
    /// thing.
    public static func explain(_ step: Step, flashedPort: String) -> String? {
        switch step {
        case .use, .waitAndRetry:
            return nil
        case .ambiguous(let ports):
            return "After the restart, \(ports.count) USB serial devices were "
                + "connected and \(flashedPort) was not one of them, so there is "
                + "no way to tell which one is this board. Unplug the others and "
                + "try again, or set the network from the display's own "
                + "Connection section once it appears."
        case .giveUp:
            return "The board did not answer within "
                + "\(Int(budgetSeconds.rounded())) seconds of the restart. The "
                + "firmware was written; only the WiFi credentials are missing. "
                + "Unplug and reconnect the board and use Set Up WiFi only, or "
                + "send them with tools/espdisp.py config."
        }
    }
}
