import XCTest
@testable import SenderProtocol

/// Naming each phase of a USB run from what esptool prints, and saying which
/// step failed, what was last seen and what to do next.
final class UsbFlashProgressTests: XCTestCase {

    /// The S3 flash plan: bootloader, partition table, boot selector, app.
    private let parts = [
        EsptoolFlashTracker.Part(role: "app", address: 0x10000, size: 2_000_000),
        EsptoolFlashTracker.Part(role: "bootloader", address: 0x0, size: 20_000),
        EsptoolFlashTracker.Part(role: "partitions", address: 0x8000, size: 3_072),
        EsptoolFlashTracker.Part(role: "boot_app0", address: 0xe000, size: 8_192),
    ]

    func testEsptool5OutputNamesEachPhaseAndPart() {
        var tracker = EsptoolFlashTracker(parts: parts)
        XCTAssertEqual(tracker.consume("Connecting...."), .enteringDownloadMode)
        XCTAssertNil(tracker.consume("Connected to ESP32-S3 on /dev/cu.usbmodem1312201:"))

        guard case .writing(let boot)? = tracker.consume(
            "Writing at 0x00000000 [=========>          ]  50.0% 6531/13062 bytes...")
        else { return XCTFail("the bootloader write was not named") }
        XCTAssertEqual(boot.index, 1)
        XCTAssertEqual(boot.count, 4)
        XCTAssertEqual(boot.role, "bootloader")
        XCTAssertEqual(boot.percent, 50)
        XCTAssertEqual(
            UsbFlashPhase.writing(boot).title, "Writing the bootloader (part 1 of 4)")

        guard case .verifying(let verified)? = tracker.consume(
            "Wrote 20208 bytes (13062 compressed) at 0x00000000 in 0.3 seconds (604.9 kbit/s).")
        else { return XCTFail("the write's hash check was not named") }
        XCTAssertEqual(verified.role, "bootloader")
        XCTAssertNil(tracker.consume("Hash of data verified."))

        // An address inside the app, not at its start, is still the app.
        guard case .writing(let app)? = tracker.consume(
            "Writing at 0x0001a000 [==>                 ]  12.3% 98304/800000 bytes...")
        else { return XCTFail("the app write was not named") }
        XCTAssertEqual(app.index, 4)
        XCTAssertEqual(app.partName, "the application")
        XCTAssertEqual(app.percent, 12)

        // Two of four parts written: esptool's exit reset is not a restart.
        XCTAssertNil(tracker.consume("Hard resetting via RTS pin..."))
    }

    func testEsptool4SpellingIsReadToo() {
        var tracker = EsptoolFlashTracker(parts: parts)
        guard case .writing(let part)? = tracker.consume("Writing at 0x00008000... (100 %)")
        else { return XCTFail("4.x write line not read") }
        XCTAssertEqual(part.role, "partitions")
        XCTAssertEqual(part.percent, 100)
        XCTAssertNil(tracker.consume("Leaving..."))
        for address in ["0x00000000", "0x00008000", "0x0000e000", "0x00010000"] {
            _ = tracker.consume("Wrote 1000 bytes (500 compressed) at \(address) in 0.1 seconds...")
            _ = tracker.consume("Hash of data verified.")
        }
        XCTAssertEqual(tracker.consume("Leaving..."), .restarting)
    }

    func testUnrecognisedAndRepeatedLinesChangeNothing() {
        var tracker = EsptoolFlashTracker(parts: parts)
        XCTAssertNil(tracker.consume("Stub flasher running."))
        XCTAssertEqual(tracker.consume("Connecting..."), .enteringDownloadMode)
        XCTAssertNil(tracker.consume("Connecting..."))
    }

    /// The bar is weighted by bytes: the tiny parts are not three quarters of it.
    func testOverallFractionIsWeightedByBytes() {
        var tracker = EsptoolFlashTracker(parts: parts)
        guard case .writing(let lastSmall)? = tracker.consume("Writing at 0x0000e000... (100 %)")
        else { return XCTFail() }
        XCTAssertLessThan(lastSmall.overallFraction, 0.02)
        guard case .writing(let halfApp)? = tracker.consume("Writing at 0x00090000... (50 %)")
        else { return XCTFail() }
        XCTAssertEqual(halfApp.overallFraction, 0.5, accuracy: 0.02)
    }

