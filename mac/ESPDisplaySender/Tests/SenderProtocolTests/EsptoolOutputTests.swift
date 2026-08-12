import XCTest
@testable import SenderProtocol

/// Reading esptool's output, and waiting for a board that has just been reset.
///
/// The chip parse is pinned against output MEASURED from the attached board rather
/// than against output imagined for it, which is the correction FEAT-001 made to
/// `probe_chip()`'s own comment: only one of the two spellings that function greps
/// for is printed by esptool 5.x.
final class EsptoolOutputTests: XCTestCase {

    /// `esptool --port /dev/cu.usbmodem1101 --connect-attempts 2 chip-id` against the
    /// attached ESP32-S3, verbatim, exit 0. Kept whole rather than reduced to the one
    /// line that matches, so that a parse which starts matching some OTHER line of a
    /// real transcript is caught.
    private let realChipIDOutput = """
        esptool v5.3.1
        Serial port /dev/cu.usbmodem1101:
        Connecting...
        Detecting chip type... ESP32-S3
        Connected to ESP32-S3 on /dev/cu.usbmodem1101:
        Chip type:          ESP32-S3 (QFN56) (revision v0.2)
        Features:           Wi-Fi, BT 5 (LE), Dual Core + LP Core, 240MHz, Embedded PSRAM 8MB (AP_3v3)
        Crystal frequency:  40MHz
        USB mode:           USB-Serial/JTAG
        MAC:                28:84:85:55:55:94
        Uploading stub flasher...
        Running stub flasher...
        Stub flasher running.
        Warning: ESP32-S3 has no chip ID. Reading MAC address instead.
        MAC:                28:84:85:55:55:94
        Hard resetting via RTS pin...
        """

    // MARK: - which chip

    func testTheRealChipIDOutputParsesToTheChipItReported() {
        XCTAssertEqual(EsptoolOutput.chipToken(in: realChipIDOutput), "esp32s3")
    }

    /// The same answer `probe_chip()` derives from the same bytes: it returned the
    /// board key `s3` for this transcript, from the token esp32s3.
    func testTheTokenAgreesWithTheCLIsOwnParse() {
        let token = EsptoolOutput.chipToken(in: realChipIDOutput)
        XCTAssertEqual(token, "esp32s3")
        // And it is the manifest's spelling, so it can be handed straight to a
        // bundle without translation.
        XCTAssertEqual(token, EsptoolCommandTests.bundle(
            chip: "esp32s3", bootloader: 0, app: 0x10000).images[0].chip)
    }

    /// esptool 4.x's spelling, kept because `esptool_path()` still locates a 4.x
    /// script. UNVERIFIED against a real 4.x run; what is asserted is that the
    /// alternative is live in the parse.
    func testTheFourPointXSpellingStillParses() {
        XCTAssertEqual(
            EsptoolOutput.chipToken(in: "Chip is ESP32-C6 (QFN40) (revision v0.0)"),
            "esp32c6")
    }

    /// "Chip type:" is NOT the line to match. 5.3.1 prints it on every run, and it
    /// is the line a parse would drift onto if the real one were removed.
    func testTheChipTypeLineIsNotWhatMatches() {
        XCTAssertNil(EsptoolOutput.chipToken(
            in: "Chip type:          ESP32-S3 (QFN56) (revision v0.2)"))
        XCTAssertNil(EsptoolOutput.chipToken(
            in: "Connected to ESP32-S3 on /dev/cu.usbmodem101:"))
    }

    func testAnOutputWithNoChipInItAnswersNothing() {
        XCTAssertNil(EsptoolOutput.chipToken(in: ""))
        XCTAssertNil(EsptoolOutput.chipToken(in: """
            esptool v5.3.1
            Serial port /dev/cu.usbmodem101:
            A fatal error occurred: Could not open /dev/cu.usbmodem101, the port is busy or doesn't exist.
            """))
    }

    /// The token is returned as parsed rather than checked against a list, so a
    /// bundle built for a chip this code has never heard of still works.
    func testAnUnknownChipIsStillReportedRatherThanDiscarded() {
        XCTAssertEqual(
            EsptoolOutput.chipToken(in: "Detecting chip type... ESP32-P4"), "esp32p4")
    }

    // MARK: - the MAC, which is the only stable identity here

    func testTheMacIsReadFromTheRealOutput() {
        XCTAssertEqual(
            EsptoolOutput.macAddress(in: realChipIDOutput), "28:84:85:55:55:94")
    }

    func testTheMacIsLowercasedSoOneBoardHasOneSpelling() {
        XCTAssertEqual(
            EsptoolOutput.macAddress(in: "MAC:                AA:BB:CC:DD:EE:FF"),
            "aa:bb:cc:dd:ee:ff")
    }

