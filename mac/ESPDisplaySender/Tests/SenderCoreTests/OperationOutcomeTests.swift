import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// Control refusals used to be four fixed strings behind guards the UI already
/// disabled, so they could never be read. The reason now comes from one place
/// that both disables the control and explains itself, which means it can be
/// checked against each precondition.
@MainActor
final class ControlAvailabilityTests: XCTestCase {

    private func makeManager(_ panels: [PanelSnapshot] = []) -> PanelManager {
        PanelManager(previewPanels: panels, savedNetworkNames: [], usbSerialPorts: [])
    }

    private func makeSession(name: String) -> DeviceSession {
        DeviceSession(
            name: name,
            sender: FrameSender(host: "127.0.0.1", port: 5568),
            source: .auto(defaultDisplay: ""),
            picker: nil,
            fps: 30)
    }

    private func panel(
        capabilities: DeviceProtocol.Capabilities,
        controlProtocolVersion: Int? = Int(DeviceProtocol.controlProtocolVersion),
        heartbeatAt: Date? = Date()
    ) -> PanelSnapshot {
        PanelSnapshot(
            serviceName: "studio-display",
            displayName: "studio-display",
            lastSeen: heartbeatAt,
            lastHeartbeatAt: heartbeatAt,
            controlProtocolVersion: controlProtocolVersion,
            capabilitiesRaw: capabilities.rawValue)
    }

    // MARK: reasons

    func testNoReasonWhenEverythingIsInPlace() {
        let manager = makeManager([panel(capabilities: .brightness)])
        manager.register(makeSession(name: "studio-display"))

        XCTAssertNil(
            manager.controlUnavailableReason("studio-display", capability: .brightness))
        XCTAssertTrue(manager.canControl("studio-display", capability: .brightness))
    }

    func testUnknownPanelHasAReason() {
        let manager = makeManager()

        let reason = manager.controlUnavailableReason("ghost", capability: .brightness)
        XCTAssertNotNil(reason)
    }

    func testMissingSessionHasAReason() {
        let manager = makeManager([panel(capabilities: .brightness)])

        XCTAssertEqual(
            manager.controlUnavailableReason("studio-display", capability: .brightness),
            "No streaming session is connected to this display.")
    }

    func testOfflinePanelHasAReason() {
        let manager = makeManager([
            panel(capabilities: .brightness, heartbeatAt: Date(timeIntervalSinceNow: -60)),
        ])
        manager.register(makeSession(name: "studio-display"))

        XCTAssertEqual(
            manager.controlUnavailableReason("studio-display", capability: .brightness),
            "This display is offline.")
    }

    func testStaleFirmwareHasAReason() {
        let manager = makeManager([
            panel(capabilities: .brightness, controlProtocolVersion: nil),
        ])
        manager.register(makeSession(name: "studio-display"))

        XCTAssertEqual(
            manager.controlUnavailableReason("studio-display", capability: .brightness),
            "Flash the current firmware to enable remote controls.")
    }

    /// The reason names the specific control, so a tooltip on a disabled switch
    /// says what is missing rather than "not available".
    func testUnsupportedCapabilityNamesTheControl() {
        let manager = makeManager([panel(capabilities: .brightness)])
        manager.register(makeSession(name: "studio-display"))

        let expected: [(DeviceProtocol.Capabilities, String)] = [
            (.flip, "rotation"),
            (.identify, "identify"),
            (.restart, "remote restart"),
        ]
        for (capability, description) in expected {
            let reason = manager.controlUnavailableReason(
                "studio-display", capability: capability)
            XCTAssertEqual(
                reason, "This display does not report support for \(description).")
        }
    }

    // MARK: refusals reach the user

    /// The guard is a backstop for a panel that goes offline between rendering
    /// and clicking. When it fires the user has to see why.
    func testRefusedControlReportsAnOutcome() {
        let manager = makeManager([panel(capabilities: [])])
        manager.register(makeSession(name: "studio-display"))
        XCTAssertNil(manager.operationOutcome)

        manager.setBrightness(high: true, for: "studio-display")

        XCTAssertEqual(manager.operationOutcome?.kind, .failure)
        XCTAssertEqual(
            manager.operationOutcome?.message,
            "This display does not report support for brightness control.")
    }

    func testRefusalTitleNamesTheControl() {
        let manager = makeManager([panel(capabilities: [])])
        manager.register(makeSession(name: "studio-display"))

        manager.restart("studio-display")

        XCTAssertEqual(manager.operationOutcome?.title, "Remote restart unavailable")
    }

