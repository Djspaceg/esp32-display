import AVFoundation
import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// A refusal to record this Mac's sound must not take the panel's own audio
/// down with it. The panel starts its speaker/microphone backend and learns
/// where to send its microphone only from downlink packets (firmware
/// audio_engine.cpp claimPeer), so without the Mac's sound the session still
/// has to stream: silence to the panel speaker, the reason in plain words.
final class AudioSystemAudioRefusalTests: XCTestCase {
    func testDeniedPermissionStillStreamsSilentDownlinkToThePanel() throws {
        let streaming = try assertSilentDownlink(access: SystemAudioAccess(
            status: { .denied },
            request: { _ in XCTFail("a denied status must not re-request") }))
        XCTAssertTrue(
            streaming?.message.contains("System Audio Recording Only") == true,
            "a refusal says where to turn it on: \(streaming?.message ?? "")")
        XCTAssertEqual(
            streaming?.sourceName,
            "Silence (no permission to record this Mac's sound)")
    }

    func testUnansweredPromptStreamsSilenceUntilItIsAnswered() throws {
        let streaming = try assertSilentDownlink(access: SystemAudioAccess(
            status: { .notDetermined },
            request: { _ in }))
        XCTAssertTrue(
            streaming?.message.contains("until the macOS prompt") == true,
            streaming?.message ?? "")
    }

    func testRefusedPromptStillStreamsSilentDownlinkToThePanel() throws {
        let streaming = try assertSilentDownlink(access: SystemAudioAccess(
            status: { .notDetermined },
            request: { completion in completion(false) }))
        XCTAssertNotNil(streaming)
        XCTAssertNotNil(
            snapshotsOfLastSession?.waitFor { $0.message.contains("macOS did not ask") },
            "a refusal with no prompt shown names the missing prompt: "
                + (snapshotsOfLastSession?.last?.message ?? ""))
    }

