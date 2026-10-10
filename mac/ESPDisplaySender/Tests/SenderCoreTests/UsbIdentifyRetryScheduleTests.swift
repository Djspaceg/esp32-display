import XCTest
import Darwin
@testable import SenderCore
@testable import SenderProtocol

/// The retry schedule and what holds it off. Separate from the end-to-end
/// test so that one also builds against the app before the retry existed.
extension UsbIdentifyRetryTests {

    func testRetriesBackOffAndRepeatTheLastDelay() {
        let manager = manager(port: "/dev/cu.usbmodem-retry")
        XCTAssertEqual(
            (1...7).map { manager.usbIdentifyRetryDelay(afterAttempt: $0) },
            [2, 4, 8, 16, 30, 30, 30])
    }

    /// Nothing in the app may be holding a USB port when a retry writes
    /// CFGSHOW, and an unplugged board is not asked again.
    func testARetryWaitsWhileTheAppOwnsUSBAndEndsAtUnplug() {
        let path = "/dev/cu.usbmodem-retry"
        let manager = manager(port: path)
        manager.updateUSBPorts([path])
        let generation = manager.usbPathGeneration(path)
        manager.usbIdentifyRetries[path] = (generation, 1, uptime() - 1)
        XCTAssertEqual(manager.usbPortsDueForIdentifyRetry(), [path])

        // Not due yet.
        XCTAssertEqual(
            manager.usbPortsDueForIdentifyRetry(now: uptime() - 5), [])

        // A flash or onboarding run on any board.
        manager.beginUSBFlash(hardwareID: "020000aabbcc")
        XCTAssertEqual(manager.usbPortsDueForIdentifyRetry(), [])
        manager.finishUSBFlash(hardwareID: "020000aabbcc", wroteFlash: false)
        XCTAssertEqual(manager.usbPortsDueForIdentifyRetry(), [path])

        // The Add sheet's esptool read.
        manager.holdUSBIdentifyRetries()
        XCTAssertEqual(manager.usbPortsDueForIdentifyRetry(), [])
        manager.releaseUSBIdentifyRetries()

        // A USB control write, a preset sync, a brightness drag.
        manager.usbControlsInFlight = 1
        XCTAssertEqual(manager.usbPortsDueForIdentifyRetry(), [])
        manager.usbControlsInFlight = 0
        manager.wifiPresetSyncTasks["020000aabbcc"] = Task {}
        XCTAssertEqual(manager.usbPortsDueForIdentifyRetry(), [])
        manager.wifiPresetSyncTasks = [:]
        manager.usbBrightnessTasks["espdisplay-5b94"] = Task {}
        XCTAssertEqual(manager.usbPortsDueForIdentifyRetry(), [])
        manager.usbBrightnessTasks = [:]

        // A repair.
        manager.holdUSBProbes()
        XCTAssertEqual(manager.usbPortsDueForIdentifyRetry(), [])
        manager.usbProbeHolds -= 1
        XCTAssertEqual(manager.usbPortsDueForIdentifyRetry(), [path])

        // A retry recorded against an earlier connection on a reused path.
        manager.usbIdentifyRetries[path] = (generation - 1, 1, uptime() - 1)
        XCTAssertEqual(manager.usbPortsDueForIdentifyRetry(), [])
        manager.usbIdentifyRetries[path] = (generation, 1, uptime() - 1)

        manager.updateUSBPorts([])
        XCTAssertNil(manager.usbIdentifyRetries[path])
        XCTAssertEqual(manager.usbPortsDueForIdentifyRetry(), [])
    }

