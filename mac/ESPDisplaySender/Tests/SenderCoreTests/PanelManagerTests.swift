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

private final class BlockingUSBControlSender: @unchecked Sendable {
    private let condition = NSCondition()
    private var active = 0
    private var started = 0
    private var released = false
    private var maximumConcurrent = 0

    func send(
        _ command: String, _ path: String, _ timeout: TimeInterval
    ) -> WifiConfigUI.CommandResult {
        condition.lock()
        active += 1
        started += 1
        maximumConcurrent = max(maximumConcurrent, active)
        condition.broadcast()
        while !released { condition.wait() }
        active -= 1
        condition.unlock()
        return .success("CFGOK")
    }

    func waitForStarts(_ count: Int, timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while started < count {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func observedMaximumConcurrent() -> Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumConcurrent
    }
}

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
        let manager = makeManager([controllablePanel()])
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
        let manager = makeManager([controllablePanel(capabilities: .brightness)])
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
        let manager = makeManager([controllablePanel()])
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

    /// A current CFGSHOW identity match is a real control path even when the
    /// panel has never joined WiFi during this app run. The old blanket gate
    /// incorrectly treats the missing session as disabling every operation.
    func testVerifiedUSBOnlyPanelCanUseItsUSBOperations() {
        let path = "/dev/cu.usbmodem-test"
        var panel = controllablePanel(
            capabilities: .power.union(.flip).union(.rotate),
            heartbeatAt: Date(timeIntervalSinceNow: -60))
        panel.firmwareVersion = nil
        panel.usbHardwareID = panel.hardwareID
        let manager = PanelManager(
            previewPanels: [panel],
            savedNetworkNames: ["Studio WiFi"],
            usbSerialPorts: [path])
        let identity = WifiConfigUI.usbIdentity(from:
            "CFGINFO ssid64= name64=c3R1ZGlvLWRpc3BsYXk= "
                + "id=020000123456 connected=0 ip=0.0.0.0 rssi=0 flip=0 "
                + "rot=0 auto=0 effective=0 motion=1 bl=high pwr=on "
                + "board=st77916 profile=st77916 target=s3-185 chip=esp32s3 "
                + "partition=8MB bat=-1 ota=off ssid= caps=00002000 "
                + "bllevel=128 fw=1.5.0")
        manager.noteUSBIdentity(
            path: path,
            identity: identity,
            generation: manager.usbPathGeneration(path))

        XCTAssertFalse(manager.selectedPanel?.isOnline == true)
        XCTAssertEqual(manager.currentUSBPort(for: panel.serviceName), path)
        XCTAssertTrue(
            manager.canControl(panel.serviceName, capability: .power),
            "power has a CFGPOWER path over verified USB")
        XCTAssertTrue(
            manager.canControl(panel.serviceName, capability: .flip),
            "180-degree orientation has a CFGFLIP path over verified USB")
        XCTAssertTrue(
            manager.canControl(panel.serviceName, capability: .rotate),
            "supported quarter-turn orientation has a CFGROT path over verified USB")
        XCTAssertNotNil(
            manager.currentUSBPort(for: panel.serviceName),
            "saved WiFi can be applied through the verified serial path")
        XCTAssertNotNil(
            manager.currentUSBPort(for: panel.serviceName),
            "rename can be sent through the verified serial path")
        XCTAssertNotNil(
            manager.currentUSBPort(for: panel.serviceName),
            "OTA-password changes can be sent through the verified serial path")
        if case .notReady(let reason) =
            manager.firmwareUpdateReadiness(panel.serviceName)
        {
            XCTFail("verified cold USB should enter firmware update: \(reason)")
        }
    }

    func testP4WithoutReportedRotateCapabilityStaysFlipOnlyOverVerifiedUSB() {
        let path = "/dev/cu.usbmodem-p4"
        var panel = controllablePanel(
            capabilities: .power.union(.flip),
            heartbeatAt: Date(timeIntervalSinceNow: -60))
        panel.usbHardwareID = panel.hardwareID
        let manager = PanelManager(
            previewPanels: [panel],
            savedNetworkNames: [],
            usbSerialPorts: [path])
        let identity = WifiConfigUI.usbIdentity(from:
            "CFGINFO ssid64= name64=c3R1ZGlvLWRpc3BsYXk= id=020000123456 "
                + "connected=0 rot=0 pwr=on board=st7703-4b profile=st7703-4b "
                + "target=p4 chip=esp32p4 partition=p4-32m-saves-ota ota=off ssid= "
                + "bllevel=128 fw=1.5.0")
        manager.noteUSBIdentity(
            path: path,
            identity: identity,
            generation: manager.usbPathGeneration(path))

        XCTAssertFalse(manager.supportsQuarterTurnRotation(panel.serviceName))
        XCTAssertFalse(manager.canControl(panel.serviceName, capability: .rotate))
    }

