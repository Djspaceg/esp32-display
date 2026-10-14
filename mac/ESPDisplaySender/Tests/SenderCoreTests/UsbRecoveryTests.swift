import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// Recovery that survives the app: the record a repair keeps on disk, how a
/// recorded board is found again, and what Resume does at each stage. No test
/// here opens a USB port or starts esptool.
@MainActor
final class UsbRecoveryTests: XCTestCase {
    private let board = "/dev/cu.usbmodem1312101"
    private let device = UsbRescue.USBIdentity(location: 0x131010, serial: "7C:0C:5F:42:39:A4")

    private func temporaryStore() throws -> UsbRecoveryStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usb-recovery-tests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return UsbRecoveryStore(url: directory.appendingPathComponent("usb-recovery.json"))
    }

    private func rescued(port: String? = nil) -> UsbRescuer.RescuedBoard {
        var board = UsbRescueTests.rescuedBoard()
        if let port { board.port = port }
        return board
    }

    // MARK: - the record on disk

    func testARecordSurvivesARelaunchAndClears() throws {
        let store = try temporaryStore()
        XCTAssertNil(store.load(), "no file is no recovery")
        var record = UsbRecovery.started(family: "s3", carrier: nil, baseline: ["/dev/cu.a"])
        record = UsbRecovery.caught(record, device: device)
        record = UsbRecovery.rescued(record, board: rescued(port: board), device: device)
        try store.save(record)
        let reopened = UsbRecoveryStore(url: store.url)
        XCTAssertEqual(reopened.load(), record)
        XCTAssertEqual(reopened.load()?.stage, .rescued)
        XCTAssertEqual(reopened.load()?.rescuedBoard(on: board)?.identity.hardwareID, "aabbccddeeff")
        reopened.clear()
        XCTAssertNil(store.load())
    }

    func testAnUnreadableRecordIsNoRecovery() throws {
        let store = try temporaryStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        XCTAssertNil(store.load())
    }

    func testEachStageKeepsWhatTheNextOneNeeds() {
        let started = UsbRecovery.started(family: "p4", carrier: "st7703-4b", baseline: ["/dev/cu.x"])
        XCTAssertEqual(started.stage, .waiting)
        XCTAssertEqual(started.baseline, ["/dev/cu.x"])
        let caught = UsbRecovery.caught(started, device: device)
        XCTAssertEqual(caught.stage, .caught)
        XCTAssertEqual(caught.usbSerial, device.serial)
        XCTAssertEqual(caught.carrier, "st7703-4b")
        let rescuedRecord = UsbRecovery.rescued(caught, board: rescued(port: board), device: device)
        XCTAssertEqual(rescuedRecord.stage, .rescued)
        let installing = UsbRecovery.installing(rescuedRecord)
        XCTAssertEqual(installing.stage, .installing)
        XCTAssertEqual(installing.rescuedBoard(on: board)?.port, board)
        XCTAssertEqual(installing.rescuedBoard(on: board)?.carrier, "st7703-4b")
    }

    // MARK: - finding the board again

    func testTheBoardIsFoundByItsUSBSerialWhereverItIsNow() {
        var record = UsbRecovery.started(family: "s3", carrier: nil, baseline: [])
        record = UsbRecovery.caught(record, device: device)
        let moved = "/dev/cu.usbmodem14101"
        let other = "/dev/cu.usbmodem5B901700691"
        let registry: [String: UsbRescue.USBIdentity] = [
            moved: .init(location: 0x1410_0000, serial: device.serial),
            other: .init(location: 0x131020, serial: "5B90170069"),
        ]
        XCTAssertEqual(UsbRecovery.locate(record, ports: [other, moved]) { registry[$0] }, moved)
    }

    /// The socket a board was in is a port, not the board: one with no USB
    /// serial is not found again by it, so Resume waits for it to be caught.
    func testABoardWithNoSerialIsNotFoundByItsSocket() {
        let noSerial = UsbRescue.USBIdentity(location: 0x131010, serial: "")
        var record = UsbRecovery.started(family: "s3", carrier: nil, baseline: [])
        record = UsbRecovery.caught(record, device: noSerial)
        let registry: [String: UsbRescue.USBIdentity] = [board: noSerial]
        XCTAssertNil(UsbRecovery.locate(record, ports: [board]) { registry[$0] })
        XCTAssertEqual(UsbRecovery.plan(record, located: nil, present: [board]), .waitForBoard)
    }

    /// The record on disk names the board by its USB serial and what it
    /// reported, never by the port or the socket it was reached on. A file
    /// written before still loads, with those read past.
    func testTheRecordKeepsNoPortOrSocket() throws {
        var record = UsbRecovery.started(family: "s3", carrier: nil, baseline: [])
        record = UsbRecovery.rescued(
            UsbRecovery.caught(record, device: device), board: rescued(port: board),
            device: device)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(record), encoding: .utf8))
        XCTAssertFalse(json.contains("\"port\""), json)
        XCTAssertFalse(json.contains("usbLocation"), json)
        XCTAssertFalse(json.contains("usbmodem1312101"), json)

        let older = """
            {"stage":"rescued","family":"s3","baseline":[],"port":"/dev/cu.usbmodem1312101",
             "usbSerial":"7C:0C:5F:42:39:A4","usbLocation":1249296}
            """
        let loaded = try JSONDecoder().decode(
            UsbRecoveryRecord.self, from: Data(older.utf8))
        XCTAssertEqual(loaded.usbSerial, "7C:0C:5F:42:39:A4")
    }

    func testAnotherDeviceOnTheRecordedNameIsNotTheBoard() {
        var record = UsbRecovery.started(family: "s3", carrier: nil, baseline: [])
        record = UsbRecovery.caught(record, device: device)
        let registry: [String: UsbRescue.USBIdentity] = [
            board: .init(location: 0x2000_0000, serial: "68:EE:8F:5D:AC:8C"),
        ]
        XCTAssertNil(UsbRecovery.locate(record, ports: [board]) { registry[$0] })
    }

    // MARK: - what Resume does

    func testResumeTakesUpEachStageWithoutAPhysicalAction() {
        let started = UsbRecovery.started(family: "s3", carrier: nil, baseline: ["/dev/cu.old"])
        let caught = UsbRecovery.caught(started, device: device)
        let rescuedRecord = UsbRecovery.rescued(caught, board: rescued(port: board), device: device)
        let installing = UsbRecovery.installing(rescuedRecord)
        let moved = "/dev/cu.usbmodem14101"

        XCTAssertEqual(UsbRecovery.plan(caught, located: moved, present: [moved]), .adopt(moved),
                       "a board caught but not yet rescued is written again where it is")
        XCTAssertEqual(UsbRecovery.plan(rescuedRecord, located: moved, present: [moved]),
                       .read(moved))
        guard case .install(let again) = UsbRecovery.plan(installing, located: moved, present: [moved])
        else { return XCTFail("an interrupted install is installed again") }
        XCTAssertEqual(again.port, moved)
        XCTAssertEqual(again.identity.hardwareID, "aabbccddeeff")
    }

    /// The baseline may be from an earlier launch, and a port that appeared
    /// since may be another board: it is marked for the person, never chosen.
    func testResumeBeforeAnythingWasCaughtMarksThePortsThatAreNew() {
        let started = UsbRecovery.started(family: "s3", carrier: nil, baseline: ["/dev/cu.old"])
        XCTAssertEqual(UsbRecovery.plan(started, located: nil, present: ["/dev/cu.old", board]),
                       .choose(newPorts: [board]))
        XCTAssertEqual(
            UsbRecovery.plan(started, located: nil, present: ["/dev/cu.old", board, "/dev/cu.c"]),
            .choose(newPorts: ["/dev/cu.c", board]))
    }

    /// Review finding: Resume began a fresh "waiting" record, so a Stop in the
    /// seconds before esptool reached the board again deleted a board that had
    /// been reached, and a quit lost its serial.
    func testAResumedRunKeepsTheRecordOfTheBoardItReached() {
        let caught = UsbRecovery.caught(
            UsbRecovery.started(family: "s3", carrier: nil, baseline: []),
            device: device)
        XCTAssertEqual(UsbRecovery.atStart(existing: caught, resuming: true, family: "s3",
                                           carrier: nil, baseline: ["/dev/cu.x"]), caught)
        XCTAssertEqual(UsbRecovery.atStart(existing: caught, resuming: false, family: "s3",
                                           carrier: nil, baseline: ["/dev/cu.x"]).stage, .waiting,
                       "a fresh Start is a new recovery")
        XCTAssertEqual(UsbRecovery.atStart(existing: caught, resuming: true, family: "c6",
                                           carrier: nil, baseline: []).family, "c6")
    }

    func testARecordIsOverOnceItsBoardAnswersWithRealFirmware() throws {
        let store = try temporaryStore()
        let rescuedRecord = UsbRecovery.rescued(
            UsbRecovery.caught(
                UsbRecovery.started(family: "s3", carrier: nil, baseline: []),
                device: device),
            board: rescued(port: board), device: device)
        XCTAssertTrue(UsbRecovery.isRecordedBoard(rescuedRecord, hardwareID: "aabbccddeeff"))
        XCTAssertTrue(UsbRecovery.isRecordedBoard(rescuedRecord, hardwareID: "7c0c5f4239a4"),
                      "a native-USB serial is the chip's MAC")
        XCTAssertFalse(UsbRecovery.isRecordedBoard(rescuedRecord, hardwareID: "68ee8f5dac8c"))
        try store.save(rescuedRecord)
        let manager = PanelManager(
            previewPanels: [], savedNetworkNames: [], usbSerialPorts: [board], recoveryStore: store)
        let rescueAnswer = WifiConfigUI.usbIdentity(from:
            "CFGINFO name64=c2lsdmVyLXJvdW5k id=aabbccddeeff board=co5300 target=s3 chip=esp32s3")
        manager.noteUSBIdentity(path: board, identity: rescueAnswer, generation: 1)
        XCTAssertNotNil(store.load(), "the rescue image (no fw=) is not the end of it")
        let other = WifiConfigUI.usbIdentity(from:
            "CFGINFO name64=b3RoZXI= id=68ee8f5dac8c board=st7789-190 target=s3 chip=esp32s3 fw=2.0.0")
        manager.noteUSBIdentity(path: board, identity: other, generation: 2)
        XCTAssertNotNil(store.load(), "another board's answer leaves it")
        let real = WifiConfigUI.usbIdentity(from:
            "CFGINFO name64=c2lsdmVyLXJvdW5k id=aabbccddeeff board=co5300 target=s3 chip=esp32s3 fw=2.0.0")
        manager.noteUSBIdentity(path: board, identity: real, generation: 3)
        XCTAssertNil(store.load())
    }

    func testAChosenPortStaysChosenWhileItIsOffUSB() {
        let model = UsbRepairModel(family: .named("s3"))
        var present = [board, "/dev/cu.other"]
        model.listPorts = { present }
        model.refreshPorts()
        model.chosenPort = board
        present = ["/dev/cu.other"]
        model.refreshPorts()
        XCTAssertEqual(model.chosenPort, board)
        XCTAssertTrue(model.attachedPorts.contains(board))
        XCTAssertFalse(model.isOnUSB(board))
    }

    func testResumeWaitsForTheBoardOnlyWhenItIsNotOnUSB() {
        let started = UsbRecovery.started(family: "s3", carrier: nil, baseline: [])
        let caught = UsbRecovery.caught(started, device: device)
        XCTAssertEqual(UsbRecovery.plan(caught, located: nil, present: []), .waitForBoard)
        let installing = UsbRecovery.installing(
            UsbRecovery.rescued(caught, board: rescued(port: board), device: device))
        XCTAssertEqual(UsbRecovery.plan(installing, located: nil, present: []), .waitForBoard)
    }

    // MARK: - the model keeps the record

    func testTheModelRecordsEachStageAndClearsItWhenDone() throws {
        let store = try temporaryStore()
        let model = UsbRepairModel(family: .named("s3"))
        model.store = store
        model.deviceForPort = { [device] _ in device }
        model.noteStarted(baseline: ["/dev/cu.old"])
        XCTAssertEqual(store.load()?.stage, .waiting)
        model.noteProgress(.phase(.rescue(.caught(port: board))))
        XCTAssertEqual(store.load()?.stage, .caught)
        XCTAssertEqual(store.load()?.usbSerial, device.serial)
        model.rescued(rescued(port: board), firmware: .none)
        XCTAssertEqual(store.load()?.stage, .rescued)
        model.noteInstallStarted(rescued(port: board))
        XCTAssertEqual(store.load()?.stage, .installing)
        model.noteInstalled()
        XCTAssertNil(store.load(), "a finished recovery leaves nothing to resume")
    }

    func testStoppingBeforeAnythingIsWrittenLeavesNothingToResume() throws {
        let store = try temporaryStore()
        let model = UsbRepairModel(family: .named("s3"))
        model.store = store
        model.noteStarted(baseline: [])
        model.noteStopped()
        XCTAssertNil(store.load())
    }

    func testStoppingAfterTheBoardIsCaughtKeepsItResumable() throws {
        let store = try temporaryStore()
        let model = UsbRepairModel(family: .named("s3"))
        model.store = store
        model.deviceForPort = { [device] _ in device }
        model.noteStarted(baseline: [])
        model.noteProgress(.phase(.rescue(.caught(port: board))))
        model.noteStopped()
        XCTAssertEqual(store.load()?.stage, .caught)
    }

    func testAnInterruptedRecoveryOpensAsResume() {
        let record = UsbRecovery.installing(UsbRecovery.rescued(
            UsbRecovery.caught(
                UsbRecovery.started(family: "s3", carrier: nil, baseline: []),
                device: device),
            board: rescued(port: board), device: device))
        let model = UsbRepairModel(family: nil, pending: record)
        XCTAssertEqual(model.stage, .resumable(record))
        XCTAssertEqual(model.family, .named("s3"))
        XCTAssertFalse(model.canStart, "Resume or Discard, not a fresh Start")
        let started = UsbRecovery.started(family: "c6", carrier: nil, baseline: [])
        let waiting = UsbRepairModel(family: nil, pending: started)
        XCTAssertEqual(waiting.stage, .resumable(started),
                       "quit while waiting for the board is offered too")
        XCTAssertEqual(waiting.family, .named("c6"))
    }

    func testResumingARecoveryThatNeverReachedTheBoardMarksItsNewPort() throws {
        let store = try temporaryStore()
        let record = UsbRecovery.started(family: "s3", carrier: nil, baseline: ["/dev/cu.old"])
        try store.save(record)
        let manager = PanelManager(
            previewPanels: [], savedNetworkNames: [], usbSerialPorts: [], recoveryStore: store)
        let model = UsbRepairModel(family: nil, pending: store.load(), store: store)
        model.listPorts = { ["/dev/cu.old", self.board] }
        model.resume(manager: manager)
        XCTAssertEqual(model.stage, .choosing, "nothing is started without a Start")
        XCTAssertNil(model.chosenPort, "marked, not chosen")
        XCTAssertEqual(model.newSinceRecoveryBegan, [board])
        XCTAssertTrue(model.canStart)
    }

    func testDiscardForgetsTheRecoveryAndLeavesTheBoardAlone() throws {
        let store = try temporaryStore()
        let record = UsbRecovery.caught(
            UsbRecovery.started(family: "s3", carrier: nil, baseline: []),
            device: device)
        try store.save(record)
        let model = UsbRepairModel(family: nil, pending: store.load(), store: store)
        XCTAssertTrue(model.canResume)
        model.discard()
        XCTAssertNil(store.load())
        XCTAssertEqual(model.stage, .choosing)
        XCTAssertFalse(model.canResume)
    }

    func testTheOneActionIsShownOnlyWhileTheBoardIsBeingWaitedFor() {
        let model = UsbRepairModel(family: .named("s3"))
        XCTAssertFalse(model.waitsForTheBoard, "not before Start")
        model.stage = .catching
        model.monitor.record(.phase(.rescue(.plugIn)))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(model.waitsForTheBoard)
        model.chosenPort = board
        XCTAssertFalse(model.waitsForTheBoard, "a chosen port needs nothing pressed")
        XCTAssertTrue(model.isLookingForTheBoard, "and can still be changed")
        model.chosenPort = nil
        model.monitor.record(.phase(.rescue(.caught(port: board))))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertFalse(model.waitsForTheBoard, "the board is reached")
    }

    func testTheIntroductionSaysTheFamilysActionAndNeverAReplug() {
        for family in UsbRescue.Family.all {
            let text = UsbRepairModel.introduction(for: family)
            XCTAssertTrue(text.contains(family.downloadModeAction))
            XCTAssertNil(text.range(of: "unplug|replug|plug (it|the board) in",
                                    options: [.regularExpression, .caseInsensitive]), text)
        }
    }

    /// Review round 2: a sheet that did not load a kept recovery must not
    /// write over it. A reached record is offered whichever way in; one that
    /// never reached a board only from Recover Board.
    func testAReachedRecoveryIsOfferedWhicheverWayIn() {
        let waiting = UsbRecovery.started(family: "s3", carrier: nil, baseline: [])
        let caught = UsbRecovery.caught(waiting, device: device)
        XCTAssertEqual(UsbRepairModel.offered(caught, fromRecoverBoard: false), caught)
        XCTAssertEqual(UsbRepairModel.offered(caught, fromRecoverBoard: true), caught)
        XCTAssertNil(UsbRepairModel.offered(waiting, fromRecoverBoard: false))
        XCTAssertEqual(UsbRepairModel.offered(waiting, fromRecoverBoard: true), waiting)
        XCTAssertNil(UsbRepairModel.offered(nil, fromRecoverBoard: true))
        var unknown = caught
        unknown.family = "h2"
        XCTAssertNil(UsbRepairModel.offered(unknown, fromRecoverBoard: true),
                     "a family with no rescue image cannot be resumed")
    }

    /// Review round 2: a different board answering on the recorded port is
    /// not rewritten.
    func testAnotherBoardOnTheRecordedPortIsNotTheRecoveredOne() {
        let rescueImage = WifiConfigUI.usbIdentity(from:
            "CFGINFO name64=c2lsdmVyLXJvdW5k id=aabbccddeeff board=co5300 target=s3 chip=esp32s3")
        let otherReal = WifiConfigUI.usbIdentity(from:
            "CFGINFO name64=b3RoZXI= id=68ee8f5dac8c board=st7789-190 target=s3 chip=esp32s3 fw=2.0.0")
        let ownReal = WifiConfigUI.usbIdentity(from:
            "CFGINFO name64=c2lsdmVyLXJvdW5k id=aabbccddeeff board=co5300 target=s3 chip=esp32s3 fw=2.0.0")
        typealias Answer = PanelManager.RecoveredBoardAnswer.Kind
        XCTAssertEqual(PanelManager.RecoveredBoardAnswer.kind(of: rescueImage, expected: "aabbccddeeff"),
                       Answer.rescue)
        XCTAssertEqual(PanelManager.RecoveredBoardAnswer.kind(of: ownReal, expected: "aabbccddeeff"),
                       Answer.realFirmware("2.0.0"))
        XCTAssertEqual(PanelManager.RecoveredBoardAnswer.kind(of: otherReal, expected: "aabbccddeeff"),
                       Answer.otherBoard("68ee8f5dac8c"))
        XCTAssertEqual(PanelManager.RecoveredBoardAnswer.kind(of: nil, expected: "aabbccddeeff"),
                       Answer.silent)
    }

    // MARK: - the way in

    func testTheFileMenuOffersRecoverBoard() throws {
        // The item's target is weak, so the controller is kept for the test.
        let controller = MainMenuController()
        let menu = controller.fileMenuForTesting()
        let item = try XCTUnwrap(menu.items.first { $0.title == "Recover Board\u{2026}" })
        XCTAssertTrue(item.target === controller)
        let posted = expectation(forNotification: .espDisplayRecoverBoard, object: nil)
        _ = controller.perform(item.action, with: item)
        wait(for: [posted], timeout: 1)
    }

    func testAnInterruptedRecoveryShowsTheWindowEvenOnABackgroundLaunch() {
        XCTAssertTrue(ESPDisplayApplicationDelegate.showsManager(
            requested: false, pendingRecovery: true))
        XCTAssertTrue(ESPDisplayApplicationDelegate.showsManager(
            requested: true, pendingRecovery: false))
        XCTAssertFalse(ESPDisplayApplicationDelegate.showsManager(
            requested: false, pendingRecovery: false))
    }
}
