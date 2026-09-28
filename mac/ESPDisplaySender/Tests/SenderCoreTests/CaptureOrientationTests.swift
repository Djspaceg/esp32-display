import AppKit
import CoreGraphics
import SenderProtocol
import XCTest

@testable import SenderCore

/// Which way up a capture streams, for every kind of source.
///
/// The firmware addresses a frame through `(rotation & 2) + landscape` on
/// rectangular glass and `rotation + landscape` on square glass
/// (`panelorient::quadrant`/`addressedRotation`). So the landscape bit alone
/// decides whether the Mac's up lands on the glass's up: it has to be exactly
/// "rectangular and rotated a quarter turn", whatever the source looks like.
///
/// Screen and Window used to take it from the source's own shape instead, so a
/// wide display or window at rotation 0 streamed landscape and arrived turned a
/// quarter turn, while a Region at the same rotation arrived upright.
final class CaptureOrientationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private enum Source: CaseIterable {
        case screen, window, tallWindow, region, draggedWideRegion, picker

        /// Each kind's own shape, in the orientation the old code read it from.
        var size: CGSize {
            switch self {
            case .screen: return CGSize(width: 1920, height: 1080)
            case .window: return CGSize(width: 1200, height: 800)
            case .tallWindow: return CGSize(width: 800, height: 1200)
            case .region: return CGSize(width: 344, height: 640)
            case .draggedWideRegion: return CGSize(width: 640, height: 344)
            case .picker: return CGSize(width: 1512, height: 982)
            }
        }
    }

    private let rectangular = PanelGeometry(width: 172, height: 320)
    private let square = PanelGeometry(width: 720, height: 720)

    private func streamsLandscape(
        _ source: Source, _ geometry: PanelGeometry, rotation: Int
    ) -> Bool {
        _ = source.size  // deliberately not consulted: see the class comment
        return DisplayCapture.streamsLandscape(geometry: geometry, rotation: rotation)
    }

    /// Up on the Mac is up on the glass at rotation 0, and a 180 flip keeps the
    /// same frame shape: every kind streams portrait.
    func testEveryKindStreamsPortraitOnRectangularGlassAtAnEvenRotation() {
        for rotation in [0, 2] {
            for source in Source.allCases {
                XCTAssertFalse(
                    streamsLandscape(source, rectangular, rotation: rotation),
                    "\(source) at \(rotation * 90) degrees streamed landscape")
            }
        }
    }

    /// 90 and 270 on rectangular glass are carried by landscape frames, for
    /// every kind - a tall window included.
    func testEveryKindStreamsLandscapeOnRectangularGlassAtAQuarterTurn() {
        for rotation in [1, 3] {
            for source in Source.allCases {
                XCTAssertTrue(
                    streamsLandscape(source, rectangular, rotation: rotation),
                    "\(source) at \(rotation * 90) degrees streamed portrait")
            }
        }
    }

    /// Square glass turns content itself for every rotation, so the landscape
    /// bit there would only add an unwanted quarter turn on top.
    func testSquareGlassNeverStreamsLandscape() {
        for rotation in 0...3 {
            for source in Source.allCases {
                XCTAssertFalse(
                    streamsLandscape(source, square, rotation: rotation),
                    "\(source) on square glass at \(rotation * 90) degrees "
                        + "streamed landscape")
            }
        }
    }

    /// The manager's record of the rotation is what reaches a live session's
    /// capture, whichever path wrote it.
    @MainActor
    func testTheRecordedRotationReachesALiveSessionsFrameShape() {
        let manager = PanelManager(
            previewPanels: [PanelSnapshot(serviceName: "a", displayName: "a")],
            savedNetworkNames: [], usbSerialPorts: [])
        let session = DeviceSession(
            name: "a", sender: FrameSender(host: "127.0.0.1", port: 5568),
            source: .auto(defaultDisplay: ""), picker: nil, fps: 30)
        manager.updatePanel("a") { $0.rotation = 1 }
        manager.register(session)
        XCTAssertTrue(session.streamsLandscape, "registering missed the rotation")

        manager.updatePanel("a") { $0.rotation = 3 }
        XCTAssertTrue(session.streamsLandscape)
        manager.updatePanel("a") { $0.rotation = 2 }
        XCTAssertFalse(session.streamsLandscape)
        manager.updatePanel("a") { $0.rotation = 0 }
        XCTAssertFalse(session.streamsLandscape)
    }

    /// A shape change reshapes the running stream, falling back to a restart
    /// when there is no stream to reshape; a 180 flip, and any turn on square
    /// glass, asks for neither.
    func testOnlyAFrameShapeChangeAsksCaptureToRestart() {
        func session(_ geometry: PanelGeometry) -> DeviceSession {
            DeviceSession(
                name: "a",
                sender: FrameSender(host: "127.0.0.1", port: 5568, geometry: geometry),
                source: .auto(defaultDisplay: ""), picker: nil, fps: 30)
        }
        let stick = session(rectangular)
        stick.setPanelRotation(2)
        XCTAssertEqual(stick.captureSettingsGenerationForTesting, 0, "0 to 180")
        stick.setPanelRotation(3)
        XCTAssertEqual(stick.captureSettingsGenerationForTesting, 1, "180 to 270")
        stick.setPanelRotation(1)
        XCTAssertEqual(stick.captureSettingsGenerationForTesting, 1, "270 to 90")

        let cube = session(square)
        for rotation in [1, 2, 3, 0] { cube.setPanelRotation(rotation) }
        XCTAssertEqual(cube.captureSettingsGenerationForTesting, 0, "square glass")
    }

    /// A landscape region saved at rotation 0 on rectangular glass, from before
    /// the frame shape followed the rotation, is stood upright so it fills the
    /// glass instead of being letterboxed into a portrait frame.
    @MainActor
    func testARegionOfTheWrongShapeForTheRotationIsTurnedToMatch() throws {
        guard let screen = DisplayCapture.preferredScreen() else {
            throw XCTSkip("no screen available to place a region on")
        }
        for (rotation, wantLandscape) in [(0, false), (2, false), (1, true), (3, true)] {
            var panel = PanelSnapshot(serviceName: "stick", displayName: "stick")
            panel.geometry = PanelGeometry(width: 170, height: 320)
            panel.rotation = rotation
            let (w, h) = wantLandscape ? (170.0, 320.0) : (320.0, 170.0)
            panel.source = .region(RegionSpec(
                display: screen.name, x: 40, y: 60, width: w, height: h))
            let manager = PanelManager(
                previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])

            manager.alignRegionToRotation(for: "stick")

            let region = try XCTUnwrap(manager.panels.first?.source.region)
            XCTAssertEqual(region.isLandscape, wantLandscape, "at \(rotation * 90)")
        }
    }

    /// Square glass keeps any region shape: its rotation turns the content.
    @MainActor
    func testSquareGlassLeavesTheRegionShapeAlone() throws {
        guard let screen = DisplayCapture.preferredScreen() else {
            throw XCTSkip("no screen available to place a region on")
        }
        var panel = PanelSnapshot(serviceName: "cube", displayName: "cube")
        panel.geometry = square
        panel.source = .region(RegionSpec(
            display: screen.name, x: 40, y: 60, width: 320, height: 160))
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])
        manager.alignRegionToRotation(for: "cube")
        XCTAssertEqual(manager.panels.first?.source.region?.width, 320)
    }

    /// On rectangular glass the marquee offers no free rotate: the rotation
    /// control decides the shape.
    @MainActor
    func testTheMarqueeOffersRotateOnlyOnSquareGlass() throws {
        guard DisplayCapture.preferredScreen() != nil else {
            throw XCTSkip("no screen available to draw a region on")
        }
        for (geometry, allowed) in [(rectangular, false), (square, true)] {
            var panel = PanelSnapshot(serviceName: "p", displayName: "p")
            panel.geometry = geometry
            let manager = PanelManager(
                previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])
            manager.chooseRegion(for: "p")
            XCTAssertEqual(manager.regionSelector.allowsRotate, allowed)
            manager.finishChoosingRegion()
        }
    }

    /// The residual: an offline panel whose size has not been reported yet,
    /// mounted at 90 degrees. Its region was turned on its side with the
    /// rotation, so the viewfinder has to be landscape too or it letterboxes
    /// the region; with no region it takes the preview capture's own
    /// rectangular default.
    func testAnOfflinePanelOfUnknownSizePreviewsInTheShapeItStreams() throws {
        var panel = PanelSnapshot(serviceName: "p", displayName: "p")
        panel.geometry = nil
        panel.rotation = 1
        XCTAssertTrue(
            PanelManager.previewLandscape(for: panel),
            "no region, 90 degrees, unknown size")

        panel.source = .region(RegionSpec(
            display: "Built-in", x: 0, y: 0, width: 640, height: 344))
        XCTAssertTrue(PanelManager.previewLandscape(for: panel), "landscape region")

        panel.rotation = 0
        panel.source = .region(RegionSpec(
            display: "Built-in", x: 0, y: 0, width: 344, height: 640))
        XCTAssertFalse(PanelManager.previewLandscape(for: panel), "portrait region")

        panel.geometry = square
        panel.rotation = 1
        XCTAssertFalse(PanelManager.previewLandscape(for: panel), "square glass")
    }
}


