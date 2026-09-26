import AppKit
import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// Choosing what a panel shows must work with the panel switched off.
///
/// It did not. Both the picker and the region selector were gated on a live
/// `DeviceSession`, and sessions only exist for panels discovered on the network,
/// so every source control was dead until the hardware was plugged in - and the
/// preview, which is the only way to judge the choice, had nothing feeding it.
/// Deciding which part of this Mac's screen to send is a decision about this Mac;
/// the panel is only the destination.
@MainActor
final class OfflineSourceSelectionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // The region selector builds an NSWindow, and NSApp must exist first.
        _ = NSApplication.shared
    }

    /// No sessions are registered on this manager, which is exactly the offline
    /// case: a panel remembered from a previous run with nothing on the network.
    private func offlineManager(
        geometry: PanelGeometry? = .panel172x320
    ) -> PanelManager {
        var panel = PanelSnapshot(serviceName: "teeny", displayName: "teeny")
        panel.geometry = geometry
        return PanelManager(
            previewPanels: [panel],
            savedNetworkNames: [],
            usbSerialPorts: [])
    }

    private func requireScreen() throws {
        guard DisplayCapture.preferredScreen() != nil else {
            throw XCTSkip("no screen available to draw a region on")
        }
    }

    func testAdvertised720SquareReshapesASavedFallbackRectangle() throws {
        try requireScreen()
        let screen = try XCTUnwrap(DisplayCapture.preferredScreen())
        let savedFallback = RegionSpec.centered(
            on: screen.name, geometry: .panel172x320, scale: 1, landscape: false,
            in: screen.size)
        var panel = PanelSnapshot(serviceName: "teeny", displayName: "teeny")
        panel.geometry = PanelGeometry(width: 720, height: 720)
        panel.source = .region(savedFallback)
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])

        manager.chooseRegion(for: "teeny")
        defer { manager.finishChoosingRegion() }

        let selectorRegion = try XCTUnwrap(manager.regionSelector.region)
        XCTAssertEqual(selectorRegion.width, selectorRegion.height, accuracy: 0.001)
    }

    func testNoAdvertisedGeometryDoesNotOpenASmallRectangle() throws {
        try requireScreen()
        let manager = offlineManager(geometry: nil)

        manager.chooseRegion(for: "teeny")

        XCTAssertNil(manager.regionSelector.region)
        XCTAssertNil(manager.panels.first?.source.region)
    }

    func testRegionCanBeChosenWhileOffline() throws {
        try requireScreen()
        let manager = offlineManager()
        XCTAssertNil(manager.panels.first?.source.region)

        manager.chooseRegion(for: "teeny")
        defer { manager.finishChoosingRegion() }

        XCTAssertNotNil(
            manager.panels.first?.source.region,
            "a region has to be recorded without a session to apply it to")
    }

    func testScalePresetsWorkWhileOffline() throws {
        try requireScreen()
        let manager = offlineManager()
        manager.chooseRegion(for: "teeny")
        defer { manager.finishChoosingRegion() }

        manager.setRegionScale(3, for: "teeny")

        // A known geometry can be framed while the panel is offline.
        let panel = manager.panels.first
        XCTAssertEqual(panel?.geometry, .panel172x320)
        XCTAssertEqual(
            panel?.source.region?.matchingScale(geometry: .panel172x320), 3)
    }

    func testRotateWorksWhileOffline() throws {
        try requireScreen()
        let manager = offlineManager()
        manager.chooseRegion(for: "teeny")
        defer { manager.finishChoosingRegion() }
        let before = try XCTUnwrap(manager.panels.first?.source.region)

        manager.rotateRegion(for: "teeny")

        let after = try XCTUnwrap(manager.panels.first?.source.region)
        XCTAssertNotEqual(after.isLandscape, before.isLandscape)
    }

    /// The choice is the thing that has to survive: a session created later reads
    /// it back out of the stored sources.
    func testOfflineChoiceReachesThePersistedSources() throws {
        try requireScreen()
        let manager = offlineManager()

        manager.chooseRegion(for: "teeny")
        manager.finishChoosingRegion()

        let stored = manager.persistedSources()["teeny"]
        XCTAssertNotNil(stored?.region, "an offline choice must be persistable")
        // And it round-trips through the on-disk shape.
        let spec = try XCTUnwrap(stored?.spec)
        XCTAssertEqual(PanelSource(spec), stored)
    }

    /// Switching back to Automatic has to clear the region, or the panel would
    /// keep streaming a rectangle the user thought they had dismissed.
    func testAutomaticClearsTheRegionWhileOffline() throws {
        try requireScreen()
        let manager = offlineManager()
        manager.chooseRegion(for: "teeny")
        manager.finishChoosingRegion()

        manager.useAutomaticSource(for: "teeny")

        XCTAssertEqual(manager.panels.first?.source, .automatic)
        XCTAssertNil(manager.panels.first?.source.region)
    }
}

