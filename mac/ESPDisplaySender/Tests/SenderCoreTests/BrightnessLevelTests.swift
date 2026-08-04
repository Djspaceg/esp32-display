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

/// The slider reads `panel.brightness`, and the device also writes it from
/// every acknowledgement and every EINF. Dragging therefore raced the panel's
/// own reports: each one carried a level a packet or two behind the cursor, so
/// the thumb visibly jumped backwards under the user's finger.
///
/// The manager now prefers the level it last asked for until the device catches
/// up. These tests pin the release conditions, because suppression that never
/// ended would be the worse bug - the UI would stop reflecting the panel at all.
@MainActor
final class BrightnessEchoSuppressionTests: XCTestCase {

    private func makeManager(brightness: Int) -> PanelManager {
        var panel = PanelSnapshot(
            serviceName: "studio-display",
            displayName: "studio-display",
            lastSeen: Date(),
            lastHeartbeatAt: Date(),
            controlProtocolVersion: Int(DeviceProtocol.controlProtocolVersion),
            capabilitiesRaw: DeviceProtocol.Capabilities.brightnessLevel
                .union(.brightness).rawValue)
        panel.brightness = brightness
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])
        manager.register(
            DeviceSession(
                name: "studio-display",
                sender: FrameSender(host: "127.0.0.1", port: 5568),
                source: .auto(defaultDisplay: ""),
                picker: nil,
                fps: 30))
        return manager
    }

    /// An acknowledgement reporting `brightness`, built as bytes so it cannot
    /// drift from what the firmware actually sends.
    private func makeAck(brightness: UInt8) throws -> DeviceProtocol.ControlAck {
        let packet = Data([
            0x45, 0x41, 0x43, 0x4B,          // EACK
            DeviceProtocol.controlProtocolVersion,
            0x05,                            // brightnessLevel
            0x34, 0x12,                      // sequence
            0x00,                            // status: applied
            0x01,                            // flags: brightnessHigh
            brightness,
            0x00,
        ])
        return try XCTUnwrap(DeviceProtocol.parseAck(packet))
    }

    private func makeInfo(brightness: UInt8) throws -> DeviceProtocol.DeviceInfo {
        let name = "studio-display"
        let firmware = "1.1.0"
        let capabilities = DeviceProtocol.Capabilities.brightnessLevel
            .union(.brightness)
        var packet = Data("EINF".utf8)
        packet.append(contentsOf: [
            DeviceProtocol.infoVersion,
            DeviceProtocol.frameProtocolVersion,
            DeviceProtocol.controlProtocolVersion,
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
        packet.append(brightness)
        packet.append(UInt8(name.utf8.count))
        packet.append(UInt8(firmware.utf8.count))
        packet.append(contentsOf: [0xAC, 0xEB, 0xE6, 0x3E, 0x90, 0x50])
        packet.append(contentsOf: name.utf8)
        packet.append(contentsOf: firmware.utf8)
        return try XCTUnwrap(DeviceProtocol.parseInfo(packet), "EINF vector is malformed")
    }

    /// The case that made the slider feel broken.
    func testStaleAcknowledgementDoesNotDragTheSliderBack() throws {
        let manager = makeManager(brightness: 128)

        manager.setBrightnessLevel(220, for: "studio-display")
        // The panel is still reporting a level from earlier in the drag.
        manager.update(.acknowledgement(try makeAck(brightness: 150)), for: "studio-display")

        XCTAssertEqual(manager.panels.first?.brightness, 220)
    }

    func testStaleInfoDoesNotDragTheSliderBack() throws {
        let manager = makeManager(brightness: 128)

        manager.setBrightnessLevel(220, for: "studio-display")
        manager.update(.info(try makeInfo(brightness: 150)), for: "studio-display")

        XCTAssertEqual(manager.panels.first?.brightness, 220)
    }

    /// Once the device confirms the commanded level, suppression must end -
    /// otherwise later genuine changes (the BOOT button, say) would be ignored.
    func testReportsApplyAgainOnceTheDeviceCatchesUp() throws {
        let manager = makeManager(brightness: 128)

        manager.setBrightnessLevel(220, for: "studio-display")
        manager.update(.acknowledgement(try makeAck(brightness: 220)), for: "studio-display")
        XCTAssertEqual(manager.panels.first?.brightness, 220)

        // A change made at the panel itself, with no command in flight.
        manager.update(.acknowledgement(try makeAck(brightness: 24)), for: "studio-display")

        XCTAssertEqual(manager.panels.first?.brightness, 24)
    }

    /// Nothing commanded, so telemetry is the only source of truth and must be
    /// applied as it always was.
    func testReportsApplyNormallyWithNoCommandInFlight() throws {
        let manager = makeManager(brightness: 128)

        manager.update(.info(try makeInfo(brightness: 200)), for: "studio-display")

        XCTAssertEqual(manager.panels.first?.brightness, 200)
    }

    /// Suppression covers the level only. The high/low flag is derived on the
    /// device from a PWM threshold the Mac has no copy of, so holding it back
    /// would mean either inventing a value or freezing a stale one - the device
    /// stays authoritative for it. This is invisible in the UI, which shows the
    /// slider rather than the switch whenever the level capability is present.
    func testDerivedHighFlagStaysTheDevicesToReport() throws {
        let manager = makeManager(brightness: 24)

        manager.setBrightnessLevel(10, for: "studio-display")
        manager.update(.acknowledgement(try makeAck(brightness: 200)), for: "studio-display")

        // Level held at what the user asked for, flag taken from the device.
        XCTAssertEqual(manager.panels.first?.brightness, 10)
        XCTAssertTrue(manager.panels.first?.brightnessHigh == true)
    }

    /// A refusal still has to surface even while brightness reports are held.
    func testRefusalIsStillReportedDuringSuppression() throws {
        let manager = makeManager(brightness: 128)
        manager.setBrightnessLevel(220, for: "studio-display")

        let refused = Data([
            0x45, 0x41, 0x43, 0x4B, DeviceProtocol.controlProtocolVersion,
            0x05, 0x34, 0x12, 0x80, 0x00, 0x96, 0x00,
        ])
        let ack = try XCTUnwrap(DeviceProtocol.parseAck(refused))
        manager.update(.acknowledgement(ack), for: "studio-display")

        XCTAssertEqual(manager.operationOutcome?.kind, .failure)
        XCTAssertEqual(manager.panels.first?.brightness, 220)
    }
}
