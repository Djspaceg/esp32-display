import Network
import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// Every control capability the firmware advertises. File scope rather than a
/// static member so it can be used as a default argument, which is evaluated
/// outside the test class's main-actor isolation.
private let allControls = DeviceProtocol.Capabilities.brightness
    .union(.flip)
    .union(.identify)
    .union(.restart)

/// Identity reconciliation and capability gating are the two places where the
/// manager can quietly do the wrong thing: lose a panel's settings when the
/// device renames itself, or send a control a panel cannot honour. Both were
/// previously only exercised by hand with real hardware.
///
/// These tests use the preview initialiser, which skips disk and timers, so
/// nothing here touches the records belonging to the installed app.
@MainActor
final class PanelManagerTests: XCTestCase {

    // MARK: helpers

    /// Build a real `DeviceInfo` by encoding an EINF packet and parsing it, so
    /// these tests cannot drift from the wire format the firmware sends.
    private func makeInfo(
        name: String,
        deviceID: [UInt8],
        capabilities: DeviceProtocol.Capabilities = allControls,
        controlProtocolVersion: UInt8 = DeviceProtocol.controlProtocolVersion,
        firmware: String = "1.1.0"
    ) throws -> DeviceProtocol.DeviceInfo {
        XCTAssertEqual(deviceID.count, 6, "device ID is a 6-byte field")
        var packet = Data("EINF".utf8)
        packet.append(contentsOf: [
            DeviceProtocol.infoVersion,
            DeviceProtocol.frameProtocolVersion,
            controlProtocolVersion,
            0x11,  // brightnessHigh + wifiConnected
        ])
        packet.append(contentsOf: [
            UInt8(capabilities.rawValue & 0xFF),
            UInt8((capabilities.rawValue >> 8) & 0xFF),
            UInt8((capabilities.rawValue >> 16) & 0xFF),
            UInt8((capabilities.rawValue >> 24) & 0xFF),
        ])
        packet.append(contentsOf: [0x3C, 0x00, 0x00, 0x00])  // uptime 60s
        packet.append(contentsOf: [0xCC, 0xFF])  // RSSI -52
        packet.append(255)  // brightness
        packet.append(UInt8(name.utf8.count))
        packet.append(UInt8(firmware.utf8.count))
        packet.append(contentsOf: deviceID)
        packet.append(contentsOf: name.utf8)
        packet.append(contentsOf: firmware.utf8)
        return try XCTUnwrap(DeviceProtocol.parseInfo(packet), "EINF vector is malformed")
    }

    /// A session that is registered but never started. `DeviceSession.init` and
    /// `FrameSender.init` only store their arguments; nothing opens a socket
    /// until `run()`, which these tests never call.
    private func makeSession(name: String) -> DeviceSession {
        DeviceSession(
            name: name,
            sender: FrameSender(host: "127.0.0.1", port: 5568),
            source: .auto(defaultDisplay: ""),
            picker: nil,
            fps: 30)
    }

    private func makeManager(_ panels: [PanelSnapshot] = []) -> PanelManager {
        PanelManager(previewPanels: panels, savedNetworkNames: [], usbSerialPorts: [])
    }

    /// A discovered service. The endpoint is never connected to here.
    private func makeDevice(_ name: String) -> DeviceBrowser.Device {
        DeviceBrowser.Device(
            name: name,
            endpoint: .hostPort(host: "127.0.0.1", port: 5568))
    }

    /// A panel that already satisfies every gate except the session, so a test
    /// can remove exactly one precondition at a time.
    private func controllablePanel(
        serviceName: String = "studio-display",
        capabilities: DeviceProtocol.Capabilities = allControls,
        heartbeatAt: Date = Date()
    ) -> PanelSnapshot {
        PanelSnapshot(
            serviceName: serviceName,
            displayName: serviceName,
            hardwareID: "020000123456",
            lastSeen: heartbeatAt,
            lastHeartbeatAt: heartbeatAt,
            controlProtocolVersion: Int(DeviceProtocol.controlProtocolVersion),
            capabilitiesRaw: capabilities.rawValue)
    }

    // MARK: capability gating

    func testControlIsAllowedWhenOnlineAndAdvertised() throws {
        let manager = makeManager()
        manager.register(makeSession(name: "studio-display"))
        manager.update(
            .info(try makeInfo(name: "studio-display", deviceID: [2, 0, 0, 0x12, 0x34, 0x56])),
            for: "studio-display")

        for capability in [DeviceProtocol.Capabilities.brightness, .flip, .identify, .restart] {
            XCTAssertTrue(manager.canControl("studio-display", capability: capability))
        }
    }