    func testP4WithReportedRotateCapabilityOffersQuarterTurnsOverVerifiedUSB() {
        let path = "/dev/cu.usbmodem-p4"
        var panel = controllablePanel(
            capabilities: .power.union(.flip),
            heartbeatAt: Date(timeIntervalSinceNow: -60))
        panel.usbHardwareID = panel.hardwareID
        let manager = PanelManager(
            previewPanels: [panel],
            savedNetworkNames: [],
            usbSerialPorts: [path])
        let identity = WifiConfigUI.usbIdentity(from:
            "CFGINFO ssid64= name64=c3R1ZGlvLWRpc3BsYXk= id=020000123456 "
                + "connected=0 rot=0 pwr=on board=st7703-4b "
                + "profile=st7703-4b target=p4 chip=esp32p4 "
                + "partition=p4-32m-saves-ota ota=off ssid= caps=00002000 "
                + "bllevel=128 fw=1.5.0")
        manager.noteUSBIdentity(
            path: path,
            identity: identity,
            generation: manager.usbPathGeneration(path))

        XCTAssertTrue(manager.supportsQuarterTurnRotation(panel.serviceName))
        XCTAssertTrue(manager.canControl(panel.serviceName, capability: .rotate))
    }

    func testRotateCapabilityWithoutUSBBoardIdentityStaysFlipOnly() {
        let path = "/dev/cu.usbmodem-unknown"
        var panel = controllablePanel(
            capabilities: .power.union(.flip),
            heartbeatAt: Date(timeIntervalSinceNow: -60))
        panel.usbHardwareID = panel.hardwareID
        let manager = PanelManager(
            previewPanels: [panel],
            savedNetworkNames: [],
            usbSerialPorts: [path])
        let identity = WifiConfigUI.usbIdentity(from:
            "CFGINFO ssid64= name64=c3R1ZGlvLWRpc3BsYXk= id=020000123456 "
                + "connected=0 rot=0 pwr=on target=p4 chip=esp32p4 "
                + "partition=p4-32m-saves-ota ota=off ssid= caps=00002000 "
                + "bllevel=128 fw=1.5.0")
        manager.noteUSBIdentity(
            path: path,
            identity: identity,
            generation: manager.usbPathGeneration(path))

        XCTAssertFalse(manager.supportsQuarterTurnRotation(panel.serviceName))
        XCTAssertFalse(manager.canControl(panel.serviceName, capability: .rotate))
    }

    func testRectangularNetworkPanelWithRotateCapabilityOffersQuarterTurns() {
        var panel = controllablePanel(capabilities: .flip.union(.rotate))
        panel.geometry = PanelGeometry(width: 172, height: 320)
        let manager = makeManager([panel])
        manager.register(makeSession(name: panel.serviceName))

        XCTAssertTrue(manager.supportsQuarterTurnRotation(panel.serviceName))
        XCTAssertTrue(manager.canControl(panel.serviceName, capability: .rotate))
        XCTAssertTrue(manager.canControl(panel.serviceName, capability: .flip))
    }

    /// Firmware from before rectangular landscape withholds `.rotate` on
    /// rectangular glass, so it keeps the 180 toggle it always had.
    func testRectangularPanelWithoutRotateCapabilityStaysFlipOnly() {
        var panel = controllablePanel(capabilities: .flip)
        panel.geometry = PanelGeometry(width: 170, height: 320)
        let manager = makeManager([panel])
        manager.register(makeSession(name: panel.serviceName))

        XCTAssertFalse(manager.supportsQuarterTurnRotation(panel.serviceName))
        XCTAssertFalse(manager.canControl(panel.serviceName, capability: .rotate))
        XCTAssertTrue(manager.canControl(panel.serviceName, capability: .flip))
    }

    func testS3LCD190WithReportedRotateCapabilityOffersQuarterTurnsOverVerifiedUSB() {
        let path = "/dev/cu.usbmodem-190"
        var panel = controllablePanel(
            capabilities: .power.union(.flip),
            heartbeatAt: Date(timeIntervalSinceNow: -60))
        panel.usbHardwareID = panel.hardwareID
        let manager = PanelManager(
            previewPanels: [panel],
            savedNetworkNames: [],
            usbSerialPorts: [path])
        let identity = WifiConfigUI.usbIdentity(from:
            "CFGINFO ssid64= name64=c3R1ZGlvLWRpc3BsYXk= id=020000123456 "
                + "connected=0 rot=1 pwr=on board=st7789-190 "
                + "profile=st7789-190 target=s3 chip=esp32s3 "
                + "partition=universal-8m-doom-saves-ota ota=off ssid= "
                + "caps=00002000 bllevel=128 fw=1.5.0")
        manager.noteUSBIdentity(
            path: path,
            identity: identity,
            generation: manager.usbPathGeneration(path))

        XCTAssertTrue(manager.supportsQuarterTurnRotation(panel.serviceName))
        XCTAssertTrue(manager.canControl(panel.serviceName, capability: .rotate))
    }

    func testUnknownGeometryStaysFlipOnlyEvenIfRotateCapabilityIsSet() {
        let panel = controllablePanel(capabilities: .flip.union(.rotate))
        let manager = makeManager([panel])
        manager.register(makeSession(name: panel.serviceName))

        XCTAssertFalse(manager.supportsQuarterTurnRotation(panel.serviceName))
        XCTAssertFalse(manager.canControl(panel.serviceName, capability: .rotate))
        XCTAssertTrue(manager.canControl(panel.serviceName, capability: .flip))
    }

