import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// The wait after a restart, driven on a virtual clock: it recovers on its own
/// from a renamed node and a slow boot, reports every look, and stops at its
/// budget instead of waiting forever.
final class UsbSettleTests: XCTestCase {
    private let flashed = "/dev/cu.usbmodem1312201"
    private let id = "1cdbd47b5b94"

    /// A fake bench: which nodes exist and what each answers, as functions of
    /// virtual time. A silent CFGSHOW costs its full three seconds, as it does on
    /// a real port.
    final class Bench: @unchecked Sendable {
        private let lock = NSLock()
        private var clock = 0.0
        private var events: [UsbFlashEvent] = []
        var probes: [String] = []
        var sends: [String] = []
        var ports: (Double) -> [String] = { _ in [] }
        var answer: (String, Double) -> UsbOnboarder.PortAnswer = { _, _ in
            UsbOnboarder.PortAnswer(existing: .silent, lastLine: nil)
        }
        var reply: (String, Int) -> WifiConfigUI.CommandResult = { _, _ in .success("CFGOK") }
        var cancelAfter: Double = .infinity

        var now: Double { lock.withLock { clock } }
        func advance(_ seconds: Double) { lock.withLock { clock += seconds } }
        func record(_ event: UsbFlashEvent) { lock.withLock { events.append(event) } }
        var recorded: [UsbFlashEvent] { lock.withLock { events } }
        var waits: [SettleWait] {
            recorded.compactMap {
                if case .phase(.waitingForBoard(let wait)) = $0 { return wait }
                return nil
            }
        }

        var io: UsbOnboarder.SettleIO {
            UsbOnboarder.SettleIO(
                ports: { [self] in ports(now) },
                probe: { [self] port, _ in
                    lock.withLock { probes.append(port) }
                    let result = answer(port, now)
                    advance(result.existing == .silent ? 3 : 0.05)
                    return result
                },
                send: { [self] command, port, _ in
                    let count = lock.withLock { () -> Int in
                        sends.append(command)
                        return sends.count
                    }
                    advance(0.05)
                    return reply(port, count)
                },
                sleep: { [self] seconds in advance(seconds) },
                now: { [self] in now },
                isCancelled: { [self] in now >= cancelAfter })
        }
    }

    private func answered(_ hardwareID: String, fw: String = "1.5.0") -> UsbOnboarder.PortAnswer {
        UsbOnboarder.PortAnswer(
            existing: .answered(name: "espdisplay-5b94", hardwareID: hardwareID),
            firmwareVersion: fw)
    }

    /// The board takes thirty seconds to start answering - the firmware's own
    /// bounded WiFi wait - and the wait rides it out.
    func testASlowBootIsWaitedOutAndEachLookIsReported() async {
        let bench = Bench()
        bench.ports = { [flashed] _ in [flashed] }
        bench.answer = { [id] _, t in
            t >= 30 ? self.answered(id)
                : UsbOnboarder.PortAnswer(existing: .silent, lastLine: "motion: raw=1,2,3")
        }
        let result = await UsbOnboarder.settle(
            flashedPort: flashed, expectedHardwareID: id, io: bench.io,
            onProgress: bench.record)
        XCTAssertEqual(try? result.get(), .init(port: flashed, firmwareVersion: "1.5.0"))

        let waits = bench.waits
        XCTAssertEqual(waits.first?.target, .reappear(flashedPort: flashed))
        XCTAssertEqual(waits.last?.target, .answer(port: flashed))
        XCTAssertEqual(waits.map(\.attempt), Array(1...waits.count))
        XCTAssertTrue(zip(waits, waits.dropFirst()).allSatisfy { $0.elapsed <= $1.elapsed })
        XCTAssertTrue(waits.allSatisfy { $0.budget == SerialSettlePolicy.budgetSeconds })
        XCTAssertEqual(waits.last?.lastSeen, "\(flashed): motion: raw=1,2,3")
    }