    /// Without a live session there is nothing to send the command over, even
    /// though the persisted record still looks complete.
    func testControlIsRefusedWithoutASession() {
        let manager = makeManager([controllablePanel()])

        XCTAssertFalse(manager.canControl("studio-display", capability: .brightness))
    }

    func testControlIsRefusedForUnadvertisedCapability() throws {
        let manager = makeManager()
        manager.register(makeSession(name: "studio-display"))
        manager.update(
            .info(try makeInfo(
                name: "studio-display",
                deviceID: [2, 0, 0, 0x12, 0x34, 0x56],
                capabilities: .brightness)),
            for: "studio-display")

        XCTAssertTrue(manager.canControl("studio-display", capability: .brightness))
        for capability in [DeviceProtocol.Capabilities.flip, .identify, .restart] {
            XCTAssertFalse(manager.canControl("studio-display", capability: capability))
        }
    }

    /// Firmware speaking a different control protocol would misread the opcode,
    /// so every control is refused regardless of the capability bits.
    func testControlIsRefusedOnControlProtocolMismatch() throws {
        let manager = makeManager()
        manager.register(makeSession(name: "studio-display"))
        manager.update(
            .info(try makeInfo(
                name: "studio-display",
                deviceID: [2, 0, 0, 0x12, 0x34, 0x56],
                controlProtocolVersion: DeviceProtocol.controlProtocolVersion + 9)),
            for: "studio-display")

        for capability in [DeviceProtocol.Capabilities.brightness, .flip, .identify, .restart] {
            XCTAssertFalse(manager.canControl("studio-display", capability: capability))
        }
    }

    /// A panel whose heartbeat has stopped cannot acknowledge anything, so the
    /// controls close even while the session object is still registered.
    func testControlIsRefusedWhenHeartbeatIsStale() {
        let stale = controllablePanel(heartbeatAt: Date(timeIntervalSinceNow: -60))
        let manager = makeManager([stale])
        manager.register(makeSession(name: "studio-display"))

        XCTAssertFalse(manager.selectedPanel?.isOnline == true)
        XCTAssertFalse(manager.canControl("studio-display", capability: .brightness))
    }

    // MARK: identity reconciliation

    /// A USB rename changes the Bonjour name, so the same board reappears as a
    /// new service. The hardware ID is what keeps the user's settings attached
    /// to it instead of stranding them on a record that never comes back.
    func testRenamedDeviceMigratesItsRecord() throws {
        var existing = controllablePanel(serviceName: "espdisplay")
        existing.usbPort = "/dev/cu.usbmodem-1"
        let manager = makeManager([existing])

        manager.update(
            .info(try makeInfo(
                name: "espdisplay-9050", deviceID: [2, 0, 0, 0x12, 0x34, 0x56])),
            for: "espdisplay-9050")

        XCTAssertEqual(manager.panels.count, 1)
        let panel = try XCTUnwrap(manager.panels.first)
        XCTAssertEqual(panel.serviceName, "espdisplay-9050")
        XCTAssertEqual(panel.displayName, "espdisplay-9050")
        XCTAssertEqual(panel.usbPort, "/dev/cu.usbmodem-1", "settings did not migrate")
        XCTAssertEqual(panel.hardwareID, "020000123456")
    }

    /// mDNS keeps advertising the old name until its TTL expires. Those updates
    /// must not resurrect the record that was just migrated away.
    func testSupersededServiceNameIsIgnoredAfterMigration() throws {
        let manager = makeManager([controllablePanel(serviceName: "espdisplay")])
        let deviceID: [UInt8] = [2, 0, 0, 0x12, 0x34, 0x56]

        manager.update(
            .info(try makeInfo(name: "espdisplay-9050", deviceID: deviceID)),
            for: "espdisplay-9050")
        manager.update(
            .info(try makeInfo(name: "espdisplay", deviceID: deviceID)),
            for: "espdisplay")

        XCTAssertEqual(manager.panels.count, 1)
        XCTAssertEqual(manager.panels.first?.serviceName, "espdisplay-9050")
    }

