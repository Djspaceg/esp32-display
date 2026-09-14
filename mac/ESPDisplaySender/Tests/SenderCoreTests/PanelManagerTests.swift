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
        panel.usbPort = path
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
                + "partition=8MB bat=-1 ota=off ssid= bllevel=128 fw=1.5.0")
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

    func testVerifiedOldFirmwareExplainsMissingUSBBrightness() {
        let path = "/dev/cu.usbmodem-test"
        var panel = controllablePanel(
            capabilities: .power.union(.flip),
            heartbeatAt: Date(timeIntervalSinceNow: -60))
        panel.usbPort = path
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
        panel.usbPort = path
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
        panel.usbPort = path
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
        panel.usbPort = path
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
        panel.usbPort = "/dev/cu.usbmodem-old"
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
        panel.usbPort = "/dev/cu.usbmodem-1"
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
    }

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
            manager.usbPortOptions(for: "studio-display").map(\.path),
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
            manager.usbPortOptions(for: "studio-display").map(\.path),
            ["/dev/cu.usbmodem-1", "/dev/cu.usbserial-2"])
    }

    func testUnassignedPanelListsDiscoveredPortsOnly() {
        let manager = PanelManager(
            previewPanels: [controllablePanel()],
            savedNetworkNames: [],
            usbSerialPorts: ["/dev/cu.usbmodem-1"])

        XCTAssertEqual(
            manager.usbPortOptions(for: "studio-display").map(\.path),
            ["/dev/cu.usbmodem-1"])
    }

    /// Clearing the assignment has to store nil, not an empty string, or the
    /// blank value would be treated as an explicit port later on.
    func testClearingTheAssignmentStoresNil() {
        var panel = controllablePanel()
        panel.usbPort = "/dev/cu.usbmodem-1"
        let manager = makeManager([panel])

        manager.setUSBPort("   ", for: "studio-display")
        XCTAssertNil(manager.panels.first?.usbPort)
        XCTAssertNil(manager.panels.first?.usbHardwareID)

        manager.setUSBPort("  /dev/cu.usbmodem-2  ", for: "studio-display")
        XCTAssertEqual(manager.panels.first?.usbPort, "/dev/cu.usbmodem-2")

        manager.setUSBPort(nil, for: "studio-display")
        XCTAssertNil(manager.panels.first?.usbPort)
        XCTAssertNil(manager.panels.first?.usbHardwareID)
    }

    func testSelectingNamedDevicePersistsHardwareIdentity() {
        let manager = PanelManager(
            previewPanels: [controllablePanel()],
            savedNetworkNames: [],
            usbSerialPorts: ["/dev/cu.usbmodem-1"])
        manager.noteUSBIdentity(
            path: "/dev/cu.usbmodem-1",
            name: "espdisplay-3456",
            hardwareID: "020000123456")

        manager.setUSBPort("/dev/cu.usbmodem-1", for: "studio-display")

        XCTAssertEqual(manager.panels.first?.usbHardwareID, "020000123456")
        XCTAssertEqual(
            manager.usbPortOptions(for: "studio-display").first?.displayName,
            "espdisplay-3456")
    }

    func testHardwareIdentityFollowsDeviceToNewPort() {
        var panel = controllablePanel()
        panel.usbPort = "/dev/cu.usbmodem-old"
        panel.usbHardwareID = "020000123456"
        let manager = PanelManager(
            previewPanels: [panel],
            savedNetworkNames: [],
            usbSerialPorts: ["/dev/cu.usbmodem-new"])

        manager.noteUSBIdentity(
            path: "/dev/cu.usbmodem-new",
            name: "studio-display",
            hardwareID: "02:00:00:12:34:56")

        XCTAssertEqual(manager.panels.first?.usbPort, "/dev/cu.usbmodem-new")
        XCTAssertEqual(manager.panels.first?.usbHardwareID, "020000123456")
    }

    func testLegacyPathAssignmentMigratesAfterDeviceMoves() {
        var panel = controllablePanel()
        panel.usbPort = "/dev/cu.usbmodem-old"
        panel.usbHardwareID = nil
        let manager = PanelManager(
            previewPanels: [panel],
            savedNetworkNames: [],
            usbSerialPorts: ["/dev/cu.usbmodem-new"])

        manager.noteUSBIdentity(
            path: "/dev/cu.usbmodem-new",
            name: "studio-display",
            hardwareID: "020000123456")

        XCTAssertEqual(manager.panels.first?.usbPort, "/dev/cu.usbmodem-new")
        XCTAssertEqual(manager.panels.first?.usbHardwareID, "020000123456")
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

        XCTAssertNil(manager.panels.first?.usbPort)
        XCTAssertNil(manager.panels.first?.usbHardwareID)
    }

    func testReusedPortPromotesLegacyPanelIDBeforeMoving() {
        var panel = controllablePanel()
        panel.usbPort = "/dev/cu.usbmodem-reused"
        panel.usbHardwareID = nil
        let manager = PanelManager(
            previewPanels: [panel],
            savedNetworkNames: [],
            usbSerialPorts: [
                "/dev/cu.usbmodem-reused",
                "/dev/cu.usbmodem-correct",
            ])

        manager.noteUSBIdentity(
            path: "/dev/cu.usbmodem-reused",
            name: "another-display",
            hardwareID: "020000abcdef")
        XCTAssertNil(manager.panels.first?.usbPort)
        XCTAssertEqual(manager.panels.first?.usbHardwareID, "020000123456")

        manager.noteUSBIdentity(
            path: "/dev/cu.usbmodem-correct",
            name: "studio-display",
            hardwareID: "020000123456")
        XCTAssertEqual(manager.panels.first?.usbPort, "/dev/cu.usbmodem-correct")
        XCTAssertEqual(manager.panels.first?.usbHardwareID, "020000123456")
    }

    func testReusedPortDoesNotReplaceSavedHardwareIdentity() {
        var panel = controllablePanel()
        panel.usbPort = "/dev/cu.usbmodem-1"
        panel.usbHardwareID = "020000123456"
        let manager = PanelManager(
            previewPanels: [panel],
            savedNetworkNames: [],
            usbSerialPorts: ["/dev/cu.usbmodem-1"])

        manager.noteUSBIdentity(
            path: "/dev/cu.usbmodem-1",
            name: "another-display",
            hardwareID: "020000abcdef")

        XCTAssertNil(manager.panels.first?.usbPort, "stale path hint was retained")
        XCTAssertEqual(manager.panels.first?.usbHardwareID, "020000123456")
        XCTAssertEqual(
            manager.usbDeviceSelection(for: "studio-display"),
            "hardware:020000123456")
        XCTAssertEqual(
            manager.usbPortOptions(for: "studio-display").first?.displayName,
            "studio-display")
        XCTAssertFalse(
            manager.usbPortOptions(for: "studio-display").first?.isConnected ?? true)

        manager.setUSBDeviceSelection("", for: "studio-display")
        XCTAssertNil(manager.panels.first?.usbHardwareID)
    }
}