    /// A board that never answers ends in a failure at the budget, not a wait
    /// that outlives it, and the failure says what was last seen.
    func testABoardThatNeverAnswersTimesOutAtTheBudget() async {
        let bench = Bench()
        bench.ports = { [flashed] _ in [flashed] }
        let result = await UsbOnboarder.settle(
            flashedPort: flashed, expectedHardwareID: id, io: bench.io,
            onProgress: bench.record)
        guard case .failure(let failure) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(failure.title, "The board did not come back")
        XCTAssertTrue(failure.message.contains("45 seconds"), failure.message)
        XCTAssertTrue(failure.message.contains("Last seen: no answer from \(flashed) within 3 s"),
                      failure.message)
        // Stopped within one look of the budget.
        XCTAssertGreaterThanOrEqual(bench.now, SerialSettlePolicy.budgetSeconds)
        XCTAssertLessThan(bench.now, SerialSettlePolicy.budgetSeconds + 3 + SerialSettlePolicy.retryWait + 0.01)
    }

    /// The measured rename: the node goes away across the reset and comes back
    /// under another name.
    func testARenamedPortIsFollowed() async {
        let bench = Bench()
        let moved = "/dev/cu.usbmodem101"
        bench.ports = { t in t < 4 ? [] : [moved] }
        bench.answer = { [id] port, _ in
            port == moved ? self.answered(id) : .init(existing: .silent)
        }
        let result = await UsbOnboarder.settle(
            flashedPort: flashed, expectedHardwareID: id, io: bench.io,
            onProgress: bench.record)
        XCTAssertEqual(try? result.get().port, moved)
        XCTAssertTrue(bench.recorded.contains(
            .log(.app, "The board moved from \(flashed) to \(moved).")))
    }

    /// Renamed, with another board plugged in too: the one reporting this ID wins.
    func testTheBoardIsIdentifiedAmongSeveralNodes() async {
        let bench = Bench()
        let other = "/dev/cu.usbmodem1101"
        let moved = "/dev/cu.usbmodem2201"
        bench.ports = { _ in [other, moved] }
        bench.answer = { [id] port, _ in
            port == moved ? self.answered(id) : self.answered("aabbccddeeff")
        }
        let result = await UsbOnboarder.settle(
            flashedPort: flashed, expectedHardwareID: id, io: bench.io,
            onProgress: bench.record)
        XCTAssertEqual(try? result.get().port, moved)
        XCTAssertEqual(bench.waits.last?.target, .identify(ports: [other, moved]))
    }

    /// Without an ID there is nothing to identify by, so several nodes still refuse.
    func testSeveralNodesWithoutAnIDStillRefuse() async {
        let bench = Bench()
        bench.ports = { _ in ["/dev/a", "/dev/b"] }
        let result = await UsbOnboarder.settle(
            flashedPort: flashed, expectedHardwareID: nil, io: bench.io)
        guard case .failure(let failure) = result else { return XCTFail() }
        XCTAssertTrue(failure.message.contains("Unplug the others"))
        XCTAssertTrue(bench.probes.isEmpty)
    }

    /// Another board answering on the node is not this one, and says so.
    func testADifferentBoardOnTheNodeIsReportedNotAccepted() async {
        let bench = Bench()
        bench.ports = { [flashed] _ in [flashed] }
        bench.answer = { _, _ in self.answered("aabbccddeeff") }
        let result = await UsbOnboarder.settle(
            flashedPort: flashed, expectedHardwareID: id, io: bench.io,
            onProgress: bench.record)
        guard case .failure(let failure) = result else { return XCTFail() }
        XCTAssertTrue(failure.message.contains("a different board (ID aabbccddeeff)"),
                      failure.message)
    }

    /// Several silent nodes each cost three seconds, so the budget is checked
    /// per node; a node that answered as another board is not asked again.
    func testIdentifyingStaysInsideTheBudgetAndSkipsOtherBoards() async {
        let bench = Bench()
        let other = "/dev/cu.usbmodem9"
        let silent = ["/dev/cu.usbmodem1", "/dev/cu.usbmodem2", "/dev/cu.usbmodem3"]
        bench.ports = { _ in [other] + silent }
        bench.answer = { port, _ in
            port == other ? self.answered("aabbccddeeff") : .init(existing: .silent)
        }
        let result = await UsbOnboarder.settle(
            flashedPort: flashed, expectedHardwareID: id, io: bench.io,
            onProgress: bench.record)
        guard case .failure = result else { return XCTFail("\(result)") }
        XCTAssertLessThanOrEqual(bench.now, SerialSettlePolicy.budgetSeconds + 3.01)
        XCTAssertEqual(bench.probes.filter { $0 == other }.count, 1)
    }

