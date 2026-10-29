import AVFoundation
import CoreAudio
import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// Stands in for ESPDisplayAudio.driver: devices by UID, and frames queued
/// for the PCM property to hand out.
final class FakeDisplayAudioDriver: DisplayAudioDriverBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [AudioObjectID: [Float]] = [:]
    private var ids: [String: AudioObjectID] = [:]
    var state = DisplayAudioDriverAvailability.ready
    private(set) var registrations: [[DisplayAudioDeviceSpec]] = []
    /// Devices appear only once registered, as the driver's do.
    var devicesAppearOnRegister = true
    /// Added to every device ID, so a test can make the driver's devices come
    /// back as new ones.
    var idBase: AudioObjectID = 100

    func availability() -> DisplayAudioDriverAvailability { lock.withLock { state } }

    /// As a driver whose client places are all taken.
    var refuseRegistrations = false

    func register(_ devices: [DisplayAudioDeviceSpec]) -> Bool {
        lock.withLock {
            registrations.append(devices)
            guard state == .ready, !refuseRegistrations else { return false }
            if devicesAppearOnRegister {
                ids = [:]
                for (index, device) in devices.enumerated() {
                    ids[device.uid] = idBase + AudioObjectID(index)
                }
            }
            return true
        }
    }

    func addDevice(uid: String, id: AudioObjectID) { lock.withLock { ids[uid] = id } }

    /// As the real driver's: another owner's device for a display carries
    /// that owner's UID suffix, so it is not found by this app's UID.
    func deviceID(uid: String) -> AudioObjectID? {
        lock.withLock { claimedElsewhere.contains(uid) ? nil : ids[uid] }
    }

    /// Devices the driver lists under this app's UID but this app does not
    /// own, the branch a device found by UID can still take.
    var listedButNotOwned: Set<String> = []
    /// What the driver says it holds, all owners together; nil when it does
    /// not say.
    var heldDevices: Int?
    func deviceCount() -> Int? { lock.withLock { heldDevices } }
    private(set) var claimScans = 0

    /// The suffix this app's devices carry in macOS; empty for tests that
    /// compare UIDs as registered.
    var suffix = ""

    func deviceUID(for uid: String) -> String { uid + suffix }

    func isClaimedElsewhere(uid: String) -> Bool {
        lock.withLock {
            claimScans += 1
            return claimedElsewhere.contains(uid) && ids[uid] != nil
        }
    }

    /// UIDs whose device another client claimed first.
    var claimedElsewhere: Set<String> = []

    func owns(device: AudioObjectID) -> Bool {
        lock.withLock {
            guard let uid = ids.first(where: { $0.value == device })?.key else { return false }
            return !claimedElsewhere.contains(uid) && !listedButNotOwned.contains(uid)
        }
    }

    func queue(_ samples: [Float], for device: AudioObjectID) {
        lock.withLock { pending[device, default: []] += samples }
    }

    func readFrames(device: AudioObjectID) -> Data? {
        lock.withLock {
            let samples = pending[device] ?? []
            pending[device] = []
            return samples.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }

    var lastRegistration: [DisplayAudioDeviceSpec]? { lock.withLock { registrations.last } }
    var registrationCount: Int { lock.withLock { registrations.count } }
}

