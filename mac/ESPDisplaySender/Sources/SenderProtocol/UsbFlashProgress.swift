import Foundation

/// What a USB flash or onboarding run is doing, in words a person can act on.
///
/// Every phase names a step the user could see go wrong: a board that is never
/// found, one that will not enter download mode, a write that stops at a part, a
/// board that restarts and never answers. The failure report built from the
/// phase that was running is what turns "it did not work" into which step, what
/// was last seen, and what to do next.
public enum UsbFlashPhase: Equatable, Sendable {
    /// Re-reading the board's identity and chip before anything is written.
    case findingBoard
    /// esptool is resetting the board into its ROM loader.
    case enteringDownloadMode
    /// A whole-chip erase, only when asked for.
    case erasing
    case writing(FlashPartProgress)
    /// esptool has written a part and is checking its hash.
    case verifying(FlashPartProgress)
    /// esptool is resetting the board out of the loader into what was written.
    case restarting
    case waitingForBoard(SettleWait)
    /// A configuration line is going down the cable; the label says which.
    case configuring(String)

    public var title: String {
        switch self {
        case .findingBoard:
            return "Finding the board"
        case .enteringDownloadMode:
            return "Putting the board in download mode"
        case .erasing:
            return "Erasing the flash"
        case .writing(let part):
            return "Writing \(part.partName) (part \(part.index) of \(part.count))"
        case .verifying(let part):
            return "Verifying \(part.partName) (part \(part.index) of \(part.count))"
        case .restarting:
            return "Restarting the board"
        case .waitingForBoard:
            return "Waiting for the board to answer"
        case .configuring(let label):
            return label
        }
    }

    /// The second line under the title, when there is more to say.
    public var detail: String? {
        switch self {
        case .writing(let part):
            return part.percent.map { "\($0)% of \(part.partName)" }
        case .waitingForBoard(let wait):
            return wait.summary
        default:
            return nil
        }
    }

    /// How far through the whole write, 0...1, weighted by bytes so the
    /// two-megabyte application is not one quarter of the bar.
    public var fraction: Double? {
        switch self {
        case .writing(let part), .verifying(let part):
            return part.overallFraction
        case .waitingForBoard(let wait):
            return wait.budget > 0 ? min(1, wait.elapsed / wait.budget) : nil
        default:
            return nil
        }
    }
}

/// One part of a multi-part write, and how far through it esptool is.
public struct FlashPartProgress: Equatable, Sendable {
    /// 1-based, in address order.
    public var index: Int
    public var count: Int
    public var role: String
    public var address: Int
    public var percent: Int?
    /// Bytes in the parts before this one, this one, and all of them.
    public var bytesBefore: Int
    public var bytes: Int
    public var totalBytes: Int

    public init(
        index: Int, count: Int, role: String, address: Int, percent: Int?,
        bytesBefore: Int, bytes: Int, totalBytes: Int
    ) {
        self.index = index
        self.count = count
        self.role = role
        self.address = address
        self.percent = percent
        self.bytesBefore = bytesBefore
        self.bytes = bytes
        self.totalBytes = totalBytes
    }

    public var partName: String {
        switch role {
        case "app": return "the application"
        case "bootloader": return "the bootloader"
        case "partitions": return "the partition table"
        case "boot_app0": return "the boot selector"
        default: return role
        }
    }

    public var overallFraction: Double {
        guard totalBytes > 0 else { return 0 }
        let done = Double(bytesBefore) + Double(bytes) * Double(percent ?? 0) / 100
        return min(1, done / Double(totalBytes))
    }
}

/// Turns esptool's output, line by line, into the phase it describes.
///
/// Both spellings esptool has used are read: 4.x prints
/// `Writing at 0x00010000... (12 %)` and 5.x
/// `Writing at 0x00010000 [=====>   ] 12.3% 4096/1234567 bytes...`. What they
/// share - `Writing at 0x`, `Wrote ... at 0x`, `Hash of data verified`,
/// `Hard resetting` - is all this matches on, and a line it does not recognise
/// changes nothing, so an unfamiliar version degrades to fewer phase changes
/// rather than wrong ones.
public struct EsptoolFlashTracker: Equatable, Sendable {
    public struct Part: Equatable, Sendable {
        public var role: String
        public var address: Int
        public var size: Int
        public init(role: String, address: Int, size: Int) {
            self.role = role
            self.address = address
            self.size = size
        }
    }

    public let parts: [Part]
    public private(set) var phase: UsbFlashPhase?

    public init(parts: [Part]) {
        self.parts = parts.sorted { $0.address < $1.address }
    }

