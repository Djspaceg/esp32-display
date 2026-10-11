import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// Repair: catching a board that drops off USB, on a virtual clock with fake
/// ports and fake esptools, plus the real process-group kill on a harmless
/// shell tree. No test here opens a USB port.
final class UsbRescueTests: XCTestCase {

    // MARK: - the fake bench

    /// A fake clock, /dev listing and esptool, the same bench as
    /// tools/test_espdisp.py `RescueWorld`.
    ///
    /// The fake esptool behaves like esptool 5.3.1 with open_port_attempts = 0:
    /// it never exits while it cannot open or connect. It opens a linked port
    /// 0.1 s after the link and holds it for one connect pass (2.4 s) before
    /// closing and reopening through the link. It connects to a port of the
    /// right family `connectAfter` seconds after the link, writes it, and exits
    /// `exitAfter` seconds later: 0 if the port is still there, 1 if not.
    final class World {
        typealias Window = (port: String, start: Double, end: Double)
        var t = 0.0
        let baseline: [Window]
        let windows: [Window]
        var limit = 60.0
        var readyAfter = 4.0
        var openAfter = 0.3
        var exitAfter = 1.0
        var earlyExit = false
        var failFirst = false
        var foreign: Set<String> = []
        var connectAfter: [String: Double] = [:]
        /// Ports of a board of another family: esptool syncs, sees the wrong
        /// chip, and exits 2 at once, as esptool 5 does ("Wrong --chip argument?").
        var wrongChip: Set<String> = []
        /// Ports where the write fails every time, with the port still there.
        var alwaysFails: Set<String> = []
        /// Ports where esptool connects and then never finishes the write.
        var hangsAfterConnect: Set<String> = []
        var identities: [String: UsbRescue.USBIdentity] = [:]
        /// What the IORegistry says publishes a port, whatever its name.
        var registry: [String: UsbRescue.USBIdentity] = [:]
        /// The port the user has named as the board by time `t`, if any.
        var adopted: (Double) -> String? = { _ in nil }
        var workers: [FakeWorker] = []
        var events: [UsbFlashEvent] = []
        var written: [String] = []

        init(baseline: [Window], windows: [Window]) {
            self.baseline = baseline
            self.windows = windows
        }

        func ports() -> [String] {
            Set((baseline + windows).filter { $0.start <= t && t < $0.end }.map(\.port)).sorted()
        }

        func identify() -> [UsbRescue.USBIdentity] {
            let present = Set(ports())
            return identities.filter { present.contains($0.key) }.sorted { $0.key < $1.key }
                .map(\.value)
        }

        var io: UsbRescuer.IO {
            UsbRescuer.IO(
                ports: { self.ports() },
                identify: { self.identify() },
                identifyPort: { self.registry[$0] },
                adopted: { self.adopted(self.t) },
                spawn: {
                    let worker = FakeWorker(world: self)
                    self.workers.append(worker)
                    return worker
                },
                now: { self.t },
                sleep: { seconds in self.t = ((self.t + seconds) * 1e6).rounded() / 1e6 },
                isCancelled: { self.t > self.limit })
        }

        var messages: [String] {
            events.compactMap {
                if case .log(.app, let text) = $0 { return text }
                return nil
            }
        }

        func said(_ needle: String) -> Bool { messages.contains { $0.contains(needle) } }

        var steps: [UsbRescueStep] {
            events.compactMap {
                if case .phase(.rescue(let step)) = $0 { return step }
                return nil
            }
        }

        var links: [String] { workers.flatMap(\.links) }

        /// The rescued port, "STOPPED" when the loop was still running at the
        /// limit, or "FAIL: <title>".
        func run(identify: Bool = true) async -> String {
            var io = self.io
            if !identify { io.identify = { [] } }
            do {
                return try await UsbRescuer.run(
                    family: .named("s3")!, regions: UsbRescueTests.regions, io: io
                ) { self.events.append($0) }
            } catch let failure as WifiConfigUI.ConfigFailure {
                return failure.title == "Stopped" ? "STOPPED" : "FAIL: \(failure.title)"
            } catch {
                return "FAIL: \(error)"
            }
        }
    }

    final class FakeWorker: RescueWorker {
        let world: World
        let born: Double
        var port: String?
        var isReady = false
        var isConnected = false
        var code: Int32?
        var links: [String] = []
        var killed = false
        var linkedAt = 0.0
        var connectedAt = 0.0
        var held: String?
        var heldSince = 0.0
        var echoed = false

        init(world: World) {
            self.world = world
            born = world.t
        }

        func poll() -> Int32? {
            let now = world.t
            if code != nil || killed { return code }
            if world.earlyExit {
                code = 2
                return code
            }
            if !isReady, now - born >= world.readyAfter { isReady = true }
            if held != nil, !isConnected, now - heldSince >= 2.4 { held = nil }
            if let port, held == nil, world.ports().contains(port), now - linkedAt >= 0.1 {
                held = port
                heldSince = now
            }
            if let held, !isConnected, world.wrongChip.contains(held), world.ports().contains(held),
               now - linkedAt >= world.openAfter {
                error = "A fatal error occurred: This chip is ESP32-C6, not ESP32-S3. "
                    + "Wrong --chip argument?"
                code = 2
                return code
            }
            if let held, !isConnected, world.ports().contains(held), !world.foreign.contains(held),
               now - linkedAt >= world.connectAfter[held, default: world.openAfter] {
                isConnected = true
                connectedAt = now
            }
            if isConnected, let held, world.hangsAfterConnect.contains(held) { return nil }
            if isConnected, let held, world.alwaysFails.contains(held),
               now - connectedAt >= world.exitAfter {
                error = "A fatal error occurred: Packet content transfer stopped"
                code = 2
                return code
            }
            if isConnected, now - connectedAt >= world.exitAfter {
                code = world.ports().contains(held ?? "") ? 0 : 1
                if world.failFirst {
                    world.failFirst = false
                    code = 1
                }
                if code == 0, let held { world.written.append(held) }
            }
            return code
        }

        func takeOutput() -> String {
            guard isConnected, !echoed else { return "" }
            echoed = true
            return "Connecting...\nConnected to ESP32-S3 on \(port ?? "?"):\n"
                + "Writing at 0x00010000 [=====>   ] 50.0% 1000/2000 bytes...\n"
        }

        func link(to port: String) throws {
            self.port = port
            linkedAt = world.t
            links.append(port)
        }

        func unlink() {
            port = nil
            if let held, !world.ports().contains(held) { self.held = nil }
        }