final class DisplayAudioDriverTests: XCTestCase {
    /// The Swift constants are a copy of the driver's header. Reading the
    /// header itself is what keeps a change on one side from going unnoticed.
    func testTheSwiftConstantsMatchTheDriverHeader() throws {
        let header = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../AudioDriver/ESPDisplayAudioProtocol.h")
            .standardizedFileURL
        let text = try String(contentsOf: header, encoding: .utf8)
        func define(_ name: String) -> String? {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 2)
                if parts.count == 3, parts[0] == "#define", parts[1] == name {
                    return String(parts[2]).trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }
        typealias P = DisplayAudioDriverProtocol
        XCTAssertEqual(define("ESPDISP_AUDIO_PROTOCOL_VERSION"), "\(P.version)")
        XCTAssertEqual(define("ESPDISP_AUDIO_BUNDLE_ID"), "\"\(P.bundleID)\"")
        XCTAssertEqual(define("ESPDISP_AUDIO_SELECTOR_REGISTER"), "'ESrg'")
        XCTAssertEqual(define("ESPDISP_AUDIO_SELECTOR_VERSION"), "'ESvr'")
        XCTAssertEqual(define("ESPDISP_AUDIO_SELECTOR_PCM"), "'ESpc'")
        XCTAssertEqual(P.registerSelector, 0x4553_7267)
        XCTAssertEqual(P.pcmSelector, 0x4553_7063)
        XCTAssertEqual(define("ESPDISP_AUDIO_SELECTOR_OWNED"), "'ESow'")
        XCTAssertEqual(P.ownedSelector, 0x4553_6F77)
        XCTAssertEqual(define("ESPDISP_AUDIO_SAMPLE_RATE"), "\(Int(P.sampleRate))")
        XCTAssertEqual(define("ESPDISP_AUDIO_MAX_READ_FRAMES"), "\(P.maxReadFrames)")
        XCTAssertEqual(define("ESPDISP_AUDIO_MAX_DEVICES"), "\(P.maxDevices)")
        XCTAssertEqual(define("ESPDISP_AUDIO_MAX_CLIENTS"), "\(P.maxClients)")
        XCTAssertEqual(
            define("ESPDISP_AUDIO_CLIENT_TIMEOUT_SECONDS"), "\(Int(P.clientTimeoutSeconds))")
        XCTAssertEqual(define("ESPDISP_AUDIO_UID_SUFFIX_BYTES"), "\(P.uidSuffixBytes)")
        XCTAssertEqual(define("ESPDISP_AUDIO_MIN_TOKEN_BYTES"), "\(P.minTokenBytes)")
        for (name, key) in [
            ("VERSION", P.Key.version), ("CLIENT", P.Key.client), ("TOKEN", P.Key.token),
            ("DEVICES", P.Key.devices), ("UID", P.Key.uid), ("NAME", P.Key.name),
            ("LATENCY", P.Key.latency),
        ] {
            XCTAssertEqual(define("ESPDISP_AUDIO_KEY_\(name)"), "\"\(key)\"")
        }
    }

    func testRegistrationPayloadIsWhatTheDriverParses() throws {
        let token = String(repeating: "t", count: 32)
        let payload = DisplayAudioDriverRegistration.payload(
            client: "app.1", token: token,
            devices: [DisplayAudioDeviceSpec(uid: "u", name: "Desk", latencyFrames: 7_200)])
        XCTAssertEqual(payload["version"] as? Int, 3)
        XCTAssertEqual(payload["client"] as? String, "app.1")
        XCTAssertEqual(payload["token"] as? String, token)
        let devices = try XCTUnwrap(payload["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0]["uid"] as? String, "u")
        XCTAssertEqual(devices[0]["name"] as? String, "Desk")
        XCTAssertEqual(devices[0]["latency"] as? Int, 7_200)
        // It must survive the trip through a property list, as CoreAudio
        // marshals it.
        XCTAssertNoThrow(try PropertyListSerialization.data(
            fromPropertyList: payload, format: .binary, options: 0))
    }

    func testADeviceUIDIsTheRegisteredUIDAndAnOwnersSuffix() {
        let uid = AppIdentity.audioDeviceUIDPrefix + "AAAA"
        XCTAssertTrue(DisplayAudioDriverProtocol.isDeviceUID(uid + ".0123456789abcdef", of: uid))
        XCTAssertFalse(DisplayAudioDriverProtocol.isDeviceUID(uid, of: uid))
        XCTAssertFalse(DisplayAudioDriverProtocol.isDeviceUID(uid + ".0123", of: uid))
        XCTAssertFalse(DisplayAudioDriverProtocol.isDeviceUID(uid + ".0123456789ABCDEF", of: uid))
        XCTAssertFalse(
            DisplayAudioDriverProtocol.isDeviceUID(uid + "B.0123456789abcdef", of: uid),
            "another display whose UID only starts the same")
        XCTAssertTrue(DisplayAudioDriverProtocol.isDeviceUID(
            DisplayAudioDriverProtocol.deviceUID(for: uid, token: "t"), of: uid))
    }

    func testDeviceUIDIsTheBoardIdentityWhenKnown() {
        XCTAssertEqual(
            DisplayAudioDeviceSpec.uid(hardwareID: "AABBCCDDEEFF", serviceName: "espdisp-1"),
            AppIdentity.audioDeviceUIDPrefix + "AABBCCDDEEFF")
        XCTAssertEqual(
            DisplayAudioDeviceSpec.uid(hardwareID: nil, serviceName: "espdisp-1"),
            AppIdentity.audioDeviceUIDPrefix + "service.espdisp-1")
        XCTAssertEqual(
            DisplayAudioDeviceSpec.latencyFrames(
                tuning: AudioRuntimeTuning(downlinkTargetMilliseconds: 150)),
            7_200)
    }

    func testTheDeviceTapDeliversWhatTheDriverMixed() throws {
        let driver = FakeDisplayAudioDriver()
        driver.addDevice(uid: "u", id: 7)
        let tap = try DisplayAudioDeviceTap(bridge: driver, uid: "u")
        XCTAssertTrue(tap.format.isInterleaved)
        XCTAssertEqual(tap.format.channelCount, 2)
        let received = SampleLog()
        try tap.start { list in
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: list))
            XCTAssertEqual(buffers.count, 1)
            XCTAssertEqual(buffers[0].mNumberChannels, 2)
            let count = Int(buffers[0].mDataByteSize) / 4
            let samples = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            received.append(Array(UnsafeBufferPointer(start: samples, count: count)))
        }
        driver.queue([0.5, -0.25, 0.5, -0.25], for: 7)
        let deadline = Date().addingTimeInterval(2)
        while received.all.count < 4, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        tap.stop()
        XCTAssertEqual(received.all, [0.5, -0.25, 0.5, -0.25])
        driver.queue([1, 1], for: 7)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(received.all.count, 4, "nothing is delivered after stop")
    }

