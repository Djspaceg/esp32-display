import XCTest
@testable import SenderProtocol

/// The esptool invocation, asserted rather than eyeballed.
///
/// The argv is the whole of what this app does to a board, and it is written to
/// match the esp32 core's own upload recipe (platform.txt:346). So the recipe is
/// spelled out here by hand, in one test, in full - the same discipline
/// `espota_command()` is held to in tools/test_espdisp.py. A change to the builder
/// that produces a plausible but different command fails that test rather than
/// being discovered on somebody's board.
final class EsptoolCommandTests: XCTestCase {

    private let tool = EsptoolCommand.Tool(
        path: "/Users/x/Library/Arduino15/packages/esp32/tools/esptool_py/5.3.1/esptool")
    private let port = "/dev/cu.usbmodem101"

    /// The four writes a blank board needs, at the addresses this repo's boards
    /// actually use, staged the way `UsbOnboarder.flash` stages them.
    private var writes: [EsptoolCommand.StagedWrite] {
        [
            .init(role: "bootloader", address: 0x0, path: "/stage/00-bootloader.bin"),
            .init(role: "partitions", address: 0x8000, path: "/stage/01-partitions.bin"),
            .init(role: "boot_app0", address: 0xe000, path: "/stage/02-boot_app0.bin"),
            .init(role: "app", address: 0x10000, path: "/stage/03-app.bin"),
        ]
    }

    // MARK: - the recipe

    func testWriteFlashArgvIsTheCoreRecipe() throws {
        let command = try EsptoolCommand.writeFlash(
            tool: tool, chip: "esp32s3", port: port, writes: writes)

        XCTAssertEqual(command.executable, tool.path)
        XCTAssertEqual(command.arguments, [
            "--chip", "esp32s3",
            "--port", "/dev/cu.usbmodem101",
            "--baud", "921600",
            "--before", "default-reset",
            "--after", "hard-reset",
            "write-flash",
            "-z",
            "--flash-mode", "keep",
            "--flash-freq", "keep",
            "--flash-size", "keep",
            "0x0", "/stage/00-bootloader.bin",
            "0x8000", "/stage/01-partitions.bin",
            "0xe000", "/stage/02-boot_app0.bin",
            "0x10000", "/stage/03-app.bin",
        ])
    }

    /// `--chip` is a GLOBAL option in esptool 5.x and has to precede the
    /// subcommand. Measured: `esptool --help` lists it under the top-level Options
    /// panel, before COMMAND.
    func testGlobalOptionsPrecedeTheSubcommand() throws {
        let command = try EsptoolCommand.writeFlash(
            tool: tool, chip: "esp32c6", port: port, writes: writes)
        let subcommand = try XCTUnwrap(command.arguments.firstIndex(of: "write-flash"))
        for option in ["--chip", "--port", "--baud", "--before", "--after"] {
            let index = try XCTUnwrap(command.arguments.firstIndex(of: option))
            XCTAssertLessThan(index, subcommand, "\(option) must come before the subcommand")
        }
    }

    /// The chip is named, never left to esptool. Passing it is what makes esptool
    /// refuse a board that is not the one the image was chosen for - the same free
    /// cross-check `resolve_board` relies on in the CLI.
    func testChipIsNeverAuto() throws {
        let command = try EsptoolCommand.writeFlash(
            tool: tool, chip: "esp32c6", port: port, writes: writes)
        let chip = try XCTUnwrap(command.arguments.firstIndex(of: "--chip"))
        XCTAssertEqual(command.arguments[chip + 1], "esp32c6")
        XCTAssertFalse(command.arguments.contains("auto"))
    }

    /// platform.txt line 347 wraps the recipe in `python3 .../tools/flasher.py`.
    /// This app runs the binary directly, so nothing about that wrapper may appear.
    func testTheFlasherWrapperIsNotUsed() throws {
        let command = try EsptoolCommand.writeFlash(
            tool: tool, chip: "esp32s3", port: port, writes: writes)
        XCTAssertFalse(command.displayLine.contains("flasher.py"))
        XCTAssertFalse(command.displayLine.contains("--build-dir"))
        XCTAssertFalse(command.displayLine.contains("--esptool"))
    }

