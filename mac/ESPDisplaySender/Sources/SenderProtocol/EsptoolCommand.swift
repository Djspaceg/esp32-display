import Foundation

/// The esptool invocation that writes a blank board, as data rather than as a
/// string, plus everything about building it that is a decision.
///
/// WHY THIS APP SHELLS OUT AT ALL, since the OTA push next door is native Swift.
/// `espota` was worth writing natively: it is one UDP invitation, one
/// challenge/response and a chunked TCP stream, and `EspotaProtocol` is 430 lines
/// of it. The serial bootloader is not that. It is SLIP framing, ROM loader sync,
/// stub upload, per-block compressed writes, MD5 verification and flash
/// detection, and a mistake anywhere in it is a board that does not boot. The
/// esp32 core already ships a native arm64 esptool that does all of it and is the
/// program the core's own upload recipe runs, so this spawns that instead.
///
/// The accepted cost, stated rather than hidden: USB flashing from the app needs
/// the esp32 core installed, which the OTA path does not. `UsbOnboardingPlan`
/// has a case for its absence that names the fix, and the sheet shows it.
///
/// THE ARGV IS THE CORE'S OWN, from esp32 core 3.3.11 platform.txt line 346
/// (`tools.esptool_py.upload.pattern_args`), read off this machine and reproduced
/// here verbatim so the two can be compared:
///
///     --chip {build.mcu} --port "{serial.port}" --baud {upload.speed}
///     {upload.flags} --before default-reset --after hard-reset write-flash
///     {upload.erase_cmd} -z --flash-mode keep --flash-freq keep --flash-size
///     keep {build.bootloader_addr} "{build.path}/{name}.bootloader.bin"
///     0x8000 "{build.path}/{name}.partitions.bin"
///     0xe000 "{runtime.platform.path}/tools/partitions/boot_app0.bin"
///     0x10000 "{build.path}/{name}.bin" {upload.extra_flags}
///
/// Placeholders as boards.txt resolves them for the two boards this repo
/// supports: `build.mcu` is esp32c6 or esp32s3, `upload.flags` and
/// `upload.extra_flags` are empty for both, `upload.erase_cmd` is empty unless
/// the EraseFlash menu asks for `-e`, and there is no bare `upload.speed` key -
/// the default is the first UploadSpeed menu entry, 921600 for both boards.
///
/// FOUR DELIBERATE DIFFERENCES FROM THE RECIPE, each with a reason:
///
///   - platform.txt line 347 wraps all of it in `python3
///     {runtime.platform.path}/tools/flasher.py`. This does not use that wrapper.
///     It only resolves `--esptool` and `--build-dir`, both of which are already
///     known here, and it would reintroduce a python3 dependency on a path whose
///     whole appeal is being a single native binary.
///   - The paths are not quoted, because argv is built as a list and handed to
///     `Process`. Quoting exists in platform.txt because that line becomes a
///     shell command; there is no shell here, so a quote would become part of
///     the filename.
///   - The addresses come from the bundle rather than from this file. boards.txt
///     puts the bootloader at 0x0 for esp32c6 (:812) and esp32s3 (:1183) and at
///     0x1000 on a classic ESP32, and it is the partition table being written in
///     the same run that decides the app lives at 0x10000.
///   - `--chip` is the detected chip, never `auto`. esptool then refuses a
///     mismatch, which is the same free cross-check `resolve_board` in
///     tools/espdisp.py relies on.
public struct EsptoolCommand: Equatable, Sendable {
    /// The program to run.
    public let executable: String
    /// Its arguments, in order, already resolved. Never a shell string.
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// The whole invocation as one line, for a log or a progress panel.
    ///
    /// FOR READING, NOT FOR RUNNING. Arguments containing a space are quoted so
    /// the line can be understood, which is exactly the transformation that
    /// would be wrong to feed back to a shell. Nothing in this app parses it.
    public var displayLine: String {
        ([executable] + arguments).map { argument in
            argument.contains(" ") ? "\"\(argument)\"" : argument
        }.joined(separator: " ")
    }

    // MARK: - constants

    /// The first UploadSpeed menu entry for both boards, which is what the core
    /// uses when nobody chooses (boards.txt esp32c6:942, esp32s3:1378).
    public static let defaultBaud = 921_600

