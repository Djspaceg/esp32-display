import SenderProtocol
import XCTest

@testable import SenderCore

/// Which network the saved-networks picker preselects.
///
/// The picker is the app's own list of Keychain credentials to apply, not a
/// report of the board. It used to fall back to whichever saved credential
/// sorted first whenever the board had not said (or was on a network this
/// Mac holds no credential for), so the row read as though the board were on
/// the app's first saved network. The board's own report now has its own row
/// (`boardNetworkDescription`), and the picker only preselects a saved
/// network the board actually reported, or one the user picked.
final class PreferredSSIDTests: XCTestCase {

    func testReportedNetworkWinsWhenItIsSaved() {
        XCTAssertEqual(
            PanelManager.preferredSSID(
                explicitSelection: nil, reportedSSID: "Studio WiFi",
                savedNames: ["Guest", "Studio WiFi"]),
            "Studio WiFi")
    }

    /// A device joined to a network this Mac holds no credential for has
    /// nothing in the saved list worth preselecting, and preselecting the first
    /// saved one would present the app's list as the board's network.
    func testReportedNetworkNotSavedPreselectsNothing() {
        XCTAssertEqual(
            PanelManager.preferredSSID(
                explicitSelection: nil, reportedSSID: "Neighbours WiFi",
                savedNames: ["Guest", "Studio WiFi"]),
            "")
    }

    /// No report yet is unknown, not "the first saved network".
    func testNoReportedNetworkPreselectsNothing() {
        XCTAssertEqual(
            PanelManager.preferredSSID(
                explicitSelection: nil, reportedSSID: nil,
                savedNames: ["Guest", "Studio WiFi"]),
            "")
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

    /// Recomputing after a delayed CFGSHOW with the same nil explicit
    /// selection picks up the network the device actually reports.
    func testDelayedDeviceReportFillsAnEmptySelection() {
        let saved = ["Guest", "Studio WiFi"]
        XCTAssertEqual(
            PanelManager.preferredSSID(
                explicitSelection: nil, reportedSSID: nil, savedNames: saved),
            "")
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
            "")
    }
}

/// The board's own network row: what CFGSHOW's `ssid=` and `connected=` say,
/// and an explicit "unknown" when nothing has - never the app's saved list.
final class BoardNetworkDescriptionTests: XCTestCase {

    func testAJoinedNetworkIsShownByName() {
        XCTAssertEqual(
            PanelManager.boardNetworkDescription(
                reportedSSID: "Studio WiFi", connected: true),
            "Studio WiFi")
    }

    func testANetworkTheBoardHasNotJoinedSaysSo() {
        XCTAssertEqual(
            PanelManager.boardNetworkDescription(
                reportedSSID: "Studio WiFi", connected: false),
            "Not connected (set to \"Studio WiFi\")")
    }

    func testNoReportIsUnknownRatherThanAGuess() {
        for connected in [nil, false] as [Bool?] {
            XCTAssertEqual(
                PanelManager.boardNetworkDescription(
                    reportedSSID: nil, connected: connected),
                "Unknown (not reported yet)")
        }
    }

    /// Heartbeats say the board has joined, but older firmware does not name it.
    func testJoinedOverWiFiWithoutAUSBReportSaysSoWithoutAName() {
        XCTAssertEqual(
            PanelManager.boardNetworkDescription(reportedSSID: nil, connected: true),
            "Connected (name not reported)")
    }

    /// An empty `ssid64=` is the board answering "none set", not no answer.
    func testAnEmptyReportIsNoneConfigured() {
        for connected in [nil, true, false] as [Bool?] {
            XCTAssertEqual(
                PanelManager.boardNetworkDescription(
                    reportedSSID: "", connected: connected),
                "None configured")
        }
    }

    func testAMissingConnectedFieldIsFlagged() {
        XCTAssertEqual(
            PanelManager.boardNetworkDescription(
                reportedSSID: "Studio WiFi", connected: nil),
            "Studio WiFi (connection not reported)")
    }
}

/// A CFGSHOW probe records both halves of the board's report on the panel.
@MainActor
final class BoardNetworkIngestTests: XCTestCase {

    func testAUSBProbeRecordsTheNetworkAndWhetherItIsJoined() {
        let path = "/dev/cu.usbmodem-test"
        var panel = PanelSnapshot(
            serviceName: "studio-display", displayName: "studio-display",
            hardwareID: "020000123456")
        panel.usbPort = path
        panel.usbHardwareID = panel.hardwareID
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: ["Guest"],
            usbSerialPorts: [path])