        var error = "could not open port"
        func lastError() -> String { error }

        func kill() { killed = true }
    }

    static let regions = [
        UsbRescue.Region(address: 0, role: "bootloader", path: "/r/bootloader.bin", bytes: 20_000),
        UsbRescue.Region(address: 0x8000, role: "partitions", path: "/r/partitions.bin", bytes: 3072),
        UsbRescue.Region(address: 0xE000, role: "boot_app0", path: "/r/boot_app0.bin", bytes: 8192),
        UsbRescue.Region(address: 0x10000, role: "app", path: "/r/app.bin", bytes: 400_000),
    ]

    private let other: World.Window = ("/dev/cu.usbmodemOTHER", 0, 1e9)
    private let board = "/dev/cu.usbmodemB"

    // MARK: - new-port selection

    func testOnlyAPortAbsentAtTheStartIsNew() {
        XCTAssertEqual(
            UsbRescue.newPorts(baseline: ["/dev/cu.usbmodemA"],
                               present: ["/dev/cu.usbmodemA", "/dev/cu.usbmodemB"]),
            ["/dev/cu.usbmodemB"])
        XCTAssertEqual(UsbRescue.newPorts(baseline: ["/dev/cu.usbmodemA"], present: []), [])
    }

    /// Real macOS spellings: a CDC port is named after the device's serial
    /// number when it has a usable one (the P4 on this Mac: serial 5B90170069,
    /// port usbmodem5B901700691), otherwise after its locationID with the
    /// trailing zero nibbles dropped, plus the interface (0x00100000 is
    /// usbmodem101, 0x01100000 usbmodem1101, 0x14100000 usbmodem14101).
    func testRealMacOSPortNamesMapToTheirDevice() {
        let p4 = UsbRescue.USBIdentity(location: 0x131220, serial: "5B90170069")
        let root = UsbRescue.USBIdentity(location: 0x0010_0000, serial: "1C:DB:D4:7B:5B:94")
        let hub = UsbRescue.USBIdentity(location: 0x0110_0000, serial: "68:EE:8F:5D:AC:8C")
        let deep = UsbRescue.USBIdentity(location: 0x1410_0000, serial: "")
        let devices = [p4, root, hub, deep]
        XCTAssertEqual(UsbRescue.identity(forPort: "/dev/cu.usbmodem5B901700691", devices: devices), p4)
        XCTAssertEqual(UsbRescue.identity(forPort: "/dev/cu.usbmodem101", devices: devices), root)
        XCTAssertEqual(UsbRescue.identity(forPort: "/dev/cu.usbmodem1101", devices: devices), hub)
        XCTAssertEqual(UsbRescue.identity(forPort: "/dev/cu.usbmodem14101", devices: devices), deep)
        XCTAssertEqual(UsbRescue.identity(forPort: "/dev/cu.usbmodem14103", devices: devices), deep,
                       "a second interface is the same device")
        XCTAssertNil(UsbRescue.identity(forPort: "/dev/cu.usbmodem1312201", devices: [root]),
                     "location 0x00100000 does not claim a port under 0x131220")
    }

    func testPortsMapToTheirUSBDevice() {
        let devices = [
            UsbRescue.USBIdentity(location: 0x131200, serial: ""),
            UsbRescue.USBIdentity(location: 0x131220, serial: "1C:DB:D4:7B:5B:94"),
            UsbRescue.USBIdentity(location: 0x140000, serial: "5A67017634"),
        ]
        XCTAssertEqual(UsbRescue.identity(forPort: "/dev/cu.usbmodem1312201", devices: devices),
                       devices[1], "the longest matching location wins")
        XCTAssertEqual(UsbRescue.identity(forPort: "/dev/cu.usbserial-5A67017634", devices: devices),
                       devices[2])
        XCTAssertNil(UsbRescue.identity(forPort: "/dev/cu.usbmodem9999", devices: devices))
        XCTAssertTrue(UsbRescue.isKnown(
            devices[1], in: [.init(location: 0x200000, serial: "1C:DB:D4:7B:5B:94")]),
            "the same serial on another socket is the same board")
        XCTAssertTrue(UsbRescue.isKnown(
            .init(location: 0x131220, serial: ""), in: [.init(location: 0x131220, serial: "")]))
        XCTAssertFalse(UsbRescue.isKnown(
            .init(location: 0x131220, serial: ""), in: [.init(location: 0x140000, serial: "")]))
        XCTAssertFalse(UsbRescue.isKnown(nil, in: devices))
    }

    func testLinkIsSpelledUnderDevAndResolvesToThePort() throws {
        let directory = try temporaryDirectory()
        let link = UsbRescue.linkPath(directory: directory.path, index: 3)
        XCTAssertTrue(link.hasPrefix("/dev/../"))
        XCTAssertNotEqual(link, UsbRescue.linkPath(directory: directory.path, index: 4))
        let target = directory.appendingPathComponent("device")
        FileManager.default.createFile(atPath: target.path, contents: nil)
        try FileManager.default.createSymbolicLink(
            atPath: UsbRescue.linkFile(for: link), withDestinationPath: target.path)
        XCTAssertEqual(
            URL(fileURLWithPath: link).resolvingSymlinksInPath().path,
            target.resolvingSymlinksInPath().path)
    }

    // MARK: - the relaunch loop

    func testAShortWindowIsAMissAndTheSameEsptoolKeepsWaiting() async {
        let world = World(
            baseline: [other, ("/dev/cu.usbmodemFLICK", 0, 5), ("/dev/cu.usbmodemFLICK", 5.5, 1e9)],
            windows: [(board, 6.0, 6.2), (board, 9.0, 1e9)])
        let result = await world.run()
        XCTAssertEqual(result, board)
        XCTAssertEqual(Set(world.links), [board], "only the new port is ever linked")
        XCTAssertTrue(world.said("esptool is ready; waiting for the board"))
        XCTAssertTrue(world.said("dropped off before esptool reached it"))
        XCTAssertTrue(world.said("Ignoring /dev/cu.usbmodemFLICK"))
        XCTAssertEqual(world.workers.count, 1, "a miss before connecting costs no relaunch")
        XCTAssertTrue(world.workers[0].killed, "esptool is stopped at the end")
        XCTAssertTrue(world.events.contains(.log(.esptool, "Connected to ESP32-S3 on \(board):")))
    }