    // MARK: - the port, which is a safety property and not a nicety

    /// esptool 5.x does not fail without `--port`. It auto-discovers, prints
    /// "Found 2 serial ports..." and picks one, which was established here by a
    /// write-flash run that connected to the board on the desk unasked. So every
    /// command this type can build carries the port the caller named.
    func testEveryCommandCarriesThePortItWasGiven() throws {
        let write = try EsptoolCommand.writeFlash(
            tool: tool, chip: "esp32s3", port: port, writes: writes)
        let probe = try EsptoolCommand.chipID(tool: tool, port: port)
        for command in [write, probe] {
            let index = try XCTUnwrap(command.arguments.firstIndex(of: "--port"))
            XCTAssertEqual(command.arguments[index + 1], port)
        }
    }

    func testAnEmptyPortIsRefusedBeforeSpawning() {
        for empty in ["", "   ", "\n", "\t "] {
            XCTAssertThrowsError(
                try EsptoolCommand.writeFlash(
                    tool: tool, chip: "esp32s3", port: empty, writes: writes)
            ) { error in
                XCTAssertEqual(error as? EsptoolCommandError, .noPort)
            }
            XCTAssertThrowsError(
                try EsptoolCommand.chipID(tool: tool, port: empty)
            ) { error in
                XCTAssertEqual(error as? EsptoolCommandError, .noPort)
            }
        }
    }

    /// The refusal says why, because the reason is the interesting part: it is not
    /// that the argument is required, it is that omitting it writes to a board
    /// nobody chose.
    func testThePortRefusalSaysWhatWouldHappenInstead() {
        let message = EsptoolCommandError.noPort.errorDescription ?? ""
        XCTAssertTrue(message.contains("pick one by itself"))
        XCTAssertTrue(message.contains("wrong board"))
    }

    func testSurroundingWhitespaceIsTrimmedRatherThanPassedThrough() throws {
        let command = try EsptoolCommand.writeFlash(
            tool: tool, chip: " esp32s3\n", port: " \(port) ", writes: writes)
        let portIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--port"))
        XCTAssertEqual(command.arguments[portIndex + 1], port)
        let chipIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--chip"))
        XCTAssertEqual(command.arguments[chipIndex + 1], "esp32s3")
    }

    // MARK: - erasing, which is destructive and never implicit

    /// `{upload.erase_cmd}` is empty in the core's default upload, so the default
    /// here is empty too. It erases NVS, which is where a board that has been set
    /// up keeps its credentials and its name.
    func testEraseAllIsNotPassedUnlessAskedFor() throws {
        let command = try EsptoolCommand.writeFlash(
            tool: tool, chip: "esp32s3", port: port, writes: writes)
        XCTAssertFalse(command.arguments.contains("-e"))
        XCTAssertFalse(command.arguments.contains("--erase-all"))
    }

    /// And when it is asked for it goes where the recipe puts it: after the
    /// subcommand, before `-z`.
    func testEraseAllGoesWhereTheRecipePutsIt() throws {
        let command = try EsptoolCommand.writeFlash(
            tool: tool, chip: "esp32s3", port: port, writes: writes, eraseAll: true)
        let subcommand = try XCTUnwrap(command.arguments.firstIndex(of: "write-flash"))
        XCTAssertEqual(command.arguments[subcommand + 1], "-e")
        XCTAssertEqual(command.arguments[subcommand + 2], "-z")
    }

    // MARK: - addresses come from the caller, never from here

    /// THE POINT OF THIS TEST is that no address is written down in the builder. A
    /// classic ESP32 puts its bootloader at 0x1000 rather than 0x0, and a
    /// differently partitioned board puts its app somewhere other than 0x10000, so
    /// a hardcoded constant would be wrong silently - the flash would take the
    /// write and the chip would not boot.
    func testAddressesAreWhateverTheWritesSay() throws {
        let unusual: [EsptoolCommand.StagedWrite] = [
            .init(role: "bootloader", address: 0x1000, path: "/s/boot.bin"),
            .init(role: "partitions", address: 0x9000, path: "/s/parts.bin"),
            .init(role: "app", address: 0x20000, path: "/s/app.bin"),
        ]
        let command = try EsptoolCommand.writeFlash(
            tool: tool, chip: "esp32", port: port, writes: unusual)
        XCTAssertEqual(command.arguments.suffix(6), [
            "0x1000", "/s/boot.bin",
            "0x9000", "/s/parts.bin",
            "0x20000", "/s/app.bin",
        ])
    }

