import CryptoKit
import Foundation

/// Repairing a board whose firmware kills its own USB right after boot: every
/// part of it that is a decision rather than a process, a pty or a port.
///
/// Such a board is on USB for well under a second to a few seconds per plug-in,
/// and esptool spends about four seconds starting up. So esptool is started
/// BEFORE the plug-in with `open_port_attempts = 0`, which makes it retry
/// opening its port every 0.1 s, forever and silently. Its port is a symlink
/// that does not exist until a new USB port appears; the link is then pointed
/// at that port, esptool resets the chip into ROM download mode, whose USB
/// stays up, and writes the family's rescue image. When the board drops off
/// first, the link is removed and the same esptool keeps waiting.
///
/// The same design as `tools/espdisp.py rescue` (`run_rescue`), which was
/// proven on hardware first; the names here follow it so the two can be read
/// side by side. `UsbRescuer` in SenderCore owns the processes and the loop.
///
/// The app asks for at most one physical action, the family's
/// `downloadModeAction`, and departs from the CLI to keep it to one: what is
/// attached at Start is fixed then, so a board put in download mode while
/// esptool starts is still new, and a port the user names (a board already on
/// USB, or one found again by Resume) is taken whatever the baseline says.
/// Every later reset is esptool's, over USB.
public enum UsbRescue {

    // MARK: - constants shared with tools/espdisp.py

    /// How often the port list and esptool's output are read.
    public static let pollSeconds = 0.01
    /// esptool reports nothing while it retries, so a linked port that has not
    /// connected by then is given up on: wrong family, not an Espressif chip,
    /// or a board that never enters download mode.
    public static let connectTimeout = 10.0
    /// Failed writes in a row on one port before it is left alone, as a port
    /// that never connects is: a board of another family fails at once, every
    /// time, and relaunching resets it every few seconds for nothing.
    public static let failuresBeforeRefusal = 3
    /// How long esptool may take once it has said "Connected to". The rescue
    /// image is under half a megabyte, written in seconds even at 460800 baud.
    public static let writeTimeout = 120.0
    /// Four connect attempts per pass: on a USB-UART bridge esptool cycles
    /// through four reset sequences, and every pass starts that cycle over.
    public static let esptoolConfig = "[esptool]\nopen_port_attempts = 0\nconnect_attempts = 4\n"
    /// Printed once esptool has failed its first open and settled into waiting.
    public static let readyMarker = "Retrying failed connection"
    public static let connectedMarker = "Connected to"
    public static let indexName = "rescue.json"
    public static let indexFormat = 1
    /// Every rescue image is exactly these four writes, the app at 0x10000.
    public static let roles = ["bootloader", "partitions", "boot_app0", "app"]
    public static let appAddress = 0x10000

    // MARK: - families

    /// A chip family the app carries a rescue image for.
    public struct Family: Equatable, Hashable, Sendable, Identifiable {
        public let key: String
        public let chip: String
        /// The family's upload speed. P4 sets UploadSpeed=460800 in its FQBN
        /// (tools/generated_board_catalog.py `p4-4b`); the rest use the core's
        /// default, 921600.
        public let baud: Int

        public var id: String { key }

        /// "ESP32-S3", as the chip is printed on the module.
        public var displayName: String { "ESP32-" + key.uppercased() }

        public init(key: String, chip: String, baud: Int) {
            self.key = key
            self.chip = chip
            self.baud = baud
        }

        public static let all: [Family] = ["c3", "c6", "s3", "p4"].compactMap { key in
            guard let expected = GeneratedBoardCatalog.expected[key] else { return nil }
            return Family(
                key: key, chip: expected.chip,
                baud: key == "p4" ? 460_800 : EsptoolCommand.defaultBaud)
        }

        public static func named(_ key: String?) -> Family? {
            guard let key else { return nil }
            return all.first { $0.key == key }
        }

        /// The one thing the person does to put a board of this family into
        /// ROM download mode, whose USB stays up until esptool resets it. Never
        /// a replug: a board with a battery does not restart when unplugged.
        ///
        /// From the vendors' pages (Waveshare, Elecrow): the S3 displays come
        /// with either a RESET button or, on the battery boards with a power
        /// chip (1.75-inch AMOLED, 0.85, 1.54), a PWR button and no RESET. The
        /// C6 boards have BOOT and RESET. The P4 boards reach the chip through a
        /// CH343 USB-UART bridge, whose DTR and RTS lines let esptool reset the
        /// chip into download mode with nothing pressed.
        public var downloadModeAction: String {
            switch key {
            case "s3":
                return "With a RESET (RST) button: hold BOOT, press and release RESET, "
                    + "then release BOOT. With a PWR button and no RESET (the 1.75-inch "
                    + "AMOLED, 0.85-inch and 1.54-inch boards, which keep running on "
                    + "their battery): hold PWR until the screen goes dark, then hold "
                    + "BOOT, press PWR, and release BOOT once the board is on."
            case "p4":
                return "Nothing to press: the board's USB-UART bridge lets esptool reset "
                    + "it into download mode by itself. Connect its UART USB port; if "
                    + "it is connected already, choose that port."
            default:
                return "Hold BOOT, press and release RESET (RST), then release BOOT."
            }
        }

