import Foundation

/// Bringing a board that has never been on the network up over USB: every part of
/// it that is a decision rather than a process spawn or a serial write.
///
/// THE CHICKEN AND EGG THIS CLOSES. A panel becomes a sidebar entry by being
/// discovered on the network, and it can only join the network once it has
/// credentials, which until now could only be given to a panel that was already
/// selected in the sidebar. A board straight out of its box satisfies neither
/// half, so the only way in was the command line. This is the path that does not
/// need one: pick the USB device, let the app read the chip off the board, write
/// the firmware the app ships with, then hand it the WiFi credentials over the
/// same cable. The board reboots, joins, advertises `_espdisp._udp`, and the
/// discovery that already exists puts it in the sidebar.
///
/// Pure: no AppKit, no Process, no serial I/O and no clock. `UsbOnboarder` in
/// SenderCore owns all of that, and it asks these types what to do.
public enum UsbOnboarding {

    // MARK: - what the app knows

    /// What asking the board which chip it is has produced so far.
    ///
    /// Three-valued on purpose. "Not asked yet" and "asked and could not tell"
    /// lead to different words and different buttons, and collapsing them would
    /// mean either nagging about a failure that has not happened or hiding one
    /// that has.
    public enum ChipDetection: Equatable, Sendable {
        case notAttempted
        /// esptool answered. The MAC is nil when the output did not carry one.
        case detected(chip: String, mac: String?)
        /// It was asked and could not say, with esptool's own reason.
        case failed(reason: String)

        public var chip: String? {
            if case .detected(let chip, _) = self { return chip }
            return nil
        }
    }

    /// Whether the esp32 core's esptool could be found.
    ///
    /// Carries where it looked, because "install the esp32 core" is only
    /// actionable if the person can see that the app looked somewhere they do not
    /// keep it.
    public enum ToolAvailability: Equatable, Sendable {
        case installed(path: String)
        case missing(searched: [String])
    }

    /// What the board on the port said when asked to identify itself with
    /// CFGSHOW.
    ///
    /// This is how "adopt a board that already works" and "onboard a blank one"
    /// are told apart without asking the user which they are doing.
    public enum ExistingFirmware: Equatable, Sendable {
        case notChecked
        /// It answered, so it is already running display_stream. The name is empty
        /// when the board has not been given one.
        case answered(name: String)
        /// Nothing answered. A blank board looks like this - and so does a board
        /// running something else entirely, which is why this does not by itself
        /// authorise a write.
        case silent
    }