    /// The new phase if this line changed it, else nil.
    public mutating func consume(_ line: String) -> UsbFlashPhase? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: UsbFlashPhase?
        if trimmed.hasPrefix("Connecting") {
            next = .enteringDownloadMode
        } else if trimmed.hasPrefix("Erasing flash") || trimmed.hasPrefix("Chip erase") {
            next = .erasing
        } else if let address = Self.address(after: "Writing at 0x", in: trimmed) {
            next = progress(at: address, percent: EsptoolOutput.percentage(in: trimmed))
                .map(UsbFlashPhase.writing)
        } else if trimmed.hasPrefix("Wrote "),
                  let address = Self.address(after: " at 0x", in: trimmed) {
            next = progress(at: address, percent: 100).map(UsbFlashPhase.verifying)
        } else if trimmed.hasPrefix("Hard resetting") || trimmed.hasPrefix("Leaving") {
            next = .restarting
        } else {
            next = nil
        }
        guard let next, next != phase else { return nil }
        phase = next
        return next
    }

    private func progress(at address: Int, percent: Int?) -> FlashPartProgress? {
        // The part a write address falls in: the last one starting at or below it.
        guard let index = parts.lastIndex(where: { $0.address <= address }) else {
            return nil
        }
        let part = parts[index]
        return FlashPartProgress(
            index: index + 1, count: parts.count, role: part.role,
            address: part.address, percent: percent,
            bytesBefore: parts[..<index].reduce(0) { $0 + $1.size },
            bytes: part.size,
            totalBytes: parts.reduce(0) { $0 + $1.size })
    }

    private static func address(after marker: String, in line: String) -> Int? {
        guard let range = line.range(of: marker) else { return nil }
        let hex = line[range.upperBound...].prefix { $0.isHexDigit }
        return hex.isEmpty ? nil : Int(hex, radix: 16)
    }
}

/// What the settle loop is waiting for, for how long, and what it last saw.
public struct SettleWait: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        /// No serial device is present yet; the board was on this one.
        case reappear(flashedPort: String)
        /// This node is present and CFGSHOW has not been answered on it yet.
        case answer(port: String)
        /// The node moved and several are present: each is asked for its ID.
        case identify(ports: [String])
    }

    public var target: Target
    /// 1-based count of looks at the device list.
    public var attempt: Int
    public var elapsed: Double
    public var budget: Double
    /// The last thing the board said, or why nothing was heard.
    public var lastSeen: String?

    public init(
        target: Target, attempt: Int, elapsed: Double, budget: Double,
        lastSeen: String? = nil
    ) {
        self.target = target
        self.attempt = attempt
        self.elapsed = elapsed
        self.budget = budget
        self.lastSeen = lastSeen
    }

    public var waitingFor: String {
        switch target {
        case .reappear(let port):
            return "the board's USB serial device to come back (it was \(port))"
        case .answer(let port):
            return "the firmware on \(port) to answer CFGSHOW"
        case .identify(let ports):
            return "one of \(ports.count) USB serial devices to report this board's ID"
        }
    }

    public var summary: String {
        "Waiting for \(waitingFor) · attempt \(attempt) · "
            + "\(Int(elapsed.rounded(.down))) of \(Int(budget.rounded())) s"
    }
}

/// Everything esptool printed and every line that crossed the serial port, in
/// order, for the Details disclosure and for copying into a bug report.
public struct UsbFlashTranscript: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case app
        case esptool
        /// A line the app wrote to the board, secrets redacted.
        case sent = "tx"
        /// A line the board wrote.
        case received = "rx"
    }

    public struct Entry: Equatable, Sendable {
        public var elapsed: Double
        public var source: Source
        public var text: String
    }

    /// Enough for a flash plus a full settle budget of log backlog; older lines
    /// go first.
    public static let limit = 4000

    public private(set) var entries: [Entry] = []
    public private(set) var dropped = 0

    public init() {}

    public mutating func append(_ source: Source, _ text: String, at elapsed: Double) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // esptool redraws its progress line hundreds of times; one line per part
        // is what is worth keeping.
        if source == .esptool, text.hasPrefix("Writing at 0x"),
           let last = entries.last, last.source == .esptool,
           last.text.hasPrefix("Writing at 0x") {
            entries[entries.count - 1] = Entry(elapsed: elapsed, source: source, text: text)
            return
        }
        entries.append(Entry(elapsed: elapsed, source: source, text: text))
        if entries.count > Self.limit {
            let excess = entries.count - Self.limit
            entries.removeFirst(excess)
            dropped += excess
        }
    }

    public var text: String {
        var lines: [String] = []
        if dropped > 0 { lines.append("(\(dropped) earlier lines dropped)") }
        for entry in entries {
            lines.append(String(format: "[%7.2f] %@ %@",
                                entry.elapsed,
                                entry.source.rawValue.padding(
                                    toLength: 7, withPad: " ", startingAt: 0),
                                entry.text))
        }
        return lines.joined(separator: "\n")
    }

    /// The last `count` lines from these sources, oldest first.
    public func last(_ count: Int, from sources: Set<Source>) -> [String] {
        Array(entries.filter { sources.contains($0.source) }.suffix(count).map(\.text))
    }
}

/// One thing that happened during a run.
public enum UsbFlashEvent: Equatable, Sendable {
    case phase(UsbFlashPhase)
    case log(UsbFlashTranscript.Source, String)
}