    /// A device another process owns is never read from: the session says
    /// so instead of claiming to play it.
    func testTheDeviceTapRefusesADeviceItDoesNotOwn() {
        let driver = FakeDisplayAudioDriver()
        driver.addDevice(uid: "u", id: 7)
        driver.claimedElsewhere = ["u"]
        XCTAssertThrowsError(try DisplayAudioDeviceTap(bridge: driver, uid: "u")) {
            XCTAssertTrue($0.localizedDescription.contains("another app"))
        }
    }

    /// Found by this app's UID, yet not this app's: the tap still refuses it.
    func testTheDeviceTapRefusesAListedDeviceItDoesNotOwn() {
        let driver = FakeDisplayAudioDriver()
        driver.addDevice(uid: "u", id: 7)
        driver.listedButNotOwned = ["u"]
        XCTAssertThrowsError(try DisplayAudioDeviceTap(bridge: driver, uid: "u")) {
            XCTAssertTrue($0.localizedDescription.contains("another app"))
        }
    }

    func testTheDeviceTapSaysWhenTheDeviceIsNotThereYet() {
        XCTAssertThrowsError(try DisplayAudioDeviceTap(bridge: FakeDisplayAudioDriver(), uid: "u")) {
            XCTAssertTrue($0.localizedDescription.contains("has not appeared"))
        }
    }

    // MARK: - The session's source

    /// The display's own output device needs no recording permission: a
    /// session switched to it streams what the driver mixed even where the
    /// tap was refused.
    func testASessionSwitchedToTheDisplayDeviceStreamsItsSound() throws {
        let (session, snapshots, panel) = try startSession()
        defer {
            session.stop()
            panel.close()
        }
        XCTAssertNotNil(snapshots.waitFor(timeoutSeconds: 4) {
            $0.state == .streaming && $0.message.contains("silence")
        }, "the refused tap streams silence first")

        let tap = ConstantSystemAudioTap(levels: [0.5, -0.25], sampleRate: 48_000, interleaved: true)
        session.setDownlinkSource(PanelDownlinkSource.displayDevice(
            name: "Desk Panel", route: .followMac,
            capture: SystemAudioCaptureSource(open: { tap })))
        let streaming = snapshots.waitFor(timeoutSeconds: 4) {
            $0.state == .streaming && $0.sourceName.contains("Desk Panel")
        }
        XCTAssertNotNil(streaming, "last: \(snapshots.last?.message ?? "none")")
        XCTAssertTrue(
            streaming?.message == "Plays what this Mac sends to the \"Desk Panel\" output while it "
                + "is chosen in Sound settings; quiet otherwise.",
            streaming?.message ?? "")
        let packets = panel.receiveDownlink(timeoutSeconds: 3) { packets in
            packets.contains { pcm16Samples($0.samples).contains { $0 != 0 } }
        }
        XCTAssertTrue(
            packets.contains { pcm16Samples($0.samples).contains { $0 != 0 } },
            "the display device's sound reaches the panel")
    }

    /// A display's own device does not depend on the default output, so a
    /// route change leaves its session be; the device being made again
    /// changes the source's key instead, and that restarts it once.
    func testARouteChangeLeavesADeviceSourceBe() throws {
        let (session, snapshots, panel) = try startSession()
        defer {
            session.stop()
            panel.close()
        }
        let tap = ConstantSystemAudioTap(levels: [0.2, 0.2], sampleRate: 48_000, interleaved: true)
        func source(_ id: String) -> PanelDownlinkSource {
            .displayDevice(
                name: "Desk Panel", route: .followMac,
                capture: SystemAudioCaptureSource(open: { tap }), identity: "u#" + id)
        }
        session.setDownlinkSource(source("7"))
        XCTAssertNotNil(snapshots.waitFor(timeoutSeconds: 4) {
            $0.state == .streaming && $0.sourceName.contains("Desk Panel")
        })
        let settled = snapshots.all.count
        session.devicesChanged()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(
            snapshots.all.dropFirst(settled).contains { $0.state == .recovering },
            "a route change does not reopen the display's device")
        session.setDownlinkSource(source("8"))
        XCTAssertNotNil(snapshots.waitFor(timeoutSeconds: 2) {
            $0.state == .recovering && $0.message == "The device speaker's source changed."
        }, "a device made again is reopened")
    }