    func testNoMacMeansNil() {
        XCTAssertNil(EsptoolOutput.macAddress(in: "Detecting chip type... ESP32-S3"))
        XCTAssertNil(EsptoolOutput.macAddress(in: "MAC:                28:84:85"))
    }

    // MARK: - progress

    /// UNVERIFIED spelling, deliberately loose parse. What is pinned is that 4.x's
    /// spelling works and that a bare percentage works, because the exact 5.3.1
    /// wording could not be established: no board was attached to run a write
    /// against, and the shipped binary is packed so the format string is not
    /// readable off disk.
    func testAPercentageIsFoundWhereverItIs() {
        XCTAssertEqual(
            EsptoolOutput.percentage(in: "Writing at 0x00010000... (12 %)"), 12)
        XCTAssertEqual(EsptoolOutput.percentage(in: "Writing... 100%"), 100)
        XCTAssertEqual(EsptoolOutput.percentage(in: "  7 % done"), 7)
        XCTAssertEqual(EsptoolOutput.percentage(in: "0%"), 0)
    }

    func testAPercentageThatIsNotOneIsIgnored() {
        XCTAssertNil(EsptoolOutput.percentage(in: "Compressed 20720 bytes to 13000..."))
        XCTAssertNil(EsptoolOutput.percentage(in: "Writing at 0x00010000..."))
        XCTAssertNil(EsptoolOutput.percentage(in: "999 %"))
        XCTAssertNil(EsptoolOutput.percentage(in: ""))
    }

    /// The last one on the line, so a line that names a total before a position
    /// reports the position.
    func testTheLastPercentageOnALineWins() {
        XCTAssertEqual(
            EsptoolOutput.percentage(in: "part 1 of 100 % ... 42 %"), 42)
    }

    // MARK: - what went wrong

    /// esptool's fatal line is preferred over the last line, because the last line of
    /// a failed run is usually its hint. Both lines here are measured output.
    func testTheFatalLineIsPreferredOverTheHintThatFollowsIt() {
        let output = """
            esptool v5.3.1
            Serial port /dev/cu.usbmodem101:
            A fatal error occurred: Could not open /dev/cu.usbmodem101, the port is busy or doesn't exist.
            Hint: Check if the port is correct and ESP connected
            """
        XCTAssertEqual(
            EsptoolOutput.failureSummary(in: output),
            "A fatal error occurred: Could not open /dev/cu.usbmodem101, the port is "
                + "busy or doesn't exist.")
    }

    func testWithoutAFatalLineTheLastLineIsTheSummary() {
        XCTAssertEqual(
            EsptoolOutput.failureSummary(in: "one\ntwo\n\n  three  \n"), "three")
    }

    /// A tool that printed nothing gets nil rather than an empty string, so a caller
    /// can say "it printed nothing at all" instead of showing a blank reason.
    func testAnEmptyTranscriptHasNoSummary() {
        XCTAssertNil(EsptoolOutput.failureSummary(in: ""))
        XCTAssertNil(EsptoolOutput.failureSummary(in: "  \n\r\n \n"))
    }

    // MARK: - line splitting

    /// Progress redraws in place with a carriage return, so a reader that split on
    /// newlines alone would show nothing until the write finished and then show one
    /// enormous line.
    func testCarriageReturnsBreakLinesToo() {
        let split = EsptoolOutput.splitLines("Writing 10 %\rWriting 20 %\r")
        XCTAssertEqual(split.lines, ["Writing 10 %", "Writing 20 %"])
        XCTAssertEqual(split.remainder, "")
    }

    func testCRLFCountsOnce() {
        let split = EsptoolOutput.splitLines("one\r\ntwo\r\n")
        XCTAssertEqual(split.lines, ["one", "two"])
        XCTAssertEqual(split.remainder, "")
    }

    /// A partial line is a remainder rather than a line, so a percentage is never
    /// reported from half of a number.
    func testAPartialLineIsHeldBack() {
        let first = EsptoolOutput.splitLines("Writing at 0x000")
        XCTAssertEqual(first.lines, [])
        XCTAssertEqual(first.remainder, "Writing at 0x000")
        let second = EsptoolOutput.splitLines(first.remainder + "10000... (12 %)\n")
        XCTAssertEqual(second.lines, ["Writing at 0x00010000... (12 %)"])
        XCTAssertEqual(second.remainder, "")
    }

    func testMixedTerminatorsAndEmptyLines() {
        let split = EsptoolOutput.splitLines("a\n\rb\n")
        XCTAssertEqual(split.lines, ["a", "", "b"])
        XCTAssertEqual(split.remainder, "")
    }

