import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// A knob board's knob is this Mac's volume knob under every gesture preset,
/// so the way back to a declined Accessibility grant has to be on its page
/// whatever the preset - not only under multimedia, and not only after a
/// refused turn raised the notice. The app knows a board has a knob from the
/// profile the board already reports, looked up in the shipped descriptors.
final class KnobBoardTests: XCTestCase {

    private func panel(profile: String?, preset: GesturePreset) -> PanelSnapshot {
        var panel = PanelSnapshot(serviceName: "panel", displayName: "panel")
        panel.profile = profile
        panel.gesturePreset = preset
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

    func testAKnobBoardOffersTheGrantUnderEveryPreset() {
        for preset in GesturePreset.allCases {
            let knob = panel(profile: "gc9a01-knob-128", preset: preset)
            XCTAssertTrue(knob.offersMediaKeyGrant(authorized: false), "\(preset)")
            XCTAssertFalse(knob.offersMediaKeyGrant(authorized: true), "\(preset)")
        }
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