    func testAFailedWriteAfterTheBoardDropsOffRelaunchesEsptool() async {
        let world = World(baseline: [other], windows: [(board, 6.0, 7.0), (board, 14.0, 1e9)])
        let result = await world.run()
        XCTAssertEqual(result, board)
        XCTAssertEqual(world.workers.count, 2, "a failed esptool is relaunched")
        XCTAssertTrue(world.workers[0].killed, "the failed esptool is reaped")
        XCTAssertTrue(world.said("dropped off before esptool reached it"))
        XCTAssertTrue(world.said("esptool: could not open port"))
        XCTAssertTrue(world.said("esptool is waiting again"))
    }

    func testAFailedWriteWithTheBoardStillAttachedRetriesWithoutAReplug() async {
        let world = World(baseline: [other], windows: [(board, 6.0, 1e9)])
        world.failFirst = true
        let result = await world.run()
        XCTAssertEqual(result, board)
        XCTAssertTrue(world.said("could not finish on \(board); trying again"))
        XCTAssertTrue(world.said("esptool reaches it in a moment"))
        XCTAssertFalse(world.said("dropped off"))
        XCTAssertTrue(world.steps.contains(.seenWhileStarting(port: board)))
    }

    func testTwoNewPortsAreNeverTouched() async {
        let world = World(
            baseline: [other], windows: [(board, 6.0, 1e9), ("/dev/cu.usbmodemC", 6.0, 1e9)])
        world.limit = 12
        let result = await world.run()
        XCTAssertEqual(result, "STOPPED")
        XCTAssertTrue(world.links.isEmpty)
        XCTAssertTrue(world.said("2 new ports appeared"))
        XCTAssertTrue(world.workers[0].killed, "esptool is stopped when the run is stopped")
        XCTAssertEqual(world.steps.last, .tooManyPorts([board, "/dev/cu.usbmodemC"]))
    }

    /// The human may do their one action the moment they press Start: a board
    /// that comes up while esptool is still starting is new, and is caught.
    func testAPortThatAppearsWhileEsptoolStartsIsCaughtOnceItIsReady() async {
        let world = World(baseline: [other], windows: [(board, 1.5, 1e9)])
        let result = await world.run()
        XCTAssertEqual(result, board)
        XCTAssertEqual(world.links, [board])
        XCTAssertTrue(world.steps.contains(.seenWhileStarting(port: board)))
    }

    // MARK: - a board that is already attached

    func testAChosenAttachedPortIsRecoveredWithoutAReplug() async {
        let world = World(baseline: [other, (board, 0, 1e9)], windows: [])
        world.adopted = { _ in self.board }
        let result = await world.run()
        XCTAssertEqual(result, board)
        XCTAssertEqual(world.links, [board], "only the chosen port is linked")
        XCTAssertTrue(world.said("chosen"))
    }

    func testAPortChosenPartWayThroughTheRunIsTakenThen() async {
        let world = World(baseline: [other, (board, 0, 1e9)], windows: [])
        world.adopted = { t in t >= 10 ? self.board : nil }
        let result = await world.run()
        XCTAssertEqual(result, board)
        XCTAssertEqual(world.links, [board])
        XCTAssertGreaterThanOrEqual(world.workers[0].linkedAt, 10)
    }

    /// A native-USB port is named for its socket: a different board plugged
    /// into the same socket comes back under the chosen name and is not taken.
    func testAChosenPortThatComesBackAsAnotherDeviceIsLeftAlone() async {
        let world = World(baseline: [other, (board, 0, 2)], windows: [(board, 3, 1e9)])
        world.adopted = { _ in self.board }
        var swapped = false
        world.registry = [board: .init(location: 0x131010, serial: "7C:0C:5F:42:39:A4")]
        let io = world.io
        var probed = io
        probed.identifyPort = { port in
            if world.t >= 3 { swapped = true }
            return world.t >= 3
                ? .init(location: 0x131010, serial: "68:EE:8F:5D:AC:8C") : world.registry[port]
        }
        world.limit = 20
        let result: String
        do {
            result = try await UsbRescuer.run(
                family: .named("s3")!, regions: UsbRescueTests.regions, io: probed
            ) { world.events.append($0) }
        } catch {
            result = "STOPPED"
        }
        XCTAssertTrue(swapped)
        XCTAssertEqual(result, "STOPPED")
        XCTAssertTrue(world.links.isEmpty, "the other board is never reset or written")
        XCTAssertTrue(world.said("another USB device"))
    }

    /// Review round 2: once refused, the other board stays refused however
    /// often it drops off and comes back; only a new choice records anew.
    func testARefusedOtherBoardOnTheChosenPortStaysRefusedThroughAFlicker() async {
        let world = World(
            baseline: [other, (board, 0, 2)],
            windows: [(board, 3, 8), (board, 8.5, 1e9)])
        world.adopted = { _ in self.board }
        var probed = world.io
        probed.identifyPort = { _ in
            world.t >= 3
                ? .init(location: 0x131010, serial: "68:EE:8F:5D:AC:8C")
                : .init(location: 0x131010, serial: "7C:0C:5F:42:39:A4")
        }
        world.limit = 30
        do {
            _ = try await UsbRescuer.run(
                family: .named("s3")!, regions: UsbRescueTests.regions, io: probed
            ) { world.events.append($0) }
        } catch {}
        XCTAssertTrue(world.links.isEmpty, "the other board is never reset or written")
    }

    func testChoosingThePortAgainRecordsTheBoardNowOnIt() async {
        let world = World(baseline: [other, (board, 0, 2)], windows: [(board, 3, 1e9)])
        var probed = world.io
        probed.adopted = { self.board }
        // The person sees the refusal and chooses the port again at t = 10.
        probed.adoptedGeneration = { world.t >= 10 ? 1 : 0 }
        probed.identifyPort = { _ in
            world.t >= 3
                ? .init(location: 0x131010, serial: "68:EE:8F:5D:AC:8C")
                : .init(location: 0x131010, serial: "7C:0C:5F:42:39:A4")
        }
        let result = (try? await UsbRescuer.run(
            family: .named("s3")!, regions: UsbRescueTests.regions, io: probed
        ) { world.events.append($0) }) ?? "STOPPED"
        XCTAssertEqual(result, board)
        XCTAssertEqual(world.links, [board])
        XCTAssertGreaterThanOrEqual(world.workers.last?.linkedAt ?? 0, 10)
        let choice = UsbRescuer.PortChoice()
        choice.port = board
        choice.port = board
        XCTAssertEqual(choice.generation, 2, "each choice counts, the same port too")
    }