    /// A refused control must not pretend it changed anything.
    func testRefusedControlDoesNotChangeState() {
        let manager = makeManager([panel(capabilities: [])])
        manager.register(makeSession(name: "studio-display"))

        manager.setFlip(true, for: "studio-display")

        XCTAssertFalse(manager.panels.first?.flipped == true)
    }

    func testAllowedControlUpdatesStateAndReportsNothing() {
        let manager = makeManager([panel(capabilities: .flip)])
        manager.register(makeSession(name: "studio-display"))

        manager.setFlip(true, for: "studio-display")

        XCTAssertTrue(manager.panels.first?.flipped == true)
        XCTAssertNil(manager.operationOutcome)
    }
}

/// Failures used to arrive through one of two channels depending on which code
/// path produced them: a SwiftUI alert for device commands, an NSAlert put up by
/// the serial layer for USB configuration. Successes had no channel at all in
/// the manager and were announced by the serial layer's own modal.
@MainActor
final class OperationOutcomeTests: XCTestCase {

    private func makeManager(_ panels: [PanelSnapshot] = []) -> PanelManager {
        PanelManager(previewPanels: panels, savedNetworkNames: [], usbSerialPorts: [])
    }

    func testFailureFromConfigFailureCarriesBothParts() {
        let outcome = OperationOutcome.failure(
            WifiConfigUI.ConfigFailure(title: "No device found", message: "Connect it."))

        XCTAssertEqual(outcome.kind, .failure)
        XCTAssertEqual(outcome.title, "No device found")
        XCTAssertEqual(outcome.message, "Connect it.")
    }

    func testSuccessAndFailureAreDistinguishable() {
        XCTAssertEqual(OperationOutcome.success("a", "b").kind, .success)
        XCTAssertEqual(OperationOutcome.failure("a", "b").kind, .failure)
    }

    /// Empty SSID is caught before any serial I/O is attempted.
    func testApplyingNoNetworkFails() {
        let manager = makeManager([
            PanelSnapshot(serviceName: "studio-display", displayName: "studio-display"),
        ])

        manager.applySavedNetwork("", to: "studio-display")

        XCTAssertEqual(manager.operationOutcome?.kind, .failure)
        XCTAssertEqual(manager.operationOutcome?.title, "No network selected")
    }

    func testConfiguringWithNoSelectionFails() {
        let manager = makeManager()

        manager.configureUSB()

        XCTAssertEqual(manager.operationOutcome?.kind, .failure)
        XCTAssertEqual(manager.operationOutcome?.title, "No display selected")
    }

    /// An action for a panel that is not in the list does nothing at all, rather
    /// than reporting a confusing outcome about a display the user cannot see.
    func testActionForUnknownPanelIsIgnored() {
        let manager = makeManager()

        manager.rename("new-name", for: "ghost")
        manager.applySavedNetwork("Studio WiFi", to: "ghost")

        XCTAssertNil(manager.operationOutcome)
    }

    func testClearingRemovesTheOutcome() {
        let manager = makeManager()
        manager.configureUSB()
        XCTAssertNotNil(manager.operationOutcome)

        manager.clearOperationOutcome()

        XCTAssertNil(manager.operationOutcome)
    }

    /// A rejected acknowledgement from the device is a failure like any other
    /// and shares the same channel.
    func testRejectedAcknowledgementIsAFailure() throws {
        let manager = makeManager()
        // EACK with a non-zero status byte, which is how the firmware refuses.
        let packet = Data([
            0x45, 0x41, 0x43, 0x4B, 0x01, 0x02, 0x34, 0x12,
            0x05, 0x00, 0x80, 0x00,
        ])
        let ack = try XCTUnwrap(DeviceProtocol.parseAck(packet))
        XCTAssertFalse(ack.succeeded)

        manager.update(.acknowledgement(ack), for: "studio-display")

        XCTAssertEqual(manager.operationOutcome?.kind, .failure)
        XCTAssertEqual(manager.operationOutcome?.title, "Display command failed")
    }

    func testAcceptedAcknowledgementReportsNothing() throws {
        let manager = makeManager()
        let packet = Data([
            0x45, 0x41, 0x43, 0x4B, 0x01, 0x02, 0x34, 0x12,
            0x00, 0x00, 0x80, 0x00,
        ])
        let ack = try XCTUnwrap(DeviceProtocol.parseAck(packet))

        manager.update(.acknowledgement(ack), for: "studio-display")

        XCTAssertNil(manager.operationOutcome)
    }
}