    /// What the user asked for. Both are legitimate, and which one is offered
    /// first is decided by `suggestedMode`.
    public enum Mode: String, Equatable, Sendable, CaseIterable, Identifiable {
        /// Write the firmware, then hand over the credentials. What a new board
        /// needs.
        case flashAndConfigure
        /// Leave the firmware alone and only hand over the credentials. What a
        /// board that already runs this firmware needs - moving it to a new
        /// network, or adopting one somebody else set up.
        case configureOnly

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .flashAndConfigure: return "Flash firmware and set up WiFi"
            case .configureOnly: return "Set up WiFi only"
            }
        }
    }

    /// Which mode to offer for a board that answered, or did not.
    ///
    /// A BOARD THAT ALREADY WORKS IS NOT RE-FLASHED BY DEFAULT. It answered
    /// CFGSHOW, so its firmware is fine and the thing it is missing is
    /// credentials; writing flash to fix a WiFi password would be a much larger
    /// action than the one asked for. Flashing stays one click away.
    ///
    /// A board that said nothing gets the flash offered, because that is what a
    /// blank board looks like - but nothing here writes anything on its own. The
    /// user confirms with the sheet's own button either way.
    public static func suggestedMode(for existing: ExistingFirmware) -> Mode {
        switch existing {
        case .answered: return .configureOnly
        case .silent, .notChecked: return .flashAndConfigure
        }
    }

    /// Whether there is enough to send for the chosen network.
    ///
    /// A NETWORK NAME IS NOT A CREDENTIAL. The blank-password case is genuinely
    /// ambiguous - it means "the network is open" for one user and "I have not
    /// typed it yet" for another - so the sheet says which and this carries the
    /// answer, rather than the plan guessing from an empty string. `.keepCurrent`
    /// is a real choice too: re-flashing a board leaves its NVS alone, so the
    /// password already on it can still be the right one.
    public enum Credential: Equatable, Sendable {
        /// A network is named and its password has not been given yet.
        case incomplete
        case ready(ConfigCommands.PasswordChange)

        public var passwordChange: ConfigCommands.PasswordChange? {
            if case .ready(let change) = self { return change }
            return nil
        }
    }

    /// Everything the sheet knows at the moment the plan is asked for.
    public struct Request: Equatable, Sendable {
        /// The chosen serial port. Empty when none is chosen, which is a case
        /// rather than an assertion because an empty port must never reach
        /// esptool.
        public var port: String
        /// Every serial device currently enumerated, so "nothing is plugged in"
        /// and "nothing is picked" can be two different sentences.
        public var availablePorts: [String]
        public var mode: Mode
        public var tool: ToolAvailability
        /// The bundle to write, embedded or chosen. Nil when neither is available.
        public var bundle: FirmwareBundle?
        public var detection: ChipDetection
        public var existing: ExistingFirmware
        /// The network to join. Empty when none is chosen.
        public var ssid: String
        /// Whether the credential for that network is complete.
        public var credential: Credential

        public init(
            port: String,
            availablePorts: [String] = [],
            mode: Mode,
            tool: ToolAvailability,
            bundle: FirmwareBundle?,
            detection: ChipDetection,
            existing: ExistingFirmware,
            ssid: String,
            credential: Credential = .ready(.keepCurrent)
        ) {
            self.port = port
            self.availablePorts = availablePorts
            self.mode = mode
            self.tool = tool
            self.bundle = bundle
            self.detection = detection
            self.existing = existing
            self.ssid = ssid
            self.credential = credential
        }
    }

    // MARK: - the serial half

    /// One configuration command to send over the cable after the flash.
    public struct ConfigStep: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            case name
            case wifi
        }

        public let kind: Kind
        /// The line to write, already built by `ConfigCommands`.
        public let command: String
        /// What to say while it is in flight.
        public let label: String
    }

    /// The commands to send, in the order they must be sent.
    ///
    /// WIFI GOES LAST, and the ordering is the whole reason this is a function
    /// rather than two calls at a call site. Both handlers in
    /// display_stream.ino end the same way - `Serial.flush(); delay(200);
    /// ESP.restart()` (CFGWIFI at :762, CFGNAME at :797) - so each one costs a
    /// reboot and a wait for the USB CDC device to come back. Sending the name
    /// last would mean the final reboot is the one that renames, and the board
    /// would arrive on the network under the name, reboot, and arrive again;
    /// sending WiFi last means the last reboot is the one that joins, which is
    /// the event the sidebar is waiting for.
    ///
    /// An empty name produces no name step at all rather than a step that sets
    /// an empty name: the firmware would sanitise it to nothing and fall back to
    /// espdisplay-XXXX, so sending it would spend a reboot to achieve what not
    /// sending it achieves.
    public static func configurationSteps(
        name: String, ssid: String, password: ConfigCommands.PasswordChange
    ) -> [ConfigStep] {
        var steps: [ConfigStep] = []
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            steps.append(ConfigStep(
                kind: .name,
                command: ConfigCommands.setName(trimmedName),
                label: "Naming the display \"\(trimmedName)\"…"))
        }
        steps.append(ConfigStep(
            kind: .wifi,
            command: ConfigCommands.setWifi(ssid: ssid, password: password),
            label: "Sending the WiFi credentials…"))
        return steps
    }
}