    func testTheWaitSaysWhatForHowLongAndWhichAttempt() {
        let wait = SettleWait(
            target: .answer(port: "/dev/cu.usbmodem1312201"),
            attempt: 3, elapsed: 7.6, budget: 45)
        XCTAssertEqual(
            wait.summary,
            "Waiting for the firmware on /dev/cu.usbmodem1312201 to answer CFGSHOW "
                + "· attempt 3 · 7 of 45 s")
        XCTAssertEqual(UsbFlashPhase.waitingForBoard(wait).fraction ?? 0, 7.6 / 45, accuracy: 0.001)
        XCTAssertTrue(SettleWait(
            target: .reappear(flashedPort: "/dev/cu.usbmodem1101"),
            attempt: 1, elapsed: 0, budget: 45).summary.contains("it was /dev/cu.usbmodem1101"))
        XCTAssertTrue(SettleWait(
            target: .identify(ports: ["/dev/a", "/dev/b"]),
            attempt: 2, elapsed: 3, budget: 45).summary.contains("one of 2 USB serial devices"))
    }

    func testTranscriptKeepsOneProgressLinePerRunAndCaps() {
        var transcript = UsbFlashTranscript()
        transcript.append(.esptool, "Writing at 0x00010000 ... 1.0%", at: 1)
        transcript.append(.esptool, "Writing at 0x00012000 ... 2.0%", at: 2)
        transcript.append(.esptool, "Wrote 2000000 bytes at 0x00010000", at: 3)
        XCTAssertEqual(transcript.entries.map(\.text), [
            "Writing at 0x00012000 ... 2.0%", "Wrote 2000000 bytes at 0x00010000"])
        XCTAssertTrue(transcript.text.contains("esptool Wrote 2000000 bytes"))

        for index in 0..<(UsbFlashTranscript.limit + 10) {
            transcript.append(.received, "line \(index)", at: 4)
        }
        XCTAssertEqual(transcript.entries.count, UsbFlashTranscript.limit)
        XCTAssertEqual(transcript.dropped, 12)
        XCTAssertTrue(transcript.text.hasPrefix("(12 earlier lines dropped)"))
    }

    /// A write that stops: the step, esptool's last lines, and a retry that is safe.
    func testAFailedWriteNamesThePartAndShowsEsptoolsLastLines() {
        var session = UsbFlashSession(flow: .onboarding)
        var tracker = EsptoolFlashTracker(parts: parts)
        for line in ["Connecting....", "Writing at 0x00010000 ... 40.0%",
                     "A fatal error occurred: Serial data stream stopped"] {
            session.apply(.log(.esptool, line), at: 1)
            if let phase = tracker.consume(line) { session.apply(.phase(phase), at: 1) }
        }
        session.fail(title: "Flashing failed", message: "esptool exited with status 2.", at: 2)
        let failure = try? XCTUnwrap(session.failure)
        XCTAssertEqual(failure?.step, "Writing the application (part 4 of 4)")
        XCTAssertEqual(failure?.lastSeen.last, "A fatal error occurred: Serial data stream stopped")
        XCTAssertTrue(failure?.nextAction.contains("rewriting is safe") ?? false)
        XCTAssertTrue(session.transcript.text.contains(
            "FAILED during Writing the application (part 4 of 4)"))
    }

