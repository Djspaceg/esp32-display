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
                  captureStatus: .streaming).deviceListStatus(
                    asOf: now, connectedViaUSB: true),
            .streaming)
        XCTAssertEqual(
            panel("Connected", added: 0, heartbeatAge: 1, discovered: true)
                .deviceListStatus(asOf: now, connectedViaUSB: false),
            .connected)
        XCTAssertEqual(
            panel("Paused", added: 0, heartbeatAge: 1, discovered: true, paused: true)
                .deviceListStatus(asOf: now, connectedViaUSB: true),
            .paused)
        XCTAssertEqual(
            panel("USB", added: 0).deviceListStatus(
                asOf: now, connectedViaUSB: true),
            .connectedViaUSB)
        XCTAssertEqual(
            panel("Connecting", added: 0, discovered: true)
                .deviceListStatus(asOf: now, connectedViaUSB: false),
            .connecting)
        XCTAssertEqual(
            panel("Offline", added: 0).deviceListStatus(
                asOf: now, connectedViaUSB: false),
            .offline)
    }

    func testSidebarStatusLineCoversEveryStatusRank() {
        XCTAssertEqual(
            panel(
                "Streaming", added: 0, heartbeatAge: 1, discovered: true,
                displayFPS: 42.1, captureStatus: .streaming
            ).sidebarStatusText(asOf: now, connectedViaUSB: false),
            "Online • 42.1 fps")
        XCTAssertEqual(
            panel("Connected", added: 0, heartbeatAge: 1, discovered: true)
                .sidebarStatusText(asOf: now, connectedViaUSB: false),
            "Online • Not mirroring")
        XCTAssertEqual(
            panel("Paused", added: 0, heartbeatAge: 1, discovered: true, paused: true)
                .sidebarStatusText(asOf: now, connectedViaUSB: false),
            "Paused")
        XCTAssertEqual(
            panel("USB", added: 0).sidebarStatusText(
                asOf: now, connectedViaUSB: true),
            "Connected via USB")
        XCTAssertEqual(
            panel("Connecting", added: 0, discovered: true)
                .sidebarStatusText(asOf: now, connectedViaUSB: false),
            "Connecting")
        XCTAssertEqual(
            panel("Offline", added: 0).sidebarStatusText(
                asOf: now, connectedViaUSB: false),
            "Offline")
    }

    func testVerifiedUSBPanelDoesNotProjectOffline() throws {
        let path = "/dev/cu.usbmodem-status"
        let hardwareID = "020000123456"
        var usbPanel = panel("USB Panel", added: 0)
        usbPanel.hardwareID = hardwareID
        usbPanel.usbHardwareID = hardwareID
        usbPanel.usbPort = path
        let manager = PanelManager(
            previewPanels: [usbPanel],
            savedNetworkNames: [],
            usbSerialPorts: [path])
        let identity = WifiConfigUI.usbIdentity(from:
            "CFGINFO name64=VVNCIFBhbmVs id=\(hardwareID) "
                + "connected=0 board=st77916 profile=st77916 "
                + "target=s3-185 chip=esp32s3 partition=8MB fw=1.5.0")
        manager.noteUSBIdentity(
            path: path,
            identity: identity,
            generation: manager.usbPathGeneration(path))

        let snapshot = try XCTUnwrap(manager.selectedPanel)
        XCTAssertNotNil(manager.verifiedUSBDevice(for: snapshot.serviceName))
        XCTAssertEqual(
            manager.deviceListStatus(for: snapshot, asOf: now),
            .connectedViaUSB)
        XCTAssertEqual(
            manager.sidebarStatusText(for: snapshot, asOf: now),
            "Connected via USB")
    }

    func testUnverifiedUSBPanelStillProjectsOffline() throws {
        let path = "/dev/cu.usbmodem-unverified"
        var usbPanel = panel("USB Panel", added: 0)
        usbPanel.hardwareID = "020000123456"
        usbPanel.usbHardwareID = usbPanel.hardwareID
        usbPanel.usbPort = path
        let manager = PanelManager(
            previewPanels: [usbPanel],
            savedNetworkNames: [],
            usbSerialPorts: [path])

        let snapshot = try XCTUnwrap(manager.selectedPanel)
        XCTAssertNil(manager.verifiedUSBDevice(for: snapshot.serviceName))
        XCTAssertEqual(
            manager.deviceListStatus(for: snapshot, asOf: now),
            .offline)
        XCTAssertEqual(
            manager.sidebarStatusText(for: snapshot, asOf: now),
            "Offline")
    }

    func testVerifiedUSBImmediatelyUsesItsStatusRank() throws {
        let path = "/dev/cu.usbmodem-ranked"
        let hardwareID = "020000123456"
        var usbPanel = panel("Zulu USB", added: 0)
        usbPanel.hardwareID = hardwareID
        usbPanel.usbHardwareID = hardwareID
        usbPanel.usbPort = path
        var settings = SenderSettings()
        settings.deviceListSortOrder = .status
        let manager = PanelManager(
            previewPanels: [
                panel("Alpha Offline", added: 0),
                usbPanel,
                panel("Middle Connecting", added: 0, discovered: true),
            ],
            savedNetworkNames: [],
            usbSerialPorts: [path],
            settings: settings)
        XCTAssertEqual(
            manager.panels.map(\.displayName),
            ["Middle Connecting", "Alpha Offline", "Zulu USB"])
        let identity = WifiConfigUI.usbIdentity(from:
            "CFGINFO name64=WnVsdSBVU0I= id=\(hardwareID) "
                + "connected=0 board=st77916 profile=st77916 "
                + "target=s3-185 chip=esp32s3 partition=8MB fw=1.5.0")

        manager.noteUSBIdentity(
            path: path,
            identity: identity,
            generation: manager.usbPathGeneration(path))

        XCTAssertEqual(
            manager.panels.map(\.displayName),
            ["Zulu USB", "Middle Connecting", "Alpha Offline"])

        let identityless = WifiConfigUI.usbIdentity(from:
            "CFGINFO name64=WnVsdSBVU0I= connected=0 "
                + "board=st77916 profile=st77916 target=s3-185 "
                + "chip=esp32s3 partition=8MB fw=1.5.0")
        manager.noteUSBIdentity(
            path: path,
            identity: identityless,
            generation: manager.usbPathGeneration(path))
        XCTAssertEqual(
            manager.panels.map(\.displayName),
            ["Middle Connecting", "Alpha Offline", "Zulu USB"])

        manager.noteUSBIdentity(
            path: path,
            identity: identity,
            generation: manager.usbPathGeneration(path))
        manager.markUSBRestarting(usbPanel.serviceName)
        let restartingPanel = try XCTUnwrap(
            manager.panels.first { $0.serviceName == usbPanel.serviceName })
        XCTAssertEqual(
            manager.deviceListStatus(for: restartingPanel, asOf: now),
            .offline)
        XCTAssertEqual(
            manager.panels.map(\.displayName),
            ["Middle Connecting", "Alpha Offline", "Zulu USB"])

        manager.noteUSBIdentity(
            path: path,
            identity: identity,
            generation: manager.usbPathGeneration(path))
        let reverifiedPanel = try XCTUnwrap(
            manager.panels.first { $0.serviceName == usbPanel.serviceName })
        XCTAssertEqual(
            manager.deviceListStatus(for: reverifiedPanel, asOf: now),
            .connectedViaUSB)
        XCTAssertEqual(
            manager.panels.map(\.displayName),
            ["Zulu USB", "Middle Connecting", "Alpha Offline"])
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
