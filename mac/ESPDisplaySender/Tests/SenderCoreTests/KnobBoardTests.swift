import AppKit
import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// A knob board's knob is this Mac's volume knob under every gesture preset,
/// so the way back to a declined Accessibility grant has to be on its page
/// whatever the preset - not only under multimedia, and not only after a
/// refused turn raised the notice. The app knows a board has a knob from the
/// profile the board already reports, looked up in the shipped descriptors.
final class KnobBoardTests: XCTestCase {

    private func panel(
        profile: String?, preset: GesturePreset, touch: Bool = true
    ) -> PanelSnapshot {
        var panel = PanelSnapshot(serviceName: "panel", displayName: "panel")
        panel.profile = profile
        panel.gesturePreset = preset
        if touch { panel.capabilitiesRaw = DeviceProtocol.Capabilities.touch.rawValue }
        return panel
    }

    /// Generated from the boards' own descriptors: exactly the boards whose
    /// carrier declares encoder lines.
    func testTheCatalogKnowsWhichBoardsHaveAKnob() {
        XCTAssertEqual(GeneratedBoardCatalog.encoderProfiles, ["gc9a01-knob-128"])
    }

    func testAKnobBoardIsKnownByItsProfile() {
        XCTAssertTrue(panel(profile: "gc9a01-knob-128", preset: .standard).hasKnob)
        XCTAssertFalse(panel(profile: "co5300", preset: .standard).hasKnob)
        XCTAssertFalse(panel(profile: nil, preset: .standard).hasKnob)
    }

    /// The profile is discovery-scoped and is cleared while the board is out
    /// of mDNS, but its knob keeps working over the session meanwhile, so
    /// once a knob is known it stays known for the launch.
    func testAKnobStaysKnownWhenTheProfileIsCleared() {
        var knob = panel(profile: "gc9a01-knob-128", preset: .standard)
        knob.profile = nil
        XCTAssertTrue(knob.hasKnob)
    }

    func testAKnobBoardOffersTheGrantUnderEveryPreset() {
        for preset in GesturePreset.allCases {
            let knob = panel(profile: "gc9a01-knob-128", preset: preset, touch: false)
            XCTAssertTrue(knob.offersMediaKeyGrant(authorized: false), "\(preset)")
            XCTAssertFalse(knob.offersMediaKeyGrant(authorized: true), "\(preset)")
        }
    }

    /// A board with no touch screen sends no multimedia gesture, whatever
    /// preset a script set on it.
    func testMultimediaWithoutTouchOffersNothing() {
        let glassless = panel(profile: "gc9107", preset: .multimedia, touch: false)
        XCTAssertFalse(glassless.offersMediaKeyGrant(authorized: false))
    }

    /// Unchanged for glass-only boards: only the multimedia preset sends keys.
    func testOtherBoardsOfferItOnlyUnderMultimedia() {
        for preset in GesturePreset.allCases {
            let glass = panel(profile: "co5300", preset: preset)
            XCTAssertEqual(
                glass.offersMediaKeyGrant(authorized: false), preset == .multimedia,
                "\(preset)")
            XCTAssertFalse(glass.offersMediaKeyGrant(authorized: true))
        }
    }
}

/// A knob gesture is the board saying it has a knob, whatever discovery has
/// or has not reported: a board renamed outside the app keeps its session but
/// its new record has no profile yet.
@MainActor
final class KnobGestureMarksTheBoardTests: XCTestCase {
    func testAKnobGestureMarksThePanelAsHavingAKnob() throws {
        let manager = PanelManager(
            previewPanels: [PanelSnapshot(serviceName: "knob", displayName: "Knob")],
            savedNetworkNames: [], usbSerialPorts: [])
        manager.mediaKeysAuthorized = { false }
        manager.requestMediaKeyAuthorization = {}
        manager.mediaKeySender = { _ in nil }
        XCTAssertFalse(try XCTUnwrap(manager.panels.first).hasKnob)

        manager.update(
            .touch(DeviceProtocol.TouchEvent(
                gesture: .knobPress, sequence: 1, x: 0, y: 0, landscape: false)),
            for: "knob")

        XCTAssertTrue(try XCTUnwrap(manager.panels.first).hasKnob)
    }
}

/// The display page itself, read as a value (see `ViewReading`): the way back
/// is on a knob board's page under the default preset even with no touch
/// screen reported, and absent from a glass board's.
@MainActor
final class KnobGrantRowViewTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func page(
        profile: String, authorized: Bool,
        preset: GesturePreset = .standard, touch: Bool = false
    ) -> ViewReading {
        var panel = PanelSnapshot(serviceName: "panel", displayName: "Panel")
        panel.profile = profile
        panel.gesturePreset = preset
        if touch { panel.capabilitiesRaw = DeviceProtocol.Capabilities.touch.rawValue }
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])
        manager.serialIODisabled = true
        manager.mediaKeysAuthorized = { authorized }
        manager.selectedServiceName = panel.serviceName
        return ViewReading(PanelDetailView(panel: panel, manager: manager))
    }

    func testAKnobBoardsPageOffersTheWayBackUnderTheDefaultPreset() {
        let knob = page(profile: "gc9a01-knob-128", authorized: false)
        XCTAssertNotNil(knob.button("Open System Settings…"))
        XCTAssertTrue(knob.strings.contains {
            $0.contains("knob") && $0.contains("Accessibility")
        })
    }

    func testNoWayBackIsOfferedOnceGranted() {
        XCTAssertNil(
            page(profile: "gc9a01-knob-128", authorized: true)
                .button("Open System Settings…"))
    }

    func testAGlassBoardsPageOffersTheWayBackUnderMultimedia() {
        let glass = page(
            profile: "co5300", authorized: false, preset: .multimedia, touch: true)
        XCTAssertNotNil(glass.button("Open System Settings…"))
        XCTAssertTrue(glass.strings.contains(
            "Playback and key presses from the device need Accessibility permission."))
    }

    func testAGlassBoardsPageOffersNothingUnderTheDefaultPreset() {
        XCTAssertNil(
            page(profile: "co5300", authorized: false).button("Open System Settings…"))
    }
}
