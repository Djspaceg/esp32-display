import Network
import XCTest

@testable import SenderCore
@testable import SenderProtocol

final class DeviceListSortPreferenceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "DeviceListSortPreferenceTests-\(UUID().uuidString)",
                isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL {
        directory.appendingPathComponent("settings.json")
    }

    func testEverySortOrderRoundTripsThroughExistingSettingsStore() throws {
        for order in DeviceListSortOrder.allCases {
            var settings = SenderSettings()
            settings.deviceListSortOrder = order

            try SettingsStore.save(settings, to: storeURL)
            let loaded = SettingsStore.load(from: storeURL)

            XCTAssertNil(loaded.failure)
            XCTAssertEqual(loaded.settings.deviceListSortOrder, order)
        }
    }

    func testUnknownStoredSortOrderFallsBackToAlphabetical() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data(#"{"deviceListSortOrder":"recentlyUsed"}"#.utf8)
            .write(to: storeURL)

        let loaded = SettingsStore.load(from: storeURL)

        XCTAssertNil(loaded.failure)
        XCTAssertEqual(loaded.settings.deviceListSortOrder, .alphabetical)
    }

    func testCorruptSettingsFileFallsBackToAlphabetical() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: storeURL)

        let loaded = SettingsStore.load(from: storeURL)

        XCTAssertNotNil(loaded.failure)
        XCTAssertEqual(loaded.settings.deviceListSortOrder, .alphabetical)
    }
}

@MainActor
final class DeviceListSortApplicationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func panel(
        _ name: String,
        added: TimeInterval,
        heartbeatAge: TimeInterval? = nil,
        discovered: Bool = false,
        paused: Bool = false,
        displayFPS: Double = 0,
        captureStatus: CaptureStatus = .waiting("Idle")
    ) -> PanelSnapshot {
        PanelSnapshot(
            serviceName: name.lowercased().replacingOccurrences(of: " ", with: "-"),
            displayName: name,
            dateAdded: now.addingTimeInterval(added),
            discovered: discovered,
            lastHeartbeatAt: heartbeatAge.map {
                now.addingTimeInterval(-$0)
            },
            displayFPS: displayFPS,
            paused: paused,
            captureStatus: captureStatus)
    }

    func testPanelStatesMapToEveryStatusRank() {
        XCTAssertEqual(
            panel("Streaming", added: 0, heartbeatAge: 1, discovered: true,
                  captureStatus: .streaming).deviceListStatus(asOf: now),
            .streaming)
        XCTAssertEqual(
            panel("Connected", added: 0, heartbeatAge: 1, discovered: true)
                .deviceListStatus(asOf: now),
            .connected)
        XCTAssertEqual(
            panel("Paused", added: 0, heartbeatAge: 1, discovered: true, paused: true)
                .deviceListStatus(asOf: now),
            .paused)
        XCTAssertEqual(
            panel("Connecting", added: 0, discovered: true)
                .deviceListStatus(asOf: now),
            .connecting)
        XCTAssertEqual(
            panel("Offline", added: 0).deviceListStatus(asOf: now),
            .offline)
    }

    func testSidebarStatusLineCoversEveryStatusRank() {
        XCTAssertEqual(
            panel(
                "Streaming", added: 0, heartbeatAge: 1, discovered: true,
                displayFPS: 42.1, captureStatus: .streaming
            ).sidebarStatusText(asOf: now),
            "Online • 42.1 fps")
        XCTAssertEqual(
            panel("Connected", added: 0, heartbeatAge: 1, discovered: true)
                .sidebarStatusText(asOf: now),
            "Online • Not mirroring")
        XCTAssertEqual(
            panel("Paused", added: 0, heartbeatAge: 1, discovered: true, paused: true)
                .sidebarStatusText(asOf: now),
            "Paused")
        XCTAssertEqual(
            panel("Connecting", added: 0, discovered: true)
                .sidebarStatusText(asOf: now),
            "Connecting")
        XCTAssertEqual(
            panel("Offline", added: 0).sidebarStatusText(asOf: now),
            "Offline")
    }

    func testChangingPreferenceImmediatelyResortsPanels() {
        let manager = PanelManager(
            previewPanels: [
                panel("Beta", added: 20),
                panel("Alpha", added: 10),
            ],
            savedNetworkNames: [],
            usbSerialPorts: [])
        XCTAssertEqual(manager.panels.map(\.displayName), ["Alpha", "Beta"])

        manager.updateDeviceListSortOrder(.dateAdded)

        XCTAssertEqual(manager.panels.map(\.displayName), ["Beta", "Alpha"])
        XCTAssertEqual(manager.settings.deviceListSortOrder, .dateAdded)
    }

    func testManagerSelectionSurvivesRecreation() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "DeviceListSortApplicationTests-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        let panels = [
            panel("Beta", added: 20),
            panel("Alpha", added: 10),
        ]
        let firstManager = PanelManager(
            previewPanels: panels,
            savedNetworkNames: [],
            usbSerialPorts: [],
            settingsPersistenceURL: settingsURL)

        firstManager.updateDeviceListSortOrder(.dateAdded)
        let reloaded = SettingsStore.load(from: settingsURL)
        let relaunchedManager = PanelManager(
            previewPanels: panels,
            savedNetworkNames: [],
            usbSerialPorts: [],
            settings: reloaded.settings)

        XCTAssertNil(reloaded.failure)
        XCTAssertEqual(relaunchedManager.settings.deviceListSortOrder, .dateAdded)
        XCTAssertEqual(
            relaunchedManager.panels.map(\.displayName),
            ["Beta", "Alpha"])
    }

    func testDiscoveryDisappearanceAndReturnDoNotChangeDateAdded() {
        let added = now.addingTimeInterval(-10_000)
        let manager = PanelManager(
            previewPanels: [
                PanelSnapshot(
                    serviceName: "panel", displayName: "Panel",
                    dateAdded: added),
            ],
            savedNetworkNames: [],
            usbSerialPorts: [])
        let device = DeviceBrowser.Device(
            name: "panel",
            endpoint: .service(
                name: "panel", type: "_espdisp._udp",
                domain: "local.", interface: nil))

        manager.noteDiscovery([device])
        manager.noteDiscovery([])
        manager.noteDiscovery([device])

        XCTAssertEqual(manager.panels.first?.dateAdded, added)
    }
}