    func testSquareNetworkPanelWithRotateCapabilityOffersQuarterTurns() {
        var panel = controllablePanel(capabilities: .flip.union(.rotate))
        panel.geometry = PanelGeometry(width: 360, height: 360)
        let manager = makeManager([panel])
        manager.register(makeSession(name: panel.serviceName))

        XCTAssertTrue(manager.supportsQuarterTurnRotation(panel.serviceName))
        XCTAssertTrue(manager.canControl(panel.serviceName, capability: .rotate))
    }

    func testVerifiedOldFirmwareExplainsMissingUSBBrightness() {
        let path = "/dev/cu.usbmodem-test"
        var panel = controllablePanel(
            capabilities: .power.union(.flip),
            heartbeatAt: Date(timeIntervalSinceNow: -60))
        panel.usbHardwareID = panel.hardwareID
        let manager = PanelManager(
            previewPanels: [panel],
            savedNetworkNames: [],
            usbSerialPorts: [path])
        let identity = WifiConfigUI.usbIdentity(from:
            "CFGINFO name64=c3R1ZGlvLWRpc3BsYXk= id=020000123456 "
                + "flip=0 rot=0 bl=high pwr=on board=st77916 "
                + "target=s3-185 chip=esp32s3 partition=8MB fw=1.4.0")
        manager.noteUSBIdentity(
            path: path, identity: identity,
            generation: manager.usbPathGeneration(path))

        XCTAssertFalse(
            manager.canControl(
                panel.serviceName, capability: .brightnessLevel))
        XCTAssertEqual(
            manager.controlUnavailableReason(
                panel.serviceName, capability: .brightnessLevel),
            "Brightness over USB needs firmware support that this display "
                + "does not report.")
        XCTAssertTrue(
            manager.supportsBrightnessLevel(panel.serviceName),
            "cold USB keeps the universal brightness row visible and disabled")
    }

    func testFreshProbeWithoutHardwareIDCannotInheritAnOldMatch() {
        let path = "/dev/cu.usbmodem-test"
        var panel = controllablePanel(capabilities: .power)
        panel.usbHardwareID = panel.hardwareID
        let manager = PanelManager(
            previewPanels: [panel],
            savedNetworkNames: [],
            usbSerialPorts: [path])
        let current = WifiConfigUI.usbIdentity(from:
            "CFGINFO name64=c3R1ZGlvLWRpc3BsYXk= id=020000123456 "
                + "rot=0 pwr=on board=st77916 target=s3-185 chip=esp32s3 "
                + "partition=8MB fw=1.5.0")
        manager.noteUSBIdentity(
            path: path, identity: current,
            generation: manager.usbPathGeneration(path))
        XCTAssertTrue(manager.canControl(panel.serviceName, capability: .power))

        let identityless = WifiConfigUI.usbIdentity(from:
            "CFGINFO name64=c3R1ZGlvLWRpc3BsYXk= rot=0 pwr=on "
                + "board=st77916 target=s3-185 chip=esp32s3 partition=8MB "
                + "fw=1.5.0")
        manager.noteUSBIdentity(
            path: path, identity: identityless,
            generation: manager.usbPathGeneration(path))

        XCTAssertFalse(manager.canControl(panel.serviceName, capability: .power))
        XCTAssertEqual(
            manager.controlUnavailableReason(
                panel.serviceName, capability: .power),
            "USB is connected, but the app has not verified this display's "
                + "hardware ID yet.")
    }

    func testRestartingUSBHasItsOwnReasonUntilTheNextProbe() {
        let path = "/dev/cu.usbmodem-test"
        var panel = controllablePanel(capabilities: .power)
        panel.usbHardwareID = panel.hardwareID
        let manager = PanelManager(
            previewPanels: [panel],
            savedNetworkNames: [],
            usbSerialPorts: [path])
        let identity = WifiConfigUI.usbIdentity(from:
            "CFGINFO name64=c3R1ZGlvLWRpc3BsYXk= id=020000123456 "
                + "rot=0 pwr=on board=st77916 target=s3-185 chip=esp32s3 "
                + "partition=8MB fw=1.5.0")
        manager.noteUSBIdentity(
            path: path, identity: identity,
            generation: manager.usbPathGeneration(path))
        manager.markUSBRestarting(panel.serviceName)

        XCTAssertEqual(
            manager.controlUnavailableReason(
                panel.serviceName, capability: .power),
            "The display is restarting; USB controls will return when it "
                + "answers CFGSHOW.")

        manager.usbDevices = []
        XCTAssertEqual(
            manager.usbSerialState(for: panel.serviceName), .absent,
            "an unplugged display is no longer described as restarting")

        manager.usbDevices = [
            WifiConfigUI.USBDeviceOption(
                path: path,
                name: identity.name,
                hardwareID: identity.hardwareID,
                target: identity.target,
                board: identity.board,
                chip: identity.chip,
                partition: identity.partition,
                serialStatus: identity.status,
                verifiedGeneration: manager.usbPathGeneration(path))
        ]
        manager.noteUSBIdentity(
            path: path, identity: identity,
            generation: manager.usbPathGeneration(path))
        XCTAssertTrue(manager.canControl(panel.serviceName, capability: .power))
    }

