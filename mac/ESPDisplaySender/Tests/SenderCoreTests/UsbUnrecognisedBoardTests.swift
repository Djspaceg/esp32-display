import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// A board whose firmware found no profile for it after a flash: it answers
/// every identity request with the same refusal, forever, and keeps its
/// screen, WiFi and streaming off. That answer ends the wait at once, and the
/// person is told in words, not with WiFi advice or a replug.
final class UsbUnrecognisedBoardTests: XCTestCase {
    private let id = "1cdbd47b5b94"

    static let unresolvedReply =
        "CFGERR profile unresolved; use CFGBOARD <profile> or CFGBOARD auto"

    /// What the user may read: no firmware command, sketch, setting or tool
    /// name, no replug, no WiFi advice, and boards are never displays.
    static func assertPlainWording(
        _ text: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        for banned in ["CFG", "profile", "display", "espdisp", "tools/", "nplug",
                       "eplug", "econnect", "credentials"] {
            XCTAssertNil(text.range(of: banned, options: .caseInsensitive),
                         "\"\(banned)\" in: \(text)", file: file, line: line)
        }
    }

    /// The T-Watch S3 after its flash, through the app's own serial code on a
    /// port that answers every CFGSHOW the way the firmware does when it found
    /// no profile for its board.
    func testAnUnrecognisedBoardEndsTheWaitAtItsFirstAnswer() async throws {
        let board = try FakeSerialBoard(onCommand: { _ in Self.unresolvedReply + "\n" })
        defer { board.stop() }
        var io = UsbOnboarder.SettleIO.live
        let path = board.path
        io.ports = { [path] }
        let events = UsbSettleTests.Bench()
        let started = ProcessInfo.processInfo.systemUptime
        let result = await UsbOnboarder.sendConfiguration(
            steps: UsbOnboarding.configurationSteps(
                name: "watch", ssid: "Stephens Manor", password: .set("hunter2hunter2")),
            flashedPort: path, expectedHardwareID: id, io: io, onProgress: events.record)
        let waited = ProcessInfo.processInfo.systemUptime - started
        guard case .failure(let failure) = result else { return XCTFail("\(result)") }
        XCTAssertLessThan(
            waited, 10,
            "waited \(Int(waited)) s for a board that answered at once; it said: "
                + "\(failure.title): \(failure.message)")
        XCTAssertTrue(
            failure.message.localizedCaseInsensitiveContains("the firmware installed fine"),
            failure.message)
        XCTAssertTrue(
            failure.message.contains("doesn't recognise this board"), failure.message)
        Self.assertPlainWording(failure.title)
        Self.assertPlainWording(failure.message)
        XCTAssertTrue(failure.boardNotRecognised, "\(failure)")
        Self.assertPlainWording(failure.nextAction ?? "")
        // Nothing but CFGSHOW was sent: the name and network stay unsent.
        XCTAssertFalse(events.recorded.contains {
            if case .log(.sent, let line) = $0 { return !line.hasSuffix("CFGSHOW") }
            return false
        })
    }

    private func answered(_ hardwareID: String) -> UsbOnboarder.PortAnswer {
        UsbOnboarder.PortAnswer(
            existing: .answered(name: "espdisplay-5b94", hardwareID: hardwareID),
            firmwareVersion: "2.0.0")
    }

    private let flashed = "/dev/cu.usbmodem12401"

    /// The boot line says the same, and is enough on its own.
    func testTheFatalBootLineAlsoEndsTheWait() async {
        let bench = UsbSettleTests.Bench()
        bench.ports = { [flashed] _ in [flashed] }
        bench.received = { _, _ in [
            "board: FATAL no unique compatible profile; display, network, "
                + "and streaming remain disabled",
        ] }
        let result = await UsbOnboarder.settle(
            flashedPort: flashed, expectedHardwareID: id, io: bench.io,
            onProgress: bench.record)
        guard case .failure(let failure) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(failure.boardNotRecognised)
        XCTAssertEqual(bench.probes.count, 1)
        XCTAssertLessThan(bench.now, 10)
    }

