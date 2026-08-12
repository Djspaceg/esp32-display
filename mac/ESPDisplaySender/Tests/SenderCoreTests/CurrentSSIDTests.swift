import XCTest

@testable import SenderCore

/// Which network the "Saved WiFi" picker defaults to.
///
/// The picker used to only ever fall back to whichever saved credential
/// sorted first, with no notion of what the device was actually joined to -
/// CFGSHOW reports that over USB, but nothing read it. `preferredSSID` is the
/// pure decision behind fixing that: pulled out of the SwiftUI view so the
/// three-way tie-break (existing selection, device-reported network, saved
/// list) can be checked without a live picker or a board.
final class PreferredSSIDTests: XCTestCase {

    func testReportedNetworkWinsWhenItIsSaved() {
        XCTAssertEqual(
            PanelManager.preferredSSID(
                current: "", reportedSSID: "Studio WiFi",
                savedNames: ["Guest", "Studio WiFi"]),
            "Studio WiFi")
    }

    /// A device joined to a network this Mac holds no credential for has
    /// nothing in the saved list worth preselecting - the old default
    /// applies instead of leaving the picker on a name it cannot offer.
    func testReportedNetworkNotSavedFallsBackToFirst() {
        XCTAssertEqual(
            PanelManager.preferredSSID(
                current: "", reportedSSID: "Neighbours WiFi",
                savedNames: ["Guest", "Studio WiFi"]),
            "Guest")
    }

    func testNoReportedNetworkFallsBackToFirst() {
        XCTAssertEqual(
            PanelManager.preferredSSID(
                current: "", reportedSSID: nil, savedNames: ["Guest", "Studio WiFi"]),
            "Guest")
    }

    func testEmptySavedListWithNoReportProducesEmptySelection() {
        XCTAssertEqual(
            PanelManager.preferredSSID(current: "", reportedSSID: nil, savedNames: []), "")
    }

    /// An in-progress pick must survive a device reply landing moments later -
    /// CFGSHOW is a multi-second round trip, and a user who has already chosen
    /// something should not be second-guessed by it.
    func testAnExistingValidSelectionIsKeptOverTheReportedNetwork() {
        XCTAssertEqual(
            PanelManager.preferredSSID(
                current: "Guest", reportedSSID: "Studio WiFi",
                savedNames: ["Guest", "Studio WiFi"]),
            "Guest")
    }

    /// A selection that fell out of the saved list (its Keychain item was
    /// deleted) is not "existing" for this purpose - it has to be replaced.
    func testASelectionNoLongerInTheSavedListIsReplaced() {
        XCTAssertEqual(
            PanelManager.preferredSSID(
                current: "Deleted Network", reportedSSID: "Studio WiFi",
                savedNames: ["Guest", "Studio WiFi"]),
            "Studio WiFi")
    }

    func testEmptyReportedNetworkNameIsNotAMatch() {
        // Empty strings are never a real SSID; savedNames deliberately does
        // not include "" in these fixtures, so this pins that an accidental
        // empty report cannot silently match one.
        XCTAssertEqual(
            PanelManager.preferredSSID(
                current: "", reportedSSID: "", savedNames: ["Guest"]),
            "Guest")
    }
}
