import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// Brightness was a single High switch mapping onto two hard-coded PWM values,
/// so the panel could only be 50% or 10%. The level command carries any value
/// 1-255 and is advertised by its own capability bit, which is what lets the UI
/// offer a slider to firmware that understands it and the old switch to
/// firmware that does not.
final class BrightnessLevelProtocolTests: XCTestCase {

    /// A new bit rather than a control-protocol bump, because bumping the
    /// version makes an exact-match check refuse every control until the panel
    /// is reflashed.
    func testLevelCapabilityIsItsOwnBit() {
        XCTAssertEqual(DeviceProtocol.Capabilities.brightnessLevel.rawValue, 0x80)
        XCTAssertFalse(
            DeviceProtocol.Capabilities.brightness
                .contains(.brightnessLevel))
        XCTAssertEqual(DeviceProtocol.controlProtocolVersion, 1)
    }

    /// Must match the firmware header, which is the peer that clamps to a PWM
    /// register. Zero is excluded on purpose.
    func testLevelRangeExcludesOff() {
        XCTAssertEqual(DeviceProtocol.brightnessLevelRange, 1...255)
    }

    func testLevelPacketCarriesTheOpcodeAndValue() {
        let packet = DeviceProtocol.controlPacket(
            opcode: .brightnessLevel, sequence: 0x1234, value: 200)

        XCTAssertEqual([UInt8](packet), [
            0x45, 0x43, 0x54, 0x4C,  // ECTL
            0x01,                    // control protocol version
            0x05,                    // brightnessLevel
            0x34, 0x12,              // sequence, little endian
            0xC8, 0x00, 0x00, 0x00,  // value 200, little endian
        ])
    }

    /// The device echoes the opcode in its acknowledgement, so it has to parse
    /// back or the ack would be discarded as malformed.
    func testLevelAcknowledgementParses() throws {
        let packet = Data([
            0x45, 0x41, 0x43, 0x4B, 0x01, 0x05, 0x34, 0x12,
            0x00, 0x01, 0xC8, 0x00,
        ])

        let ack = try XCTUnwrap(DeviceProtocol.parseAck(packet))
        XCTAssertEqual(ack.opcode, .brightnessLevel)
        XCTAssertTrue(ack.succeeded)
        XCTAssertEqual(ack.brightness, 200)
    }

    func testBinaryBrightnessIsUnchanged() {
        let high = DeviceProtocol.controlPacket(
            opcode: .brightness, sequence: 1, value: 1)
        let low = DeviceProtocol.controlPacket(
            opcode: .brightness, sequence: 1, value: 0)

        XCTAssertEqual([UInt8](high)[5], 0x01)
        XCTAssertEqual([UInt8](high)[8], 0x01)
        XCTAssertEqual([UInt8](low)[8], 0x00)
    }
}

/// The manager clamps and gates the level, so a slider cannot ask for something
/// the firmware would refuse.
@MainActor
final class BrightnessLevelControlTests: XCTestCase {

    private func makeSession(name: String) -> DeviceSession {
        DeviceSession(
            name: name,
            sender: FrameSender(host: "127.0.0.1", port: 5568),
            source: .auto(defaultDisplay: ""),
            picker: nil,
            fps: 30)
    }

    private func makeManager(
        capabilities: DeviceProtocol.Capabilities, brightness: Int = 128
    ) -> PanelManager {
        var panel = PanelSnapshot(
            serviceName: "studio-display",
            displayName: "studio-display",
            lastSeen: Date(),
            lastHeartbeatAt: Date(),
            controlProtocolVersion: Int(DeviceProtocol.controlProtocolVersion),
            capabilitiesRaw: capabilities.rawValue)
        panel.brightness = brightness
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])
        manager.register(makeSession(name: "studio-display"))
        return manager
    }

    func testLevelIsAppliedImmediatelySoASliderTracks() {
        let manager = makeManager(capabilities: .brightnessLevel)

        manager.setBrightnessLevel(64, for: "studio-display")

        XCTAssertEqual(manager.panels.first?.brightness, 64)
        XCTAssertNil(manager.operationOutcome)
    }

    func testLevelIsClampedIntoRange() {
        let manager = makeManager(capabilities: .brightnessLevel)

        manager.setBrightnessLevel(0, for: "studio-display")
        XCTAssertEqual(manager.panels.first?.brightness, 1)

        manager.setBrightnessLevel(-40, for: "studio-display")
        XCTAssertEqual(manager.panels.first?.brightness, 1)

        manager.setBrightnessLevel(9_000, for: "studio-display")
        XCTAssertEqual(manager.panels.first?.brightness, 255)
    }

    /// Firmware without the bit rejects opcode 5 outright, so the manager must
    /// refuse rather than send it and leave the UI showing a level that never
    /// took effect.
    func testLevelIsRefusedWithoutTheCapability() {
        let manager = makeManager(capabilities: .brightness, brightness: 128)

        manager.setBrightnessLevel(64, for: "studio-display")

        XCTAssertEqual(manager.panels.first?.brightness, 128)
        XCTAssertEqual(manager.operationOutcome?.kind, .failure)
        XCTAssertEqual(
            manager.operationOutcome?.message,
            "This display does not report support for brightness levels.")
    }

    /// The high/low switch still has to work for firmware that only offers it.
    func testBinaryBrightnessStillWorksWithoutTheLevelCapability() {
        let manager = makeManager(capabilities: .brightness)

        manager.setBrightness(high: false, for: "studio-display")

        XCTAssertFalse(manager.panels.first?.brightnessHigh == true)
        XCTAssertNil(manager.operationOutcome)
    }

    func testLevelAndBinaryAreGatedIndependently() {
        let levelOnly = makeManager(capabilities: .brightnessLevel)
        XCTAssertTrue(
            levelOnly.canControl("studio-display", capability: .brightnessLevel))
        XCTAssertFalse(
            levelOnly.canControl("studio-display", capability: .brightness))

        let binaryOnly = makeManager(capabilities: .brightness)
        XCTAssertTrue(
            binaryOnly.canControl("studio-display", capability: .brightness))
        XCTAssertFalse(
            binaryOnly.canControl("studio-display", capability: .brightnessLevel))
    }
}