        /// The family a chip token names, when exactly one does.
        public static func forChip(_ chip: String?) -> Family? {
            let matches = all.filter { $0.chip == chip }
            return matches.count == 1 ? matches[0] : nil
        }
    }

    // MARK: - the image

    /// One verified write of a rescue image.
    public struct Region: Equatable, Sendable {
        public let address: Int
        public let role: String
        public let path: String
        public let bytes: Int
    }

    public enum ImageError: Error, LocalizedError, Equatable {
        case missing(family: String, reason: String)
        case malformed(String)
        case mismatch(file: String)

        public var errorDescription: String? {
            switch self {
            case .missing(let family, let reason):
                return "This copy of the app has no usable rescue firmware for "
                    + "ESP32-\(family.uppercased()) (\(reason))."
            case .malformed(let reason):
                return "The rescue firmware index is not usable: \(reason)."
            case .mismatch(let file):
                return "The rescue firmware file \(file) does not match its index."
            }
        }
    }

    /// The verified writes for one family's rescue image in `directory`
    /// (`firmware-rescue/<family>/`, or the app's copy of it).
    ///
    /// Refuses anything that is not exactly the four bundle-style regions, for
    /// this family's chip, byte-identical to what the index recorded - the
    /// checks `load_rescue_images` makes.
    public static func loadImage(family: Family, directory: URL) throws -> [Region] {
        let indexURL = directory.appendingPathComponent(indexName)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL))
        } catch {
            throw ImageError.missing(family: family.key, reason: error.localizedDescription)
        }
        guard let index = object as? [String: Any],
              (index["format"] as? Int) == indexFormat
        else { throw ImageError.malformed("unsupported index format") }
        guard index["family"] as? String == family.key,
              index["chip"] as? String == family.chip
        else {
            throw ImageError.malformed("it describes \(index["family"] ?? "?")/"
                + "\(index["chip"] ?? "?"), not \(family.key)/\(family.chip)")
        }
        guard let entries = index["regions"] as? [[String: Any]],
              entries.count == roles.count,
              entries.map({ $0["role"] as? String ?? "" }).sorted() == roles.sorted()
        else {
            throw ImageError.malformed("it must list exactly " + roles.joined(separator: ", "))
        }
        var regions: [Region] = []
        for entry in entries {
            let role = entry["role"] as? String ?? "?"
            guard let address = entry["address"] as? Int, address >= 0 else {
                throw ImageError.malformed("\(role) has no valid address")
            }
            guard let name = entry["file"] as? String, !name.isEmpty,
                  (name as NSString).lastPathComponent == name
            else { throw ImageError.malformed("\(role) has no valid file name") }
            let url = directory.appendingPathComponent(name)
            guard let blob = try? Data(contentsOf: url) else {
                throw ImageError.missing(family: family.key, reason: "\(name) is missing")
            }
            let digest = SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
            guard blob.count == entry["bytes"] as? Int,
                  digest == entry["sha256"] as? String
            else { throw ImageError.mismatch(file: name) }
            regions.append(Region(address: address, role: role, path: url.path, bytes: blob.count))
        }
        guard regions.first(where: { $0.role == "app" })?.address == appAddress else {
            throw ImageError.malformed("the app must be written at 0x10000")
        }
        guard Set(regions.map(\.address)).count == regions.count else {
            throw ImageError.malformed("two regions share one flash address")
        }
        return regions.sorted { $0.address < $1.address }
    }

    // MARK: - which port

    /// Ports present now that were not attached before the plug-in.
    public static func newPorts<S: Sequence, T: Sequence>(
        baseline: S, present: T
    ) -> [String] where S.Element == String, T.Element == String {
        let known = Set(baseline)
        return Set(present).filter { !known.contains($0) }.sorted()
    }

    /// The USB device behind a serial port: where it is plugged and its serial
    /// number, which may be empty.
    public struct USBIdentity: Hashable, Sendable {
        public let location: Int
        public let serial: String

        public init(location: Int, serial: String) {
            self.location = location
            self.serial = serial
        }
    }

    /// The device behind a /dev/cu.* name, or nil when it cannot be told.
    /// Only the fallback: `UsbRescuer.usbDevice(forPort:)` asks the IORegistry
    /// which device publishes the port, and that answer is used when it has one.
    ///
    /// macOS names a CDC port usbmodem<serial><interface> when the device has
    /// a usable serial number (5B90170069 is usbmodem5B901700691), otherwise
    /// usbmodem<location in hex, trailing zero nibbles dropped><interface>
    /// (0x14100000 is usbmodem14101, 0x00100000 usbmodem101). Many bridge ports
    /// are usbserial-<serial>. The interface is one or two digits, which is what
    /// keeps location 0x00100000 ("1") from claiming usbmodem1312201.
    public static func identity(forPort port: String, devices: [USBIdentity]) -> USBIdentity? {
        func isInterface<S: StringProtocol>(_ rest: S) -> Bool {
            (1...2).contains(rest.count) && rest.allSatisfy(\.isNumber)
        }
        let name = (port as NSString).lastPathComponent
        var best: USBIdentity?
        if name.hasPrefix("cu.usbmodem") {
            let suffix = name.dropFirst("cu.usbmodem".count).lowercased()
            for device in devices where !device.serial.isEmpty {
                let token = device.serial.lowercased()
                if suffix.hasPrefix(token), isInterface(suffix.dropFirst(token.count)) {
                    return device
                }
            }
            var bestToken = ""
            for device in devices where device.location != 0 {
                var token = String(device.location, radix: 16)
                while token.hasSuffix("0") { token.removeLast() }
                if suffix.hasPrefix(token), isInterface(suffix.dropFirst(token.count)),
                   token.count > bestToken.count {
                    best = device
                    bestToken = token
                }
            }
        } else if name.hasPrefix("cu.usbserial-") {
            let suffix = String(name.dropFirst("cu.usbserial-".count))
            best = devices.last { !$0.serial.isEmpty && $0.serial == suffix }
        }
        return best
    }

    /// Whether a port's device was attached before the rescue started. The same
    /// serial is the same board wherever it is plugged; the same location is the
    /// same socket. A port whose device cannot be found is left to the name check.
    public static func isKnown<S: Sequence>(
        _ identity: USBIdentity?, in known: S
    ) -> Bool where S.Element == USBIdentity {
        guard let identity else { return false }
        return known.contains {
            (!identity.serial.isEmpty && identity.serial == $0.serial)
                || identity.location == $0.location
        }
    }

    /// Whether two readings are one USB device: by serial when both have
    /// one, else by socket. Stricter than `isKnown`, for which the same socket
    /// is enough: a board chosen by port must not turn out to be another board
    /// plugged into that socket.
    public static func isSameDevice(_ a: USBIdentity, _ b: USBIdentity) -> Bool {
        if !a.serial.isEmpty, !b.serial.isEmpty { return a.serial == b.serial }
        return a.location == b.location
    }

    /// The --port one spawned esptool is given, spelled under /dev/.
    ///
    /// esptool picks its USB Serial/JTAG reset only after matching the port to a
    /// USB device, and esptool 5.1 resolves a symlinked port only under /dev/,
    /// so the link, which lives in a private directory, is named through
    /// /dev/.. . Every spawn gets its own index, so no esptool that outlived its
    /// kill can follow the link meant for the next one.
    public static func linkPath(directory: String, index: Int) -> String {
        // realpath(3), as os.path.realpath: URL.resolvingSymlinksInPath would
        // strip /private and spell the directory differently from the CLI.
        let resolved = realpath(directory, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? directory
        return linkPrefix + resolved + "/port-\(index)"
    }

    private static let linkPrefix = "/dev/.."

    /// Where the file behind a `linkPath` lives, spelled without /dev/.. .
    public static func linkFile(for link: String) -> String {
        link.hasPrefix(linkPrefix + "/") ? String(link.dropFirst(linkPrefix.count)) : link
    }

    // MARK: - what esptool and the rescue image said

    /// The last line that names an error, else the last line at all. esptool
    /// follows a serial exception with a generic note about drivers, which would
    /// otherwise hide the actual error.
    public static func lastError(in tail: String) -> String {
        let lines = tail.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.allSatisfy { $0 == "." } }
        let errors = lines.filter { line in
            line.range(of: "error occurred|errno|could not|failed",
                       options: [.regularExpression, .caseInsensitive]) != nil
                && !line.hasPrefix("Note:") && !line.hasPrefix("For troubleshooting")
        }
        return EsptoolOutput.withoutProgressBar(errors.last ?? lines.last ?? "")
    }

    /// The profile a stored CFGBOARD override forces, from the rescue image's
    /// CFGINFO, or nil when there is none.
    public static func storedOverride(inReply reply: String) -> String? {
        let forced = reply.split(separator: " ").last { $0.hasPrefix("cfgboard=") }
            .map { String($0.dropFirst("cfgboard=".count)) }
        guard let forced, !forced.isEmpty, forced != "auto" else { return nil }
        return forced
    }

    public static let clearOverrideCommand = "CFGBOARD auto"

    /// Whether esptool gave up because the chip is not the one it was told
    /// ("This chip is ESP32-C6, not ESP32-S3. Wrong --chip argument?").
    public static func isWrongChip(_ error: String) -> Bool {
        error.contains("Wrong --chip")
            || error.range(of: "This chip is .+, not ", options: .regularExpression) != nil
    }

    /// esptool's output with terminal control sequences removed. On a pty it
    /// may colour its warnings and redraw its progress bar with escapes.
    public static func strippingTerminalCodes(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}