    /// In the order given. `FirmwareBundle.flashPlan` has already sorted by
    /// address, and re-sorting here would mean two places deciding the order.
    func testWritesKeepTheOrderTheyWereGivenIn() throws {
        let reversed = Array(writes.reversed())
        let command = try EsptoolCommand.writeFlash(
            tool: tool, chip: "esp32s3", port: port, writes: reversed)
        XCTAssertEqual(command.arguments.suffix(8), [
            "0x10000", "/stage/03-app.bin",
            "0xe000", "/stage/02-boot_app0.bin",
            "0x8000", "/stage/01-partitions.bin",
            "0x0", "/stage/00-bootloader.bin",
        ])
    }

    /// Lowercase hex, `0x` prefix, no padding - platform.txt's own spelling, so the
    /// two can be compared by eye.
    func testHexAddressSpelling() {
        XCTAssertEqual(EsptoolCommand.hexAddress(0), "0x0")
        XCTAssertEqual(EsptoolCommand.hexAddress(0x8000), "0x8000")
        XCTAssertEqual(EsptoolCommand.hexAddress(0xe000), "0xe000")
        XCTAssertEqual(EsptoolCommand.hexAddress(0x10000), "0x10000")
        XCTAssertEqual(EsptoolCommand.hexAddress(0x110000), "0x110000")
    }

    // MARK: - a plan straight out of a bundle

    /// End to end from a bundle to an argv, which is the path the app takes, and
    /// with addresses that are NOT this repo's so the test fails if any of them is
    /// ever assumed rather than read.
    func testAPlanFromABundleProducesTheArgvForItsOwnAddresses() throws {
        let bundle = Self.bundle(chip: "esp32", bootloader: 0x1000, app: 0x30000)
        let plan = try XCTUnwrap(bundle.flashPlan(forChip: "esp32"))
        let staged = plan.enumerated().map { index, write in
            EsptoolCommand.StagedWrite(
                role: write.role, address: write.address,
                path: "/stage/" + EsptoolCommand.stagedFilename(
                    index: index, role: write.role))
        }
        let command = try EsptoolCommand.writeFlash(
            tool: tool, chip: "esp32", port: port, writes: staged)
        XCTAssertEqual(command.arguments.suffix(8), [
            "0x1000", "/stage/00-bootloader.bin",
            "0x8000", "/stage/01-partitions.bin",
            "0xe000", "/stage/02-boot_app0.bin",
            "0x30000", "/stage/03-app.bin",
        ])
    }

    func testStagedFilenamesAreOrderedAndNamedAfterTheirRole() {
        XCTAssertEqual(
            EsptoolCommand.stagedFilename(index: 0, role: "bootloader"),
            "00-bootloader.bin")
        XCTAssertEqual(
            EsptoolCommand.stagedFilename(index: 3, role: "app"), "03-app.bin")
        // Two digits, so a listing sorts the way the writes are ordered.
        XCTAssertEqual(
            EsptoolCommand.stagedFilename(index: 11, role: "spiffs"), "11-spiffs.bin")
    }

    // MARK: - refusals

    func testNothingToWriteIsRefused() {
        XCTAssertThrowsError(
            try EsptoolCommand.writeFlash(
                tool: tool, chip: "esp32s3", port: port, writes: [])
        ) { XCTAssertEqual($0 as? EsptoolCommandError, .nothingToWrite) }
    }

    func testAWriteWithNoStagedFileIsRefused() {
        XCTAssertThrowsError(
            try EsptoolCommand.writeFlash(
                tool: tool, chip: "esp32s3", port: port,
                writes: [.init(role: "app", address: 0x10000, path: "")])
        ) { XCTAssertEqual($0 as? EsptoolCommandError, .writeWithoutFile(role: "app")) }
    }