        for (connected, expected) in [("0", false), ("1", true)] {
            let identity = WifiConfigUI.usbIdentity(from:
                "CFGINFO ssid64=U3R1ZGlvIFdpRmk= name64=c3R1ZGlvLWRpc3BsYXk= "
                    + "id=020000123456 connected=\(connected) rot=0 pwr=on "
                    + "board=st77916 target=s3-185 chip=esp32s3 partition=8MB "
                    + "fw=1.5.0")
            manager.noteUSBIdentity(
                path: path, identity: identity,
                generation: manager.usbPathGeneration(path))

            let recorded = manager.panels.first { $0.serviceName == "studio-display" }
            XCTAssertEqual(recorded?.currentSSID, "Studio WiFi")
            XCTAssertEqual(recorded?.networkConnected, expected)
        }
    }

    func testAnEmptySSIDReportIsRecordedAsNoneSet() {
        let path = "/dev/cu.usbmodem-test"
        var panel = PanelSnapshot(
            serviceName: "studio-display", displayName: "studio-display",
            hardwareID: "020000123456")
        panel.usbPort = path
        panel.usbHardwareID = panel.hardwareID
        panel.currentSSID = "Old Network"
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [path])
        let identity = WifiConfigUI.usbIdentity(from:
            "CFGINFO ssid64= name64=c3R1ZGlvLWRpc3BsYXk= id=020000123456 "
                + "connected=0 rot=0 pwr=on board=st77916 target=s3-185 "
                + "chip=esp32s3 partition=8MB fw=1.5.0")
        manager.noteUSBIdentity(
            path: path, identity: identity,
            generation: manager.usbPathGeneration(path))
        XCTAssertEqual(manager.panels.first?.currentSSID, "",
                       "an empty report must replace the old name")
    }

    /// A USB probe stamps its report, so a later silence over WiFi can be
    /// told apart from one that came before it.
    func testAUSBProbeStampsItsReport() {
        let path = "/dev/cu.usbmodem-test"
        var panel = PanelSnapshot(
            serviceName: "studio-display", displayName: "studio-display",
            hardwareID: "020000123456")
        panel.usbPort = path
        panel.usbHardwareID = panel.hardwareID
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [path])
        let before = Date()
        let identity = WifiConfigUI.usbIdentity(from:
            "CFGINFO ssid64=U3R1ZGlvIFdpRmk= name64=c3R1ZGlvLWRpc3BsYXk= "
                + "id=020000123456 connected=1 rot=0 pwr=on board=st77916 "
                + "target=s3-185 chip=esp32s3 partition=8MB fw=1.5.0")
        manager.noteUSBIdentity(
            path: path, identity: identity,
            generation: manager.usbPathGeneration(path))
        let stamped = manager.panels.first?.networkReportedAt
        XCTAssertNotNil(stamped)
        XCTAssertGreaterThanOrEqual(stamped ?? .distantPast, before)
    }
}

/// The row has to stop saying "connected" once the board goes quiet over WiFi:
/// heartbeats are the live proof, and a USB report only stands until a newer
/// silence contradicts it.
final class BoardNetworkFreshnessTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func panel(
        connected: Bool?, reportedSecondsAgo: Double?, heartbeatSecondsAgo: Double?
    ) -> PanelSnapshot {
        var panel = PanelSnapshot(serviceName: "a", displayName: "a")
        panel.currentSSID = "Studio WiFi"
        panel.networkConnected = connected
        panel.networkReportedAt = reportedSecondsAgo.map { now.addingTimeInterval(-$0) }
        panel.lastReplyAt = heartbeatSecondsAgo.map { now.addingTimeInterval(-$0) }
        return panel
    }

    /// The residual: EINF said connected, then the board dropped off WiFi.
    func testABoardThatWentQuietOverWiFiIsNoLongerShownConnected() {
        XCTAssertEqual(
            panel(connected: true, reportedSecondsAgo: 300, heartbeatSecondsAgo: 60)
                .boardNetworkDescription(asOf: now),
            "Not connected (set to \"Studio WiFi\")")
    }

    /// Heartbeats outrank a boot-time `connected=0` read over USB.
    func testLiveHeartbeatsShowItConnected() {
        XCTAssertEqual(
            panel(connected: false, reportedSecondsAgo: 300, heartbeatSecondsAgo: 2)
                .boardNetworkDescription(asOf: now),
            "Studio WiFi")
    }

    /// A USB report newer than the last heartbeat is the newer word.
    func testAUSBReportNewerThanTheSilenceStands() {
        XCTAssertEqual(
            panel(connected: true, reportedSecondsAgo: 1, heartbeatSecondsAgo: 60)
                .boardNetworkDescription(asOf: now),
            "Studio WiFi")
        XCTAssertEqual(
            panel(connected: false, reportedSecondsAgo: 1, heartbeatSecondsAgo: nil)
                .boardNetworkDescription(asOf: now),
            "Not connected (set to \"Studio WiFi\")")
    }
}