    /// Discovery must not resurrect it either.
    func testSupersededServiceNameIsNotRediscovered() throws {
        let manager = makeManager([controllablePanel(serviceName: "espdisplay")])
        manager.update(
            .info(try makeInfo(
                name: "espdisplay-9050", deviceID: [2, 0, 0, 0x12, 0x34, 0x56])),
            for: "espdisplay-9050")

        manager.noteDiscovery([makeDevice("espdisplay"), makeDevice("espdisplay-9050")])

        XCTAssertEqual(manager.panels.count, 1)
        XCTAssertEqual(manager.panels.first?.serviceName, "espdisplay-9050")
    }

    func testSelectionFollowsTheMigratedPanel() throws {
        let manager = makeManager([controllablePanel(serviceName: "espdisplay")])
        XCTAssertEqual(manager.selectedServiceName, "espdisplay")

        manager.update(
            .info(try makeInfo(
                name: "espdisplay-9050", deviceID: [2, 0, 0, 0x12, 0x34, 0x56])),
            for: "espdisplay-9050")

        XCTAssertEqual(manager.selectedServiceName, "espdisplay-9050")
    }

    /// Two different boards must stay two panels, however similar their names.
    func testDifferentHardwareDoesNotMerge() throws {
        let manager = makeManager([controllablePanel(serviceName: "espdisplay")])

        manager.update(
            .info(try makeInfo(
                name: "espdisplay-9050", deviceID: [9, 9, 9, 9, 9, 9])),
            for: "espdisplay-9050")

        XCTAssertEqual(manager.panels.count, 2)
        XCTAssertEqual(
            Set(manager.panels.map(\.serviceName)), ["espdisplay", "espdisplay-9050"])
    }

    /// The common case: a panel reporting in repeatedly under its own name is
    /// not a rename and must not fan out into duplicates.
    func testRepeatedInfoUnderTheSameNameIsNotAMigration() throws {
        let manager = makeManager()
        let info = try makeInfo(name: "studio-display", deviceID: [2, 0, 0, 0x12, 0x34, 0x56])

        for _ in 0..<3 {
            manager.update(.info(info), for: "studio-display")
        }

        XCTAssertEqual(manager.panels.count, 1)
    }

    // MARK: USB port assignment

    /// An assigned port that is currently unplugged still has to appear in the
    /// menu, otherwise the assignment silently disappears from the UI.
    func testAssignedPortStaysListedWhenDisconnected() {
        var panel = controllablePanel()
        panel.usbPort = "/dev/cu.usbserial-GONE"
        let manager = PanelManager(
            previewPanels: [panel],
            savedNetworkNames: [],
            usbSerialPorts: ["/dev/cu.usbmodem-1"])

        XCTAssertEqual(
            manager.usbPortOptions(for: "studio-display"),
            ["/dev/cu.usbserial-GONE", "/dev/cu.usbmodem-1"])
    }

    func testConnectedAssignedPortIsNotDuplicated() {
        var panel = controllablePanel()
        panel.usbPort = "/dev/cu.usbmodem-1"
        let manager = PanelManager(
            previewPanels: [panel],
            savedNetworkNames: [],
            usbSerialPorts: ["/dev/cu.usbmodem-1", "/dev/cu.usbserial-2"])

        XCTAssertEqual(
            manager.usbPortOptions(for: "studio-display"),
            ["/dev/cu.usbmodem-1", "/dev/cu.usbserial-2"])
    }

    func testUnassignedPanelListsDiscoveredPortsOnly() {
        let manager = PanelManager(
            previewPanels: [controllablePanel()],
            savedNetworkNames: [],
            usbSerialPorts: ["/dev/cu.usbmodem-1"])

        XCTAssertEqual(
            manager.usbPortOptions(for: "studio-display"), ["/dev/cu.usbmodem-1"])
    }

    /// Clearing the assignment has to store nil, not an empty string, or the
    /// blank value would be treated as an explicit port later on.
    func testClearingTheAssignmentStoresNil() {
        var panel = controllablePanel()
        panel.usbPort = "/dev/cu.usbmodem-1"
        let manager = makeManager([panel])

        manager.setUSBPort("   ", for: "studio-display")
        XCTAssertNil(manager.panels.first?.usbPort)

        manager.setUSBPort("  /dev/cu.usbmodem-2  ", for: "studio-display")
        XCTAssertEqual(manager.panels.first?.usbPort, "/dev/cu.usbmodem-2")

        manager.setUSBPort(nil, for: "studio-display")
        XCTAssertNil(manager.panels.first?.usbPort)
    }
}