    func testAMoveIsLoggedOnce() async {
        let bench = Bench()
        let moved = "/dev/cu.usbmodem101"
        bench.ports = { _ in [moved] }
        bench.answer = { [id] _, t in t > 12 ? self.answered(id) : .init(existing: .silent) }
        _ = await UsbOnboarder.settle(
            flashedPort: flashed, expectedHardwareID: id, io: bench.io,
            onProgress: bench.record)
        XCTAssertEqual(bench.recorded.filter {
            if case .log(.app, let text) = $0 { return text.hasPrefix("The board moved") }
            return false
        }.count, 1)
    }

    func testStoppingEndsTheWait() async {
        let bench = Bench()
        bench.ports = { [flashed] _ in [flashed] }
        bench.cancelAfter = 5
        let result = await UsbOnboarder.settle(
            flashedPort: flashed, expectedHardwareID: id, io: bench.io)
        guard case .failure(let failure) = result else { return XCTFail() }
        XCTAssertEqual(failure.title, "Stopped")
        XCTAssertLessThan(bench.now, 10)
    }

    /// A line whose reply was lost is sent once more after the board is found
    /// again; the run then carries on.
    func testALostReplyIsSentOnceMore() async {
        let bench = Bench()
        bench.ports = { [flashed] _ in [flashed] }
        bench.answer = { [id] _, _ in self.answered(id) }
        bench.reply = { _, count in
            count == 1 ? .failure("no response from the device") : .success("CFGOK saved")
        }
        let steps = UsbOnboarding.configurationSteps(
            name: "", ssid: "Stephens Manor", password: .keepCurrent)
        let result = await UsbOnboarder.sendConfiguration(
            steps: steps, flashedPort: flashed, expectedHardwareID: id,
            io: bench.io, onProgress: bench.record)
        XCTAssertEqual(try? result.get(), flashed)
        XCTAssertEqual(bench.sends.count, 2)
        // The board is found again before the resend, not written to blind.
        XCTAssertEqual(bench.probes.count, 2)
        XCTAssertTrue(bench.recorded.contains(.phase(.configuring("Sending the WiFi credentials…"))))
    }

    func testARefusalIsNotRetried() async {
        let bench = Bench()
        bench.ports = { [flashed] _ in [flashed] }
        bench.answer = { [id] _, _ in self.answered(id) }
        bench.reply = { _, _ in .failure("CFGERR bad ssid") }
        let result = await UsbOnboarder.sendConfiguration(
            steps: UsbOnboarding.configurationSteps(
                name: "", ssid: "x", password: .keepCurrent),
            flashedPort: flashed, expectedHardwareID: id, io: bench.io,
            onProgress: bench.record)
        guard case .failure(let failure) = result else { return XCTFail() }
        XCTAssertTrue(failure.message.contains("CFGERR bad ssid"))
        XCTAssertEqual(bench.sends.count, 1)
    }

    /// The live probe, through the app's own serial code, against a port that
    /// answers the way the Waveshare 1.9 did after its flash: behind a
    /// truncated backlog. This is the wait that never ended.
    func testSettleAcceptsTheBoardBehindATruncatedBacklog() async throws {
        let board = try FakeSerialBoard(onCommand: { command in
            command == "CFGSHOW"
                ? SerialReplyFramingTests.truncatedBacklog + SerialReplyFramingTests.reply + "\n"
                : nil
        })
        defer { board.stop() }
        var io = UsbOnboarder.SettleIO.live
        let path = board.path
        io.ports = { [path] }
        let events = Bench()
        let result = await UsbOnboarder.settle(
            flashedPort: path, expectedHardwareID: "1C:DB:D4:7B:5B:94", io: io,
            onProgress: events.record)
        XCTAssertEqual(try? result.get(), .init(port: path, firmwareVersion: "1.5.0"))
        // The backlog is in the transcript, so a failure would have shown it.
        XCTAssertTrue(events.recorded.contains(.log(.sent, "\(path): CFGSHOW")))
        XCTAssertTrue(events.recorded.contains {
            if case .log(.received, let line) = $0 { return line.contains("heap=12151CFGINFO") }
            return false
        })
    }
}