    func testAnAttachedPortThatDropsAndReturnsIsStillLeftAloneUnlessChosen() async {
        let world = World(
            baseline: [other, (board, 0, 5), (board, 6, 1e9)], windows: [])
        world.limit = 20
        let result = await world.run()
        XCTAssertEqual(result, "STOPPED")
        XCTAssertTrue(world.links.isEmpty)
        XCTAssertTrue(world.said("choose it"),
                      "the way to take it is to choose it, not to replug it")
    }

    // MARK: - one physical action

    /// Nothing the run says asks for the board to be unplugged or plugged in
    /// again: a battery board does not restart that way, and every reset after
    /// the one action is esptool's, over USB.
    func testNoInstructionAsksForTheBoardToBeReplugged() async {
        let runs: [World] = [
            World(baseline: [other], windows: [(board, 6.0, 6.2), (board, 9.0, 1e9)]),
            World(baseline: [other], windows: [(board, 6.0, 7.0), (board, 14.0, 1e9)]),
            World(baseline: [other, (board, 0, 5), (board, 6, 1e9)], windows: []),
        ]
        let foreign = World(baseline: [other], windows: [(board, 6.0, 1e9)])
        foreign.foreign = [board]
        let wrong = World(baseline: [other], windows: [(board, 6.0, 1e9)])
        wrong.wrongChip = [board]
        for world in runs + [foreign, wrong] {
            world.limit = 30
            _ = await world.run()
            let texts = world.messages + world.steps.flatMap { [$0.title, $0.detail ?? ""] }
            for text in texts {
                XCTAssertNil(text.range(of: "unplug|plug (it|the board) in|plugged in again|once more|keep it plugged",
                                        options: [.regularExpression, .caseInsensitive]),
                             "asks for a replug: \(text)")
            }
        }
    }

    func testEachFamilySaysItsOneDownloadModeAction() {
        let s3 = UsbRescue.Family.named("s3")!.downloadModeAction
        XCTAssertTrue(s3.contains("BOOT") && s3.contains("RESET") && s3.contains("PWR"),
                      "S3 boards come with RESET or with PWR; both are named: \(s3)")
        let c6 = UsbRescue.Family.named("c6")!.downloadModeAction
        XCTAssertTrue(c6.contains("BOOT") && c6.contains("RESET"))
        let p4 = UsbRescue.Family.named("p4")!.downloadModeAction
        XCTAssertTrue(p4.localizedCaseInsensitiveContains("nothing to press"),
                      "P4 boards are reset by esptool through their USB-UART bridge")
        for family in UsbRescue.Family.all {
            XCTAssertNil(family.downloadModeAction.range(
                of: "unplug|replug", options: [.regularExpression, .caseInsensitive]),
                "\(family.key): \(family.downloadModeAction)")
        }
    }

    func testABoardEsptoolCannotReachIsGivenUpAndTheNextOneIsRescued() async {
        let foreign = "/dev/cu.usbserial-FOREIGN"
        let world = World(baseline: [other], windows: [(foreign, 6.0, 1e9), (board, 20.0, 1e9)])
        world.foreign = [foreign]
        let result = await world.run()
        XCTAssertEqual(result, board)
        XCTAssertTrue(world.said("could not connect to \(foreign)"))
        XCTAssertEqual(world.links, [foreign, board], "a refused port is not relinked")
        XCTAssertTrue(world.workers[0].killed && world.workers[0].code == nil,
                      "the esptool that gave up is killed, not left connecting")
        XCTAssertEqual(world.workers[0].links, [foreign])
        XCTAssertEqual(world.workers.dropFirst().first?.links, [board])
        XCTAssertTrue(world.steps.contains(.couldNotConnect(port: foreign, family: "s3")))
    }

    func testAnEsptoolThatStopsWhileWaitingIsAFailureNotALoop() async {
        let world = World(baseline: [other], windows: [])
        world.earlyExit = true
        let result = await world.run()
        XCTAssertEqual(result, "FAIL: esptool stopped while waiting for the board")
        XCTAssertEqual(world.workers.count, 1)
        XCTAssertTrue(world.workers[0].killed)
    }

    func testAConnectJustAfterTheTimeoutIsNeverWritten() async {
        let slow = "/dev/cu.usbmodemSLOW"
        let world = World(baseline: [other], windows: [(slow, 6.0, 1e9), (board, 22.0, 1e9)])
        world.connectAfter = [slow: 10.4]
        let result = await world.run()
        XCTAssertFalse(world.written.contains(slow))
        XCTAssertEqual(result, board)
        XCTAssertTrue(world.said("could not connect to \(slow)"))
    }

    /// A board attached before the run, moved to a socket on the Mac itself
    /// after "Plug the board in now", under the names macOS really gives it.
    func testARenamedPortOfAnAttachedBoardIsNotNew() async {
        let attached = "/dev/cu.usbmodem1312201"
        let renamed = "/dev/cu.usbmodem14101"
        let fresh = "/dev/cu.usbmodem101"
        let world = World(
            baseline: [(attached, 0, 6)], windows: [(renamed, 6.5, 1e9), (fresh, 12.0, 1e9)])
        world.identities = [
            attached: .init(location: 0x131220, serial: "1C:DB:D4:7B:5B:94"),
            renamed: .init(location: 0x1410_0000, serial: "1C:DB:D4:7B:5B:94"),
            fresh: .init(location: 0x0010_0000, serial: "68:EE:8F:5D:AC:8C"),
        ]
        let result = await world.run()
        XCTAssertFalse(world.links.contains(renamed))
        XCTAssertTrue(world.said("same USB device"))
        XCTAssertEqual(result, fresh)
    }

    /// The registry's answer wins over the name: a pre-attached board under a
    /// name no rule parses is still recognised.
    func testTheRegistrysDeviceForAPortIsUsedBeforeItsName() async {
        let attached = "/dev/cu.usbmodem5B901700691"
        let moved = "/dev/cu.usbserial-0001"
        let device = UsbRescue.USBIdentity(location: 0x131220, serial: "5B90170069")
        let world = World(baseline: [(attached, 0, 6)], windows: [(moved, 6.5, 1e9)])
        world.identities = [attached: device]
        world.registry = [moved: UsbRescue.USBIdentity(location: 0x1410_0000, serial: "5B90170069")]
        world.limit = 20
        let result = await world.run()
        XCTAssertEqual(result, "STOPPED")
        XCTAssertTrue(world.links.isEmpty)
        XCTAssertTrue(world.said("same USB device"))
        XCTAssertNil(UsbRescuer.usbDevice(forPort: "/dev/cu.not-a-registered-port"),
                     "a port nothing publishes has no device (registry read only)")
    }