    /// Two payloads at one address means only the last one survives, which is a
    /// contradiction rather than a preference.
    func testTwoWritesAtOneAddressAreRefused() {
        XCTAssertThrowsError(
            try EsptoolCommand.writeFlash(
                tool: tool, chip: "esp32s3", port: port,
                writes: [
                    .init(role: "partitions", address: 0x8000, path: "/a"),
                    .init(role: "spiffs", address: 0x8000, path: "/b"),
                ])
        ) { error in
            XCTAssertEqual(
                error as? EsptoolCommandError,
                .duplicateAddress(role: "spiffs", other: "partitions", address: 0x8000))
            XCTAssertTrue(
                (error.localizedDescription).contains("0x8000"),
                "the message names the address in the spelling the argv uses")
        }
    }

    func testANegativeAddressIsRefused() {
        XCTAssertThrowsError(
            try EsptoolCommand.writeFlash(
                tool: tool, chip: "esp32s3", port: port,
                writes: [.init(role: "app", address: -1, path: "/a")])
        ) {
            XCTAssertEqual(
                $0 as? EsptoolCommandError, .negativeAddress(role: "app", address: -1))
        }
    }

    func testAnEmptyToolAndAnEmptyChipAreRefused() {
        XCTAssertThrowsError(
            try EsptoolCommand.writeFlash(
                tool: EsptoolCommand.Tool(path: ""), chip: "esp32s3", port: port,
                writes: writes)
        ) { XCTAssertEqual($0 as? EsptoolCommandError, .noTool) }
        XCTAssertThrowsError(
            try EsptoolCommand.writeFlash(
                tool: tool, chip: " ", port: port, writes: writes)
        ) { XCTAssertEqual($0 as? EsptoolCommandError, .noChip) }
    }

    func testUnusableBaudAndConnectAttemptsAreRefused() {
        XCTAssertThrowsError(
            try EsptoolCommand.writeFlash(
                tool: tool, chip: "esp32s3", port: port, baud: 0, writes: writes)
        ) { XCTAssertEqual($0 as? EsptoolCommandError, .badBaud(0)) }
        XCTAssertThrowsError(
            try EsptoolCommand.chipID(tool: tool, port: port, connectAttempts: 0)
        ) { XCTAssertEqual($0 as? EsptoolCommandError, .badConnectAttempts(0)) }
    }

    /// Every refusal says something, and they say different things: a message that
    /// was the same for two causes would send someone looking in the wrong place.
    func testEveryRefusalSaysSomethingDifferent() {
        let errors: [EsptoolCommandError] = [
            .noTool, .noPort, .noChip, .nothingToWrite,
            .writeWithoutFile(role: "app"),
            .duplicateAddress(role: "a", other: "b", address: 0x8000),
            .negativeAddress(role: "app", address: -1),
            .badBaud(0), .badConnectAttempts(0),
        ]
        let messages = errors.map { $0.errorDescription ?? "" }
        XCTAssertFalse(messages.contains(""))
        XCTAssertEqual(Set(messages).count, errors.count)
    }

    // MARK: - the probe

    /// The same argv `probe_chip()` builds in tools/espdisp.py, so the app and the
    /// CLI ask the board the same question.
    func testChipIDArgv() throws {
        let command = try EsptoolCommand.chipID(tool: tool, port: port)
        XCTAssertEqual(command.executable, tool.path)
        XCTAssertEqual(command.arguments, [
            "--port", port, "--connect-attempts", "2", "chip-id",
        ])
    }

    // MARK: - a 4.x esptool.py

    /// UNVERIFIED against a real 4.x install; what is asserted is the shape, which
    /// is read off `esptool_path()` in tools/espdisp.py: 5.x is a binary called
    /// `esptool`, 4.x a script called `esptool.py`, and 4.x accepted only the
    /// underscored subcommands.
    func testAPythonEsptoolIsRunThroughTheInterpreterWithUnderscoredSubcommands() throws {
        let script = EsptoolCommand.Tool(path: "/core/esptool_py/4.9.0/esptool.py")
        let write = try EsptoolCommand.writeFlash(
            tool: script, chip: "esp32s3", port: port, writes: writes)
        XCTAssertEqual(write.executable, "/usr/bin/python3")
        XCTAssertEqual(write.arguments.first, script.path)
        XCTAssertTrue(write.arguments.contains("write_flash"))
        XCTAssertFalse(write.arguments.contains("write-flash"))

        let probe = try EsptoolCommand.chipID(tool: script, port: port)
        XCTAssertEqual(probe.arguments, [
            script.path, "--port", port, "--connect-attempts", "2", "chip_id",
        ])
    }

