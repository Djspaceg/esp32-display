import AVFoundation
import Darwin
import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// A refused microphone must not take the panel's own audio down with it. The
/// panel starts its speaker/microphone backend and learns where to send its
/// microphone only from downlink packets (firmware audio_engine.cpp claimPeer),
/// so with no Mac microphone the session still has to stream: silence to the
/// panel speaker, the panel microphone back to the Mac speakers.
final class AudioMicrophoneRefusalTests: XCTestCase {
    func testDeniedMicrophoneStillStreamsSilentDownlinkToThePanel() throws {
        try assertSilentDownlink(access: MicrophoneAccess(
            status: { .denied },
            request: { _ in XCTFail("a denied status must not re-request") }))
    }

    func testRefusedPromptStillStreamsSilentDownlinkToThePanel() throws {
        let streaming = try assertSilentDownlink(access: MicrophoneAccess(
            status: { .notDetermined },
            request: { completion in completion(false) }))
        XCTAssertTrue(
            streaming?.message.contains("did not let ESPDisplaySender ask") == true,
            "a refusal with no prompt names the missing prompt, not System "
                + "Settings: \(streaming?.message ?? "")")
    }

    /// Access granted but no usable input (no microphone, or one this session
    /// cannot convert): the panel microphone still plays here instead of the
    /// session restarting every second forever.
    func testUnusableMicrophoneFallsBackToSilenceInsteadOfLooping() throws {
        let noInput = MicrophoneCaptureSource(open: { _ in
            throw NSError(
                domain: "test", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No input device."])
        })
        let (session, snapshots, panel) = try startSession(
            access: MicrophoneAccess(
                status: { .authorized },
                request: { _ in XCTFail("an authorized status must not re-request") }),
            captureSource: noInput)
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
            streaming?.message.contains("No input device.") == true,
            "the message carries the capture failure: \(streaming?.message ?? "")")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(
            snapshots.all.contains { $0.state == .recovering },
            "an unusable microphone is a steady state, not a 1 s restart loop")
    }

    /// Granting access later restarts into capture without a relaunch. The
    /// fake reports `.authorized` exactly once so the restart lands back in
    /// silence mode and the test never opens a real microphone.
    func testLaterGrantRestartsTheSession() throws {
        let grant = GrantOnce()
        let (session, snapshots, panel) = try startSession(access: MicrophoneAccess(
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
                    && $0.message == "Microphone access was granted."
            },
            "the 1 Hz permission check restarts once access is granted")
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

    @discardableResult
    private func assertSilentDownlink(
        access: MicrophoneAccess
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
            "with no microphone the panel speaker gets silence")

        let streaming = snapshots.waitFor { $0.state == .streaming }
        XCTAssertNotNil(streaming, "the session reports streaming, not failed")
        XCTAssertTrue(
            streaming?.message.contains("microphone") == true,
            "the message names the refused microphone: \(streaming?.message ?? "")")
        XCTAssertFalse(
            snapshots.all.contains { $0.state == .failed },
            "a refused microphone is not a failed session")
        return streaming
    }

    private func startSession(
        access: MicrophoneAccess,
        captureSource: MicrophoneCaptureSource = MicrophoneCaptureSource(open: { _ in
            XCTFail("a refused microphone must never be opened")
            throw POSIXError(.EPERM)
        })
    ) throws -> (PanelAudioSession, SnapshotLog, LoopbackPanel) {
        let panel = try LoopbackPanel()
        let address = PanelPeerAddress()
        address.publish("127.0.0.1")
        let snapshots = SnapshotLog()
        // The loopback panel never replies. A long liveness timeout keeps its
        // restart from consuming GrantOnce's single `.authorized` and opening a
        // real microphone on a slow runner.
        let session = PanelAudioSession(
            descriptor: descriptor(port: panel.port),
            tuning: AudioRuntimeTuning(responseTimeoutMilliseconds: 30_000),
            peerAddress: address,
            radioBudget: PanelRadioBudget(),
            microphoneAccess: access,
            captureSource: captureSource,
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

    func status() -> AVAuthorizationStatus {
        lock.withLock {
            guard armed else { return .denied }
            armed = false
            return .authorized
        }
    }
}

private final class SnapshotLog: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots = [PanelAudioSnapshot]()

    func append(_ snapshot: PanelAudioSnapshot) {
        lock.withLock { snapshots.append(snapshot) }
    }

    var all: [PanelAudioSnapshot] { lock.withLock { snapshots } }
    var last: PanelAudioSnapshot? { all.last }

    func waitFor(
        timeoutSeconds: Double = 2,
        _ predicate: (PanelAudioSnapshot) -> Bool
    ) -> PanelAudioSnapshot? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            if let match = all.last(where: predicate) { return match }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        return nil
    }
}

/// A UDP socket on 127.0.0.1 standing in for the panel's audio port.
private final class LoopbackPanel {
    private let fd: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        self.fd = fd
        port = UInt16(bigEndian: address.sin_port)
    }

    func receive(timeoutSeconds: Int) -> Data? {
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(
            fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 2_048)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        return Data(buffer.prefix(count))
    }

    func close() { Darwin.close(fd) }
}