    func testAWrongChipFamilyIsGivenUpInsteadOfResetForever() async {
        let world = World(baseline: [other], windows: [(board, 6.0, 1e9)])
        world.wrongChip = [board]
        world.limit = 60
        let result = await world.run()
        XCTAssertEqual(result, "STOPPED")
        XCTAssertEqual(world.links, [board], "the board is reset once, not every few seconds")
        XCTAssertTrue(world.said("is it an ESP32-S3 board?"))
        XCTAssertTrue(world.steps.contains(.couldNotConnect(port: board, family: "s3")))
    }

    func testRepeatedWriteFailuresOnOnePortAreGivenUp() async {
        let world = World(baseline: [other], windows: [(board, 6.0, 1e9)])
        world.alwaysFails = [board]
        world.limit = 120
        let result = await world.run()
        XCTAssertEqual(result, "STOPPED")
        XCTAssertEqual(world.links.count, UsbRescue.failuresBeforeRefusal,
                       "after that many failed writes the port is left alone")
        XCTAssertTrue(world.said("is it an ESP32-S3 board?"))
    }

    func testAHungWriteIsGivenUpAfterTheWriteLimit() async {
        let world = World(baseline: [other], windows: [(board, 6.0, 1e9)])
        world.hangsAfterConnect = [board]
        world.limit = UsbRescue.writeTimeout + 30
        let result = await world.run()
        XCTAssertEqual(result, "STOPPED")
        XCTAssertTrue(world.workers[0].killed, "the hung esptool is killed at the limit")
        XCTAssertGreaterThan(world.workers.count, 1)
        XCTAssertTrue(world.said("stopped writing to \(board)"))
    }

    func testTheStartMessageSaysBoardsAttachedNowAreLeftAlone() async {
        let world = World(baseline: [other], windows: [])
        world.limit = 5
        _ = await world.run()
        let first = world.messages.first ?? ""
        XCTAssertFalse(first.contains("unplug it now"),
                       "a board unplugged after Start comes back under the same name and is ignored")
        XCTAssertTrue(world.said("left alone"))
        XCTAssertTrue(world.said("/dev/cu.usbmodemOTHER"))
    }

    // MARK: - phase reporting

    func testARunReportsEachInstructionInOrder() async {
        let world = World(baseline: [other], windows: [(board, 6.0, 6.2), (board, 9.0, 1e9)])
        _ = await world.run()
        XCTAssertEqual(world.steps, [
            .startingEsptool, .plugIn, .caught(port: board),
            .missed(esptoolReady: true), .caught(port: board), .rescued(port: board),
        ])
        let flashPhases = world.events.compactMap { event -> UsbFlashPhase? in
            if case .phase(let phase) = event, case .rescue = phase { return nil }
            if case .phase(let phase) = event { return phase }
            return nil
        }
        XCTAssertEqual(flashPhases.first, .enteringDownloadMode,
                       "esptool's own output drives the flash phases once linked")
        XCTAssertTrue(flashPhases.contains {
            if case .writing(let part) = $0 { return part.role == "app" && part.index == 4 }
            return false
        })
    }

    func testAMissAfterConnectingSaysSoWhileEsptoolRestarts() async {
        let world = World(baseline: [other], windows: [(board, 6.0, 7.0), (board, 14.0, 1e9)])
        _ = await world.run()
        let missed = world.steps.filter { if case .missed = $0 { return true }; return false }
        XCTAssertEqual(missed, [.missed(esptoolReady: false), .missed(esptoolReady: true)])
    }

    func testRescueStepsReadAsPlainInstructions() {
        XCTAssertEqual(UsbFlashPhase.rescue(.plugIn).title, "Waiting for the board")
        XCTAssertEqual(UsbFlashPhase.rescue(.missed(esptoolReady: true)).title,
                       "The board dropped off before esptool reached it")
        XCTAssertEqual(UsbFlashPhase.rescue(.missed(esptoolReady: false)).detail,
                       "esptool is starting again.")
        XCTAssertEqual(
            UsbRepairModel.headline(for: .installing(Self.rescuedBoard()), phase: .writing(
                FlashPartProgress(index: 1, count: 4, role: "bootloader", address: 0,
                                  percent: 5, bytesBefore: 0, bytes: 1, totalBytes: 4))),
            "Rescue firmware is on - installing the real firmware")
        XCTAssertEqual(UsbRepairModel.headline(for: .catching, phase: .rescue(.plugIn)),
                       "Waiting for the board")
        XCTAssertEqual(UsbRepairModel.headline(for: .catching, phase: .enteringDownloadMode),
                       "Got it - leave the board as it is")
    }

    func testARepairFailureNamesTheStepAndWhatToDo() {
        var session = UsbFlashSession(flow: .repair)
        session.apply(.phase(.rescue(.startingEsptool)), at: 0)
        session.apply(.phase(.rescue(.plugIn)), at: 4)
        XCTAssertEqual(session.phase?.title, "Waiting for the board")
        XCTAssertTrue(session.transcript.text.contains("Waiting for the board - esptool is ready"))
        session.apply(.log(.esptool, "A fatal error occurred: could not open port"), at: 5)
        session.fail(title: "esptool stopped while waiting for the board",
                     message: "could not open port", at: 5)
        XCTAssertEqual(session.failure?.step, "Waiting for the board")
        XCTAssertEqual(session.failure?.lastSeen, ["A fatal error occurred: could not open port"])
        XCTAssertTrue(session.failure?.nextAction.contains("press Resume, or Start Over") == true)

        var installing = UsbFlashSession(flow: .repair)
        installing.apply(.phase(.waitingForBoard(SettleWait(
            target: .reappear(flashedPort: board), attempt: 1, elapsed: 1, budget: 60))), at: 0)
        installing.fail(title: "The board did not come back", message: "", at: 1)
        XCTAssertTrue(installing.failure?.nextAction.hasPrefix("Press Resume") == true)
        for phase: UsbFlashPhase in [
            .findingBoard, .enteringDownloadMode, .restarting, .rescue(.rescued(port: board)),
            .rescue(.plugIn),
        ] {
            var repair = UsbFlashSession(flow: .repair)
            repair.apply(.phase(phase), at: 0)
            repair.fail(title: "x", message: "", at: 1)
            XCTAssertNil(repair.failure?.nextAction.range(
                of: "unplug|plug it|replug", options: [.regularExpression, .caseInsensitive]),
                "\(phase): \(repair.failure?.nextAction ?? "")")
        }
    }

    // MARK: - the process-tree kill