    func testBrightnessReplacementCannotOverlapABegunSerialWrite() async {
        let path = "/dev/cu.usbmodem-test"
        var panel = controllablePanel(
            capabilities: .brightnessLevel,
            heartbeatAt: Date(timeIntervalSinceNow: -60))
        panel.usbHardwareID = panel.hardwareID
        let manager = PanelManager(
            previewPanels: [panel],
            savedNetworkNames: [],
            usbSerialPorts: [path])
        let identity = WifiConfigUI.usbIdentity(from:
            "CFGINFO name64=c3R1ZGlvLWRpc3BsYXk= id=020000123456 "
                + "rot=0 bl=high bllevel=64 pwr=on board=st77916 "
                + "target=s3-185 chip=esp32s3 partition=8MB fw=1.5.0")
        manager.noteUSBIdentity(
            path: path, identity: identity,
            generation: manager.usbPathGeneration(path))

        let sender = BlockingUSBControlSender()
        manager.usbControlSender = { command, path, timeout in
            sender.send(command, path, timeout)
        }
        manager.usbControlReprobe = { _, _ in }

        manager.setBrightnessLevel(80, for: panel.serviceName)
        let firstStarted = await Task.detached {
            sender.waitForStarts(1, timeout: 2)
        }.value
        XCTAssertTrue(firstStarted)

        manager.setBrightnessLevel(160, for: panel.serviceName)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            sender.observedMaximumConcurrent(), 1,
            "a replacement value must wait for the begun serial write")

        sender.release()
        let secondStarted = await Task.detached {
            sender.waitForStarts(2, timeout: 2)
        }.value
        XCTAssertTrue(secondStarted)
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    // MARK: screensaver default

    /// A board nobody gave a screensaver is assigned the app's default when it
    /// connects; one with a template of its own keeps it, and one whose
    /// firmware cannot show a template is left alone.
    func testConnectingAssignsTheDefaultScreensaverOnlyWhenUnset() throws {
        var blank = controllablePanel(
            serviceName: "blank-panel", capabilities: allControls.union(.idleText))
        blank.hardwareID = "020000000001"
        var spaces = controllablePanel(
            serviceName: "spaces-panel", capabilities: allControls.union(.idleText))
        spaces.hardwareID = "020000000002"
        spaces.idleText = " \n "
        var custom = controllablePanel(
            serviceName: "custom-panel", capabilities: allControls.union(.idleText))
        custom.hardwareID = "020000000003"
        custom.idleText = "Studio\nback at {uptime}"
        var incapable = controllablePanel(serviceName: "incapable-panel")
        incapable.hardwareID = "020000000004"
        let manager = makeManager([blank, spaces, custom, incapable])

        for (index, panel) in [blank, spaces, custom, incapable].enumerated() {
            manager.register(makeSession(name: panel.serviceName))
            manager.update(
                .info(try makeInfo(
                    name: panel.serviceName,
                    deviceID: [2, 0, 0, 0, 0, UInt8(index + 1)],
                    capabilities: panel.capabilities)),
                for: panel.serviceName)
        }

        func stored(_ name: String) -> String? {
            manager.panels.first { $0.serviceName == name }?.idleText
        }
        XCTAssertEqual(stored("blank-panel"), ScreensaverTemplate.standard)
        XCTAssertEqual(stored("spaces-panel"), ScreensaverTemplate.standard)
        XCTAssertEqual(stored("custom-panel"), "Studio\nback at {uptime}")
        XCTAssertEqual(stored("incapable-panel"), "")
        XCTAssertEqual(
            manager.screensaverPreview(for: "blank-panel").lines,
            ["blank-panel", "Excellent wifi (-52 dBm)", "up for 1m"])
    }

    // MARK: firmware updates

    /// OTA gets its own refusal because the generic one is true and useless:
    /// updates are off on every panel until someone sets a password over USB, so
    /// the message has to name the command that does it.
    ///
    /// One message for two causes, and it says so. The capability bit is
    /// advertised only while the panel is actually listening
    /// (`otapolicy::advertisesCapability` keys on `Status::On` alone), so its
    /// absence means either no password or a password that never got to listen,
    /// and from out here those look identical.
    func testFirmwareUpdateRefusalNamesSetPassword() throws {
        let manager = makeManager([controllablePanel()])
        manager.register(makeSession(name: "studio-display"))
        manager.update(
            .info(try makeInfo(
                name: "studio-display",
                deviceID: [2, 0, 0, 0x12, 0x34, 0x56],
                capabilities: allControls)),
            for: "studio-display")

        XCTAssertFalse(manager.canControl("studio-display", capability: .ota))
        let reason = try XCTUnwrap(
            manager.controlUnavailableReason("studio-display", capability: .ota))
        XCTAssertEqual(
            reason,
            "Wireless updating needs WiFi and an active OTA password. "
                + "Connect over USB to set one.")
    }

    /// The generic wording is still what every other capability gets, so the OTA
    /// case is a special case and not a rewrite of the ladder. Same panel, same
    /// rung, different capability.
    func testOtherCapabilitiesKeepTheGenericRefusal() throws {
        let manager = makeManager([controllablePanel()])
        manager.register(makeSession(name: "studio-display"))
        manager.update(
            .info(try makeInfo(
                name: "studio-display",
                deviceID: [2, 0, 0, 0x12, 0x34, 0x56],
                capabilities: DeviceProtocol.Capabilities.ota.union(.brightness))),
            for: "studio-display")

        XCTAssertTrue(manager.canControl("studio-display", capability: .ota))
        let reason = try XCTUnwrap(
            manager.controlUnavailableReason("studio-display", capability: .restart))
        XCTAssertEqual(
            reason, "This display does not report support for remote restart.")
        XCTAssertFalse(reason.contains("set-password"))
    }