    /// The reset behaviour from the recipe. `--after hard-reset` is what leaves
    /// the board running what was just written instead of sitting in the
    /// bootloader.
    public static let beforeReset = "default-reset"
    public static let afterReset = "hard-reset"

    // MARK: - the tool

    /// Which esptool was found, and what its command spellings are.
    ///
    /// Keying the spelling off the `.py` extension is the inference
    /// `tools/espdisp.py esptool_path()` already makes and says so: esptool 5.x
    /// ships a native binary called `esptool`, 4.x ships a Python script called
    /// `esptool.py`. Measured on the 5.3.1 binary here, both spellings work and
    /// the hyphen is canonical (`write_flash` answers with "Deprecated: Command
    /// 'write_flash' is deprecated"); 4.x accepted only the underscore.
    ///
    /// UNVERIFIED: no 4.x esptool is installed on this machine, so the script
    /// path - the interpreter, the underscore spellings and whether
    /// /usr/bin/python3 can run it - has not been exercised. It is written this
    /// way because getting it wrong for a 4.x core costs a confusing failure and
    /// the shape is read off espdisp.py rather than guessed.
    public struct Tool: Equatable, Sendable {
        /// Absolute path to the esptool binary or to esptool.py.
        public let path: String

        public init(path: String) {
            self.path = path
        }

        public var isPythonScript: Bool { path.hasSuffix(".py") }

        /// macOS's own python3 by absolute path. A GUI app's PATH is
        /// /usr/bin:/bin:/usr/sbin:/sbin, so a bare `python3` would not resolve
        /// to Homebrew's anyway.
        public static let pythonPath = "/usr/bin/python3"

        var executable: String { isPythonScript ? Self.pythonPath : path }
        var leadingArguments: [String] { isPythonScript ? [path] : [] }
        var writeFlashSubcommand: String { isPythonScript ? "write_flash" : "write-flash" }
        var chipIDSubcommand: String { isPythonScript ? "chip_id" : "chip-id" }
    }

    /// One payload staged on disk, ready to be named in the argv. esptool takes
    /// paths rather than stdin, which is why the bytes a bundle already holds in
    /// memory have to be written out first.
    public struct StagedWrite: Equatable, Sendable {
        /// The `FirmwareBundle.FlashWrite` role this came from, for messages and
        /// for the staged filename.
        public let role: String
        /// The flash address, taken from the bundle.
        public let address: Int
        /// Where the payload was staged.
        public let path: String

        public init(role: String, address: Int, path: String) {
            self.role = role
            self.address = address
            self.path = path
        }
    }

    /// The filename a write is staged under, inside a directory of its own.
    ///
    /// Indexed so the directory listing is in write order, and the role is in the
    /// name so a failure that names a file is readable. Pure, so the staging code
    /// and its test agree on the names without one asking the other.
    public static func stagedFilename(index: Int, role: String) -> String {
        String(format: "%02d-%@.bin", index, role)
    }

    /// Flash addresses as the recipe writes them: lowercase hex with an `0x`
    /// prefix and no padding, so 0x8000 and 0xe000 look like platform.txt's.
    public static func hexAddress(_ address: Int) -> String {
        "0x" + String(address, radix: 16)
    }

    // MARK: - builders