    /// A board that never answers keeps one pending retry at a time, moved on
    /// by its own failures only, and the attempt that answers clears it.
    func testOnlyARetryWhoseTimeHasComeMovesTheSchedule() async throws {
        let answering = LockedLines()
        let board = try FakeSerialBoard(onCommand: { command in
            command == "CFGSHOW" && !answering.lines.isEmpty
                ? SerialReplyFramingTests.reply + "\n" : nil
        })
        defer { board.stop() }
        let manager = manager(port: board.path)
        manager.usbIdentifyRetryDelays = [60]
        manager.updateUSBPorts([board.path])

        _ = await manager.probeUSBDevice(board.path, timeout: 0.3)
        let first = try XCTUnwrap(manager.usbIdentifyRetries[board.path])
        XCTAssertEqual(first.attempts, 1)
        // Asked again early (the Add sheet's own read): not a step of the backoff.
        _ = await manager.probeUSBDevice(board.path, timeout: 0.3)
        XCTAssertEqual(manager.usbIdentifyRetries[board.path]?.attempts, 1)
        XCTAssertEqual(manager.usbIdentifyRetries[board.path]?.nextAt, first.nextAt)

        answering.append("booted")
        _ = await manager.probeUSBDevice(board.path, timeout: 2)
        XCTAssertNil(manager.usbIdentifyRetries[board.path])
    }

    private func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A board whose tty survives its restart is asked again on the schedule.
    func testARestartingBoardIsAskedAgainWithoutANewPort() throws {
        let path = "/dev/cu.usbmodem-retry"
        let manager = manager(port: path)
        manager.updateUSBPorts([path])
        let identity = WifiConfigUI.usbIdentity(from: SerialReplyFramingTests.reply)
        manager.noteUSBIdentity(
            path: path, identity: identity, generation: manager.usbPathGeneration(path))
        let serviceName = try XCTUnwrap(manager.panels.first?.serviceName)
        XCTAssertNil(manager.usbIdentifyRetries[path])
        // Verified and not restarting: a setter may be driving it, so no retry.
        manager.usbIdentifyRetries[path] = (manager.usbPathGeneration(path), 1, uptime() - 1)
        XCTAssertEqual(manager.usbPortsDueForIdentifyRetry(), [])
        manager.usbIdentifyRetries[path] = nil

        manager.markUSBRestarting(serviceName)
        XCTAssertEqual(manager.usbSerialState(for: serviceName), .restarting)
        let pending = try XCTUnwrap(manager.usbIdentifyRetries[path])
        XCTAssertEqual(pending.generation, manager.usbPathGeneration(path))
        XCTAssertEqual(manager.usbPortsDueForIdentifyRetry(now: pending.nextAt), [path])
    }

    /// esptool holds the port under an exclusive lock for its whole run: the
    /// probe writes nothing to it.
    func testAProbeSendsNothingToAPortAnotherProgramHasLocked() throws {
        let asked = LockedLines()
        let board = try FakeSerialBoard(onCommand: { command in
            asked.append(command)
            return SerialReplyFramingTests.reply + "\n"
        })
        defer { board.stop() }
        let holder = open(board.path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(holder, 0)
        XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0)

        guard case .unavailable = WifiConfigUI.probePort(board.path, timeout: 0.5) else {
            return XCTFail("a locked port was probed")
        }
        XCTAssertEqual(asked.lines, [])

        _ = flock(holder, LOCK_UN)
        close(holder)
        guard case .identified = WifiConfigUI.probePort(board.path, timeout: 2) else {
            return XCTFail("the port was not probed once the lock was gone")
        }
    }

    /// A setter's CFGOK taken off the same tty is not the board identifying itself.
    func testACFGOKIsNotAnIdentity() throws {
        let board = try FakeSerialBoard(onCommand: { _ in "CFGOK name \"Desk\", restarting\n" })
        defer { board.stop() }
        guard case .unavailable = WifiConfigUI.probePort(board.path, timeout: 1) else {
            return XCTFail("a CFGOK was taken as an identity")
        }
    }