    func testABinaryEsptoolIsRunDirectly() {
        let binary = EsptoolCommand.Tool(path: "/core/esptool_py/5.3.1/esptool")
        XCTAssertFalse(binary.isPythonScript)
        XCTAssertEqual(binary.executable, binary.path)
        XCTAssertEqual(binary.leadingArguments, [])
        XCTAssertEqual(binary.writeFlashSubcommand, "write-flash")
        XCTAssertEqual(binary.chipIDSubcommand, "chip-id")
    }

    // MARK: - the display line

    /// For reading. A path with a space is quoted so the line makes sense, which is
    /// exactly why the line is not what gets run.
    func testDisplayLineQuotesArgumentsWithSpaces() throws {
        let command = try EsptoolCommand.writeFlash(
            tool: tool, chip: "esp32s3", port: port,
            writes: [.init(role: "app", address: 0x10000, path: "/tmp/my stage/app.bin")])
        XCTAssertTrue(command.displayLine.contains("\"/tmp/my stage/app.bin\""))
        XCTAssertTrue(command.displayLine.contains("--port \(port)"))
    }

    // MARK: - fixture

    /// A bundle built through the internal initialiser rather than from bytes.
    ///
    /// Deliberate division of labour: `FirmwareBundleTests` owns the byte layout and
    /// asserts it against hand-solved offsets, and these tests are about what the
    /// manifest MEANS once read. Building bytes here would duplicate that solver
    /// without testing anything this file is responsible for.
    static func bundle(
        chip: String, bootloader: Int, app: Int, version: String = "1.2.0"
    ) -> FirmwareBundle {
        let appPayload = Data("app".utf8)
        let parts: [(String, Int, Data)] = [
            ("bootloader", bootloader, Data("boot".utf8)),
            ("partitions", 0x8000, Data("parts".utf8)),
            ("boot_app0", 0xe000, Data("otadata".utf8)),
        ]
        let image = FirmwareBundle.Image(
            board: chip == "esp32c6" ? "c6" : "s3",
            chip: chip,
            fqbn: "esp32:esp32:\(chip)",
            filename: "display_stream.ino.bin",
            offset: 0,
            byteCount: appPayload.count,
            sha256: FirmwareBundle.sha256Hex(appPayload),
            appAddress: app,
            flashParts: parts.map { role, address, payload in
                FirmwareBundle.FlashPart(
                    role: role, address: address,
                    filename: "display_stream.ino.\(role).bin",
                    offset: 0, byteCount: payload.count,
                    sha256: FirmwareBundle.sha256Hex(payload))
            })
        return FirmwareBundle(
            format: FirmwareBundle.format,
            firmwareVersion: version,
            builtAt: "2026-01-02T03:04:05Z",
            sourceCommit: nil,
            sourceDirty: false,
            tool: "espdisp.py bundle",
            images: [image],
            payloads: [chip: appPayload],
            flashPayloads: [
                chip: Dictionary(
                    uniqueKeysWithValues: parts.map { ($0.0, $0.2) }),
            ])
    }

    /// A generation-1 bundle: an application image and nothing else, which is a
    /// perfectly good over-the-air payload and cannot bring up a blank board.
    static func otaOnlyBundle(chip: String) -> FirmwareBundle {
        let payload = Data("app".utf8)
        return FirmwareBundle(
            format: FirmwareBundle.formatV1,
            firmwareVersion: "1.1.0",
            builtAt: "2025-12-01T00:00:00Z",
            sourceCommit: nil,
            sourceDirty: false,
            tool: "espdisp.py bundle",
            images: [FirmwareBundle.Image(
                board: "s3", chip: chip, fqbn: "esp32:esp32:\(chip)",
                filename: "display_stream.ino.bin", offset: 0,
                byteCount: payload.count,
                sha256: FirmwareBundle.sha256Hex(payload),
                appAddress: nil, flashParts: [])],
            payloads: [chip: payload],
            flashPayloads: [:])
    }
}
