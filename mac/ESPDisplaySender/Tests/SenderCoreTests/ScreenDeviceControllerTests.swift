import CoreVideo
import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// The controller with fake covers and feeds: nothing here puts a window on a
/// screen or starts ScreenCaptureKit.
@MainActor
final class ScreenDeviceFakes {
    final class FakeCover: ScreenCoverPresenting {
        var covered: [(AttachedScreen, Int)] = []
        var removed = false
        var presented = 0
        var cleared = 0
        func cover(_ screen: AttachedScreen, rotation: Int) { covered.append((screen, rotation)) }
        func present(_ frame: CVPixelBuffer) { presented += 1 }
        func clear() { cleared += 1 }
        func remove() { removed = true }
        func reassert() {}
    }

    final class FakeFeed: ScreenDeviceFeed {
        var started: [(region: RegionSpec, geometry: PanelGeometry, rotation: Int, fps: Int)] = []
        var moved: [RegionSpec] = []
        var stopped = false
        var failure: String?
        var startFailure: String?
        /// Set to hold the start until `release()`, as a slow ScreenCaptureKit would.
        var holdsStart = false
        private var held: CheckedContinuation<Void, Never>?
        private(set) var onFrame: (@MainActor (CVPixelBuffer) -> Void)?
        func start(
            region: RegionSpec, geometry: PanelGeometry, rotation: Int, fps: Int,
            onFrame: @escaping @MainActor (CVPixelBuffer) -> Void
        ) async -> String? {
            started.append((region, geometry, rotation, fps))
            self.onFrame = onFrame
            if holdsStart { await withCheckedContinuation { held = $0 } }
            return startFailure
        }
        func release() {
            held?.resume()
            held = nil
        }
        func move(to region: RegionSpec) async -> Bool {
            moved.append(region)
            return true
        }
        func stop() async { stopped = true }
    }

    var screens: [AttachedScreen] = []
    var covers: [FakeCover] = []
    var feeds: [FakeFeed] = []
    var nextStartFailure: String?
    var nextHoldsStart = false

    func makeController(storeURL: URL? = nil) -> ScreenDeviceController {
        ScreenDeviceController(
            storeURL: storeURL, live: false,
            readScreens: { [unowned self] in self.screens },
            makeCover: { [unowned self] _ in
                let cover = FakeCover()
                self.covers.append(cover)
                return cover
            },
            makeFeed: { [unowned self] in
                let feed = FakeFeed()
                feed.startFailure = self.nextStartFailure
                feed.holdsStart = self.nextHoldsStart
                self.feeds.append(feed)
                return feed
            })
    }
}

@MainActor
final class ScreenDeviceControllerTests: XCTestCase {
    let fakes = ScreenDeviceFakes()
    let builtIn = ScreenDeviceTests.builtIn
    let oled = ScreenDeviceTests.oled

    func testUsingAScreenCoversItAndShowsARegionOfTheMenuBarScreen() async {
        fakes.screens = [builtIn, oled]
        let controller = fakes.makeController()
        controller.reconcile()
        XCTAssertEqual(controller.entries.map(\.name), ["BOE VX039"])
        XCTAssertTrue(fakes.covers.isEmpty)

        controller.use(oled.identity.key)
        await controller.settle()
        XCTAssertEqual(fakes.covers.count, 1)
        XCTAssertEqual(fakes.covers[0].covered.last?.0.displayID, oled.displayID)
        XCTAssertEqual(fakes.feeds.count, 1)
        let start = fakes.feeds[0].started.first
        XCTAssertEqual(start?.region.display, "Built-in Retina Display")
        XCTAssertEqual(start?.geometry, PanelGeometry(width: 1920, height: 1080))
        XCTAssertEqual(start?.fps, 60)
        XCTAssertEqual(controller.status(oled.identity.key), .showing("Built-in Retina Display"))
        XCTAssertEqual(controller.coveredDisplays, ["BOE VX039"])
    }

    func testUnpluggingRemovesTheCoverAtOnceAndReturningClearsTheError() async {
        fakes.screens = [builtIn, oled]
        let controller = fakes.makeController()
        controller.reconcile()
        controller.use(oled.identity.key)
        await controller.settle()

        fakes.screens = [builtIn]
        controller.reconcile()
        await controller.settle()
        XCTAssertTrue(fakes.covers[0].removed)
        XCTAssertTrue(fakes.feeds[0].stopped)
        XCTAssertEqual(controller.status(oled.identity.key), .unplugged)
        XCTAssertTrue(controller.status(oled.identity.key).needsAttention)
        XCTAssertEqual(controller.entries.map(\.name), ["BOE VX039"])
        XCTAssertTrue(controller.coveredDisplays.isEmpty)

        // Back on another port: a new display ID and position, same identity.
        var back = oled
        back.displayID = 99
        back.frame = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        fakes.screens = [back, builtIn]
        controller.reconcile()
        await controller.settle()
        XCTAssertEqual(fakes.covers.count, 2)
        XCTAssertEqual(fakes.covers[1].covered.last?.0.displayID, 99)
        XCTAssertEqual(controller.status(oled.identity.key), .showing("Built-in Retina Display"))
        XCTAssertFalse(controller.status(oled.identity.key).needsAttention)
    }