/// What a repair run is doing, for `UsbFlashPhase.rescue`. Each title is the
/// plain instruction the person holding the board needs at that moment.
public enum UsbRescueStep: Equatable, Sendable {
    /// esptool is starting; a board plugged in now would be missed.
    case startingEsptool
    /// esptool is waiting and the next new port is the board.
    case plugIn
    /// The board dropped off before esptool reached it. `esptoolReady` is false
    /// while a replacement esptool is still starting.
    case missed(esptoolReady: Bool)
    /// A new port appeared while esptool was still starting.
    case seenWhileStarting(port: String)
    /// The link points at the board and esptool is resetting it.
    case caught(port: String)
    /// esptool never connected to this port within `UsbRescue.connectTimeout`.
    case couldNotConnect(port: String, family: String)
    /// More than one new port appeared; none is touched.
    case tooManyPorts([String])
    /// The rescue image is written and running on this port.
    case rescued(port: String)
    /// The rescue image has been asked what board it is on.
    case readingBoard(port: String)

    public var title: String {
        switch self {
        case .startingEsptool:
            return "Starting esptool"
        case .plugIn:
            return "Waiting for the board"
        case .missed:
            return "The board dropped off before esptool reached it"
        case .seenWhileStarting:
            return "Board seen - esptool is almost ready"
        case .caught:
            return "Got it - leave the board as it is"
        case .couldNotConnect:
            return "Could not reach the board"
        case .tooManyPorts:
            return "More than one new USB device appeared"
        case .rescued, .readingBoard:
            return "Rescue firmware is on"
        }
    }

