import AVFoundation
import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// The display speaker plays the Mac's sound, not the Mac microphone; it
/// plays it at the display's own volume; and the display's microphone is
/// received but not played on the Mac's speakers. Every test here stands in
/// a fake tap and a loopback panel, so nothing real is recorded or played.
final class PanelAudioRoutingTests: XCTestCase {
    func testDownlinkCarriesTheMacsSoundNotTheMicrophone() throws {
        let tap = ConstantSystemAudioTap(
            levels: [0.5, -0.25], sampleRate: 16_000, interleaved: false)
        let (session, snapshots, panel) = try startSession(tap: tap)
        defer {
            session.stop()
            panel.close()
        }
        let levels = steadyLevels(panel)
        let last = snapshots.last
        let context = "got \(String(describing: levels)), state "
            + "\(String(describing: last?.state)): \(last?.message ?? "no update")"
        XCTAssertEqual(
            levels?.left ?? 0, 16_384, accuracy: 64,
            "the display speaker carries the Mac's left channel at full volume; "
                + context)
        XCTAssertEqual(
            levels?.right ?? 0, -8_192, accuracy: 64,
            "and its right channel, not a copy of the left; " + context)
        XCTAssertEqual(tap.started, 1, "the Mac's sound is tapped exactly once")
        XCTAssertEqual(
            snapshots.waitFor { $0.state == .streaming }?.sourceName,
            "This Mac's sound")
    }

    /// The tap may deliver interleaved stereo; it reaches the wire the same.
    func testInterleavedTapReachesTheDownlink() throws {
        let tap = ConstantSystemAudioTap(
            levels: [0.5, -0.25], sampleRate: 48_000, interleaved: true)
        let (session, _, panel) = try startSession(tap: tap)
        defer {
            session.stop()
            panel.close()
        }
        let levels = steadyLevels(panel)
        XCTAssertEqual(levels?.left ?? 0, 16_384, accuracy: 256)
        XCTAssertEqual(levels?.right ?? 0, -8_192, accuracy: 256)
    }

    /// A tap whose IO cycles are far apart (a large IO buffer) is not
    /// mistaken for a quiet one: no silence is spliced between its cycles.
    func testASlowTapGetsNoSilenceSplicedIn() throws {
        let tap = ConstantSystemAudioTap(
            levels: [0.5, -0.25], sampleRate: 16_000, interleaved: false,
            cycleSeconds: 0.06)
        let (session, _, panel) = try startSession(tap: tap)
        defer {
            session.stop()
            panel.close()
        }
        // Past the startup ramp, where nothing has been tapped yet.
        _ = panel.receiveDownlink(timeoutSeconds: 0.5) { _ in false }
        let packets = panel.receiveDownlink(timeoutSeconds: 4) { $0.count >= 60 }
        XCTAssertGreaterThanOrEqual(packets.count, 60)
        // Spliced silence can land part-way into a packet, so count samples.
        let silent = packets.flatMap { pcm16Samples($0.samples) }.filter { $0 == 0 }.count
        XCTAssertEqual(silent, 0, "silence spliced into a slow tap's sound")
    }

    func testSpeakerVolumeScalesTheSamplesSent() throws {
        let tap = ConstantSystemAudioTap(
            levels: [0.5, -0.25], sampleRate: 16_000, interleaved: false)
        let (session, _, panel) = try startSession(tap: tap, speakerVolume: 0.5)
        defer {
            session.stop()
            panel.close()
        }
        // 0.5 * 0.5^2 of full scale on the left, -0.25 * 0.5^2 on the right.
        let half = steadyLevels(panel)
        XCTAssertEqual(
            half?.left ?? 0, 4_096, accuracy: 64,
            "50% volume sends a quarter of the amplitude")
        XCTAssertEqual(half?.right ?? 0, -2_048, accuracy: 64)

        session.setSpeakerVolume(1)
        XCTAssertEqual(
            steadyLevels(panel, after: 0.3)?.left ?? 0, 16_384, accuracy: 64,
            "a volume change applies to the running stream")

        session.setSpeakerVolume(0)
        let muted = steadyLevels(panel, after: 0.3)
        XCTAssertEqual(
            muted?.left, 0,
            "0% still sends packets, as silence, so the panel keeps its peer")
        XCTAssertEqual(muted?.right, 0)
    }