    /// A serial device no display record points at is let go after the cap;
    /// a display's own port is asked until it answers or is unplugged.
    func testOnlyADisplaysOwnPortIsAskedForever() async throws {
        let board = try FakeSerialBoard(onCommand: { _ in nil })
        defer { board.stop() }
        // The record knows the board's hardware ID and its saved path; a
        // silent board has reported no ID, so the path is what links them.
        for (savedPort, expectRetry) in [("/dev/cu.usbmodem-other", false), (board.path, true)] {
            let manager = manager(port: savedPort)
            manager.usbUnknownPortRetryAttempts = 2
            manager.updateUSBPorts([board.path])
            for _ in 0..<3 {
                if let pending = manager.usbIdentifyRetries[board.path] {
                    manager.usbIdentifyRetries[board.path]?.nextAt = pending.nextAt - 100
                }
                _ = await manager.probeUSBDevice(board.path, timeout: 0.1)
            }
            XCTAssertEqual(
                manager.usbIdentifyRetries[board.path] != nil, expectRetry,
                "saved port \(savedPort)")
        }
    }

    /// A preset sync's CFGINFO wifi line read off the same tty is skipped, and
    /// the probe goes on to CFGSHOW's own answer.
    func testAProbeSkipsAnotherCommandsCFGINFO() throws {
        let board = try FakeSerialBoard(chunked: { command in
            command == "CFGSHOW"
                ? ["CFGINFO wifi capacity=10 valid=0x001 active=0\n",
                   SerialReplyFramingTests.reply + "\n"]
                : nil
        })
        defer { board.stop() }
        guard case .identified(let identity) = WifiConfigUI.probePort(board.path, timeout: 2)
        else { return XCTFail("CFGSHOW's answer was not found") }
        XCTAssertEqual(identity.hardwareID, "1cdbd47b5b94")
        XCTAssertFalse(WifiConfigUI.isIdentityReply("CFGINFO audio test is not running"))
        XCTAssertFalse(WifiConfigUI.isIdentityReply("CFGINFO wifi slot=1 valid=1 active=0 ssid64=eA=="))
        XCTAssertTrue(WifiConfigUI.isIdentityReply("CFGINFO ssid=Cafe connected=1 ip=1.2.3.4 rssi=-50"))
        XCTAssertTrue(WifiConfigUI.isIdentityReply("CFGINFO id=1cdbd47b5b94 board=x profile=x target=s3"))
    }

    /// A board with no display record that answered once and then went quiet
    /// (reset, crash loop) is asked again: no setter can be driving it.
    func testAnUnownedBoardThatGoesQuietIsAskedAgain() async throws {
        let board = try FakeSerialBoard(onCommand: { _ in nil })
        defer { board.stop() }
        let manager = manager(port: "/dev/cu.usbmodem-other")
        manager.panels[0].hardwareID = "020000aabbcc"
        manager.panels[0].usbHardwareID = "020000aabbcc"
        manager.updateUSBPorts([board.path])
        manager.noteUSBIdentity(
            path: board.path,
            identity: WifiConfigUI.usbIdentity(from: SerialReplyFramingTests.reply),
            generation: manager.usbPathGeneration(board.path))
        XCTAssertFalse(manager.usbPortBelongsToADisplay(board.path))

        _ = await manager.probeUSBDevice(board.path, timeout: 0.1)
        let pending = try XCTUnwrap(manager.usbIdentifyRetries[board.path])
        XCTAssertEqual(
            manager.usbPortsDueForIdentifyRetry(now: pending.nextAt), [board.path])
    }

    /// A restart asks soon even when an earlier miss scheduled the next ask
    /// far out.
    func testARestartBringsAFarOffRetryForward() throws {
        let path = "/dev/cu.usbmodem-retry"
        let manager = manager(port: path)
        manager.updateUSBPorts([path])
        manager.noteUSBIdentity(
            path: path,
            identity: WifiConfigUI.usbIdentity(from: SerialReplyFramingTests.reply),
            generation: manager.usbPathGeneration(path))
        manager.usbIdentifyRetries[path] = (manager.usbPathGeneration(path), 5, uptime() + 30)
        manager.markUSBRestarting(try XCTUnwrap(manager.panels.first?.serviceName))
        let pending = try XCTUnwrap(manager.usbIdentifyRetries[path])
        XCTAssertLessThanOrEqual(pending.nextAt, uptime() + 2.5)
        XCTAssertEqual(pending.attempts, 0, "a restart starts the backoff over")
    }
}