    /// What was going on, for a failure's "Failed while:" line.
    public var activity: String {
        switch self {
        case .startingEsptool: return "Starting esptool"
        case .plugIn, .missed, .seenWhileStarting, .tooManyPorts:
            return "Waiting for the board"
        case .caught: return "Resetting the board into download mode"
        case .couldNotConnect: return "Connecting to the board"
        case .rescued, .readingBoard: return "Reading the repaired board"
        }
    }

    public var detail: String? {
        switch self {
        case .startingEsptool:
            return "This takes a few seconds. The board can be put in download mode "
                + "now; esptool reaches it as soon as it is ready."
        case .plugIn:
            return "esptool is ready and reaches the board the moment it is in "
                + "download mode."
        case .missed(let ready):
            return ready
                ? "esptool is waiting again, and takes the board as soon as it is back."
                : "esptool is starting again."
        case .seenWhileStarting(let port):
            return "Board seen on \(port); esptool reaches it in a moment."
        case .caught(let port):
            return "Board seen on \(port); resetting it into download mode."
        case .couldNotConnect(let port, let family):
            return "esptool gave up on \(port): it did not connect within "
                + "\(Int(UsbRescue.connectTimeout)) s, or its writes kept failing. Is it "
                + "an ESP32-\(family.uppercased()) board?"
        case .tooManyPorts(let ports):
            return "\(ports.count) new USB serial devices appeared "
                + "(\(ports.joined(separator: ", "))); none of them is touched. Choose "
                + "the board's port to go on."
        case .rescued(let port):
            return "The board is running the rescue image on \(port); its USB now "
                + "stays on. Install the real firmware to finish."
        case .readingBoard(let port):
            return "Asking the rescue image on \(port) which board it found."
        }
    }
}