    /// A fake process group that ignores SIGTERM until `termWorks`.
    final class FakeGroup: @unchecked Sendable {
        var signals: [Int32] = []
        var alive = true
        var termWorks = false
        var clock = 0.0

        var seam: EsptoolRunner.Signals {
            EsptoolRunner.Signals(
                signalGroup: { _, signal in
                    // Every attempt is recorded, dead group or not, so a test
                    // can see a kill that should not have signalled at all.
                    self.signals.append(signal)
                    guard self.alive else { return false }
                    if signal == SIGKILL || (signal == SIGTERM && self.termWorks) {
                        self.alive = false
                    }
                    return true
                },
                groupAlive: { _ in self.alive },
                reap: { _ in self.alive ? nil : -self.signals.last! },
                sleep: { self.clock += $0 },
                now: { self.clock })
        }
    }

    func testKillSendsSIGTERMToTheGroupAndStopsThereWhenItWorks() {
        let group = FakeGroup()
        group.termWorks = true
        let process = EsptoolRunner.WaitingProcess(pid: 4242, fd: nil, signals: group.seam)
        process.kill(grace: 1)
        XCTAssertEqual(group.signals, [SIGTERM])
        XCTAssertEqual(process.exitCode, -SIGTERM)
    }

    func testKillEscalatesToSIGKILLAfterTheGrace() {
        let group = FakeGroup()
        let process = EsptoolRunner.WaitingProcess(pid: 4242, fd: nil, signals: group.seam)
        process.kill(grace: 1)
        XCTAssertEqual(group.signals, [SIGTERM, SIGKILL])
        XCTAssertGreaterThanOrEqual(group.clock, 1, "SIGKILL only after the grace period")
        process.kill(grace: 1)
        XCTAssertEqual(group.signals, [SIGTERM, SIGKILL], "a second kill signals nothing")
    }