    /// A Mac where the tap cannot be created: the panel microphone still
    /// arrives instead of the session restarting every second forever.
    func testUnavailableTapFallsBackToSilenceInsteadOfLooping() throws {
        let noTap = SystemAudioCaptureSource(open: {
            throw NSError(
                domain: "test", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No tap for you."])
        })
        let (session, snapshots, panel) = try startSession(
            access: SystemAudioAccess(
                status: { .authorized },
                request: { _ in XCTFail("an authorized status must not re-request") }),
            source: noTap)
        defer {
            session.stop()
            panel.close()
        }
        guard let datagram = panel.receive(timeoutSeconds: 4) else {
            XCTFail("no audio datagram reached the panel; last state "
                + "\(String(describing: snapshots.last?.state)): "
                + "\(snapshots.last?.message ?? "no update")")
            return
        }
        guard case .pcm(let pcm) = try AudioProtocol.decode(datagram) else {
            XCTFail("the panel received a non-PCM datagram")
            return
        }
        XCTAssertEqual(pcm.kind, .pcmDownlink)
        XCTAssertTrue(pcm.samples.allSatisfy { $0 == 0 })
        let streaming = snapshots.waitFor { $0.state == .streaming }
        XCTAssertTrue(
            streaming?.message.contains("No tap for you.") == true,
            "the message carries the tap failure: \(streaming?.message ?? "")")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(
            snapshots.all.contains { $0.state == .recovering },
            "an unavailable tap is a steady state, not a 1 s restart loop")
    }

    /// Granting permission later restarts into the tap without a relaunch.
    /// The fake reports `.authorized` exactly once, so the restart lands back
    /// in silence and the test never opens a real tap.
    func testLaterGrantRestartsTheSession() throws {
        let grant = GrantOnce()
        let (session, snapshots, panel) = try startSession(access: SystemAudioAccess(
            status: { grant.status() },
            request: { _ in XCTFail("a denied status must not re-request") }))
        defer {
            session.stop()
            panel.close()
        }
        XCTAssertNotNil(panel.receive(timeoutSeconds: 4))
        grant.arm()
        XCTAssertNotNil(
            snapshots.waitFor(timeoutSeconds: 3) {
                $0.state == .recovering
                    && $0.message == "Permission to record this Mac's sound was granted."
            },
            "the 1 Hz permission check restarts once permission is granted")
    }

    /// A refused tap records silence rather than failing, so permission
    /// turned off while the Mac's sound streams has to be noticed and said.
    func testPermissionTurnedOffWhileStreamingIsNoticed() throws {
        try assertRevocationIsNoticed(revokedTo: .denied)
    }

    /// Removing the app from the list can read as never asked, not denied.
    func testAppRemovedFromThePermissionListIsNoticed() throws {
        try assertRevocationIsNoticed(revokedTo: .notDetermined)
    }

    private func assertRevocationIsNoticed(
        revokedTo revokedStatus: SystemAudioPermission
    ) throws {
        let revoked = Flag()
        let tap = ConstantSystemAudioTap(
            levels: [0, 0], sampleRate: 16_000, interleaved: false)
        let (session, snapshots, panel) = try startSession(
            access: SystemAudioAccess(
                status: { revoked.isSet ? revokedStatus : .authorized },
                // Like `.system`: a prompt that is raised and never answered.
                request: { _ in }),
            source: SystemAudioCaptureSource(open: { tap }))
        defer {
            session.stop()
            panel.close()
        }
        XCTAssertNotNil(snapshots.waitFor(timeoutSeconds: 4) {
            $0.sourceName == PanelAudioSession.tappedSourceName
        })
        revoked.set()
        XCTAssertNotNil(
            snapshots.waitFor(timeoutSeconds: 3) {
                $0.message == "Permission to record this Mac's sound was turned off."
            },
            "the 1 Hz check while streaming restarts into silence")
        XCTAssertNotNil(snapshots.waitFor(timeoutSeconds: 3) {
            $0.state == .streaming && $0.message.contains("silence")
        })
    }

    /// A tap that delivers nothing must not silence the downlink: the panel
    /// learns this Mac only from downlink packets. Silence fills in, at the
    /// pacer's rate, until the tap delivers again.
    func testAQuietTapStillKeepsTheDownlinkFlowing() throws {
        let (session, snapshots, panel) = try startSession(
            access: SystemAudioAccess(status: { .authorized }, request: nil),
            source: SystemAudioCaptureSource(open: { QuietSystemAudioTap() }))
        defer {
            session.stop()
            panel.close()
        }
        XCTAssertNotNil(snapshots.waitFor(timeoutSeconds: 4) {
            $0.sourceName == PanelAudioSession.tappedSourceName
        })
        let start = Date()
        let packets = panel.receiveDownlink(timeoutSeconds: 3) { $0.count >= 50 }
        let seconds = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(packets.count, 50, "no steady downlink")
        XCTAssertTrue(packets.allSatisfy { $0.samples.allSatisfy { $0 == 0 } })
        XCTAssertLessThan(seconds, 1.6, "50 packets of 20 ms took \(seconds) s")
    }

    /// The writer reads the layout from the buffer list itself: one
    /// interleaved buffer or one per channel both land in the ring the same,
    /// and any other shape is skipped and counted, not misread.
    func testTheRingWriterAcceptsEitherLayoutAndCountsOthers() throws {
        let ring = try XCTUnwrap(AudioCaptureRingLifetime(
            slotCount: 8, maximumFrames: 64, channels: 2))
        ring.setAccepting(true)
        let writer = SystemAudioRingWriter(
            lease: ring.makeCallbackLease(), channels: 2, slotFrames: 64)
        func list(interleaved: Bool, channels: UInt32) -> AVAudioPCMBuffer {
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                channels: channels, interleaved: interleaved)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
            buffer.frameLength = 4
            let audio = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for (index, part) in audio.enumerated() {
                let samples = part.mData!.assumingMemoryBound(to: Float.self)
                for sample in 0..<Int(part.mDataByteSize) / 4 {
                    samples[sample] = interleaved
                        ? (sample % 2 == 0 ? 0.5 : -0.25)
                        : (index == 0 ? 0.5 : -0.25)
                }
            }
            return buffer
        }
        let interleaved = list(interleaved: true, channels: 2)
        let planar = list(interleaved: false, channels: 2)
        let mono = list(interleaved: false, channels: 1)
        writer.write(interleaved.audioBufferList)
        writer.write(planar.audioBufferList)
        writer.write(mono.audioBufferList)
        XCTAssertEqual(writer.skipped, 1, "a mono list is not a stereo tap's")

        var left = [Float](repeating: 9, count: 64)
        var right = [Float](repeating: 9, count: 64)
        var frames: UInt32 = 0
        for _ in 0..<2 {
            XCTAssertTrue(ring.read(
                channelZero: &left, channelOne: &right,
                frameCapacity: 64, frameCount: &frames))
            XCTAssertEqual(frames, 4)
            XCTAssertEqual(Array(left.prefix(4)), [0.5, 0.5, 0.5, 0.5])
            XCTAssertEqual(Array(right.prefix(4)), [-0.25, -0.25, -0.25, -0.25])
        }
        XCTAssertFalse(ring.read(
            channelZero: &left, channelOne: &right,
            frameCapacity: 64, frameCount: &frames))
    }

