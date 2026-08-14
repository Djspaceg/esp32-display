import XCTest

@testable import SenderCore

/// Which network the "Saved WiFi" picker defaults to.
///
/// The picker used to only ever fall back to whichever saved credential
/// sorted first, with no notion of what the device was actually joined to -
/// CFGSHOW reports that over USB, but nothing read it. `preferredSSID` is the
/// pure decision behind fixing that: pulled out of the SwiftUI view so the
/// tie-break between explicit user intent, device report, and saved fallback
/// can be checked without a live picker or a board.
final class PreferredSSIDTests: XCTestCase {

    func testReportedNetworkWinsWhenItIsSaved() {
        XCTAssertEqual(
            PanelManager.preferredSSID(
                explicitSelection: nil, reportedSSID: "Studio WiFi",
                savedNames: ["Guest", "Studio WiFi"]),
            "Studio WiFi")
    }

    /// A device joined to a network this Mac holds no credential for has
    /// nothing in the saved list worth preselecting - the old default
    /// applies instead of leaving the picker on a name it cannot offer.
    func testReportedNetworkNotSavedFallsBackToFirst() {
        XCTAssertEqual(
            PanelManager.preferredSSID(
                explicitSelection: nil, reportedSSID: "Neighbours WiFi",
                savedNames: ["Guest", "Studio WiFi"]),
            "Guest")
    }

    func testNoReportedNetworkFallsBackToFirst() {
        XCTAssertEqual(
            PanelManager.preferredSSID(
                explicitSelection: nil, reportedSSID: nil,
                savedNames: ["Guest", "Studio WiFi"]),
            "Guest")
    }

    func testEmptySavedListWithNoReportProducesEmptySelection() {
        XCTAssertEqual(
            PanelManager.preferredSSID(
                explicitSelection: nil, reportedSSID: nil, savedNames: []), "")
    }

    /// An in-progress pick must survive a device reply landing moments later -
    /// CFGSHOW is a multi-second round trip, and a user who has already chosen
    /// something should not be second-guessed by it.
    func testAnExistingValidSelectionIsKeptOverTheReportedNetwork() {
        XCTAssertEqual(
            PanelManager.preferredSSID(
                explicitSelection: "Guest", reportedSSID: "Studio WiFi",
                savedNames: ["Guest", "Studio WiFi"]),
            "Guest")
    }

    /// A selection that fell out of the saved list (its Keychain item was
    /// deleted) is not "existing" for this purpose - it has to be replaced.
    func testASelectionNoLongerInTheSavedListIsReplaced() {
        XCTAssertEqual(
            PanelManager.preferredSSID(
                explicitSelection: "Deleted Network", reportedSSID: "Studio WiFi",
                savedNames: ["Guest", "Studio WiFi"]),
            "Studio WiFi")
    }

    /// The displayed fallback is not user intent. Recomputing after CFGSHOW
    /// with the same nil explicit selection must therefore restore the network
    /// the device actually reports instead of preserving the fallback.
    func testDelayedDeviceReportReplacesAutomaticFallback() {
        let saved = ["Guest", "Studio WiFi"]
        XCTAssertEqual(
            PanelManager.preferredSSID(
                explicitSelection: nil, reportedSSID: nil, savedNames: saved),
            "Guest")
        XCTAssertEqual(
            PanelManager.preferredSSID(
                explicitSelection: nil, reportedSSID: "Studio WiFi", savedNames: saved),
            "Studio WiFi")
    }

    func testEmptyReportedNetworkNameIsNotAMatch() {
        // Empty strings are never a real SSID; savedNames deliberately does
        // not include "" in these fixtures, so this pins that an accidental
        // empty report cannot silently match one.
        XCTAssertEqual(
            PanelManager.preferredSSID(
                explicitSelection: nil, reportedSSID: "", savedNames: ["Guest"]),
            "Guest")
    }
}