/// Which step failed, what was last seen, and one thing to do about it.
public struct UsbFlashFailure: Equatable, Sendable {
    public var title: String
    public var message: String
    /// The phase title that was running, e.g. "Writing the application (part 4 of 4)".
    public var step: String
    public var lastSeen: [String]
    public var nextAction: String
}

/// The state of one run, reduced from its events. A value, so the sheet's view
/// of it and a test's are the same thing.
public struct UsbFlashSession: Equatable, Sendable {
    public enum Flow: Equatable, Sendable {
        /// Add Display: flash, then name and credentials.
        case onboarding
        /// Add Display on a board that already runs this firmware: name and
        /// credentials only, nothing written to flash.
        case configureOnly
        /// Firmware Update over USB: flash, then wait for the board to answer.
        case update
    }

    public let flow: Flow
    public private(set) var phase: UsbFlashPhase?
    public private(set) var transcript = UsbFlashTranscript()
    public private(set) var failure: UsbFlashFailure?

    public init(flow: Flow) {
        self.flow = flow
    }

    public mutating func apply(_ event: UsbFlashEvent, at elapsed: Double) {
        switch event {
        case .phase(let next):
            // Wait ticks change every second; only a change of what is being
            // waited for is worth a transcript line.
            let announce: Bool
            if case .waitingForBoard(let old) = phase, case .waitingForBoard(let new) = next {
                announce = old.target != new.target
            } else {
                announce = phase?.title != next.title
            }
            phase = next
            if announce {
                transcript.append(.app, next.title + (next.detail.map { " - \($0)" } ?? ""),
                                  at: elapsed)
            }
        case .log(let source, let text):
            transcript.append(source, text, at: elapsed)
        }
    }

    /// Record the run's failure against whatever phase was running.
    public mutating func fail(
        title: String, message: String, nextAction: String? = nil, at elapsed: Double
    ) {
        // Everything that can fail while the board is being found is a check
        // made before anything is written - a name in use, a missing esptool, a
        // bundle for another chip - as much as a board that is not answering.
        let step: String
        switch phase {
        case .findingBoard, nil: step = "Checking the board before writing"
        case let phase?: step = phase.title
        }
        failure = UsbFlashFailure(
            title: title, message: message, step: step,
            lastSeen: lastSeen,
            nextAction: nextAction ?? defaultNextAction)
        transcript.append(.app, "FAILED during \(step): \(title) - \(message)", at: elapsed)
    }

    private var lastSeen: [String] {
        switch phase {
        case .enteringDownloadMode, .erasing, .writing, .verifying, .restarting:
            return transcript.last(3, from: [.esptool])
        case .waitingForBoard(let wait):
            let received = transcript.last(2, from: [.received])
            if !received.isEmpty { return received }
            return wait.lastSeen.map { [$0] } ?? []
        case .configuring:
            return transcript.last(2, from: [.sent, .received])
        case .findingBoard, nil:
            return transcript.last(3, from: [.esptool, .received])
        }
    }

    private var defaultNextAction: String {
        switch phase {
        case .findingBoard, nil:
            return "Nothing was written. Fix what the message says and try again; "
                + "if the board is not answering, unplug it, plug it back in with "
                + "a data cable (not a charge-only one) and press Refresh."
        case .enteringDownloadMode:
            return "Hold the board's BOOT button while plugging it in (or hold BOOT "
                + "and tap RESET), release it, then try again."
        case .erasing, .writing, .verifying:
            return "Try again: rewriting is safe. If it stops at the same place, "
                + "use another cable or a USB port directly on the Mac, not a hub."
        case .restarting, .waitingForBoard:
            switch flow {
            case .onboarding:
                return "The firmware is written. Unplug the board, plug it back in, "
                    + "then run this again with Set Up WiFi only."
            case .configureOnly:
                return "Unplug the board, plug it back in, and run Set Up WiFi "
                    + "only again."
            case .update:
                return "The firmware is written. Unplug the board and plug it back "
                    + "in; it should answer within a minute."
            }
        case .configuring:
            return "Unplug the board, plug it back in, then run this again with "
                + "Set Up WiFi only to resend the settings."
        }
    }
}

extension ConfigCommands {
    /// A command as it may appear in a transcript: passwords replaced.
    public static func redactedForLog(_ command: String) -> String {
        var words = command.split(separator: " ", omittingEmptySubsequences: false)
            .map(String.init)
        guard let verb = words.first else { return command }
        let secretIndex: Int?
        switch verb {
        case "CFGWIFI": secretIndex = 2
        case "CFGWIFISET": secretIndex = 3
        case "CFGOTAPW": secretIndex = words.count > 1 && words[1] == "clear" ? nil : 1
        default: secretIndex = nil
        }
        if let secretIndex, words.count > secretIndex, !words[secretIndex].isEmpty,
           words[secretIndex] != "-" {
            words[secretIndex] = "<hidden>"
        }
        return words.joined(separator: " ")
    }
}