    /// esptool hard-resets the board on its way out of a failed write too, so
    /// "Hard resetting" after a write that died part-way must not read as a
    /// finished write: the human's run stopped at 78.7% of the app and was told
    /// "The firmware is written" and to go on to Set Up WiFi.
    func testAWriteThatDiesBeforeTheEndIsNotCalledWritten() {
        for flow in [UsbFlashSession.Flow.onboarding, .update] {
            var session = UsbFlashSession(flow: flow)
            var tracker = EsptoolFlashTracker(parts: parts)
            for line in [
                "Connecting....",
                "Wrote 20208 bytes (13062 compressed) at 0x00000000 in 0.3 seconds (604.9 kbit/s).",
                "Hash of data verified.",
                "Writing at 0x006dc4d4 [=====================>       ]  78.7% 1376256/1749840 bytes... ",
                "Hard resetting via RTS pin...",
                "A fatal error occurred: No more data to read from the serial port.",
            ] {
                session.apply(.log(.esptool, line), at: 1)
                if let phase = tracker.consume(line) { session.apply(.phase(phase), at: 1) }
            }
            session.fail(title: "Flashing failed", message: "esptool exited with status 2.", at: 2)
            let next = session.failure?.nextAction ?? ""
            XCTAssertFalse(next.contains("firmware is written"), "\(flow): \(next)")
            XCTAssertFalse(next.contains("Set Up WiFi"), "\(flow): \(next)")
            XCTAssertTrue(next.contains("rewriting is safe"), "\(flow): \(next)")
            XCTAssertEqual(session.failure?.step, "Writing the application (part 4 of 4)")
        }
    }

    /// Only a reset after every part was written and hash-checked is the board
    /// restarting.
    func testHardResetAfterEveryPartIsRestarting() {
        var tracker = EsptoolFlashTracker(parts: parts)
        for address in ["0x00000000", "0x00008000", "0x0000e000", "0x00010000"] {
            _ = tracker.consume("Wrote 1000 bytes (500 compressed) at \(address) in 0.1 seconds.")
            _ = tracker.consume("Hash of data verified.")
        }
        XCTAssertEqual(tracker.consume("Hard resetting via RTS pin..."), .restarting)
    }

    /// esptool prints "Wrote" before its hash check, so a last part whose check
    /// fails is not written, and the reset on the way out is not a restart.
    func testAFailedHashOnTheLastPartIsNotCalledWritten() {
        var session = UsbFlashSession(flow: .onboarding)
        var tracker = EsptoolFlashTracker(parts: parts)
        var lines: [String] = ["Connecting...."]
        for address in ["0x00000000", "0x00008000", "0x0000e000"] {
            lines += ["Wrote 1000 bytes (500 compressed) at \(address) in 0.1 seconds.",
                      "Hash of data verified."]
        }
        lines += ["Wrote 1832512 bytes (1000000 compressed) at 0x00010000 in 20.0 seconds.",
                  "Hard resetting via RTS pin...",
                  "A fatal error occurred: MD5 of file does not match data in flash!"]
        for line in lines {
            session.apply(.log(.esptool, line), at: 1)
            if let phase = tracker.consume(line) { session.apply(.phase(phase), at: 1) }
        }
        session.fail(title: "Flashing failed", message: "esptool exited with status 2.", at: 2)
        let next = session.failure?.nextAction ?? ""
        XCTAssertFalse(next.contains("firmware is written"), next)
        XCTAssertTrue(next.contains("rewriting is safe"), next)
    }

    func testDownloadModeFailureSaysToHoldBoot() {
        var session = UsbFlashSession(flow: .update)
        session.apply(.phase(.enteringDownloadMode), at: 0)
        session.apply(.log(.esptool, "Failed to connect to ESP32-S3: No serial data received."), at: 1)
        session.fail(title: "Flashing failed", message: "x", at: 2)
        XCTAssertTrue(session.failure?.nextAction.contains("BOOT") ?? false)
        XCTAssertEqual(session.failure?.lastSeen,
                       ["Failed to connect to ESP32-S3: No serial data received."])
    }

    /// A timed-out wait shows the board's last line, and the advice depends on
    /// whether credentials were still to be sent.
    func testATimedOutWaitShowsTheBoardsLastLine() {
        let wait = SettleWait(target: .answer(port: "/dev/x"), attempt: 12,
                              elapsed: 45, budget: 45, lastSeen: "no answer from /dev/x within 3 s")
        var onboarding = UsbFlashSession(flow: .onboarding)
        onboarding.apply(.phase(.waitingForBoard(wait)), at: 0)
        onboarding.fail(title: "The board did not come back", message: "m", at: 45)
        XCTAssertEqual(onboarding.failure?.step, "Waiting for the board to answer")
        XCTAssertEqual(onboarding.failure?.lastSeen, ["no answer from /dev/x within 3 s"])
        XCTAssertTrue(onboarding.failure?.nextAction.contains("Set Up WiFi only") ?? false)

        var update = UsbFlashSession(flow: .update)
        update.apply(.phase(.waitingForBoard(wait)), at: 0)
        update.apply(.log(.received, "heap=12151"), at: 1)
        update.fail(title: "t", message: "m", nextAction: "custom", at: 45)
        XCTAssertEqual(update.failure?.lastSeen, ["heap=12151"])
        XCTAssertEqual(update.failure?.nextAction, "custom")
    }