    func testEncodingAppliesTheGain() {
        XCTAssertEqual(
            pcm16Samples(AudioDownlinkPCM.encode([0.5, -0.5, 1, -1], gain: 0.25)),
            [4_096, -4_096, 8_192, -8_192])
        XCTAssertEqual(
            pcm16Samples(AudioDownlinkPCM.encode([0.5, 2], gain: 1)),
            [16_384, 32_767], "full gain is unchanged, and still clamps")
        XCTAssertEqual(PanelSpeakerVolume.gain(1), 1)
        XCTAssertEqual(PanelSpeakerVolume.gain(0), 0)
        XCTAssertEqual(PanelSpeakerVolume.gain(0.5), 0.25)
        XCTAssertEqual(PanelSpeakerVolume.clamped(1.7), 1)
        XCTAssertEqual(PanelSpeakerVolume.clamped(-1), 0)
        XCTAssertEqual(PanelSpeakerVolume.clamped(.nan), PanelSpeakerVolume.default)
    }

    /// The panel's microphone still arrives, is decoded and goes through the
    /// jitter buffer, but it is handed to the sink, not the Mac speakers.
    func testUplinkIsReceivedButNotPlayedOnTheMac() throws {
        let tap = ConstantSystemAudioTap(
            levels: [0, 0], sampleRate: 16_000, interleaved: false)
        let recording = RecordingUplinkSink()
        let (session, snapshots, panel) = try startSession(
            tap: tap, uplinkSink: recording.sink)
        defer {
            session.stop()
            panel.close()
        }
        XCTAssertNotNil(panel.receive(timeoutSeconds: 4), "no downlink to answer")
        // A level far below hearing, in case a build under test does play it.
        let frames = 320
        let samples = Data(
            [Int16](repeating: 8, count: frames * 2).flatMap {
                [UInt8(UInt16(bitPattern: $0) & 0xFF), UInt8(UInt16(bitPattern: $0) >> 8)]
            })
        let deadline = Date().addingTimeInterval(4)
        var sequence: UInt16 = 1
        while Date() < deadline, recording.received.count < frames * 2 * 4 {
            let pcm = AudioProtocol.PCM(
                kind: .pcmUplink, sequence: sequence, streamGeneration: 7,
                sampleRateHz: 16_000, sampleCounter: UInt32(sequence) * UInt32(frames),
                timestampMicros: UInt32(sequence) * 20_000,
                frameCount: UInt16(frames), channels: 2, samples: samples)
            panel.send(try AudioProtocol.encode(pcm))
            sequence &+= 1
            Thread.sleep(forTimeInterval: 0.02)
        }
        let received = recording.received
        XCTAssertGreaterThanOrEqual(
            received.count, frames * 2 * 4, "the display microphone reached the sink")
        XCTAssertEqual(
            received.last ?? 0, 8.0 / 32_768, accuracy: 1e-6,
            "the sink gets the panel's samples unchanged")
        let destination = snapshots.waitFor { $0.state == .streaming }?
            .uplinkDestination ?? ""
        XCTAssertNotEqual(destination, "System Default")
        XCTAssertTrue(
            destination.contains("not played on this Mac"),
            "the display microphone is not routed to the Mac's speakers: "
                + destination)
    }

    /// The median level of each channel (left, right) over the second half of
    /// the packets received in `seconds`, skipping `after` seconds first. Nil
    /// if nothing arrived.
    private func steadyLevels(
        _ panel: LoopbackPanel, after: Double = 0, seconds: Double = 0.6
    ) -> (left: Double, right: Double)? {
        if after > 0 {
            _ = panel.receiveDownlink(timeoutSeconds: after) { _ in false }
        }
        let packets = panel.receiveDownlink(timeoutSeconds: 4) {
            $0.count >= Int(seconds / 0.02)
        }
        guard !packets.isEmpty else { return nil }
        let tail = packets.suffix(max(1, packets.count / 2))
        let samples = tail.flatMap { pcm16Samples($0.samples) }
        func median(_ channel: Int) -> Double {
            let values = samples.enumerated()
                .filter { $0.offset % 2 == channel }
                .map { Double($0.element) }
                .sorted()
            return values[values.count / 2]
        }
        return (median(0), median(1))
    }

    private func startSession(
        tap: ConstantSystemAudioTap,
        speakerVolume: Double = 1,
        uplinkSink: PanelUplinkSink = .discard
    ) throws -> (PanelAudioSession, SnapshotLog, LoopbackPanel) {
        let panel = try LoopbackPanel()
        let address = PanelPeerAddress()
        address.publish("127.0.0.1")
        let snapshots = SnapshotLog()
        let session = PanelAudioSession(
            descriptor: AudioStreamDescriptor(
                port: panel.port,
                version: AudioProtocol.version,
                sampleRateHz: 16_000,
                playbackChannels: 2,
                captureChannels: 2),
            tuning: AudioRuntimeTuning(responseTimeoutMilliseconds: 30_000),
            peerAddress: address,
            radioBudget: PanelRadioBudget(),
            speakerVolume: speakerVolume,
            systemAudioAccess: SystemAudioAccess(
                status: { .authorized },
                request: { _ in XCTFail("an authorized status must not re-request") }),
            systemAudioSource: SystemAudioCaptureSource(open: { tap }),
            uplinkSink: uplinkSink,
            onUpdate: { snapshots.append($0) })
        session.setEnabled(true)
        session.start()
        return (session, snapshots, panel)
    }
}