/// The one queue that region drags and reshapes share, driven through a stand-in
/// for ScreenCaptureKit's reconfigure call.
final class CaptureReconfigureTests: XCTestCase {

    private struct Refused: Error {}

    private let rectangular = PanelGeometry(width: 172, height: 320)

    /// Samples at the new size must be accepted as soon as ScreenCaptureKit
    /// may send them. Switching only after the call returns dropped the first
    /// new-shape frame, which on a static screen is the only one.
    func testTheNewFrameSizeIsExpectedWhileTheReshapeIsApplied() async {
        let capture = DisplayCapture(geometry: rectangular, landscape: false, onFrame: { _, _ in })
        let during = LockedBox<(Int, Int)?>(nil)
        capture.configureForTesting = { _, _, _ in
            during.set((capture.frameSizeForTesting.width, capture.frameSizeForTesting.height))
        }
        let applied = await capture.reshape(landscape: true)
        XCTAssertTrue(applied)
        XCTAssertEqual(during.get()?.0, 320)
        XCTAssertEqual(during.get()?.1, 172)
        XCTAssertTrue(capture.landscape)
    }

    /// A reshape that ScreenCaptureKit refuses leaves the stream in the old
    /// shape with the panel at the new rotation, so capture has to be rebuilt,
    /// whatever the error was.
    func testARefusedReshapeStopsTheCaptureSoItIsRebuilt() async {
        let capture = DisplayCapture(geometry: rectangular, landscape: false, onFrame: { _, _ in })
        capture.configureForTesting = { _, _, _ in throw Refused() }
        let applied = await capture.reshape(landscape: true)
        XCTAssertFalse(applied)
        XCTAssertTrue(capture.stopped, "the stream kept the old shape unnoticed")
        XCTAssertFalse(capture.landscape)
        XCTAssertEqual(capture.frameSizeForTesting.width, 172, "size not rolled back")
    }