    /// Permission granted in System Settings while the prompt's own answer is
    /// still outstanding goes straight to the tap, once, instead of looping.
    func testGrantWhileThePromptIsOutstandingOpensTheTapOnce() throws {
        let granted = Flag()
        let tap = ConstantSystemAudioTap(
            levels: [0, 0], sampleRate: 16_000, interleaved: false)
        let (session, snapshots, panel) = try startSession(
            access: SystemAudioAccess(
                status: { granted.isSet ? .authorized : .notDetermined },
                request: { _ in }),
            source: SystemAudioCaptureSource(open: { tap }))
        defer {
            session.stop()
            panel.close()
        }
        XCTAssertNotNil(snapshots.waitFor(timeoutSeconds: 4) {
            $0.message.contains("until the macOS prompt")
        })
        granted.set()
        XCTAssertNotNil(snapshots.waitFor(timeoutSeconds: 4) {
            $0.sourceName == PanelAudioSession.tappedSourceName
        })
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertEqual(tap.started, 1, "one restart into the tap, not a loop")
    }

    /// Nothing captures an input any more, so a microphone coming or going
    /// must not count as a route change that restarts every display's audio.
    func testInputOnlyChangesAreNotAnOutputRouteChange() {
        let speakers = AudioDeviceOption(
            uid: "speakers", name: "Speakers", supportsInput: false, supportsOutput: true)
        let mic = AudioDeviceOption(
            uid: "mic", name: "Mic", supportsInput: true, supportsOutput: false)
        let before = CoreAudioRouteSnapshot(
            options: [speakers], defaultInputUID: nil, defaultOutputUID: "speakers")
        let withMic = CoreAudioRouteSnapshot(
            options: [mic, speakers], defaultInputUID: "mic", defaultOutputUID: "speakers")
        XCTAssertEqual(before.outputRoute, withMic.outputRoute)
        let newOutput = CoreAudioRouteSnapshot(
            options: [speakers], defaultInputUID: nil, defaultOutputUID: nil)
        XCTAssertNotEqual(before.outputRoute, newOutput.outputRoute)
    }

    /// Our own aggregate devices come and go with every restart. If the
    /// device list showed them, each restart would look like a route change
    /// and restart again. Only the predicate is checked here: no test creates
    /// a real aggregate device.
    func testOwnTapDevicesAreHiddenFromTheDeviceList() {
        XCTAssertTrue(SystemAudioTapIdentity.isOwnAggregate(
            uid: SystemAudioTapIdentity.aggregateUIDPrefix + UUID().uuidString))
        XCTAssertFalse(SystemAudioTapIdentity.isOwnAggregate(uid: "BuiltInSpeakerDevice"))
    }

    /// The silence feed never sets the rate itself: the pacer's
    /// drift-corrected deadlines do, so a panel draining fast (multiplier
    /// below 1) gets more frames and one draining slow gets fewer.
    func testSilenceRateFollowsThePacersDriftCorrection() {
        let sampleRate: UInt32 = 16_000
        let packetFrames = 320
        for multiplier in [1.0004, 1.0, 0.9996] {
            var pacer = AudioPacketPacer()
            var pending = 0
            var sentFrames = 0
            var nextSend: UInt64?
            let tickNanos: UInt64 = 5_000_000
            let seconds: UInt64 = 600
            var now: UInt64 = 0
            while now < seconds * 1_000_000_000 {
                pending += AudioSilenceFeed.packetsToQueue(
                    pending: pending, ceilingFrames: 3_520, packetFrames: packetFrames)
                while pending > 0 {
                    if nextSend == nil {
                        nextSend = pacer.deadlineNanos(
                            nowNanos: now, frameCount: packetFrames,
                            sampleRateHz: sampleRate, rateMultiplier: multiplier)
                    }
                    guard let deadline = nextSend, deadline <= now else { break }
                    pending -= 1
                    sentFrames += packetFrames
                    nextSend = nil
                }
                now += tickNanos
            }
            let expected = Double(sampleRate) * Double(seconds) / multiplier
            XCTAssertEqual(
                Double(sentFrames), expected, accuracy: Double(packetFrames * 2),
                "multiplier \(multiplier) must deliver rate / multiplier")
        }
    }

