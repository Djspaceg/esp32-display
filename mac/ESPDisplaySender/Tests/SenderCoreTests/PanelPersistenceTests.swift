import XCTest

@testable import SenderCore

/// Persistence used to round-trip the whole `PanelSnapshot`, so a restart
/// restored week-old RSSI, uptime, heap and pacing as if they were current, and
/// restored a `paused` flag that no live session honoured. These tests pin the
/// boundary between what is durable and what has to come from the device.
final class PanelPersistenceTests: XCTestCase {

    // MARK: helpers

    /// A snapshot with every field set to something non-default, so any field
    /// that leaks into persistence shows up as a changed value rather than
    /// coincidentally matching the default.
    private func populatedSnapshot() -> PanelSnapshot {
        PanelSnapshot(
            serviceName: "studio-display",
            displayName: "Studio Display",
            hardwareID: "esp32c6-a1b2c3d4",
            address: "192.168.1.42",
            usbPort: "/dev/cu.usbserial-A1B2C3D4",
            discovered: true,
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000),
            lastHeartbeatAt: Date(timeIntervalSince1970: 1_700_000_050),
            rssi: -52,
            displayFPS: 39.8,
            framesSent: 128_440,
            sendErrors: 7,
            diffPercent: 18,
            framesShown: 128_397,
            framesDropped: 43,
            freeHeap: 186_624,
            spacingMicros: 200,
            firmwareVersion: "1.1.0",
            currentSSID: "Studio WiFi",
            frameProtocolVersion: 2,
            controlProtocolVersion: 3,
            capabilitiesRaw: 0x6F,
            uptimeSeconds: 93_840,
            brightness: 255,
            brightnessHigh: true,
            flipped: true,
            sleeping: true,
            idle: true,
            paused: true,
            sourceDescription: "Tiny Monitor",
            lastError: "gave up reaching this display")
    }

    /// Asserts a snapshot carries no device-reported readings.
    private func assertNoTelemetry(
        _ panel: PanelSnapshot, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(panel.discovered, "discovered", file: file, line: line)
        XCTAssertNil(panel.lastHeartbeatAt, "lastHeartbeatAt", file: file, line: line)
        XCTAssertNil(panel.rssi, "rssi", file: file, line: line)
        XCTAssertEqual(panel.displayFPS, 0, "displayFPS", file: file, line: line)
        XCTAssertEqual(panel.framesSent, 0, "framesSent", file: file, line: line)
        XCTAssertEqual(panel.sendErrors, 0, "sendErrors", file: file, line: line)
        XCTAssertEqual(panel.diffPercent, 0, "diffPercent", file: file, line: line)
        XCTAssertEqual(panel.framesShown, 0, "framesShown", file: file, line: line)
        XCTAssertEqual(panel.framesDropped, 0, "framesDropped", file: file, line: line)
        XCTAssertEqual(panel.freeHeap, 0, "freeHeap", file: file, line: line)
        XCTAssertEqual(panel.spacingMicros, 0, "spacingMicros", file: file, line: line)
        XCTAssertNil(panel.firmwareVersion, "firmwareVersion", file: file, line: line)
        XCTAssertNil(panel.currentSSID, "currentSSID", file: file, line: line)
        XCTAssertNil(panel.frameProtocolVersion, "frameProtocolVersion", file: file, line: line)
        XCTAssertNil(panel.controlProtocolVersion, "controlProtocolVersion", file: file, line: line)
        XCTAssertEqual(panel.capabilitiesRaw, 0, "capabilitiesRaw", file: file, line: line)
        XCTAssertEqual(panel.uptimeSeconds, 0, "uptimeSeconds", file: file, line: line)
        XCTAssertEqual(panel.brightness, 0, "brightness", file: file, line: line)
        XCTAssertFalse(panel.flipped, "flipped", file: file, line: line)
        XCTAssertFalse(panel.sleeping, "sleeping", file: file, line: line)
        XCTAssertFalse(panel.idle, "idle", file: file, line: line)
        XCTAssertFalse(panel.paused, "paused", file: file, line: line)
        XCTAssertEqual(panel.sourceDescription, "Automatic", "sourceDescription",
                       file: file, line: line)
        XCTAssertNil(panel.lastError, "lastError", file: file, line: line)
    }

    // MARK: projection

    func testPersistedRecordKeepsIdentityAndSettings() {
        let record = PersistedPanel(snapshot: populatedSnapshot())

        XCTAssertEqual(record.serviceName, "studio-display")
        XCTAssertEqual(record.displayName, "Studio Display")
        XCTAssertEqual(record.hardwareID, "esp32c6-a1b2c3d4")
        XCTAssertEqual(record.usbPort, "/dev/cu.usbserial-A1B2C3D4")
        XCTAssertEqual(record.address, "192.168.1.42")
        XCTAssertEqual(record.lastSeen, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testRestoredSnapshotHasNoTelemetry() {
        let restored = PersistedPanel(snapshot: populatedSnapshot()).snapshot

        XCTAssertEqual(restored.serviceName, "studio-display")
        XCTAssertEqual(restored.displayName, "Studio Display")
        XCTAssertEqual(restored.hardwareID, "esp32c6-a1b2c3d4")
        XCTAssertEqual(restored.usbPort, "/dev/cu.usbserial-A1B2C3D4")
        XCTAssertEqual(restored.address, "192.168.1.42")
        XCTAssertEqual(restored.lastSeen, Date(timeIntervalSince1970: 1_700_000_000))
        assertNoTelemetry(restored)
    }

    /// A restored panel must read as offline even though `lastSeen` survives,
    /// because `isOnline` keys off the heartbeat and nothing has arrived yet.
    func testRestoredSnapshotReadsOffline() {
        var snapshot = populatedSnapshot()
        snapshot.lastSeen = Date()
        snapshot.lastHeartbeatAt = Date()
        XCTAssertTrue(snapshot.isOnline)

        let restored = PersistedPanel(snapshot: snapshot).snapshot
        XCTAssertFalse(restored.isOnline)
        XCTAssertEqual(restored.statusText, "Offline")
    }

    // MARK: encoding

    func testJSONRoundTripPreservesRecord() throws {
        let record = PersistedPanel(snapshot: populatedSnapshot())
        let data = try JSONEncoder.espDisplay.encode([record])
        let decoded = try JSONDecoder.espDisplay.decode([PersistedPanel].self, from: data)

        XCTAssertEqual(decoded, [record])
    }

    func testEncodedRecordOmitsTelemetryKeys() throws {
        let data = try JSONEncoder.espDisplay.encode(
            [PersistedPanel(snapshot: populatedSnapshot())])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        for key in ["rssi", "uptimeSeconds", "freeHeap", "spacingMicros", "displayFPS",
                    "framesSent", "framesShown", "framesDropped", "sendErrors",
                    "diffPercent", "brightness", "brightnessHigh", "flipped", "sleeping",
                    "idle", "paused", "discovered", "lastHeartbeatAt", "firmwareVersion",
                    "currentSSID", "capabilitiesRaw", "frameProtocolVersion",
                    "controlProtocolVersion", "sourceDescription", "lastError"] {
            XCTAssertFalse(json.contains("\"\(key)\""), "\(key) reached disk")
        }
        for key in ["serviceName", "displayName", "hardwareID", "usbPort", "address",
                    "lastSeen"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "\(key) missing from disk")
        }
    }

    // MARK: migration

    /// Files written before the split hold the full snapshot. Unknown keys are
    /// ignored on decode, so they load without a migration step and the stale
    /// readings they carry are dropped rather than restored.
    func testLegacyFullSnapshotFileLoadsWithoutTelemetry() throws {
        let legacy = """
            [
              {
                "address" : "192.168.1.42",
                "brightness" : 255,
                "brightnessHigh" : true,
                "capabilitiesRaw" : 111,
                "controlProtocolVersion" : 3,
                "diffPercent" : 18,
                "discovered" : true,
                "displayFPS" : 39.799999999999997,
                "displayName" : "Studio Display",
                "firmwareVersion" : "1.1.0",
                "flipped" : true,
                "frameProtocolVersion" : 2,
                "framesDropped" : 43,
                "framesSent" : 128440,
                "framesShown" : 128397,
                "freeHeap" : 186624,
                "hardwareID" : "esp32c6-a1b2c3d4",
                "idle" : true,
                "lastHeartbeatAt" : "2023-11-14T22:14:10Z",
                "lastSeen" : "2023-11-14T22:13:20Z",
                "paused" : true,
                "rssi" : -52,
                "sendErrors" : 7,
                "serviceName" : "studio-display",
                "sleeping" : true,
                "sourceDescription" : "Tiny Monitor",
                "spacingMicros" : 200,
                "uptimeSeconds" : 93840,
                "usbPort" : "/dev/cu.usbserial-A1B2C3D4"
              }
            ]
            """
        let records = try JSONDecoder.espDisplay.decode(
            [PersistedPanel].self, from: XCTUnwrap(legacy.data(using: .utf8)))

        XCTAssertEqual(records.count, 1)
        let restored = try XCTUnwrap(records.first).snapshot
        XCTAssertEqual(restored.serviceName, "studio-display")
        XCTAssertEqual(restored.displayName, "Studio Display")
        XCTAssertEqual(restored.hardwareID, "esp32c6-a1b2c3d4")
        XCTAssertEqual(restored.usbPort, "/dev/cu.usbserial-A1B2C3D4")
        XCTAssertEqual(restored.address, "192.168.1.42")
        XCTAssertEqual(restored.lastSeen, Date(timeIntervalSince1970: 1_700_000_000))
        assertNoTelemetry(restored)
    }

    /// A record written by a panel that was never reached over USB or WiFi has
    /// no optional fields at all; those files must still load.
    func testMinimalRecordLoads() throws {
        let minimal = """
            [{ "displayName" : "travel-display", "serviceName" : "travel-display" }]
            """
        let records = try JSONDecoder.espDisplay.decode(
            [PersistedPanel].self, from: XCTUnwrap(minimal.data(using: .utf8)))

        let restored = try XCTUnwrap(records.first).snapshot
        XCTAssertEqual(restored.serviceName, "travel-display")
        XCTAssertEqual(restored.displayName, "travel-display")
        XCTAssertNil(restored.hardwareID)
        XCTAssertNil(restored.usbPort)
        XCTAssertNil(restored.address)
        XCTAssertNil(restored.lastSeen)
        assertNoTelemetry(restored)
    }
}
