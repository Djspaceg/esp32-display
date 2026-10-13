import Network
import SenderProtocol
import XCTest

@testable import SenderCore

/// Where the "Connected WiFi" row gets its answer, through the manager's real
/// ingest paths rather than hand-set timestamps.
@MainActor
final class BoardNetworkSourceTests: XCTestCase {

    private let path = "/dev/cu.usbmodem-test"
    private let panelName = "studio-display"

    private func manager() -> PanelManager {
        var panel = PanelSnapshot(
            serviceName: panelName, displayName: panelName, hardwareID: "020000123456")
        panel.usbHardwareID = panel.hardwareID
        return PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [path])
    }

    private func usbReport(
        _ manager: PanelManager, ssid64: String, connected: Int
    ) {
        let identity = WifiConfigUI.usbIdentity(from:
            "CFGINFO ssid64=\(ssid64) name64=c3R1ZGlvLWRpc3BsYXk= "
                + "id=020000123456 connected=\(connected) rot=0 pwr=on "
                + "board=st77916 target=s3-185 chip=esp32s3 partition=8MB fw=1.5.0")
        manager.noteUSBIdentity(
            path: path, identity: identity,
            generation: manager.usbPathGeneration(path))
    }

    private func announce(_ manager: PanelManager, ssid: String) {
        manager.noteDiscovery([
            DeviceBrowser.Device(
                name: panelName,
                endpoint: .service(
                    name: panelName, type: "_espdisp._udp", domain: "local.", interface: nil),
                metadata: ServiceMetadata(txtRecords: ["ssid": ssid]))
        ])
    }

    private func status(heartbeatAge: TimeInterval?) -> DeviceSession.Status {
        DeviceSession.Status(
            serviceName: panelName, displayFPS: 0, framesSent: 0, sendErrors: 0,
            diffPercent: 0, heartbeatAge: heartbeatAge,
            stats: BandProtocol.DeviceStats(), info: nil,
            resolvedAddress: "192.168.1.42", spacingMicros: 200, paused: false,
            parked: false, sourceDescription: "", landscape: false,
            captureStatus: .streaming, lastFrameAt: nil, updatedAt: Date())
    }

    private func row(_ manager: PanelManager) -> String? {
        manager.panels.first { $0.serviceName == panelName }?
            .boardNetworkDescription(asOf: Date())
    }

    /// A reconnect marks the link ready and refreshes the heartbeat grace
    /// period without the board saying anything. That is not the board being
    /// on WiFi: here it said over USB it is not connected, and nothing since.
    func testAReconnectWithNoReplyIsNotTheBoardBeingConnected() {
        let manager = manager()
        usbReport(manager, ssid64: "U3R1ZGlvIFdpRmk=", connected: 0)
        manager.update(status(heartbeatAge: 0.5))
        XCTAssertEqual(row(manager), "Not connected (set to \"Studio WiFi\")")
    }

    /// The board was renamed onto a new network over USB and restarted; the
    /// Mac's mDNS cache still carries the old announcement and hands it back on
    /// the next browse change. The newer USB report must win.
    func testACachedAnnouncementDoesNotOverrideANewerUSBReport() {
        let manager = manager()
        announce(manager, ssid: "Old Net")
        usbReport(manager, ssid64: "TmV3IE5ldA==", connected: 1)
        announce(manager, ssid: "Old Net")
        XCTAssertEqual(row(manager), "New Net")
    }

    /// An announcement stops meaning anything once the service is gone.
    func testAnAnnouncedNameGoesWithTheService() {
        let manager = manager()
        announce(manager, ssid: "Old Net")
        manager.noteDiscovery([])
        XCTAssertEqual(row(manager), "Unknown (not reported yet)")
    }

    /// Replies arrive as events the moment they land; the status report comes
    /// every five seconds only while capture is running. A board heartbeating
    /// while capture waits for its source is on WiFi.
    func testAHeartbeatEventAloneShowsTheBoardOnWiFi() {
        let manager = manager()
        announce(manager, ssid: "Studio WiFi")
        manager.update(.heartbeat(BandProtocol.DeviceStats()), for: panelName)
        XCTAssertEqual(row(manager), "Studio WiFi")
    }

    /// Even while the board replies, a USB report newer than the announcement
    /// names the network: the cached record can still be the old one.
    func testAUSBReportNewerThanTheAnnouncementWinsWhileReplying() {
        let manager = manager()
        announce(manager, ssid: "Old Net")
        usbReport(manager, ssid64: "TmV3IE5ldA==", connected: 1)
        manager.updatePanel(panelName) { $0.lastReplyAt = Date() }
        XCTAssertEqual(row(manager), "New Net")
    }
}