    func testBlankLinesAreNotWorthShowing() {
        XCTAssertFalse(EsptoolOutput.isStatusWorthy(""))
        XCTAssertFalse(EsptoolOutput.isStatusWorthy("   \t"))
        XCTAssertTrue(EsptoolOutput.isStatusWorthy("Hard resetting via RTS pin..."))
    }
}

/// When to talk to a board again after it has reset, and to which device node.
final class SerialSettlePolicyTests: XCTestCase {
    private let flashed = "/dev/cu.usbmodem1101"
    /// The same physical board, after esptool's hard reset, as observed on this
    /// machine.
    private let moved = "/dev/cu.usbmodem101"

    /// THE NODE COMING BACK IS NOT THE FIRMWARE BEING READY, so the first answer is
    /// always to wait - including when the node the board was flashed on is still
    /// listed, which it can be for a moment after the reset.
    func testTheFirstStepIsAlwaysToWait() {
        XCTAssertEqual(
            SerialSettlePolicy.step(attempt: 0, flashedPort: flashed, ports: [flashed]),
            .waitAndRetry(seconds: SerialSettlePolicy.initialWait))
        XCTAssertEqual(
            SerialSettlePolicy.step(attempt: 0, flashedPort: flashed, ports: []),
            .waitAndRetry(seconds: SerialSettlePolicy.initialWait))
    }

    func testTheSamePortIsUsedWhenItIsStillThere() {
        XCTAssertEqual(
            SerialSettlePolicy.step(
                attempt: 1, flashedPort: flashed, ports: [flashed, "/dev/cu.usbserial-1"]),
            .use(port: flashed))
    }

    /// The measured case: the path changed across the reset, and the single device
    /// present is the board.
    func testASingleDeviceUnderADifferentNameIsTheBoard() {
        XCTAssertEqual(
            SerialSettlePolicy.step(attempt: 1, flashedPort: flashed, ports: [moved]),
            .use(port: moved))
    }

    /// And it is NOT guessed at when there is a choice. Picking here would be the
    /// same mistake as running esptool without --port.
    func testSeveralUnfamiliarDevicesAreAmbiguousRatherThanGuessed() {
        let step = SerialSettlePolicy.step(
            attempt: 1, flashedPort: flashed, ports: [moved, "/dev/cu.usbmodem2201"])
        XCTAssertEqual(step, .ambiguous(ports: [moved, "/dev/cu.usbmodem2201"]))
        let message = try? XCTUnwrap(
            SerialSettlePolicy.explain(step, flashedPort: flashed))
        XCTAssertTrue(message?.contains("2 USB serial devices") ?? false)
        XCTAssertTrue(message?.contains("Unplug the others") ?? false)
    }

    func testNothingConnectedYetMeansWaitAgain() {
        XCTAssertEqual(
            SerialSettlePolicy.step(attempt: 3, flashedPort: flashed, ports: []),
            .waitAndRetry(seconds: SerialSettlePolicy.retryWait))
    }

    func testTheBudgetRunsOutAndSaysWhatWasAndWasNotDone() {
        let step = SerialSettlePolicy.step(
            attempt: SerialSettlePolicy.attempts, flashedPort: flashed, ports: [])
        XCTAssertEqual(step, .giveUp)
        let message = SerialSettlePolicy.explain(step, flashedPort: flashed) ?? ""
        // The distinction that matters after a flash: the firmware IS on the board.
        XCTAssertTrue(message.contains("firmware was written"))
        XCTAssertTrue(message.contains("only the WiFi credentials are missing"))
        XCTAssertTrue(message.contains("\(Int(SerialSettlePolicy.budgetSeconds.rounded()))"))
    }

    /// About twenty seconds, which is the shape of the budget rather than an exact
    /// number: a board boots, initialises a panel and only then reads serial.
    func testTheBudgetIsLongEnoughForABoardToBootAPanel() {
        XCTAssertGreaterThan(SerialSettlePolicy.budgetSeconds, 15)
        XCTAssertLessThan(SerialSettlePolicy.budgetSeconds, 60)
    }

    func testWaitingStepsHaveNothingToExplain() {
        XCTAssertNil(
            SerialSettlePolicy.explain(.use(port: flashed), flashedPort: flashed))
        XCTAssertNil(
            SerialSettlePolicy.explain(.waitAndRetry(seconds: 1), flashedPort: flashed))
    }

    /// A negative attempt cannot happen through the loop, and answering it with a
    /// wait rather than a crash is the choice this pins.
    func testANegativeAttemptWaits() {
        XCTAssertEqual(
            SerialSettlePolicy.step(attempt: -1, flashedPort: flashed, ports: [flashed]),
            .waitAndRetry(seconds: SerialSettlePolicy.initialWait))
    }
}