    /// The bundled esptool is a PyInstaller bootloader with the real esptool as
    /// its child; killing only the parent would leave the child holding the
    /// port. This shell has the same shape, and both ignore SIGTERM, so only a
    /// SIGKILL to the whole group ends it.
    func testKillStopsTheWholeProcessTree() throws {
        let directory = try temporaryDirectory()
        let process = try EsptoolRunner.WaitingProcess(
            EsptoolCommand(executable: "/bin/sh", arguments: ["-c",
                "trap '' TERM; sleep 60 & echo child $!; "
                    + "[ -t 1 ] && echo on-a-terminal; echo Retrying failed connection; wait"]),
            environment: ["PATH": "/usr/bin:/bin"], directory: directory.path)
        var output = ""
        XCTAssertTrue(waitFor(5) {
            output += process.read()
            return output.contains("Retrying failed connection")
        })
        XCTAssertTrue(output.contains("on-a-terminal"), "esptool writes to a terminal, not a pipe")
        // A terminal ends lines with \r\n, one Character in Swift, so split on
        // the scalar set rather than on "\n".
        let child = try XCTUnwrap(output.components(separatedBy: .newlines)
            .first { $0.hasPrefix("child ") }
            .flatMap { Int32($0.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)) })
        XCTAssertTrue(isAlive(child))
        process.kill(grace: 0.5)
        XCTAssertNotNil(process.exitCode, "the leader is reaped, not left a zombie")
        XCTAssertTrue(waitFor(5) { !self.isAlive(child) }, "the child is stopped with its parent")
    }

    /// The app quitting or crashing never runs kill(): its end closes its
    /// descriptors, and that alone must stop an esptool that retries forever.
    func testTheAppGoingAwayStopsTheWholeTree() throws {
        let directory = try temporaryDirectory()
        let process = try EsptoolRunner.WaitingProcess(
            EsptoolCommand(executable: "/bin/sh", arguments: ["-c",
                "sleep 60 & echo child $!; echo Retrying failed connection; wait"]),
            environment: ["PATH": "/usr/bin:/bin"], directory: directory.path)
        var output = ""
        XCTAssertTrue(waitFor(5) {
            output += process.read()
            return output.contains("Retrying failed connection")
        })
        let child = try XCTUnwrap(output.components(separatedBy: .newlines)
            .first { $0.hasPrefix("child ") }
            .flatMap { Int32($0.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)) })
        XCTAssertTrue(isAlive(child))
        usleep(300_000)
        XCTAssertNil(process.poll(), "the watchdog waits while the app is there")
        process.abandon()
        XCTAssertTrue(waitFor(5) { process.poll() != nil }, "the leader is hung up")
        XCTAssertTrue(waitFor(5) { !self.isAlive(child) }, "and so is its child")
    }

    func testTheWatchdogPassesEsptoolsExitStatusThrough() throws {
        let directory = try temporaryDirectory()
        let process = try EsptoolRunner.WaitingProcess(
            EsptoolCommand(executable: "/bin/sh", arguments: ["-c", "exit 3"]),
            environment: ["PATH": "/usr/bin:/bin"], directory: directory.path)
        XCTAssertTrue(waitFor(5) { process.poll() != nil })
        XCTAssertEqual(process.exitCode, 3)
    }

    func testTheWorkerSeesReadinessAndAnUnflushedConnect() throws {
        let directory = try temporaryDirectory()
        let link = UsbRescue.linkPath(directory: directory.path, index: 0)
        let process = try EsptoolRunner.WaitingProcess(
            EsptoolCommand(executable: "/bin/sh", arguments: ["-c",
                "echo Retrying failed connection; sleep 1; "
                    + "printf 'Connected to ESP32-S3 on /dev/x:'; sleep 30"]),
            environment: ["PATH": "/usr/bin:/bin"], directory: directory.path)
        let worker = UsbRescuer.EsptoolWorker(process: process, link: link)
        defer { worker.kill() }
        XCTAssertTrue(waitFor(5) { worker.poll() == nil && worker.isReady })
        try worker.link(to: "/dev/cu.usbmodemB")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: UsbRescue.linkFile(for: link)),
            "/dev/cu.usbmodemB", "linking points the waiting path at the new port")
        XCTAssertTrue(waitFor(5) { worker.poll() == nil && worker.isConnected })
        XCTAssertTrue(worker.takeOutput().contains("Connected to"))
        worker.kill()
        XCTAssertFalse(FileManager.default.fileExists(atPath: UsbRescue.linkFile(for: link)),
                       "killing a worker removes its link")
        XCTAssertNotNil(worker.poll())
    }

    // MARK: - the esptool invocation

    func testEachSpawnGetsItsOwnLinkAndTheCLIsArguments() throws {
        let work = try temporaryDirectory()
        var made: [(EsptoolCommand, [String: String], String)] = []
        let spawn = try UsbRescuer.spawner(
            family: .named("s3")!, regions: Self.regions, work: work,
            tool: EsptoolCommand.Tool(path: "/opt/esptool"),
            environment: ["PATH": "/bin"]
        ) { command, environment, link in
            made.append((command, environment, link))
            return FakeWorker(world: World(baseline: [], windows: []))
        }
        _ = try spawn()
        _ = try spawn()
        XCTAssertEqual(made.count, 2)
        XCTAssertNotEqual(made[0].2, made[1].2, "a relaunched esptool never shares a link")
        for (command, environment, link) in made {
            XCTAssertEqual(command.executable, "/opt/esptool")
            XCTAssertEqual(command.arguments, [
                "--chip", "esp32s3", "--port", link, "--baud", "921600",
                "--before", "default-reset", "--after", "hard-reset", "write-flash",
                "0x0", "/r/bootloader.bin", "0x8000", "/r/partitions.bin",
                "0xe000", "/r/boot_app0.bin", "0x10000", "/r/app.bin",
            ])
            XCTAssertEqual(environment["ESPTOOL_OPEN_PORT_ATTEMPTS"], "0")
            XCTAssertEqual(environment["PATH"], "/bin")
            let config = try String(contentsOfFile: try XCTUnwrap(environment["ESPTOOL_CFGFILE"]),
                                    encoding: .utf8)
            XCTAssertTrue(config.contains("open_port_attempts = 0"))
            XCTAssertTrue(config.contains("connect_attempts = 4"))
        }
    }

    func testTheRescueWriteNeverErasesAndStillRefusesAnEmptyPort() throws {
        let tool = EsptoolCommand.Tool(path: "/opt/esptool")
        let writes = [EsptoolCommand.StagedWrite(role: "app", address: 0x10000, path: "/r/app.bin")]
        let command = try EsptoolCommand.rescueWriteFlash(
            tool: tool, chip: "esp32p4", port: "/dev/../x/port-0", baud: 460_800, writes: writes)
        XCTAssertFalse(command.arguments.contains("-e"))
        XCTAssertEqual(command.arguments[5], "460800")
        XCTAssertThrowsError(try EsptoolCommand.rescueWriteFlash(
            tool: tool, chip: "esp32p4", port: " ", baud: 460_800, writes: writes)) {
            XCTAssertEqual($0 as? EsptoolCommandError, .noPort)
        }
        XCTAssertEqual(UsbRescue.Family.named("p4")?.baud, 460_800)
        XCTAssertEqual(UsbRescue.Family.all.map(\.chip), ["esp32c3", "esp32c6", "esp32s3", "esp32p4"])
    }

    // MARK: - the images the app carries

    func testEveryCommittedRescueImageLoadsAndVerifies() throws {
        for family in UsbRescue.Family.all {
            let regions = try UsbRescue.loadImage(
                family: family, directory: Self.repoRoot.appendingPathComponent(
                    "firmware-rescue/\(family.key)"))
            XCTAssertEqual(regions.map(\.role).sorted(), UsbRescue.roles.sorted(), family.key)
            XCTAssertEqual(regions.first { $0.role == "app" }?.address, 0x10000)
        }
    }

    func testATamperedOrMisfiledRescueImageIsRefused() throws {
        let copy = try temporaryDirectory().appendingPathComponent("s3")
        try FileManager.default.copyItem(
            at: Self.repoRoot.appendingPathComponent("firmware-rescue/s3"), to: copy)
        XCTAssertThrowsError(try UsbRescue.loadImage(family: .named("c6")!, directory: copy)) {
            guard case .malformed = $0 as? UsbRescue.ImageError else {
                return XCTFail("\($0)")
            }
        }
        let indexURL = copy.appendingPathComponent(UsbRescue.indexName)
        let original = try Data(contentsOf: indexURL)
        var index = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var regions = try XCTUnwrap(index["regions"] as? [[String: Any]])
        regions.append(["address": 0x300000, "file": "app.bin", "bytes": 1, "sha256": "x"])
        index["regions"] = regions
        try JSONSerialization.data(withJSONObject: index).write(to: indexURL)
        XCTAssertThrowsError(try UsbRescue.loadImage(family: .named("s3")!, directory: copy),
                             "a region without a role is refused, as the CLI refuses it")
        try original.write(to: indexURL)
        let handle = try FileHandle(forWritingTo: copy.appendingPathComponent("app.bin"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        XCTAssertThrowsError(try UsbRescue.loadImage(family: .named("s3")!, directory: copy)) {
            XCTAssertEqual($0 as? UsbRescue.ImageError, .mismatch(file: "app.bin"))
        }
    }

    // MARK: - after the write

    func testTheRescuedBoardIsReadWithItsStoredOverride() async {
        let tries = Counter()
        let events = EventLog()
        let rescued = await UsbRescuer.readRescuedBoard(
            port: board, family: .named("s3")!, exists: { _ in true },
            send: { command, _, _ in
                XCTAssertEqual(command, "CFGSHOW")
                tries.count += 1
                return tries.count < 3 ? .failure("no response")
                    : .success("CFGINFO id=aabbccddeeff board=st7789-190 profile=st7789-190 "
                        + "target=s3 chip=esp32s3 partition=universal-8m-doom-ota "
                        + "cfgboard=st7789-190")
            },
            sleep: { _ in }, onProgress: { events.append($0) })
        XCTAssertEqual(tries.count, 3, "a rescue image still restarting is asked again")
        XCTAssertEqual(rescued?.storedOverride, "st7789-190")
        XCTAssertEqual(rescued?.identity.hardwareID, "aabbccddeeff")
        XCTAssertEqual(rescued?.identity.target, "s3")
        XCTAssertEqual(events.events.first, .phase(.rescue(.readingBoard(port: self.board))))
        XCTAssertNil(UsbRescue.storedOverride(inReply: "CFGINFO id=aabbccddeeff cfgboard=auto"))
    }

    func testTheInstallTakesTheRescuedBoardsFamilyImage() throws {
        let releases = try Self.releaseSet()
        let s3 = try PanelManager.repairInstallSelection(
            for: Self.rescuedBoard(), releases: releases)
        XCTAssertEqual(s3.canonicalTarget, "s3")
        XCTAssertNotNil(s3.selection.bundle.flashPlan(forTarget: "s3"))
    }

    static func rescuedP4(carrier: String?, reported: String) -> UsbRescuer.RescuedBoard {
        UsbRescuer.RescuedBoard(
            port: "/dev/cu.usbmodemB", family: .named("p4")!,
            identity: WifiConfigUI.usbIdentity(from:
                "CFGINFO id=e8f60ae0a0e4 board=\(reported) profile=\(reported) target=p4 "
                    + "chip=esp32p4 partition=p4-32m-ota cfgboard=auto"),
            storedOverride: nil, carrier: carrier)
    }

    /// P4 takes the CLI's carrier guard: the user names the carrier before the
    /// rescue image is written, and the install goes ahead only when the
    /// rescue image's own detection agrees with that choice.
    func testAP4InstallNeedsTheNamedCarrierToMatchTheRescuedBoard() throws {
        let releases = try Self.releaseSet()
        let p4 = try PanelManager.repairInstallSelection(
            for: Self.rescuedP4(carrier: "jd9365-4c", reported: "jd9365-4c"),
            releases: releases)
        XCTAssertEqual(p4.canonicalTarget, "p4")
        XCTAssertThrowsError(try PanelManager.repairInstallSelection(
            for: Self.rescuedP4(carrier: "st7703-4b", reported: "jd9365-4c"),
            releases: releases)
        ) { error in
            XCTAssertEqual(error as? PanelManager.RepairInstallError,
                           .carrierMismatch(chosen: "st7703-4b", reported: "jd9365-4c"))
            XCTAssertTrue(error.localizedDescription.contains("st7703-4b"))
        }
        XCTAssertThrowsError(try PanelManager.repairInstallSelection(
            for: Self.rescuedP4(carrier: nil, reported: "jd9365-4c"),
            releases: releases)
        ) { error in
            XCTAssertEqual(error as? PanelManager.RepairInstallError,
                           .carrierMismatch(chosen: nil, reported: "jd9365-4c"))
        }
    }

    @MainActor
    func testTheP4RepairWaitsForACarrierBeforeStarting() {
        let model = UsbRepairModel(family: .named("p4"))
        XCTAssertTrue(model.needsCarrier)
        XCTAssertFalse(model.canStart)
        XCTAssertEqual(model.carrierChoices.map(\.profile),
                       ["st7703-4b", "jd9365-4c", "jd9365-34c"])
        model.carrier = "jd9365-4c"
        XCTAssertTrue(model.canStart)
        model.carrier = "co5300"
        XCTAssertFalse(model.canStart, "a profile from another family is no choice")
        let s3 = UsbRepairModel(family: .named("s3"))
        XCTAssertFalse(s3.needsCarrier)
        XCTAssertTrue(s3.canStart)
        XCTAssertFalse(UsbRepairModel(family: nil).canStart)
    }

    /// What the S3 rescue image really says when its detector finds no board:
    /// variantToken(Unknown) is "auto" and targetToken(Unknown) "unknown".
    func testAnUnidentifiedBoardIsRefusedAndSaysSo() throws {
        let releases = try Self.releaseSet()
        var unidentified = Self.rescuedBoard()
        unidentified.identity = WifiConfigUI.usbIdentity(from:
            "CFGINFO id=aabbccddeeff board=auto profile=auto target=unknown "
                + "chip=esp32s3 partition=universal-8m-doom-ota cfgboard=auto")
        XCTAssertThrowsError(
            try PanelManager.repairInstallSelection(for: unidentified, releases: releases)
        ) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("could not identify"), message)
            XCTAssertTrue(message.contains("ESP32-S3"), message)
        }
    }

    @MainActor
    func testRepairHoldsBackgroundProbesOfNewPorts() {
        let manager = PanelManager(previewPanels: [], savedNetworkNames: [], usbSerialPorts: [])
        let ports = ["/dev/cu.usbmodem-not-a-device"]
        XCTAssertEqual(manager.portsToIdentify(ports), ports)
        manager.holdUSBProbes()
        manager.holdUSBProbes()
        XCTAssertEqual(manager.portsToIdentify(ports), [], "no CFGSHOW while a repair holds probes")
        manager.usbProbeHolds -= 1
        XCTAssertEqual(manager.portsToIdentify(ports), [], "one owner's release keeps another's hold")
    }

    func testEsptoolOutputHelpers() {
        XCTAssertEqual(UsbRescue.lastError(in:
            "Connecting....\nA serial exception error occurred: device disconnected\n"
                + "Note: This error originates from pySerial.\nFor troubleshooting steps visit: x\n"),
            "A serial exception error occurred: device disconnected")
        XCTAssertEqual(UsbRescue.strippingTerminalCodes("\u{1B}[33mWarning\u{1B}[0m\u{1B}[2K"),
                       "Warning")
    }

    // MARK: - helpers

    static func rescuedBoard() -> UsbRescuer.RescuedBoard {
        UsbRescuer.RescuedBoard(
            port: "/dev/cu.usbmodemB", family: .named("s3")!,
            identity: WifiConfigUI.usbIdentity(from:
                "CFGINFO id=aabbccddeeff board=st7789-190 profile=st7789-190 target=s3 "
                    + "chip=esp32s3 partition=universal-8m-doom-ota cfgboard=auto"),
            storedOverride: nil)
    }

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static func releaseSet() throws -> BundledFirmware.ReleaseSet {
        let releaseRoot = repoRoot.appendingPathComponent("firmware-releases")
        let catalog = try FirmwareReleaseCatalog.read(
            contentsOf: releaseRoot.appendingPathComponent(FirmwareReleaseCatalog.fileName))
        var options = [String: [BundledFirmware.RevisionOption]]()
        for entry in catalog.families.values {
            options[entry.family] = try entry.revisions.map { revision in
                let url = releaseRoot.appendingPathComponent(revision.artifact)
                let bundle = try FirmwareBundle.read(Data(contentsOf: url))
                return BundledFirmware.RevisionOption(
                    revision: revision,
                    selection: .init(catalogEntry: entry, revision: revision, bundle: bundle, url: url),
                    unavailableReason: nil)
            }
        }
        return .init(catalog: catalog, revisionOptions: options)
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("espdisp-rescue-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func waitFor(_ seconds: Double, _ predicate: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            if predicate() { return true }
            usleep(20_000)
        }
        return predicate()
    }

    private func isAlive(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    final class Counter: @unchecked Sendable { var count = 0 }

    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [UsbFlashEvent] = []
        func append(_ event: UsbFlashEvent) { lock.withLock { stored.append(event) } }
        var events: [UsbFlashEvent] { lock.withLock { stored } }
    }
}