    /// A reshape queued behind a region update rides the same drain, and is
    /// not lost when that drain's next call fails.
    func testAReshapeQueuedBehindARegionUpdateIsNotLostOnFailure() async {
        let capture = DisplayCapture(geometry: rectangular, landscape: false, onFrame: { _, _ in })
        let gate = AsyncGate()
        let calls = LockedBox(0)
        capture.configureForTesting = { _, _, _ in
            let call = calls.update { $0 += 1; return $0 }
            if call == 1 { await gate.wait() }
            if call == 2 { throw Refused() }
        }
        async let region = capture.updateRegion(CGRect(x: 0, y: 0, width: 344, height: 640))
        while calls.get() == 0 { await Task.yield() }
        let queued = await capture.reshape(landscape: true)
        XCTAssertTrue(queued, "queued behind the running drain")
        await gate.open()
        _ = await region
        XCTAssertTrue(capture.stopped, "the queued reshape was dropped silently")
    }

    /// The region update the reshape queued behind is the call that fails:
    /// the reshape never reached ScreenCaptureKit, so capture must be rebuilt.
    func testAReshapeQueuedBehindAFailingRegionUpdateStopsTheCapture() async {
        let capture = DisplayCapture(geometry: rectangular, landscape: false, onFrame: { _, _ in })
        let gate = AsyncGate()
        let calls = LockedBox(0)
        capture.configureForTesting = { _, _, _ in
            calls.update { $0 += 1 }
            await gate.wait()
            throw Refused()
        }
        async let region = capture.updateRegion(CGRect(x: 0, y: 0, width: 172, height: 320))
        while calls.get() == 0 { await Task.yield() }
        _ = await capture.reshape(landscape: true)
        await gate.open()
        _ = await region
        XCTAssertTrue(capture.stopped, "the queued reshape was dropped silently")
    }

    /// A drain whose stream went away mid-way has applied nothing, and must
    /// not report success.
    func testADrainWithNoStreamLeftDoesNotReportSuccess() async {
        let capture = DisplayCapture(geometry: rectangular, landscape: false, onFrame: { _, _ in })
        let gate = AsyncGate()
        let calls = LockedBox(0)
        capture.configureForTesting = { _, _, _ in
            calls.update { $0 += 1 }
            await gate.wait()
        }
        async let first = capture.updateRegion(CGRect(x: 0, y: 0, width: 172, height: 320))
        while calls.get() == 0 { await Task.yield() }
        _ = await capture.updateRegion(CGRect(x: 30, y: 0, width: 172, height: 320))
        capture.configureForTesting = nil  // as stop() leaves it: no stream
        await gate.open()
        let result = await first
        XCTAssertFalse(result, "reported a change applied to no stream")
    }

    /// Updates arriving during a drain are applied newest-first, not one by one.
    func testUpdatesDuringADrainCoalesceToTheNewest() async {
        let capture = DisplayCapture(geometry: rectangular, landscape: false, onFrame: { _, _ in })
        let gate = AsyncGate()
        let applied = LockedBox<[CGRect?]>([])
        capture.configureForTesting = { _, _, rect in
            let first = applied.update { $0.append(rect); return $0.count == 1 }
            if first { await gate.wait() }
        }
        async let drain = capture.updateRegion(CGRect(x: 0, y: 0, width: 172, height: 320))
        while applied.get().isEmpty { await Task.yield() }
        _ = await capture.updateRegion(CGRect(x: 10, y: 0, width: 172, height: 320))
        _ = await capture.updateRegion(CGRect(x: 20, y: 0, width: 172, height: 320))
        await gate.open()
        _ = await drain
        XCTAssertEqual(applied.get().map { $0?.minX }, [0, 20])
    }
}

/// A value shared with a closure the drain calls on another task.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
    func update<T>(_ change: (inout Value) -> T) -> T { lock.withLock { change(&value) } }
}

/// Holds a reconfigure call until the test lets it finish.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