    /// A check that fails before anything is written - a name in use, a missing
    /// esptool - is not blamed on the cable.
    func testAFailureBeforeWritingSaysNothingWasWritten() {
        var session = UsbFlashSession(flow: .onboarding)
        session.apply(.phase(.findingBoard), at: 0)
        session.fail(title: "Display name already in use", message: "m", at: 1)
        XCTAssertEqual(session.failure?.step, "Checking the board before writing")
        XCTAssertTrue(session.failure?.nextAction.hasPrefix("Nothing was written.") ?? false)
    }

    func testConfigureOnlyNeverClaimsTheFirmwareWasWritten() {
        var session = UsbFlashSession(flow: .configureOnly)
        session.apply(.phase(.waitingForBoard(SettleWait(
            target: .answer(port: "/dev/x"), attempt: 1, elapsed: 45, budget: 45))), at: 0)
        session.fail(title: "t", message: "m", at: 45)
        XCTAssertFalse(session.failure?.nextAction.contains("firmware is written") ?? true)
    }

    /// A wait tick every second is one transcript line per change of target,
    /// not one per tick.
    func testWaitTicksDoNotFloodTheTranscript() {
        var session = UsbFlashSession(flow: .onboarding)
        for attempt in 1...5 {
            session.apply(.phase(.waitingForBoard(SettleWait(
                target: .answer(port: "/dev/x"), attempt: attempt,
                elapsed: Double(attempt), budget: 45))), at: Double(attempt))
        }
        XCTAssertEqual(session.transcript.entries.count, 1)
        if case .waitingForBoard(let wait) = session.phase {
            XCTAssertEqual(wait.attempt, 5)
        } else {
            XCTFail("the latest tick is the phase")
        }
    }

    func testTranscriptNeverCarriesAPassword() {
        let wifi = ConfigCommands.setWifi(ssid: "Stephens Manor", password: .set("hunter22"))
        XCTAssertEqual(ConfigCommands.redactedForLog(wifi), "CFGWIFI U3RlcGhlbnMgTWFub3I= <hidden>")
        let keep = ConfigCommands.setWifi(ssid: "Cafe", password: .keepCurrent)
        XCTAssertEqual(ConfigCommands.redactedForLog(keep), keep)
        let open = ConfigCommands.setWifi(ssid: "Cafe", password: .openNetwork)
        XCTAssertEqual(ConfigCommands.redactedForLog(open), open)
        let preset = ConfigCommands.setWifiPreset(slot: 1, ssid: "Cafe", password: "secretpw")!
        XCTAssertFalse(ConfigCommands.redactedForLog(preset).contains(
            Data("secretpw".utf8).base64EncodedString()))
        XCTAssertEqual(
            ConfigCommands.redactedForLog(ConfigCommands.setOTAPassword("hunter2hunter2")),
            "CFGOTAPW <hidden>")
        XCTAssertEqual(ConfigCommands.redactedForLog(ConfigCommands.clearOTAPassword), "CFGOTAPW clear")
        XCTAssertEqual(ConfigCommands.redactedForLog("CFGSHOW"), "CFGSHOW")
    }

    /// The node moved and several are present: with the board's ID known, each
    /// is asked instead of refusing.
    func testSeveralCandidatesAreIdentifiedWhenTheIDIsKnown() {
        let ports = ["/dev/cu.usbmodem101", "/dev/cu.usbmodem2201"]
        XCTAssertEqual(
            SerialSettlePolicy.step(
                attempt: 1, flashedPort: "/dev/cu.usbmodem1101", ports: ports,
                canIdentify: true),
            .identify(ports: ports))
        XCTAssertNil(SerialSettlePolicy.explain(.identify(ports: ports), flashedPort: "x"))
    }
}