/// Switching between attached displays.
///
/// Displays are offered in the window rather than through the macOS picker, so
/// moving a panel from one monitor to another is a single click. The list has to
/// behave when the stored monitor is no longer attached.
@MainActor
final class DisplaySelectionTests: XCTestCase {

    private func manager(source: PanelSource) -> PanelManager {
        var panel = PanelSnapshot(serviceName: "teeny", displayName: "teeny")
        panel.geometry = .panel172x320
        panel.source = source
        return PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])
    }

    func testSelectingADisplayRecordsIt() {
        let manager = manager(source: .automatic)

        manager.selectDisplay("Studio Display", for: "teeny")

        XCTAssertEqual(manager.panels.first?.source, .display("Studio Display"))
    }

    func testSwitchingBetweenDisplaysReplacesTheChoice() {
        let manager = manager(source: .display("Built-in Retina Display"))

        manager.selectDisplay("Studio Display", for: "teeny")

        XCTAssertEqual(manager.panels.first?.source, .display("Studio Display"))
    }

    /// A monitor that has been unplugged still has to appear in the list, or the
    /// dropdown would show a blank value and the panel would look retargeted just
    /// because a cable came out.
    func testADetachedDisplayIsStillOffered() {
        let manager = manager(source: .display("Unplugged Monitor"))

        XCTAssertTrue(
            manager.displayOptions(for: "teeny").contains("Unplugged Monitor"))
    }

    func testAnEmptyNameIsIgnored() {
        let manager = manager(source: .display("Studio Display"))

        manager.selectDisplay("", for: "teeny")

        XCTAssertEqual(
            manager.panels.first?.source, .display("Studio Display"),
            "an empty selection must not wipe the stored choice")
    }

    /// The choice has to survive to disk, since that is what a session reads when
    /// the panel eventually comes back.
    func testDisplayChoiceReachesThePersistedSources() {
        let manager = manager(source: .automatic)

        manager.selectDisplay("Studio Display", for: "teeny")

        XCTAssertEqual(
            manager.persistedSources()["teeny"], .display("Studio Display"))
    }
}

/// Escape has to put back whatever the panel was showing before the marquee
/// opened - including a source that was not a region at all.
@MainActor
final class RegionCancelTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func manager(source: PanelSource) -> PanelManager {
        var panel = PanelSnapshot(serviceName: "teeny", displayName: "teeny")
        panel.source = source
        panel.geometry = .panel172x320
        return PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])
    }

    private func requireScreen() throws {
        guard DisplayCapture.preferredScreen() != nil else {
            throw XCTSkip("no screen available to draw a region on")
        }
    }

    func testCancellingRestoresAutomatic() throws {
        try requireScreen()
        let manager = manager(source: .automatic)
        manager.chooseRegion(for: "teeny")
        XCTAssertNotNil(
            manager.panels.first?.source.region, "the region should be live first")

        manager.cancelChoosingRegion()

        XCTAssertEqual(manager.panels.first?.source, .automatic)
    }

    func testCancellingRestoresAPreviousDisplay() throws {
        try requireScreen()
        let manager = manager(source: .display("Studio Display"))
        manager.chooseRegion(for: "teeny")

        manager.cancelChoosingRegion()

        XCTAssertEqual(manager.panels.first?.source, .display("Studio Display"))
    }

    /// Confirming keeps the rectangle, which is the whole point of the exercise.
    func testConfirmingKeepsTheRegion() throws {
        try requireScreen()
        let manager = manager(source: .automatic)
        manager.chooseRegion(for: "teeny")

        manager.finishChoosingRegion()

        XCTAssertNotNil(manager.panels.first?.source.region)
    }

    /// Cancelling a region that was already there must leave it alone rather than
    /// clearing it.
    func testCancellingAnEditKeepsTheOriginalRegion() throws {
        try requireScreen()
        let original = RegionSpec(
            display: "Some Display", x: 40, y: 60, width: 172, height: 320)
        let manager = manager(source: .region(original))

        manager.chooseRegion(for: "teeny")
        manager.cancelChoosingRegion()

        XCTAssertEqual(manager.panels.first?.source.region?.x, original.x)
        XCTAssertEqual(manager.panels.first?.source.region?.y, original.y)
    }
}