    /// A WiFi-only run installed nothing, so it does not say the firmware
    /// installed fine, and it sends nothing.
    func testAWifiOnlyRunSaysTheBoardsFirmwareDoesNotRecogniseIt() async {
        let bench = UsbSettleTests.Bench()
        bench.ports = { [flashed] _ in [flashed] }
        bench.received = { _, _ in [Self.unresolvedReply] }
        let result = await UsbOnboarder.sendConfiguration(
            steps: UsbOnboarding.configurationSteps(
                name: "", ssid: "Home", password: .set("hunter2hunter2")),
            flashedPort: flashed, expectedHardwareID: id, wroteFirmware: false,
            io: bench.io, onProgress: bench.record)
        guard case .failure(let failure) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(failure.boardNotRecognised)
        XCTAssertFalse(failure.message.contains("installed fine"), failure.message)
        XCTAssertTrue(failure.message.contains("doesn't recognise this board"), failure.message)
        Self.assertPlainWording(failure.message)
        XCTAssertTrue(bench.sends.isEmpty)
    }

    /// A board that cannot report its ID is this one only on the node it was
    /// written on, or on a node that appeared after the restart. A watch left
    /// plugged in from an earlier run says the same thing, and must not be
    /// taken for the board just written while that one is still away.
    func testAnUnrecognisedBoardAlreadyConnectedIsNotTakenForThisOne() async {
        let watch = "/dev/cu.usbmodem2401"
        let bench = UsbSettleTests.Bench()
        // The board just written never comes back; only the old watch is there.
        bench.ports = { _ in [watch] }
        bench.received = { port, _ in port == watch ? [Self.unresolvedReply] : [] }
        let result = await UsbOnboarder.settle(
            flashedPort: flashed, expectedHardwareID: id, io: bench.io,
            onProgress: bench.record)
        guard case .failure(let failure) = result else { return XCTFail("\(result)") }
        XCTAssertFalse(failure.boardNotRecognised, failure.message)
        XCTAssertGreaterThanOrEqual(bench.now, SerialSettlePolicy.budgetSeconds)
        XCTAssertTrue(
            failure.message.contains("The board on \(watch), which was already connected, "
                + "answered that its firmware doesn't recognise it."), failure.message)
        XCTAssertNil(failure.message.range(of: "CFG"), failure.message)
        // Its raw refusal is the last line received, so none are shown.
        XCTAssertFalse(failure.showsLastSeen)
        XCTAssertFalse(OperationOutcome.failure(failure).showsLastSeen)
    }

    /// The written board renamed across the reset: its new node was not there
    /// when the wait began, so its refusal is this board's, alone or beside an
    /// old board that answers with another ID or not at all.
    func testARenamedNodeThatAppearedAfterTheRestartIsThisBoard() async {
        let other = "/dev/cu.usbmodem1101"
        let silent = "/dev/cu.usbmodem3"
        let moved = "/dev/cu.usbmodem2401"
        for before in [[String](), [other], [other, silent]] {
            let bench = UsbSettleTests.Bench()
            bench.ports = { [flashed] t in t < 1 ? before + [flashed] : before + [moved] }
            bench.answer = { port, _ in
                port == other ? self.answered("aabbccddeeff") : .init(existing: .silent)
            }
            bench.received = { port, _ in port == moved ? [Self.unresolvedReply] : [] }
            let result = await UsbOnboarder.settle(
                flashedPort: flashed, expectedHardwareID: id, io: bench.io,
                onProgress: bench.record)
            guard case .failure(let failure) = result else { return XCTFail("\(result)") }
            XCTAssertTrue(failure.boardNotRecognised, "\(before): \(failure.message)")
            XCTAssertLessThan(bench.now, 15, "\(before)")
        }
    }

    /// The firmware-update, game-data and repair callers reword a failed
    /// wait; this one reaches them as it is. Same call, same flag.
    func testTheFailureIsMarkedSoCallersPassItThrough() {
        let installed = UsbOnboarder.unrecognisedBoardFailure(wroteFirmware: true)
        let untouched = UsbOnboarder.unrecognisedBoardFailure(wroteFirmware: false)
        XCTAssertTrue(installed.boardNotRecognised && untouched.boardNotRecognised)
        XCTAssertFalse(installed.showsLastSeen || untouched.showsLastSeen)
        XCTAssertEqual(installed.title, untouched.title)
        XCTAssertNotEqual(installed.message, untouched.message)
        for text in [installed.title, installed.message, untouched.message,
                     installed.nextAction ?? "nil"] {
            Self.assertPlainWording(text)
        }
    }

