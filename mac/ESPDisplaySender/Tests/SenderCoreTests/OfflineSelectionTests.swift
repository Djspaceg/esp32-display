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
    private func offlineManager() -> PanelManager {
        PanelManager(
            previewPanels: [
                PanelSnapshot(serviceName: "teeny", displayName: "teeny"),
            ],
            savedNetworkNames: [],
            usbSerialPorts: [])
    }

    private func requireScreen() throws {
        guard DisplayCapture.preferredScreen() != nil else {
            throw XCTSkip("no screen available to draw a region on")
        }
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

        // Read back against the panel's own geometry, which is what the UI does.
        // An offline panel has never advertised one, so this is also the assertion
        // that the nil fallback keeps the presets working for a panel that has
        // said nothing - the case region mode is most often used in, since framing
        // works with the panel switched off.
        let panel = manager.panels.first
        XCTAssertNil(panel?.geometry, "an offline panel has advertised nothing")
        XCTAssertEqual(
            panel?.source.region?.matchingScale(geometry: panel?.geometry), 3)
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