    func testStopUsingRemovesTheWindow() async {
        fakes.screens = [builtIn, oled]
        let controller = fakes.makeController()
        controller.reconcile()
        controller.use(oled.identity.key)
        await controller.settle()
        controller.stopUsing(oled.identity.key)
        await controller.settle()
        XCTAssertTrue(fakes.covers[0].removed)
        XCTAssertTrue(fakes.feeds[0].stopped)
        XCTAssertEqual(controller.status(oled.identity.key), .notInUse)
        XCTAssertTrue(controller.records.isEmpty)
    }

    func testTearDownRemovesEveryWindow() async {
        fakes.screens = [builtIn, oled]
        let controller = fakes.makeController()
        controller.reconcile()
        controller.use(oled.identity.key)
        await controller.settle()
        controller.tearDown()
        await controller.settle()
        XCTAssertTrue(fakes.covers[0].removed)
        XCTAssertTrue(fakes.feeds[0].stopped)
    }

    func testPauseStopsTheCaptureAndKeepsTheCoverAndResumeStartsIt() async {
        fakes.screens = [builtIn, oled]
        let controller = fakes.makeController()
        controller.reconcile()
        controller.use(oled.identity.key)
        await controller.settle()
        controller.setPaused(true, for: oled.identity.key)
        await controller.settle()
        XCTAssertTrue(fakes.feeds[0].stopped)
        XCTAssertFalse(fakes.covers[0].removed)
        XCTAssertEqual(controller.status(oled.identity.key), .paused)
        controller.setPaused(false, for: oled.identity.key)
        await controller.settle()
        XCTAssertEqual(fakes.feeds.count, 2)
        XCTAssertEqual(controller.status(oled.identity.key), .showing("Built-in Retina Display"))
    }

    func testAQuarterTurnRelaysTheCoverTurnsTheRegionAndRestartsTheCapture() async {
        fakes.screens = [builtIn, oled]
        let controller = fakes.makeController()
        controller.reconcile()
        controller.use(oled.identity.key)
        await controller.settle()
        let before = controller.record(oled.identity.key)?.region
        controller.setRotation(1, for: oled.identity.key)
        await controller.settle()
        XCTAssertEqual(fakes.covers[0].covered.last?.1, 1)
        let after = controller.record(oled.identity.key)?.region
        // On its side, the shape kept, and clamped into the host.
        XCTAssertEqual((after?.height ?? 0) / (after?.width ?? 1), 16.0 / 9.0, accuracy: 0.01)
        XCTAssertLessThanOrEqual(after?.height ?? .infinity, builtIn.frame.height)
        XCTAssertGreaterThan(before?.width ?? 0, before?.height ?? 0)
        XCTAssertEqual(fakes.feeds.count, 2)
        XCTAssertEqual(fakes.feeds[1].started.first?.rotation, 1)
        XCTAssertTrue(fakes.feeds[0].stopped)
    }

    func testAScreenThatGainsTheMenuBarIsUncoveredAndSaysWhy() async {
        fakes.screens = [builtIn, oled]
        let controller = fakes.makeController()
        controller.reconcile()
        controller.use(oled.identity.key)
        await controller.settle()
        var main = oled
        main.hasMenuBar = true
        var other = builtIn
        other.hasMenuBar = false
        fakes.screens = [other, main]
        controller.reconcile()
        await controller.settle()
        XCTAssertTrue(fakes.covers[0].removed)
        guard case .problem(let text) = controller.status(oled.identity.key) else {
            return XCTFail("expected a problem")
        }
        XCTAssertTrue(text.contains("menu bar"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("display"))
    }

    func testAFailedStartIsShownOnTheDeviceAndTheCoverGoesBlack() async {
        fakes.screens = [builtIn, oled]
        fakes.nextStartFailure = "Capture could not start: not permitted"
        let controller = fakes.makeController()
        controller.reconcile()
        controller.use(oled.identity.key)
        await controller.settle()
        XCTAssertEqual(
            controller.status(oled.identity.key),
            .problem("Capture could not start: not permitted"))
        XCTAssertGreaterThan(fakes.covers[0].cleared, 0)
        XCTAssertFalse(fakes.covers[0].removed)
    }

    func testARegionWhoseScreenIsUnpluggedWaitsWithTheCoverBlack() async {
        let studio = ScreenDeviceTests.studio
        fakes.screens = [builtIn, oled, studio]
        let controller = fakes.makeController()
        controller.reconcile()
        controller.use(oled.identity.key)
        await controller.settle()
        // The region moves to the studio screen while it is attached, and
        // then that screen is unplugged under the running capture.
        let region = RegionSpec(display: "Studio Display", x: 0, y: 0, width: 960, height: 540)
        controller.setRegion(region, for: oled.identity.key)
        await controller.settle()
        XCTAssertEqual(controller.status(oled.identity.key), .showing("Studio Display"))
        let running = fakes.feeds.last
        fakes.screens = [builtIn, oled]
        controller.reconcile()
        await controller.settle()
        XCTAssertEqual(running?.stopped, true)
        guard case .problem(let text) = controller.status(oled.identity.key) else {
            return XCTFail("expected a problem")
        }
        XCTAssertTrue(text.contains("Studio Display"))
        XCTAssertFalse(fakes.covers[0].removed)
        XCTAssertGreaterThan(fakes.covers[0].cleared, 0)
    }

    static func frame() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer!
    }