    func testTheSameSourceTwiceDoesNotRestart() throws {
        let (session, snapshots, panel) = try startSession()
        defer {
            session.stop()
            panel.close()
        }
        XCTAssertNotNil(snapshots.waitFor(timeoutSeconds: 4) { $0.state == .streaming })
        session.setDownlinkSource(.systemTap())
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(snapshots.all.contains { $0.state == .recovering })
    }

    /// Back from the display device to the tap, as when the copy is chosen
    /// again or the driver goes away.
    func testSwitchingBackToTheTapRestartsIntoIt() throws {
        let tap = ConstantSystemAudioTap(levels: [0.1, 0.1], sampleRate: 48_000, interleaved: true)
        let authorized = SystemAudioAccess(status: { .authorized }, request: nil)
        let (session, snapshots, panel) = try startSession(
            access: authorized, source: SystemAudioCaptureSource(open: { tap }))
        defer {
            session.stop()
            panel.close()
        }
        XCTAssertNotNil(snapshots.waitFor(timeoutSeconds: 4) {
            $0.sourceName == PanelAudioSession.tappedSourceName
        })
        let device = ConstantSystemAudioTap(
            levels: [0.2, 0.2], sampleRate: 48_000, interleaved: true)
        session.setDownlinkSource(PanelDownlinkSource.displayDevice(
            name: "Desk Panel", route: .followMac,
            capture: SystemAudioCaptureSource(open: { device })))
        XCTAssertNotNil(snapshots.waitFor(timeoutSeconds: 4) {
            $0.state == .streaming && $0.sourceName.contains("Desk Panel")
        })
        let before = snapshots.all.count
        session.setDownlinkSource(PanelDownlinkSource.systemTap(
            access: authorized, capture: SystemAudioCaptureSource(open: { tap })))
        let deadline = Date().addingTimeInterval(4)
        var back = false
        while !back, Date() < deadline {
            back = snapshots.all.dropFirst(before).contains {
                $0.state == .streaming && $0.sourceName == PanelAudioSession.tappedSourceName
                    && $0.message == PanelDownlinkSource.tapStreamingMessage
            }
            if !back { Thread.sleep(forTimeInterval: 0.02) }
        }
        XCTAssertTrue(back, "last: \(snapshots.last?.message ?? "none")")
    }

    func testADeviceThatIsNotThereYetStreamsSilenceAndSaysWhy() throws {
        let (session, snapshots, panel) = try startSession()
        defer {
            session.stop()
            panel.close()
        }
        session.setDownlinkSource(PanelDownlinkSource.displayDevice(
            name: "Desk Panel", route: .followMac,
            capture: .displayDevice(uid: "missing", bridge: FakeDisplayAudioDriver())))
        let waiting = snapshots.waitFor(timeoutSeconds: 4) {
            $0.state == .streaming && $0.message.contains("has not appeared")
        }
        XCTAssertNotNil(waiting, "last: \(snapshots.last?.message ?? "none")")
        XCTAssertFalse(
            waiting?.message.contains("recorded") == true,
            "a missing device is not a recording problem: \(waiting?.message ?? "")")
    }

    private func startSession(
        access: SystemAudioAccess = SystemAudioAccess(status: { .denied }, request: nil),
        source: SystemAudioCaptureSource = SystemAudioCaptureSource(open: {
            throw POSIXError(.EPERM)
        })
    ) throws -> (PanelAudioSession, SnapshotLog, LoopbackPanel) {
        let panel = try LoopbackPanel()
        let address = PanelPeerAddress()
        address.publish("127.0.0.1")
        let snapshots = SnapshotLog()
        let session = PanelAudioSession(
            descriptor: AudioStreamDescriptor(
                port: panel.port, version: AudioProtocol.version, sampleRateHz: 16_000,
                playbackChannels: 2, captureChannels: 2),
            tuning: AudioRuntimeTuning(responseTimeoutMilliseconds: 30_000),
            peerAddress: address,
            radioBudget: PanelRadioBudget(),
            systemAudioAccess: access,
            systemAudioSource: source,
            onUpdate: { snapshots.append($0) })
        session.setEnabled(true)
        session.start()
        return (session, snapshots, panel)
    }
}

final class SampleLog: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = [Float]()
    func append(_ more: [Float]) { lock.withLock { samples += more } }
    var all: [Float] { lock.withLock { samples } }
}