/// What onboarding would do with what the app currently knows, in words, and how
/// far it can get.
///
/// The same shape as `FirmwareUpdatePlan` and for the same two reasons: a view
/// cannot be tested, and the awkward answers here have to be told apart. "This
/// bundle has no image for this chip" is the wrong file; "this bundle is an
/// over-the-air bundle" is the right file for a different job; "the chip could
/// not be read" is neither, it is a board that is not listening. Each one has a
/// different fix and none of them is "cannot add device".
///
/// A DEFINITE CONTRADICTION REFUSES; MISSING INFORMATION DOES NOT - the stance
/// `classify_ota_target` takes in tools/espdisp.py and `availability` takes in
/// FirmwareBundle. So a chip that has not been read yet is a step to take, while
/// a chip that has been read and has no image is a refusal.
public struct UsbOnboardingPlan: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Ready: write the firmware and then hand over the credentials.
        case flash
        /// Ready: the board already runs this firmware, so only credentials.
        case configureOnly
        /// No USB device is chosen. First thing the sheet asks for.
        case chooseDevice
        /// No serial port is chosen and none is connected either, which is a
        /// different sentence: nothing to pick, rather than nothing picked.
        case connectDevice
        /// The chip has not been read yet. A step, not a problem.
        case detectChip
        /// It was read and could not be determined.
        case chipUnreadable
        /// No firmware bundle at all: the app shipped without one and none was
        /// chosen.
        case chooseBundle
        /// The bundle has no image for the chip on the cable. The wrong file.
        case noImageForChip
        /// The bundle carries an image for this chip but cannot bring up a blank
        /// board - a generation-1, over-the-air-only file.
        case bundleIsOTAOnly
        /// The esp32 core's esptool is not installed, so nothing can be written.
        case esptoolMissing
        /// No network chosen, so the board would come up unable to join.
        case chooseNetwork
        /// A network is chosen and its password has not been given.
        case enterPassword
        /// Configure-only was asked for and the board never answered, so there is
        /// nothing on the other end to configure.
        case boardNotAnswering
    }

    public let headline: String
    public let detail: String
    public let action: Action

    /// Whether the sheet's confirm button may do anything.
    public var canStart: Bool {
        switch action {
        case .flash, .configureOnly:
            return true
        case .chooseDevice, .connectDevice, .detectChip, .chipUnreadable,
             .chooseBundle, .noImageForChip, .bundleIsOTAOnly, .esptoolMissing,
             .chooseNetwork, .enterPassword, .boardNotAnswering:
            return false
        }
    }

    /// The verb on the button, so it says what will happen rather than "OK" for
    /// both a flash and a WiFi change.
    public var verb: String {
        switch action {
        case .configureOnly: return "Set Up WiFi"
        default: return "Flash and Add"
        }
    }

    /// Whether this is a write to flash rather than a configuration change, which
    /// is what makes the confirmation deliberate.
    public var writesFlash: Bool { action == .flash }

    /// Classify.
    public static func make(_ request: UsbOnboarding.Request) -> UsbOnboardingPlan {
        // A port first, whatever the mode: everything below it talks to a board.
        if request.port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard !request.availablePorts.isEmpty else {
                return UsbOnboardingPlan(
                    headline: "Connect the board",
                    detail: "No USB serial device is connected to this Mac. Plug "
                        + "the board in with a data cable - a charge-only cable "
                        + "powers it without appearing here - and press Refresh.",
                    action: .connectDevice)
            }
            return UsbOnboardingPlan(
                headline: "Choose the USB device",
                detail: "Pick the board's serial device above. Nothing is sent to "
                    + "a device this app picked by itself, which is deliberate: "
                    + "esptool will choose one on its own if it is not told, and "
                    + "the wrong choice writes firmware to somebody's working "
                    + "board.",
                action: .chooseDevice)
        }

        switch request.mode {
        case .configureOnly:
            if case .silent = request.existing {
                return UsbOnboardingPlan(
                    headline: "Nothing answered on that device",
                    detail: "Setting up WiFi only needs a board that is already "
                        + "running this firmware, and this one did not answer. "
                        + "Choose \"\(UsbOnboarding.Mode.flashAndConfigure.label)\" "
                        + "to write the firmware first.",
                    action: .boardNotAnswering)
            }
            if let plan = networkPlan(request) { return plan }
            return UsbOnboardingPlan(
                headline: "Send the WiFi credentials",
                detail: describeExisting(request.existing)
                    + "Its credentials for \"\(request.ssid)\" are sent over the "
                    + "cable, and it restarts and joins. The firmware on it is "
                    + "left alone.",
                action: .configureOnly)

        case .flashAndConfigure:
            // The tool before the chip, because reading the chip is itself an
            // esptool run: without it there is no detection to wait for.
            if case .missing(let searched) = request.tool {
                return UsbOnboardingPlan(
                    headline: "The esp32 core is not installed",
                    detail: "Writing a board over USB uses the esptool that comes "
                        + "with the Arduino esp32 core, and it was not found"
                        + describeSearched(searched)
                        + " Install it with \"arduino-cli core install "
                        + "esp32:esp32\". Until then, tools/espdisp.py flash does "
                        + "the same job from a terminal.",
                    action: .esptoolMissing)
            }
            guard let bundle = request.bundle else {
                return UsbOnboardingPlan(
                    headline: "No firmware to write",
                    detail: "This copy of the app did not come with a firmware "
                        + "bundle, so choose an .espdispfw file - or build one "
                        + "with tools/espdisp.py bundle.",
                    action: .chooseBundle)
            }
            switch request.detection {
            case .notAttempted:
                return UsbOnboardingPlan(
                    headline: "Read the board",
                    detail: "The chip is read off the board rather than chosen "
                        + "from a list, so the right image is written whichever "
                        + "board this is.",
                    action: .detectChip)
            case .failed(let reason):
                return UsbOnboardingPlan(
                    headline: "Could not tell what this board is",
                    detail: "esptool could not read the chip: \(reason) A board "
                        + "in the middle of booting, a cable that only carries "
                        + "power, or another program holding the port all look "
                        + "like this. Nothing is written to a board that has not "
                        + "said what it is.",
                    action: .chipUnreadable)
            case .detected(let chip, _):
                guard bundle.image(forChip: chip) != nil else {
                    return UsbOnboardingPlan(
                        headline: "Nothing in this firmware for this board",
                        detail: "This board is an \(chip). The bundle carries "
                            + "\(describe(bundle.chips)). Choose a bundle that "
                            + "includes \(chip), or build one with "
                            + "tools/espdisp.py bundle --board.",
                        action: .noImageForChip)
                }
                guard let writes = bundle.flashPlan(forChip: chip) else {
                    return UsbOnboardingPlan(
                        headline: "This bundle cannot set up a blank board",
                        detail: "It is a format 1 bundle: it carries the "
                            + "application image and not the bootloader, "
                            + "partition table and boot_app0 a board that has "
                            + "never been flashed also needs. It is still a good "
                            + "over-the-air update. Build a current one with "
                            + "tools/espdisp.py bundle.",
                        action: .bundleIsOTAOnly)
                }
                if let plan = networkPlan(request) { return plan }
                let bytes = writes.reduce(0) { $0 + $1.payload.count }
                return UsbOnboardingPlan(
                    headline: "Write \(bundle.firmwareVersion) to this \(chip)",
                    detail: describeExisting(request.existing)
                        + "\(writes.count) parts, \(bytes) bytes, are written in "
                        + "one go at the addresses the bundle carries. Then the "
                        + "credentials for \"\(request.ssid)\" go over the same "
                        + "cable and the board restarts, joins, and appears in "
                        + "the sidebar by itself.",
                    action: .flash)
            }
        }
    }

    /// The network check, shared by both modes so they cannot drift.
    ///
    /// A board with no credentials boots into whatever `wifi_config.h` its builder
    /// compiled in - possibly somebody else's network, possibly the checked-in
    /// placeholders - and then never appears in the sidebar. Refusing here is what
    /// makes the flow end where the user expects it to.
    private static func networkPlan(_ request: UsbOnboarding.Request) -> UsbOnboardingPlan? {
        if request.ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return UsbOnboardingPlan(
                headline: "Choose the WiFi network",
                detail: "The board needs credentials of its own to reach this Mac. "
                    + "The images in a bundle carry whatever network their builder "
                    + "compiled in, which is why they are sent separately, and the "
                    + "board's own saved network wins on the next boot.",
                action: .chooseNetwork)
        }
        if request.credential == .incomplete {
            return UsbOnboardingPlan(
                headline: "Enter the password for \"\(request.ssid)\"",
                detail: "Or say the network is open, if it has no password. A blank "
                    + "field is not read as an open network here: sending an empty "
                    + "password to a board that needs one leaves it unable to join "
                    + "and nothing on screen to say why.",
                action: .enterPassword)
        }
        return nil
    }

    private static func describeExisting(_ existing: UsbOnboarding.ExistingFirmware) -> String {
        switch existing {
        case .answered(let name) where !name.isEmpty:
            return "This board already runs this firmware and calls itself "
                + "\"\(name)\". "
        case .answered:
            return "This board already runs this firmware and has no name yet. "
        case .silent, .notChecked:
            return ""
        }
    }

    private static func describeSearched(_ searched: [String]) -> String {
        guard !searched.isEmpty else { return "." }
        return " under \(searched.joined(separator: " or "))."
    }

    /// `esp32c6`, or `esp32c6 and esp32s3`. Same phrasing as
    /// `FirmwareUpdatePlan.describe`, so a bundle described in two places reads
    /// the same way twice.
    private static func describe(_ chips: [String]) -> String {
        switch chips.count {
        case 0: return "no images at all"
        case 1: return "an image for \(chips[0])"
        default:
            let last = chips[chips.count - 1]
            let rest = chips.dropLast().joined(separator: ", ")
            return "images for \(rest) and \(last)"
        }
    }
}