    func testAStartThatFinishesAfterTheDeviceWasReplacedIsStoppedAndDrawsNothing() async {
        fakes.screens = [builtIn, oled]
        let controller = fakes.makeController()
        controller.reconcile()
        // The first start hangs in ScreenCaptureKit while the device is turned
        // off and on again.
        fakes.nextHoldsStart = true
        controller.use(oled.identity.key)
        for _ in 0..<5 { await Task.yield() }
        controller.stopUsing(oled.identity.key)
        fakes.nextHoldsStart = false
        controller.use(oled.identity.key)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(fakes.feeds.count, 2)
        let stale = fakes.feeds[0]
        let live = fakes.feeds[1]
        stale.release()
        await controller.settle()

        XCTAssertTrue(stale.stopped, "the late stream must be stopped")
        XCTAssertFalse(live.stopped)
        XCTAssertEqual(controller.status(oled.identity.key), .showing("Built-in Retina Display"))
        stale.onFrame?(Self.frame())
        XCTAssertEqual(fakes.covers[1].presented, 0, "a stale stream drew into the new cover")
        live.onFrame?(Self.frame())
        XCTAssertEqual(fakes.covers[1].presented, 1)
    }

    func testAStreamThatDiesShowsWhyAndIsRetriedAfterAPause() async {
        fakes.screens = [builtIn, oled]
        let controller = fakes.makeController()
        controller.reconcile()
        controller.use(oled.identity.key)
        await controller.settle()
        fakes.feeds[0].failure = "Capture stopped: the stream ended."
        controller.tick()
        await controller.settle()
        XCTAssertEqual(
            controller.status(oled.identity.key), .problem("Capture stopped: the stream ended."))
        XCTAssertEqual(fakes.feeds.count, 1, "retried at once rather than after a pause")
        controller.tick()
        XCTAssertEqual(fakes.feeds.count, 1)
    }

    func testAScreenNoLongerOfferedCannotBeUsed() async {
        fakes.screens = [builtIn, oled]
        let controller = fakes.makeController()
        controller.boardCaptureDisplays = { ["BOE VX039"] }
        controller.reconcile()
        XCTAssertNil(controller.entry(oled.identity.key))
        controller.use(oled.identity.key)
        await controller.settle()
        XCTAssertTrue(controller.records.isEmpty)
        XCTAssertTrue(fakes.covers.isEmpty)
        controller.use(builtIn.identity.key)
        XCTAssertTrue(controller.records.isEmpty, "the menu-bar screen is never covered")
    }

    func testQuittingDoesNotOverwriteAFileThatCouldNotBeRead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        fakes.screens = [builtIn, oled]
        let controller = fakes.makeController(storeURL: url)
        XCTAssertNotNil(controller.loadFailure)
        controller.reconcile()
        controller.tearDown()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json")
    }

    func testABoardCannotBePointedAtAScreenUsedAsADevice() {
        let manager = PanelManager(
            previewPanels: [PanelSnapshot(serviceName: "desk", displayName: "Desk")],
            savedNetworkNames: [], usbSerialPorts: [])
        manager.coveredDisplayNames = ["BOE VX039"]
        manager.selectDisplay("BOE VX039", for: "desk")
        XCTAssertEqual(manager.panels.first?.source, .automatic)
        XCTAssertEqual(manager.operationOutcome?.kind, .failure)
        manager.clearOperationOutcome()
        manager.selectDisplay("Studio Display", for: "desk")
        XCTAssertEqual(manager.panels.first?.source, .display("Studio Display"))
        XCTAssertNil(manager.operationOutcome)
    }

    func testDevicesArePairedAgainAfterARestart() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        fakes.screens = [builtIn, oled]
        let first = fakes.makeController(storeURL: url)
        first.reconcile()
        first.use(oled.identity.key)
        first.setRotation(2, for: oled.identity.key)
        await first.settle()
        first.tearDown()
        await first.settle()

        var back = oled
        back.displayID = 55
        fakes.screens = [builtIn, back]
        let second = fakes.makeController(storeURL: url)
        XCTAssertNil(second.loadFailure)
        second.reconcile()
        await second.settle()
        XCTAssertEqual(second.record(oled.identity.key)?.rotation, 2)
        XCTAssertEqual(fakes.covers.last?.covered.last?.0.displayID, 55)
        XCTAssertEqual(fakes.covers.last?.covered.last?.1, 2)
    }
}