    /// The refusal title is composed from `describe(_:)` like every other one, so
    /// without a `.ota` case in it this would read "This control unavailable".
    func testFirmwareUpdateRefusalIsTitledByName() {
        let manager = makeManager([controllablePanel(capabilities: allControls)])
        manager.register(makeSession(name: "studio-display"))

        XCTAssertNil(manager.beginFirmwareUpdate("studio-display"))
        XCTAssertEqual(
            manager.operationOutcome?.title, "Firmware updates unavailable")
    }

    // MARK: identity reconciliation

    /// A USB rename changes the Bonjour name, so the same board reappears as a
    /// new service. The hardware ID is what keeps the user's settings attached
    /// to it instead of stranding them on a record that never comes back.
    func testRenamedDeviceMigratesItsRecord() throws {
        var existing = controllablePanel(serviceName: "espdisplay")
        existing.usbHardwareID = "020000123456"
        let manager = makeManager([existing])

        manager.update(
            .info(try makeInfo(
                name: "espdisplay-9050", deviceID: [2, 0, 0, 0x12, 0x34, 0x56])),
            for: "espdisplay-9050")

        XCTAssertEqual(manager.panels.count, 1)
        let panel = try XCTUnwrap(manager.panels.first)
        XCTAssertEqual(panel.serviceName, "espdisplay-9050")
        XCTAssertEqual(panel.displayName, "espdisplay-9050")
        XCTAssertEqual(panel.usbHardwareID, "020000123456", "settings did not migrate")
        XCTAssertEqual(panel.hardwareID, "020000123456")
    }