    /// Through the sheet's own monitor and footer: its own next step, and
    /// none of the raw lines the run last saw, which name the firmware's
    /// commands. The transcript behind Details keeps them.
    @MainActor
    func testTheFooterShowsItsOwnNextStepAndNoRawLines() async {
        let failure = UsbOnboarder.unrecognisedBoardFailure(wroteFirmware: true)
        for flow in [UsbFlashSession.Flow.onboarding, .configureOnly, .update, .repair] {
            let monitor = UsbFlashMonitor(flow: flow)
            monitor.record(.phase(.waitingForBoard(SettleWait(
                target: .answer(port: flashed), attempt: 2, elapsed: 2.5, budget: 45,
                lastSeen: nil))))
            monitor.record(.log(.received, Self.unresolvedReply))
            monitor.fail(.failure(failure))
            guard case .failure(_, _, let message, let lastSeen, let nextAction) =
                FlashFooterStatus.usb(monitor.session)
            else { return XCTFail("\(flow): \(monitor.session)") }
            XCTAssertEqual(message, failure.message, "\(flow)")
            XCTAssertEqual(lastSeen, [], "\(flow)")
            XCTAssertEqual(nextAction, failure.nextAction, "\(flow)")
            XCTAssertTrue(
                monitor.session.transcript.entries.contains { $0.text == Self.unresolvedReply },
                "\(flow)")
        }
        // Anything else still shows what was last seen.
        let monitor = UsbFlashMonitor(flow: .onboarding)
        monitor.record(.phase(.waitingForBoard(SettleWait(
            target: .answer(port: flashed), attempt: 2, elapsed: 2.5, budget: 45,
            lastSeen: nil))))
        monitor.record(.log(.received, "motion: raw=1,2,3"))
        monitor.fail(.failure(WifiConfigUI.ConfigFailure(title: "t", message: "m")))
        XCTAssertEqual(monitor.session.failure?.lastSeen, ["motion: raw=1,2,3"])
    }

    /// Closed before the run ended, the sheet hands its failure to the main
    /// window's alert, which keeps the next step.
    func testTheAlertKeepsTheNextStep() {
        let outcome = OperationOutcome.failure(
            UsbOnboarder.unrecognisedBoardFailure(wroteFirmware: true))
        XCTAssertEqual(
            outcome.alertText, outcome.message + "\n\nNext: " + (outcome.nextAction ?? ""))
        XCTAssertEqual(OperationOutcome.failure("t", "m").alertText, "m")
    }

    /// A firmware update or game-data write checks the board before it
    /// writes. A board refusing that check this way is told so in words,
    /// not as silence with advice to restart it, and esptool is not run.
    @MainActor
    func testTheCheckBeforeAWriteSaysTheFirmwareDoesNotRecogniseTheBoard() async {
        let manager = PanelManager(previewPanels: [], savedNetworkNames: [], usbSerialPorts: [])
        let outcome = await manager.explainUnansweredBoard(
            path: flashed, expectedID: id, reason: Self.unresolvedReply,
            nothingDone: "nothing was written")
        XCTAssertEqual(outcome.kind, .failure)
        XCTAssertEqual(outcome.title, "This firmware doesn't recognise this board")
        XCTAssertTrue(outcome.message.contains("nothing was written"), outcome.message)
        XCTAssertFalse(outcome.showsLastSeen)
        XCTAssertNil(outcome.restartPort)
        Self.assertPlainWording(outcome.message)
        Self.assertPlainWording(outcome.nextAction ?? "")
    }

    /// Battery boards keep running when unplugged, so no advice after a USB
    /// restart says to unplug one, and none sends the person to a tool.
    func testNoWaitAdviceSaysToReplugOrUseATool() {
        var texts: [String] = []
        for wroteFirmware in [true, false] {
            for sentName in [true, false] {
                texts.append(SerialSettlePolicy.explain(
                    .giveUp, flashedPort: flashed, wroteFirmware: wroteFirmware,
                    sentName: sentName) ?? "")
            }
        }
        let waiting = SettleWait(target: .answer(port: flashed), attempt: 9,
                                 elapsed: 45, budget: 45, lastSeen: nil)
        for flow in [UsbFlashSession.Flow.onboarding, .configureOnly, .update, .repair] {
            for phase in [UsbFlashPhase.waitingForBoard(waiting), .restarting,
                          .configuring("Sending the WiFi credentials…")] {
                var session = UsbFlashSession(flow: flow)
                session.apply(.phase(phase), at: 0)
                session.fail(title: "t", message: "m", at: 1)
                texts.append(session.failure?.nextAction ?? "")
            }
        }
        for text in texts {
            for banned in ["nplug", "plug it", "plug the", "eplug", "tools/", "espdisp"] {
                XCTAssertNil(text.range(of: banned, options: .caseInsensitive),
                             "\"\(banned)\" in: \(text)")
            }
        }
    }
}