/// The streamed region has to follow a quarter turn, from the user's own
/// instruction: "rectangular screens only flip 180. if the app chooses a
/// 90/270 degree orientation, the app changes the region orientation too."
///
/// On square glass this is about a region the user has dragged to a non-square
/// shape, which the marquee allows: turning the panel leaves the captured shape
/// lying across the glass the wrong way until the region turns with it. On
/// rectangular glass it is what makes 90 and 270 landscape at all: the panel
/// draws whatever shape the frames arrive in, so the region has to lie on its
/// side for an odd rotation and stand upright for an even one.
@MainActor
final class QuarterTurnRegionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func panelWithWideRegion(_ screen: (name: String, size: CGSize))
        -> PanelSnapshot {
        var panel = PanelSnapshot(serviceName: "cube", displayName: "cube")
        panel.geometry = PanelGeometry(width: 240, height: 240)
        // Deliberately NOT square: a square region rotates to itself, so it
        // could never show whether the swap happened.
        panel.source = .region(RegionSpec(
            display: screen.name, x: 40, y: 60, width: 320, height: 160))
        return panel
    }

    func testAQuarterTurnTurnsTheRegionOnItsSide() throws {
        guard let found = DisplayCapture.preferredScreen() else {
            throw XCTSkip("no screen available to place a region on")
        }
        let screen = (name: found.name, size: found.size)
        let manager = PanelManager(
            previewPanels: [panelWithWideRegion(screen)],
            savedNetworkNames: [], usbSerialPorts: [])

        manager.applyRegionQuarterTurn(from: 0, to: 1, for: "cube")

        let region = try XCTUnwrap(manager.panels.first?.source.region)
        XCTAssertEqual(region.width, 160, accuracy: 0.001,
                       "a quarter turn must swap the region's sides")
        XCTAssertEqual(region.height, 320, accuracy: 0.001,
                       "a quarter turn must swap the region's sides")
    }

    func testAHalfTurnLeavesTheRegionAlone() throws {
        guard let found = DisplayCapture.preferredScreen() else {
            throw XCTSkip("no screen available to place a region on")
        }
        let screen = (name: found.name, size: found.size)
        let manager = PanelManager(
            previewPanels: [panelWithWideRegion(screen)],
            savedNetworkNames: [], usbSerialPorts: [])

        manager.applyRegionQuarterTurn(from: 0, to: 2, for: "cube")

        let region = try XCTUnwrap(manager.panels.first?.source.region)
        XCTAssertEqual(region.width, 320, accuracy: 0.001,
                       "180 degrees keeps the same shape on the glass")
        XCTAssertEqual(region.height, 160, accuracy: 0.001,
                       "180 degrees keeps the same shape on the glass")
    }

    // MARK: rectangular glass (the 1.9-inch S3, 170x320)

    private func stick(_ screen: (name: String, size: CGSize),
                       width: Double, height: Double) -> PanelSnapshot {
        var panel = PanelSnapshot(serviceName: "stick", displayName: "stick")
        panel.geometry = PanelGeometry(width: 170, height: 320)
        panel.source = .region(RegionSpec(
            display: screen.name, x: 40, y: 60, width: width, height: height))
        return panel
    }

    private func region(
        after previous: Int, _ next: Int, from panel: PanelSnapshot
    ) throws -> RegionSpec {
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])
        manager.applyRegionQuarterTurn(from: previous, to: next, for: "stick")
        return try XCTUnwrap(manager.panels.first?.source.region)
    }

    func testRectangularNinetyAndTwoSeventyCaptureALandscapeRegion() throws {
        guard let found = DisplayCapture.preferredScreen() else {
            throw XCTSkip("no screen available to place a region on")
        }
        let screen = (name: found.name, size: found.size)
        for next in [1, 3] {
            let turned = try region(
                after: 0, next, from: stick(screen, width: 170, height: 320))
            XCTAssertEqual(turned.width, 320, accuracy: 0.001,
                           "\(next * 90) degrees must capture 320 wide")
            XCTAssertEqual(turned.height, 170, accuracy: 0.001,
                           "\(next * 90) degrees must capture 170 tall")
        }
    }

    func testRectangularBackToUprightCapturesAPortraitRegion() throws {
        guard let found = DisplayCapture.preferredScreen() else {
            throw XCTSkip("no screen available to place a region on")
        }
        let screen = (name: found.name, size: found.size)
        for next in [0, 2] {
            let turned = try region(
                after: 1, next, from: stick(screen, width: 320, height: 170))
            XCTAssertEqual(turned.width, 170, accuracy: 0.001)
            XCTAssertEqual(turned.height, 320, accuracy: 0.001)
        }
    }

    /// A region already dragged landscape at 0 degrees is already what 90
    /// needs; toggling it would stand it upright and lose landscape.
    func testRectangularLandscapeRegionStaysLandscapeAtNinety() throws {
        guard let found = DisplayCapture.preferredScreen() else {
            throw XCTSkip("no screen available to place a region on")
        }
        let screen = (name: found.name, size: found.size)
        let kept = try region(
            after: 0, 1, from: stick(screen, width: 320, height: 170))
        XCTAssertEqual(kept.width, 320, accuracy: 0.001)
        XCTAssertEqual(kept.height, 170, accuracy: 0.001)
    }

    /// A rotation set outside this app (serial CFGROT, another Mac) reaches it
    /// only as a report, and still has to lay the region on its side.
    func testRectangularReportedQuarterTurnTurnsTheRegion() throws {
        guard let found = DisplayCapture.preferredScreen() else {
            throw XCTSkip("no screen available to place a region on")
        }
        let screen = (name: found.name, size: found.size)
        var panel = stick(screen, width: 170, height: 320)
        panel.rotation = 1
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])
        manager.followReportedRotation(from: 0, for: "stick")
        let turned = try XCTUnwrap(manager.panels.first?.source.region)
        XCTAssertEqual(turned.width, 320, accuracy: 0.001)
        XCTAssertEqual(turned.height, 170, accuracy: 0.001)
    }

    /// Just after this app commanded a rotation, a report can still carry the
    /// old value; following it would turn the region back.
    func testReportedRotationInsideTheEchoGraceIsIgnored() throws {
        guard let found = DisplayCapture.preferredScreen() else {
            throw XCTSkip("no screen available to place a region on")
        }
        let screen = (name: found.name, size: found.size)
        let manager = PanelManager(
            previewPanels: [stick(screen, width: 320, height: 170)],
            savedNetworkNames: [], usbSerialPorts: [])
        manager.commandedRotationAt["stick"] = Date()
        manager.followReportedRotation(from: 1, for: "stick")
        let kept = try XCTUnwrap(manager.panels.first?.source.region)
        XCTAssertEqual(kept.width, 320, accuracy: 0.001)
    }

    func testSquareReportedRotationLeavesTheRegionAlone() throws {
        guard let found = DisplayCapture.preferredScreen() else {
            throw XCTSkip("no screen available to place a region on")
        }
        let screen = (name: found.name, size: found.size)
        var panel = panelWithWideRegion(screen)
        panel.rotation = 1
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])
        manager.followReportedRotation(from: 0, for: "cube")
        let kept = try XCTUnwrap(manager.panels.first?.source.region)
        XCTAssertEqual(kept.width, 320, accuracy: 0.001)
    }

    func testRectangularHalfTurnKeepsTheRegionShape() throws {
        guard let found = DisplayCapture.preferredScreen() else {
            throw XCTSkip("no screen available to place a region on")
        }
        let screen = (name: found.name, size: found.size)
        let landscape = try region(
            after: 1, 3, from: stick(screen, width: 320, height: 170))
        XCTAssertEqual(landscape.width, 320, accuracy: 0.001)
        let portrait = try region(
            after: 0, 2, from: stick(screen, width: 170, height: 320))
        XCTAssertEqual(portrait.width, 170, accuracy: 0.001)
    }
}