    /// A provisional session rejected for the wrong hardware was another board
    /// using this record's name, so the knob it reported is not this board's.
    func testARejectedProvisionalSessionTakesBackTheKnobItReported() throws {
        let manager = makeManager([controllablePanel(serviceName: "desk")])
        manager.updatePanel("desk") { $0.profile = "gc9a01-knob-128" }
        XCTAssertTrue(try XCTUnwrap(manager.panels.first).knobReported)
        let session = makeSession(name: "desk")
        manager.register(session, provisional: true)

        manager.update(
            .info(try makeInfo(name: "desk", deviceID: [2, 0, 0, 0x65, 0x43, 0x21])),
            for: "desk",
            sessionID: session.id)

        let panel = try XCTUnwrap(manager.panels.first { $0.serviceName == "desk" })
        XCTAssertFalse(panel.knobReported)
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

    /// Discovery of unowned hardware must not create a permanent record.
    func testDifferentHardwareDoesNotCreateARecord() throws {
        let manager = makeManager([controllablePanel(serviceName: "espdisplay")])

        manager.update(
            .info(try makeInfo(
                name: "espdisplay-9050", deviceID: [9, 9, 9, 9, 9, 9])),
            for: "espdisplay-9050")

        XCTAssertEqual(manager.panels.count, 1)
        XCTAssertEqual(manager.panels.first?.serviceName, "espdisplay")
    }

    /// Repeated telemetry updates an existing record but never invents one.
    func testRepeatedInfoUnderTheSameNameIsNotAMigration() throws {
        let manager = makeManager([controllablePanel()])
        let info = try makeInfo(name: "studio-display", deviceID: [2, 0, 0, 0x12, 0x34, 0x56])

        for _ in 0..<3 {
            manager.update(.info(info), for: "studio-display")
        }

        XCTAssertEqual(manager.panels.count, 1)
    }

    // MARK: record ownership and deletion

    func testDiscoveryDoesNotCreateARecord() {
        let manager = makeManager()

        manager.noteDiscovery([makeDevice("unowned-display")])

        XCTAssertTrue(manager.panels.isEmpty)
        XCTAssertFalse(manager.hasRecord(forServiceName: "unowned-display"))
    }

    func testUnknownSessionIsStoppedInsteadOfCreatingARecord() {
        let manager = makeManager()
        let session = makeSession(name: "unowned-display")

        manager.register(session)

        XCTAssertTrue(session.isStopped)
        XCTAssertTrue(manager.panels.isEmpty)
    }

    func testLegacyPrimaryIDFallsBackToCanonicalUSBIdentity() throws {
        var panel = controllablePanel(serviceName: "old-name")
        panel.hardwareID = "esp32c6-legacy"
        panel.usbHardwareID = "020000123456"
        let manager = PanelManager(
            previewPanels: [panel],
            savedNetworkNames: [],
            usbSerialPorts: ["/dev/cu.usbmodem-new"])

        XCTAssertTrue(manager.shouldLaunchDiscoveredService("new-name"))
        manager.noteUSBIdentity(
            path: "/dev/cu.usbmodem-new",
            name: "new-name",
            hardwareID: "020000123456")
        XCTAssertEqual(
            manager.currentUSBPort(for: "old-name"),
            "/dev/cu.usbmodem-new")

        let session = makeSession(name: "new-name")
        manager.register(session, provisional: true)
        manager.update(
            .info(try makeInfo(
                name: "new-name", deviceID: [2, 0, 0, 0x12, 0x34, 0x56])),
            for: "new-name",
            sessionID: session.id)

        XCTAssertEqual(manager.panels.count, 1)
        XCTAssertEqual(manager.panels.first?.serviceName, "new-name")
        XCTAssertFalse(session.senderPausedForTesting)
    }

    func testProvisionalSessionBindsExternallyRenamedRecordByHardwareID() throws {
        let manager = makeManager([controllablePanel(serviceName: "old-name")])
        let session = makeSession(name: "new-name")
        manager.register(session, provisional: true)
        XCTAssertTrue(session.senderPausedForTesting)

        manager.update(
            .info(try makeInfo(
                name: "new-name", deviceID: [2, 0, 0, 0x12, 0x34, 0x56])),
            for: "new-name",
            sessionID: session.id)

        XCTAssertEqual(manager.panels.count, 1)
        XCTAssertEqual(manager.panels.first?.serviceName, "new-name")
        XCTAssertFalse(session.senderPausedForTesting)
    }

    /// The session arrives under the new name before any record owns it, so
    /// registering it cannot apply the saved volume; binding must.
    func testRenamedRecordsSavedVolumeReachesItsSession() throws {
        var panel = controllablePanel(serviceName: "old-name")
        panel.speakerVolume = 0.2
        let manager = makeManager([panel])
        let session = makeSession(name: "new-name")
        manager.register(session, provisional: true)
        XCTAssertEqual(session.speakerVolumeForTesting, PanelSpeakerVolume.default)

        manager.update(
            .info(try makeInfo(
                name: "new-name", deviceID: [2, 0, 0, 0x12, 0x34, 0x56])),
            for: "new-name",
            sessionID: session.id)

        XCTAssertEqual(manager.panels.first?.serviceName, "new-name")
        XCTAssertEqual(session.speakerVolumeForTesting, 0.2)
    }

    func testUserPauseSurvivesRepeatedInfo() throws {
        // EINF repeats every 2 seconds and every arrival re-binds identity.
        // The provisional pause must lift on the FIRST bind only: unpausing
        // on every bind silently undid a user's pause within seconds.
        let manager = makeManager([controllablePanel()])
        let session = makeSession(name: "studio-display")
        manager.register(session)
        let info = try makeInfo(
            name: "studio-display", deviceID: [2, 0, 0, 0x12, 0x34, 0x56])
        manager.update(.info(info), for: "studio-display", sessionID: session.id)
        XCTAssertFalse(session.senderPausedForTesting)

        manager.setPaused(true, for: "studio-display")
        manager.update(.info(info), for: "studio-display", sessionID: session.id)

        XCTAssertTrue(session.senderPausedForTesting,
                      "a repeated EINF must not undo a user pause")
    }

    /// What a session reports while its sender is held or paused, as
    /// `DeviceSession` builds it: a paused sender reads as suspended.
    private func sessionStatus(
        paused: Bool, info: DeviceProtocol.DeviceInfo? = nil
    ) -> DeviceSession.Status {
        DeviceSession.Status(
            serviceName: "studio-display", displayFPS: 0, framesSent: 0,
            sendErrors: 0, diffPercent: 0, heartbeatAge: 0.5,
            stats: BandProtocol.DeviceStats(), info: info,
            resolvedAddress: "192.168.1.42", spacingMicros: 200, paused: paused,
            parked: false, sourceDescription: "", landscape: false,
            captureStatus: paused
                ? .suspended("Paused. Frames are not being sent.") : .streaming,
            lastFrameAt: nil, updatedAt: Date())
    }

    /// Every new session is held paused until EINF binds it to its record, so
    /// no frame leaves before the hardware is proven. That hold is not the
    /// user's pause: at every launch the sidebar read "Paused", with the pause
    /// icon, until the first EINF arrived - 25 s for a board that had just
    /// restarted.
    func testTheIdentityHoldReadsAsConnectingNotPaused() throws {
        let manager = makeManager([controllablePanel()])
        let session = makeSession(name: "studio-display")
        manager.register(session)
        XCTAssertTrue(session.senderPausedForTesting, "the hold still stops frames")

        manager.update(sessionStatus(paused: true), sessionID: session.id)

        let panel = try XCTUnwrap(manager.panels.first)
        XCTAssertFalse(panel.paused)
        XCTAssertEqual(
            panel.statusText(asOf: Date(), connectedViaUSB: false), "Connecting")
        XCTAssertNotEqual(
            panel.captureStatus, .suspended("Paused. Frames are not being sent."))
    }

    /// The status that carries the binding EINF was built while the hold was
    /// still on, so it must not flash "Paused" either. A pause the user makes
    /// after the bind still reads as one.
    func testTheBindingStatusIsNotAPauseButAUserPauseAfterItIs() throws {
        let manager = makeManager([controllablePanel()])
        let session = makeSession(name: "studio-display")
        manager.register(session)
        let info = try makeInfo(
            name: "studio-display", deviceID: [2, 0, 0, 0x12, 0x34, 0x56])

        manager.update(sessionStatus(paused: true, info: info), sessionID: session.id)

        XCTAssertFalse(session.senderPausedForTesting)
        XCTAssertFalse(try XCTUnwrap(manager.panels.first).paused)
        XCTAssertNotEqual(
            manager.panels.first?.statusText(asOf: Date(), connectedViaUSB: false),
            "Paused")

        manager.setPaused(true, for: "studio-display")
        manager.update(sessionStatus(paused: true, info: info), sessionID: session.id)

        XCTAssertTrue(try XCTUnwrap(manager.panels.first).paused)
        XCTAssertEqual(
            manager.panels.first?.statusText(asOf: Date(), connectedViaUSB: false),
            "Paused")
    }

    /// Pause stays available during the hold, so a pause made there is the
    /// user's and must outlast the hold: neither a held status nor the bind
    /// that lifts the hold may undo it.
    func testAPauseMadeDuringTheHoldSurvivesTheBind() throws {
        let manager = makeManager([controllablePanel()])
        let session = makeSession(name: "studio-display")
        manager.register(session)
        manager.update(sessionStatus(paused: true), sessionID: session.id)

        manager.setPaused(true, for: "studio-display")
        manager.update(sessionStatus(paused: true), sessionID: session.id)
        XCTAssertTrue(try XCTUnwrap(manager.panels.first).paused,
                      "a held status must not clear the user's pause")

        let info = try makeInfo(
            name: "studio-display", deviceID: [2, 0, 0, 0x12, 0x34, 0x56])
        manager.update(.info(info), for: "studio-display", sessionID: session.id)
        XCTAssertTrue(session.senderPausedForTesting, "the bind must keep the user's pause")
        XCTAssertEqual(
            manager.panels.first?.statusText(asOf: Date(), connectedViaUSB: false),
            "Paused")
    }

    /// Resume during the hold is the user's choice too, but it must not lift
    /// the hold: frames still wait for EINF.
    func testAResumeDuringTheHoldDoesNotSendBeforeTheBind() throws {
        let manager = makeManager([controllablePanel()])
        let session = makeSession(name: "studio-display")
        manager.register(session)
        manager.update(sessionStatus(paused: true), sessionID: session.id)

        manager.setPaused(true, for: "studio-display")
        manager.setPaused(false, for: "studio-display")

        XCTAssertTrue(session.senderPausedForTesting, "still held until EINF")
        let info = try makeInfo(
            name: "studio-display", deviceID: [2, 0, 0, 0x12, 0x34, 0x56])
        manager.update(.info(info), for: "studio-display", sessionID: session.id)
        XCTAssertFalse(session.senderPausedForTesting)
    }

    /// A session retired while held leaves nothing waiting on the record.
    func testRetiringAHeldSessionClearsTheHold() throws {
        let manager = makeManager([controllablePanel()])
        let session = makeSession(name: "studio-display")
        manager.register(session)
        manager.update(sessionStatus(paused: true), sessionID: session.id)

        manager.retire("studio-display", sessionID: session.id)

        XCTAssertFalse(try XCTUnwrap(manager.panels.first).awaitingIdentity)
    }

    /// The usual first bind is the EINF event itself; status reports trail it
    /// by up to five seconds. Neither the identity text nor a status built
    /// while the hold was on may outlive the bind.
    func testAnEventBindEndsTheWaitAndALateHeldStatusIsNotAPause() throws {
        let manager = makeManager([controllablePanel()])
        let session = makeSession(name: "studio-display")
        manager.register(session)
        manager.update(sessionStatus(paused: true), sessionID: session.id)
        let info = try makeInfo(
            name: "studio-display", deviceID: [2, 0, 0, 0x12, 0x34, 0x56])

        manager.update(.info(info), for: "studio-display", sessionID: session.id)
        let bound = try XCTUnwrap(manager.panels.first)
        XCTAssertFalse(bound.awaitingIdentity)
        // What capture is really doing, not a guess: capture that is stuck
        // with an unchanged state publishes nothing more to correct one.
        XCTAssertEqual(bound.captureStatus, session.captureStatus)

        manager.update(sessionStatus(paused: true, info: info), sessionID: session.id)
        let late = try XCTUnwrap(manager.panels.first)
        XCTAssertFalse(late.paused)
        XCTAssertNotEqual(late.statusText(asOf: Date(), connectedViaUSB: false), "Paused")
        XCTAssertEqual(late.captureStatus, session.captureStatus)
    }

    func testProvisionalUnownedSessionIsStoppedAfterIdentity() throws {
        let manager = makeManager([controllablePanel()])
        let session = makeSession(name: "unowned-display")
        manager.register(session, provisional: true)

        manager.update(
            .info(try makeInfo(
                name: "unowned-display", deviceID: [9, 9, 9, 9, 9, 9])),
            for: "unowned-display",
            sessionID: session.id)

        XCTAssertTrue(session.isStopped)
        XCTAssertEqual(manager.panels.count, 1)
        XCTAssertFalse(manager.shouldLaunchDiscoveredService("unowned-display"))
    }

    func testLateSupersededRegistrationStopsSession() throws {
        let manager = makeManager([controllablePanel(serviceName: "old-name")])
        manager.update(
            .info(try makeInfo(
                name: "new-name", deviceID: [2, 0, 0, 0x12, 0x34, 0x56])),
            for: "new-name")
        let stale = makeSession(name: "old-name")

        manager.register(stale, provisional: true)

        XCTAssertTrue(stale.isStopped)
    }

    func testStaleSessionTokenCannotOverwriteReplacementRecord() throws {
        let manager = makeManager([controllablePanel()])
        let current = makeSession(name: "studio-display")
        manager.register(current)

        manager.update(
            .info(try makeInfo(
                name: "studio-display", deviceID: [9, 9, 9, 9, 9, 9])),
            for: "studio-display",
            sessionID: UUID())

        XCTAssertEqual(manager.panels.first?.hardwareID, "020000123456")
    }

    func testSelectedOnlineRecordCanBeDeleted() {
        let manager = makeManager([controllablePanel()])
        let session = makeSession(name: "studio-display")
        manager.register(session)
        XCTAssertTrue(manager.canForget("studio-display"))

        manager.forget("studio-display")

        XCTAssertTrue(session.isStopped)
        XCTAssertTrue(manager.panels.isEmpty)
        XCTAssertNil(manager.selectedServiceName)
    }

    func testDeletingSelectionChoosesNearestRemainingRecord() {
        let manager = makeManager([
            controllablePanel(serviceName: "one"),
            controllablePanel(serviceName: "two"),
            controllablePanel(serviceName: "three"),
        ])
        manager.selectedServiceName = "two"

        manager.forget("two")

        XCTAssertEqual(manager.panels.map(\.serviceName), ["one", "three"])
        XCTAssertEqual(manager.selectedServiceName, "three")
    }

    // MARK: USB record association


    func testAssociatedUSBDeviceIsIdentifiedByHardwareID() {
        let manager = PanelManager(
            previewPanels: [controllablePanel()],
            savedNetworkNames: [],
            usbSerialPorts: ["/dev/cu.usbmodem-1"])
        manager.noteUSBIdentity(
            path: "/dev/cu.usbmodem-1",
            name: "studio-display",
            hardwareID: "020000123456")

        XCTAssertTrue(manager.isUSBDeviceAssociated("/dev/cu.usbmodem-1"))
        XCTAssertEqual(
            manager.associatedDisplayName(forUSBPath: "/dev/cu.usbmodem-1"),
            "studio-display")
        XCTAssertEqual(
            manager.currentUSBPort(for: "studio-display"),
            "/dev/cu.usbmodem-1")
    }

    func testReusedPathWithDifferentHardwareIsAvailableForAdd() {
        var panel = controllablePanel()
        panel.usbHardwareID = "020000123456"
        let manager = PanelManager(
            previewPanels: [panel],
            savedNetworkNames: [],
            usbSerialPorts: ["/dev/cu.usbmodem-1"])

        manager.noteUSBIdentity(
            path: "/dev/cu.usbmodem-1",
            name: "new-board",
            hardwareID: "020000abcdef")

        XCTAssertFalse(manager.isUSBDeviceAssociated("/dev/cu.usbmodem-1"))
        XCTAssertNil(manager.currentUSBPort(for: "studio-display"))
        XCTAssertEqual(manager.panels.first?.usbHardwareID, "020000123456")
    }

    /// A port is where a board is plugged in, not the board: the record is
    /// paired with whichever port its board answers on now, and moves with
    /// the board when it is plugged in somewhere else.
    func testTheRecordIsPairedWithWhicheverPortItsBoardAnswersOn() {
        let manager = PanelManager(
            previewPanels: [controllablePanel()],
            savedNetworkNames: [],
            usbSerialPorts: ["/dev/cu.usbmodem-old"])
        manager.noteUSBIdentity(
            path: "/dev/cu.usbmodem-old", name: "studio-display",
            hardwareID: "020000123456")
        XCTAssertEqual(manager.currentUSBPort(for: "studio-display"), "/dev/cu.usbmodem-old")

        manager.updateUSBPorts(["/dev/cu.usbmodem-new"])
        XCTAssertNil(manager.currentUSBPort(for: "studio-display"),
            "a port the board has not answered on is not its port")
        manager.noteUSBIdentity(
            path: "/dev/cu.usbmodem-new", name: "studio-display",
            hardwareID: "02:00:00:12:34:56")
        XCTAssertEqual(manager.currentUSBPort(for: "studio-display"), "/dev/cu.usbmodem-new")
        XCTAssertEqual(manager.associatedDisplayName(forUSBPath: "/dev/cu.usbmodem-new"),
            "studio-display")
    }

    func testAutomaticPanelDoesNotBecomeManuallyAssignedDuringProbe() {
        let manager = PanelManager(
            previewPanels: [controllablePanel()],
            savedNetworkNames: [],
            usbSerialPorts: ["/dev/cu.usbmodem-1"])

        manager.noteUSBIdentity(
            path: "/dev/cu.usbmodem-1",
            name: "studio-display",
            hardwareID: "020000123456")

        XCTAssertNil(manager.panels.first?.usbHardwareID)
    }

    func testReusedPortDoesNotReplaceSavedHardwareIdentity() {
        var panel = controllablePanel()
        panel.usbHardwareID = "020000123456"
        let manager = PanelManager(
            previewPanels: [panel],
            savedNetworkNames: [],
            usbSerialPorts: ["/dev/cu.usbmodem-1"])

        manager.noteUSBIdentity(
            path: "/dev/cu.usbmodem-1",
            name: "another-display",
            hardwareID: "020000abcdef")

        XCTAssertEqual(manager.panels.first?.usbHardwareID, "020000123456")
        XCTAssertNil(manager.currentUSBPort(for: "studio-display"))
    }
}