    /// The top-up never queues past the downlink ceiling, where each packet
    /// would be dropped on arrival.
    func testSilenceTopUpStaysUnderTheDownlinkCeiling() {
        XCTAssertEqual(AudioSilenceFeed.packetsToQueue(
            pending: 0, ceilingFrames: 3_520, packetFrames: 320), 2)
        XCTAssertEqual(AudioSilenceFeed.packetsToQueue(
            pending: 1, ceilingFrames: 3_520, packetFrames: 320), 1)
        XCTAssertEqual(AudioSilenceFeed.packetsToQueue(
            pending: 0, ceilingFrames: 2_400, packetFrames: 1_600), 1,
            "100 ms packets under a 150 ms ceiling queue one, not two")
        XCTAssertEqual(AudioSilenceFeed.packetsToQueue(
            pending: 1, ceilingFrames: 2_400, packetFrames: 1_600), 0)
    }

    private var snapshotsOfLastSession: SnapshotLog?

    @discardableResult
    private func assertSilentDownlink(
        access: SystemAudioAccess
    ) throws -> PanelAudioSnapshot? {
        let (session, snapshots, panel) = try startSession(access: access)
        defer {
            session.stop()
            panel.close()
        }
        let expected = descriptor()

        guard let datagram = panel.receive(timeoutSeconds: 4) else {
            XCTFail("no audio datagram reached the panel; last state "
                + "\(String(describing: snapshots.last?.state)): "
                + "\(snapshots.last?.message ?? "no update")")
            return nil
        }
        guard case .pcm(let pcm) = try AudioProtocol.decode(datagram) else {
            XCTFail("the panel received a non-PCM datagram")
            return nil
        }
        XCTAssertEqual(pcm.kind, .pcmDownlink)
        XCTAssertEqual(pcm.channels, expected.playbackChannels)
        XCTAssertGreaterThan(pcm.frameCount, 0)
        XCTAssertTrue(
            pcm.samples.allSatisfy { $0 == 0 },
            "without the Mac's sound the panel speaker gets silence")

        let streaming = snapshots.waitFor { $0.state == .streaming }
        XCTAssertNotNil(streaming, "the session reports streaming, not failed")
        XCTAssertTrue(
            streaming?.message.contains("silence") == true,
            "the message says the display gets silence: \(streaming?.message ?? "")")
        XCTAssertFalse(
            snapshots.all.contains { $0.state == .failed },
            "a refusal is not a failed session")
        return streaming
    }

    private func startSession(
        access: SystemAudioAccess,
        source: SystemAudioCaptureSource = SystemAudioCaptureSource(open: {
            XCTFail("a refused tap must never be opened")
            throw POSIXError(.EPERM)
        })
    ) throws -> (PanelAudioSession, SnapshotLog, LoopbackPanel) {
        let panel = try LoopbackPanel()
        let address = PanelPeerAddress()
        address.publish("127.0.0.1")
        let snapshots = SnapshotLog()
        snapshotsOfLastSession = snapshots
        // The loopback panel never replies. A long liveness timeout keeps its
        // restart from consuming GrantOnce's single `.authorized` and opening a
        // real tap on a slow runner.
        let session = PanelAudioSession(
            descriptor: descriptor(port: panel.port),
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

    private func descriptor(port: UInt16 = 0) -> AudioStreamDescriptor {
        AudioStreamDescriptor(
            port: port,
            version: AudioProtocol.version,
            sampleRateHz: 16_000,
            playbackChannels: 2,
            captureChannels: 2)
    }
}

/// `.denied` until armed, then `.authorized` exactly once.
private final class GrantOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false

    func arm() { lock.withLock { armed = true } }

    func status() -> SystemAudioPermission {
        lock.withLock {
            guard armed else { return .denied }
            armed = false
            return .authorized
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