/// The app asks for System Audio Recording Only, the one permission the tap
/// needs, and no longer for the microphone it stopped using.
final class AudioPrivacyDeclarationTests: XCTestCase {
    private let macDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testInfoPlistDeclaresSystemAudioAndNotTheMicrophone() throws {
        let data = try Data(contentsOf: macDirectory.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any])
        XCTAssertFalse(
            (plist["NSAudioCaptureUsageDescription"] as? String ?? "").isEmpty,
            "without it macOS cannot prompt for System Audio Recording")
        XCTAssertNil(plist["NSMicrophoneUsageDescription"])
    }

    func testTheAppIsNotSignedForAudioInput() throws {
        let project = try String(
            contentsOf: macDirectory.appendingPathComponent(
                "ESPDisplaySender/ESPDisplaySender.xcodeproj/project.pbxproj"),
            encoding: .utf8)
        XCTAssertFalse(project.contains("ENABLE_RESOURCE_ACCESS_AUDIO_INPUT"))
    }
}

/// The volume is the user's choice for one display, so it is saved with that
/// display's record and survives a restart.
final class SpeakerVolumePersistenceTests: XCTestCase {
    func testAChosenVolumeRoundTrips() throws {
        var panel = PanelSnapshot(serviceName: "panel", displayName: "Panel")
        panel.speakerVolume = 0.4
        let data = try JSONEncoder.espDisplay.encode([PersistedPanel(snapshot: panel)])
        let loaded = try JSONDecoder.espDisplay.decode([PersistedPanel].self, from: data)
        XCTAssertEqual(try XCTUnwrap(loaded.first?.snapshot.speakerVolume), 0.4, accuracy: 1e-9)
    }

    /// A display nobody has set starts below full, so its first sound is not
    /// a blast, and a file from before the setting existed loads that way.
    func testTheDefaultIsNotWrittenOutAndOldFilesLoadAtTheDefault() throws {
        XCTAssertLessThan(PanelSpeakerVolume.default, 1)
        XCTAssertGreaterThan(PanelSpeakerVolume.default, 0)
        let stored = PersistedPanel(
            snapshot: PanelSnapshot(serviceName: "panel", displayName: "Panel"))
        XCTAssertNil(stored.speakerVolume)
        let json = Data(#"[{"serviceName":"panel","displayName":"Panel"}]"#.utf8)
        let loaded = try JSONDecoder.espDisplay.decode([PersistedPanel].self, from: json)
        XCTAssertEqual(loaded.first?.snapshot.speakerVolume, PanelSpeakerVolume.default)
    }

    /// A display's audio session can be installed long after its record was
    /// bound, when the board's audio advertisement arrives. It must start at
    /// the saved volume, not the default.
    func testAnAudioSessionInstalledLaterStartsAtTheSavedVolume() throws {
        final class Box: @unchecked Sendable { var session: PanelAudioSession? }
        let box = Box()
        let device = DeviceSession(
            name: "desk",
            sender: FrameSender(host: "127.0.0.1", port: 5568),
            audioSessionFactory: { descriptor in
                let session = PanelAudioSession(
                    descriptor: descriptor,
                    peerAddress: PanelPeerAddress(),
                    radioBudget: PanelRadioBudget(),
                    systemAudioAccess: SystemAudioAccess(
                        status: { .denied }, request: nil),
                    systemAudioSource: SystemAudioCaptureSource(open: {
                        throw POSIXError(.EPERM)
                    }),
                    onUpdate: { _ in })
                box.session = session
                return session
            },
            source: .auto(defaultDisplay: ""), picker: nil, fps: 30)
        device.setSpeakerVolume(0.3)
        device.reconcileAudio(.available(AudioStreamDescriptor(
            port: 5569, version: AudioProtocol.version, sampleRateHz: 16_000,
            playbackChannels: 2, captureChannels: 2)))
        let installed = try XCTUnwrap(box.session)
        XCTAssertEqual(installed.speakerGainForTesting, PanelSpeakerVolume.gain(0.3))
        installed.stop()
        device.stop()
    }

    @MainActor
    func testTheManagerClampsAndRecordsTheVolume() {
        let manager = PanelManager(
            previewPanels: [PanelSnapshot(serviceName: "panel", displayName: "Panel")],
            savedNetworkNames: [], usbSerialPorts: [])
        manager.setSpeakerVolume(0.3, for: "panel")
        XCTAssertEqual(manager.panels.first?.speakerVolume, 0.3)
        manager.setSpeakerVolume(4, for: "panel", persist: false)
        XCTAssertEqual(manager.panels.first?.speakerVolume, 1)
    }
}
