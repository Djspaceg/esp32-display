import XCTest

@testable import SenderProtocol

final class AudioProtocolTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "hex", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let bytes = try text.split(whereSeparator: { $0.isWhitespace }).map {
            try XCTUnwrap(UInt8(String($0), radix: 16))
        }
        return Data(bytes)
    }

    func testPCMEncoderAndDecoderMatchFirmwareVector() throws {
        let expected = try fixture("eaud-pcm-v1")
        let pcm = AudioProtocol.PCM(
            kind: .pcmDownlink,
            sequence: 7,
            streamGeneration: 3,
            sampleRateHz: 16_000,
            sampleCounter: 320,
            timestampMicros: 123_456,
            frameCount: 4,
            channels: 2,
            samples: Data((0..<16).map { UInt8($0) }))

        XCTAssertEqual(try AudioProtocol.encode(pcm), expected)
        XCTAssertEqual(try AudioProtocol.decode(expected), .pcm(pcm))
    }

    func testStatusDecoderMatchesFirmwareVector() throws {
        let decoded = try AudioProtocol.decode(fixture("eaud-status-v1"))
        XCTAssertEqual(decoded, .status(AudioProtocol.StatusDatagram(
            sequence: 8,
            streamGeneration: 9,
            sampleRateHz: 48_000,
            timestampMicros: 10,
            status: AudioProtocol.Status(
                fillFrames: 100,
                targetFrames: 120,
                minimumFillFrames: 80,
                underruns: 2,
                underrunDurationMilliseconds: 250,
                latePackets: 3,
                lostFrames: 4,
                hardCorrections: 5,
                ingressDrops: 6,
                queueDrops: 7,
                engineDrops: 8,
                captureOverruns: 9))))
    }

    func testDecoderRefusesMalformedPackets() throws {
        let fixture = try fixture("eaud-pcm-v1")
        XCTAssertThrowsError(try AudioProtocol.decode(Data(fixture.prefix(20)))) {
            XCTAssertEqual($0 as? AudioProtocolError, .truncated)
        }
        var wrongMagic = fixture
        wrongMagic[0] = 0
        XCTAssertThrowsError(try AudioProtocol.decode(wrongMagic)) {
            XCTAssertEqual($0 as? AudioProtocolError, .badMagic)
        }
        var wrongVersion = fixture
        wrongVersion[4] = 2
        XCTAssertThrowsError(try AudioProtocol.decode(wrongVersion)) {
            XCTAssertEqual($0 as? AudioProtocolError, .versionMismatch(2))
        }
        XCTAssertThrowsError(try AudioProtocol.decode(Data(fixture.dropLast()))) {
            XCTAssertEqual(
                $0 as? AudioProtocolError,
                .badLength(declared: fixture.count, actual: fixture.count - 1))
        }
    }

    func testPacketFramesUseDescriptorAndStayWithinMTU() {
        let descriptor = AudioStreamDescriptor(
            port: 5_569,
            version: 1,
            sampleRateHz: 16_000,
            playbackChannels: 2,
            captureChannels: 2)
        XCTAssertEqual(
            AudioTiming.packetFrames(
                descriptor: descriptor, tuning: AudioRuntimeTuning()),
            320)

        let faster = AudioStreamDescriptor(
            port: 5_569,
            version: 1,
            sampleRateHz: 48_000,
            playbackChannels: 2,
            captureChannels: 1)
        XCTAssertEqual(
            AudioTiming.packetFrames(
                descriptor: faster, tuning: AudioRuntimeTuning()),
            350,
            "the requested duration is capped by bytes, not a fixed frame count")
    }

    func testLatencyAndClockDriftDefaultsAreDerived() {
        let tuning = AudioRuntimeTuning()
        XCTAssertEqual(tuning.downlinkTargetMilliseconds, 150)
        XCTAssertEqual(tuning.downlinkCeilingMilliseconds, 220)
        XCTAssertEqual(tuning.uplinkTargetMilliseconds, 80)
        XCTAssertEqual(tuning.uplinkCeilingMilliseconds, 120)
        XCTAssertEqual(tuning.derivedDriftBoundPPM, 200)
        XCTAssertEqual(tuning.maximumCorrectionPPM, 400)
        XCTAssertEqual(
            AudioTiming.frames(
                milliseconds: tuning.uplinkTargetMilliseconds,
                sampleRateHz: 48_000),
            3_840)
        XCTAssertEqual(
            AudioTiming.correctionPPM(
                fillDeltaFrames: 1, elapsedFrames: 48_000, tuning: tuning),
            20.833333333333332,
            accuracy: 0.000_001)
        XCTAssertEqual(
            AudioTiming.correctionPPM(
                fillDeltaFrames: 100, elapsedFrames: 48_000, tuning: tuning),
            400,
            "observations are clamped to the derived operating margin")
    }

    func testSequenceTrackerCountsGapsAndRejectsLatePackets() {
        var tracker = AudioSequenceTracker()
        XCTAssertTrue(tracker.accept(sequence: 7, streamGeneration: 1))
        XCTAssertTrue(tracker.accept(sequence: 8, streamGeneration: 1))
        XCTAssertTrue(tracker.accept(sequence: 10, streamGeneration: 1))
        XCTAssertEqual(tracker.lostPackets, 1)
        XCTAssertFalse(tracker.accept(sequence: 9, streamGeneration: 1))
        XCTAssertEqual(tracker.latePackets, 1)
        XCTAssertTrue(tracker.accept(sequence: 2, streamGeneration: 2))
        XCTAssertEqual(tracker.lostPackets, 1, "new generation is a restart, not loss")
    }
}
