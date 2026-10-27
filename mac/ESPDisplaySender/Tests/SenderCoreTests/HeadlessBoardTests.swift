import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// A board with no screen (the bare XIAO ESP32-S3) is a device all the same:
/// listed, flashable, WiFi-configurable, restartable and updatable. Everything
/// that needs a screen is off, with the reason said, and nothing streams.
@MainActor
final class HeadlessBoardTests: XCTestCase {

    private let bare = "xiao-s3-bare"

    private func makeManager(_ panels: [PanelSnapshot]) -> PanelManager {
        PanelManager(previewPanels: panels, savedNetworkNames: [], usbSerialPorts: [])
    }

    private func makeSession(name: String, headless: Bool = false) -> DeviceSession {
        DeviceSession(
            name: name,
            sender: FrameSender(host: "127.0.0.1", port: 5568),
            source: .auto(defaultDisplay: ""),
            picker: nil,
            fps: 30,
            headless: headless)
    }

    /// What the bare XIAO's firmware advertises: restart and telemetry, and
    /// both update paths once an OTA password is set.
    private func barePanel(profile: String? = "xiao-s3-bare") -> PanelSnapshot {
        var panel = PanelSnapshot(
            serviceName: "espdisplay-8af8",
            displayName: "espdisplay-8af8",
            lastSeen: Date(),
            lastHeartbeatAt: Date(),
            controlProtocolVersion: Int(DeviceProtocol.controlProtocolVersion),
            capabilitiesRaw: DeviceProtocol.Capabilities(
                [.restart, .telemetry, .ota, .streamUpdate]).rawValue)
        panel.profile = profile
        panel.target = "s3"
        panel.chip = "esp32s3"
        return panel
    }

    func testTheCatalogNamesTheBoardWithNoScreen() {
        XCTAssertEqual(GeneratedBoardCatalog.headlessProfiles, [bare])
        XCTAssertNil(GeneratedBoardCatalog.geometryByProfile[bare])
        XCTAssertTrue(GeneratedBoardCatalog.profilesByTarget["s3"]?.contains(bare) == true)
        XCTAssertEqual(GeneratedBoardCatalog.boardNameByProfile[bare],
                       "XIAO ESP32-S3 (no screen)")
        // Every board with a screen still has its geometry.
        for (_, profiles) in GeneratedBoardCatalog.profilesByTarget {
            for profile in profiles
            where !GeneratedBoardCatalog.headlessProfiles.contains(profile) {
                XCTAssertNotNil(GeneratedBoardCatalog.geometryByProfile[profile], profile)
            }
        }
    }

    func testOnlyAReportedHeadlessProfileHasNoScreen() {
        XCTAssertTrue(PanelSnapshot.profileHasNoScreen(bare))
        XCTAssertFalse(PanelSnapshot.profileHasNoScreen("st7735-042"))
        XCTAssertFalse(PanelSnapshot.profileHasNoScreen(nil))
        XCTAssertFalse(PanelSnapshot.profileHasNoScreen("a-board-from-newer-firmware"))
        XCTAssertTrue(barePanel().hasNoScreen)
        XCTAssertFalse(barePanel(profile: "st7735-042").hasNoScreen)
    }

    func testScreenControlsAreOffWithTheReasonAndTheRestStayOn() {
        let panel = barePanel()
        let manager = makeManager([panel])
        manager.register(makeSession(name: panel.serviceName, headless: true))

        for operation: PanelManager.Operation in [
            .brightness, .brightnessLevel, .brightnessLevels, .flip, .rotate,
            .automaticRotation, .power, .identify, .streaming,
        ] {
            XCTAssertTrue(PanelManager.needsScreen(operation), "\(operation)")
            XCTAssertEqual(
                manager.operationUnavailableReason(panel.serviceName, operation: operation),
                PanelManager.noScreenReason, "\(operation)")
        }
        for operation: PanelManager.Operation in [
            .restart, .rename, .otaPassword, .firmwareUpdate, .wirelessFirmwareUpdate,
        ] {
            XCTAssertFalse(PanelManager.needsScreen(operation), "\(operation)")
            XCTAssertNotEqual(
                manager.operationUnavailableReason(panel.serviceName, operation: operation),
                PanelManager.noScreenReason, "\(operation)")
        }
        XCTAssertTrue(manager.canControl(panel.serviceName, capability: .restart))
        XCTAssertFalse(manager.canPerform(.streaming, for: panel.serviceName))
    }

    func testABoardWithAScreenIsNotRefusedForHavingNone() {
        var panel = barePanel(profile: "st7735-042")
        panel.capabilitiesRaw = DeviceProtocol.Capabilities([.restart, .identify]).rawValue
        let manager = makeManager([panel])
        manager.register(makeSession(name: panel.serviceName))
        XCTAssertNil(
            manager.operationUnavailableReason(panel.serviceName, operation: .identify))
    }

    func testNoGamesAreOfferedToABoardWithNoScreen() {
        let panel = barePanel()
        let manager = makeManager([panel])
        XCTAssertFalse(GamesDataRow.isOffered(for: panel, manager: manager))
        XCTAssertTrue(
            GamesDataRow.isOffered(for: barePanel(profile: "st7735-042"), manager: manager))
    }

    func testTheManagerKnowsWhichDeviceHasNoScreen() {
        let manager = makeManager([barePanel()])
        XCTAssertTrue(manager.hasNoScreen("espdisplay-8af8"))
        XCTAssertFalse(manager.hasNoScreen("someone-else"))
    }

    func testAHeadlessSessionSaysSoAndNeverCaptures() async {
        var statuses: [CaptureStatus] = []
        let lock = NSLock()
        let session = DeviceSession(
            name: "espdisplay-8af8",
            sender: FrameSender(host: "127.0.0.1", port: 5568),
            source: .auto(defaultDisplay: ""),
            picker: nil,
            fps: 30,
            headless: true,
            onStatus: { status in
                lock.withLock { statuses.append(status.captureStatus) }
            })
        XCTAssertTrue(session.headless)
        let run = Task { await session.run() }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              lock.withLock({ !statuses.contains(DeviceSession.headlessStatus) }) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        session.stop()
        _ = await run.value
        let seen = lock.withLock { statuses }
        XCTAssertTrue(seen.contains(DeviceSession.headlessStatus))
        XCTAssertFalse(seen.contains { $0.isStreaming })
        XCTAssertEqual(session.captureStatus, DeviceSession.headlessStatus)
    }

    func testTheNoScreenExplanationSaysWhatStillWorks() {
        let text = PanelDetailView.noScreenExplanation
        XCTAssertTrue(text.contains("no screen"))
        XCTAssertTrue(text.contains("WiFi"))
        XCTAssertTrue(text.contains("firmware"))
    }
}