    /// The write-flash invocation for a set of staged payloads.
    ///
    /// Throws rather than returning an optional so each refusal can say which
    /// thing was wrong; every one of them is a programming error caught before a
    /// process is spawned, which is the entire point - see `noPort`.
    public static func writeFlash(
        tool: Tool,
        chip: String,
        port: String,
        baud: Int = defaultBaud,
        writes: [StagedWrite],
        eraseAll: Bool = false
    ) throws -> EsptoolCommand {
        let chip = chip.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.path.isEmpty else { throw EsptoolCommandError.noTool }
        guard !chip.isEmpty else { throw EsptoolCommandError.noChip }
        // THE SAFETY CHECK THIS TYPE EXISTS FOR. esptool 5.x does not fail when
        // --port is missing: it auto-discovers, prints "Found 2 serial ports..."
        // and picks one itself. That was established here by accident, by a
        // write-flash run with no --port that connected to the board on the desk
        // unasked. So an empty port is refused before anything is spawned, and
        // `port` below is never optional and never omitted.
        guard !port.isEmpty else { throw EsptoolCommandError.noPort }
        guard baud > 0 else { throw EsptoolCommandError.badBaud(baud) }
        guard !writes.isEmpty else { throw EsptoolCommandError.nothingToWrite }

        var seen: [Int: String] = [:]
        for write in writes {
            guard !write.path.isEmpty else {
                throw EsptoolCommandError.writeWithoutFile(role: write.role)
            }
            guard write.address >= 0 else {
                throw EsptoolCommandError.negativeAddress(
                    role: write.role, address: write.address)
            }
            if let other = seen[write.address] {
                throw EsptoolCommandError.duplicateAddress(
                    role: write.role, other: other, address: write.address)
            }
            seen[write.address] = write.role
        }

        var arguments = tool.leadingArguments
        arguments += [
            "--chip", chip,
            "--port", port,
            "--baud", String(baud),
            "--before", beforeReset,
            "--after", afterReset,
            tool.writeFlashSubcommand,
        ]
        // {upload.erase_cmd}, which is EMPTY in the core's default upload and is
        // only `-e` when the board's EraseFlash menu asks for it. It stays a
        // deliberate choice here for the same reason: it erases the whole chip,
        // including the NVS a configured board keeps its credentials in.
        if eraseAll { arguments.append("-e") }
        arguments += [
            "-z",
            "--flash-mode", "keep",
            "--flash-freq", "keep",
            "--flash-size", "keep",
        ]
        // In the order given, which `FirmwareBundle.flashPlan` has already put in
        // ascending address order. The partition table and the app travel in one
        // invocation because the table is what says where the app lives: a
        // factory board read here had its app at 0x110000 and nothing at all at
        // 0x10000, so writing the app against the old table would put an image
        // inside what that table calls NVS.
        for write in writes {
            arguments += [hexAddress(write.address), write.path]
        }
        return EsptoolCommand(executable: tool.executable, arguments: arguments)
    }

    /// The read-only probe that asks a board what it is.
    ///
    /// Same `--port` rule, and for the same reason: without it esptool picks a
    /// board for you, and a probe that silently talked to the wrong one would
    /// then choose the image for a flash of the right one.
    public static func chipID(
        tool: Tool, port: String, connectAttempts: Int = 2
    ) throws -> EsptoolCommand {
        let port = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.path.isEmpty else { throw EsptoolCommandError.noTool }
        guard !port.isEmpty else { throw EsptoolCommandError.noPort }
        guard connectAttempts > 0 else {
            throw EsptoolCommandError.badConnectAttempts(connectAttempts)
        }
        var arguments = tool.leadingArguments
        arguments += [
            "--port", port,
            "--connect-attempts", String(connectAttempts),
            tool.chipIDSubcommand,
        ]
        return EsptoolCommand(executable: tool.executable, arguments: arguments)
    }
}

/// Why an invocation was refused before it ran.
///
/// Every case is something the app got wrong rather than something the user did,
/// so the messages name the missing piece plainly and do not suggest a fix the
/// user could apply. They exist as cases rather than as one assertion because
/// `noPort` in particular must be a refusal that can be tested for.
public enum EsptoolCommandError: Error, LocalizedError, Equatable {
    case noTool
    case noPort
    case noChip
    case nothingToWrite
    case writeWithoutFile(role: String)
    case duplicateAddress(role: String, other: String, address: Int)
    case negativeAddress(role: String, address: Int)
    case badBaud(Int)
    case badConnectAttempts(Int)

    public var errorDescription: String? {
        switch self {
        case .noTool:
            return "No esptool was given to run."
        case .noPort:
            return "No serial port was given. esptool would pick one by itself, "
                + "which could write firmware to the wrong board, so this is "
                + "refused instead."
        case .noChip:
            return "No chip was given, and this app never passes --chip auto: "
                + "naming the chip is what makes esptool refuse the wrong board."
        case .nothingToWrite:
            return "There is nothing to write."
        case .writeWithoutFile(let role):
            return "The \(role) payload was not staged to a file."
        case .duplicateAddress(let role, let other, let address):
            return "\(role) and \(other) would both be written to "
                + "\(EsptoolCommand.hexAddress(address)); only the last one "
                + "would survive."
        case .negativeAddress(let role, let address):
            return "The \(role) payload has a negative flash address (\(address))."
        case .badBaud(let baud):
            return "\(baud) is not a usable serial speed."
        case .badConnectAttempts(let attempts):
            return "\(attempts) connection attempts is not a usable number."
        }
    }
}
