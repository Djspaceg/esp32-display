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

    func availability() -> DisplayAudioDriverAvailability { lock.withLock { state } }

    func register(_ devices: [DisplayAudioDeviceSpec]) -> Bool {
        lock.withLock {
            registrations.append(devices)
            guard state == .ready else { return false }
            if devicesAppearOnRegister {
                ids = [:]
                for (index, device) in devices.enumerated() {
                    ids[device.uid] = AudioObjectID(100 + index)
                }
            }
            return true
        }
    }

    func addDevice(uid: String, id: AudioObjectID) { lock.withLock { ids[uid] = id } }

    func deviceID(uid: String) -> AudioObjectID? { lock.withLock { ids[uid] } }

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
        XCTAssertEqual(define("ESPDISP_AUDIO_SAMPLE_RATE"), "\(Int(P.sampleRate))")
        XCTAssertEqual(define("ESPDISP_AUDIO_MAX_READ_FRAMES"), "\(P.maxReadFrames)")
        XCTAssertEqual(define("ESPDISP_AUDIO_MAX_DEVICES"), "\(P.maxDevices)")
        XCTAssertEqual(
            define("ESPDISP_AUDIO_CLIENT_TIMEOUT_SECONDS"), "\(Int(P.clientTimeoutSeconds))")
        for (name, key) in [
            ("VERSION", P.Key.version), ("CLIENT", P.Key.client),
            ("DEVICES", P.Key.devices), ("UID", P.Key.uid), ("NAME", P.Key.name),
            ("LATENCY", P.Key.latency),
        ] {
            XCTAssertEqual(define("ESPDISP_AUDIO_KEY_\(name)"), "\"\(key)\"")
        }
    }

    func testRegistrationPayloadIsWhatTheDriverParses() throws {
        let payload = DisplayAudioDriverRegistration.payload(
            client: "app.1",
            devices: [DisplayAudioDeviceSpec(uid: "u", name: "Desk", latencyFrames: 7_200)])
        XCTAssertEqual(payload["version"] as? Int, 1)
        XCTAssertEqual(payload["client"] as? String, "app.1")
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

    func testDeviceUIDIsTheBoardIdentityWhenKnown() {
        XCTAssertEqual(
            DisplayAudioDeviceSpec.uid(hardwareID: "AABBCCDDEEFF", serviceName: "espdisp-1"),
            "com.espdisplay.display.AABBCCDDEEFF")
        XCTAssertEqual(
            DisplayAudioDeviceSpec.uid(hardwareID: nil, serviceName: "espdisp-1"),
            "com.espdisplay.display.service.espdisp-1")
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
            name: "Desk Panel", route: .displaysOnly,
            capture: SystemAudioCaptureSource(open: { tap })))
        let streaming = snapshots.waitFor(timeoutSeconds: 4) {
            $0.state == .streaming && $0.sourceName.contains("Desk Panel")
        }
        XCTAssertNotNil(streaming, "last: \(snapshots.last?.message ?? "none")")
        XCTAssertTrue(
            streaming?.message.contains("only output") == true,
            streaming?.message ?? "")
        let packets = panel.receiveDownlink(timeoutSeconds: 3) { packets in
            packets.contains { pcm16Samples($0.samples).contains { $0 != 0 } }
        }
        XCTAssertTrue(
            packets.contains { pcm16Samples($0.samples).contains { $0 != 0 } },
            "the display device's sound reaches the panel")
    }

    func testTheSameSourceTwiceDoesNotRestart() throws {
        let (session, snapshots, panel) = try startSession()
        defer {
            session.stop()
            panel.close()
        }
        XCTAssertNotNil(snapshots.waitFor(timeoutSeconds: 4) { $0.state == .streaming })
        session.setDownlinkSource(.systemTap(note: nil))
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(snapshots.all.contains { $0.state == .recovering })
    }

    func testAFallbackNoteRidesOnTheTapMessage() throws {
        let tap = ConstantSystemAudioTap(levels: [0.1, 0.1], sampleRate: 48_000, interleaved: true)
        let (session, snapshots, panel) = try startSession(
            access: SystemAudioAccess(status: { .authorized }, request: nil),
            source: SystemAudioCaptureSource(open: { tap }))
        defer {
            session.stop()
            panel.close()
        }
        XCTAssertNotNil(snapshots.waitFor(timeoutSeconds: 4) {
            $0.sourceName == PanelAudioSession.tappedSourceName
        })
        session.setDownlinkSource(PanelDownlinkSource.systemTap(
            note: "The display audio driver is not installed.",
            access: SystemAudioAccess(status: { .authorized }, request: nil),
            capture: SystemAudioCaptureSource(open: { tap })))
        XCTAssertNotNil(snapshots.waitFor(timeoutSeconds: 4) {
            $0.state == .streaming && $0.message.hasSuffix("The display audio driver is not installed.")
        }, "last: \(snapshots.last?.message ?? "none")")
    }

    func testADeviceThatIsNotThereYetStreamsSilenceAndSaysWhy() throws {
        let (session, snapshots, panel) = try startSession()
        defer {
            session.stop()
            panel.close()
        }
        session.setDownlinkSource(PanelDownlinkSource.displayDevice(
            name: "Desk Panel", route: .mirror,
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
