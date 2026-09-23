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
        XCTAssertEqual(tuning.downlinkPanelTargetMilliseconds, 120)
        XCTAssertEqual(tuning.uplinkTargetMilliseconds, 80)
        XCTAssertEqual(tuning.uplinkCeilingMilliseconds, 120)
        XCTAssertEqual(tuning.uplinkJitterMilliseconds, 40)
        XCTAssertEqual(tuning.uplinkJitterCeilingMilliseconds, 80)
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

    func testPacketPacerSpacesBurstCallbacksAtTheDescriptorRate() {
        var pacer = AudioPacketPacer()

        XCTAssertEqual(
            pacer.deadlineNanos(
                nowNanos: 1_000_000_000,
                frameCount: 320,
                sampleRateHz: 16_000),
            1_000_000_000)
        XCTAssertEqual(
            pacer.deadlineNanos(
                nowNanos: 1_000_000_000,
                frameCount: 320,
                sampleRateHz: 16_000),
            1_020_000_000)
        XCTAssertEqual(
            pacer.deadlineNanos(
                nowNanos: 1_100_000_000,
                frameCount: 320,
                sampleRateHz: 16_000),
            1_100_000_000)
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

    func testDriftControllerFiltersAndBoundsFillSlope() {
        let tuning = AudioRuntimeTuning()
        var controller = AudioDriftController()

        XCTAssertEqual(
            controller.observe(
                timestampMicros: 10,
                fillFrames: 1_000,
                sampleRateHz: 48_000,
                tuning: tuning),
            0)
        let correction = controller.observe(
            timestampMicros: 1_000_010,
            fillFrames: 1_048,
            sampleRateHz: 48_000,
            tuning: tuning)
        XCTAssertGreaterThan(correction, 0)
        XCTAssertLessThanOrEqual(correction, tuning.maximumCorrectionPPM)
        XCTAssertEqual(
            controller.rateMultiplier,
            1 + correction / 1_000_000,
            accuracy: 0.000_000_1)
    }

    func testVariableRatioResamplerChangesDurationAtThePPMBound() {
        XCTAssertEqual(
            AudioLinearResampler.outputFrameCount(
                inputFrames: 48_000, rateMultiplier: 1.0004),
            47_981)
        let input = (0..<16).map(Float.init)
        let output = AudioLinearResampler.resample(
            interleavedSamples: input,
            channels: 1,
            rateMultiplier: 2)
        XCTAssertEqual(output.count, 8)
        XCTAssertEqual(output.first, 0)
        XCTAssertEqual(output.last, 15)

        var streaming = AudioVariableRateResampler()
        var totalFrames = 0
        let callback = [Float](repeating: 0, count: 320)
        for _ in 0..<100 {
            totalFrames += streaming.resample(
                interleavedSamples: callback,
                channels: 1,
                rateMultiplier: 1.0004).count
        }
        XCTAssertEqual(
            totalFrames,
            Int((32_000.0 / 1.0004).rounded(.down)),
            "fractional ppm corrections must survive callback-sized rounding")

        var sparse = AudioVariableRateResampler()
        XCTAssertEqual(
            sparse.resample(
                interleavedSamples: [1],
                channels: 1,
                rateMultiplier: 2),
            [])
        XCTAssertEqual(
            sparse.resample(
                interleavedSamples: [1],
                channels: 1,
                rateMultiplier: 2),
            [1],
            "sub-frame output is carried rather than forced negative")
    }

    func testComposedDownlinkCorrectionChangesDeliveredWireRateForBothSigns() {
        func deliveredFramesPerSecond(fillOffset: Int) -> Double {
            let sampleRate: UInt32 = 16_000
            let packetFrames = 320
            let targetFrames = 1_920
            let tuning = AudioRuntimeTuning(
                driftFilterWeight: 1,
                driftRecoveryMilliseconds: 250)
            var controller = AudioDriftController()
            _ = controller.observe(
                timestampMicros: 0,
                fillFrames: targetFrames + fillOffset,
                sampleRateHz: sampleRate,
                tuning: tuning,
                targetFillFrames: targetFrames)
            _ = controller.observe(
                timestampMicros: 1_000_000,
                fillFrames: targetFrames + fillOffset,
                sampleRateHz: sampleRate,
                tuning: tuning,
                targetFillFrames: targetFrames)

            let multiplier = controller.rateMultiplier
            var resampler = AudioVariableRateResampler()
            let captureCallback = [Float](repeating: 0, count: packetFrames)
            var correctedFrames = 0
            for _ in 0..<5_000 {
                correctedFrames += resampler.resample(
                    interleavedSamples: captureCallback,
                    channels: 1,
                    rateMultiplier: multiplier).count
            }

            let fullPackets = correctedFrames / packetFrames
            var pacer = AudioPacketPacer()
            for _ in 0..<fullPackets {
                _ = pacer.deadlineNanos(
                    nowNanos: 0,
                    frameCount: packetFrames,
                    sampleRateHz: sampleRate,
                    rateMultiplier: multiplier)
            }
            let endNanos = pacer.deadlineNanos(
                nowNanos: 0,
                frameCount: packetFrames,
                sampleRateHz: sampleRate,
                rateMultiplier: multiplier)
            return Double(fullPackets * packetFrames)
                * 1_000_000_000
                / Double(endNanos)
        }

        XCTAssertGreaterThan(
            deliveredFramesPerSecond(fillOffset: -100),
            16_000,
            "below-target fill must deliver more than the nominal wire rate")
        XCTAssertLessThan(
            deliveredFramesPerSecond(fillOffset: 100),
            16_000,
            "above-target fill must deliver less than the nominal wire rate")
    }

    func testLatencyTargetContributesToDriftCorrection() {
        var controller = AudioDriftController()
        let tuning = AudioRuntimeTuning(driftFilterWeight: 1)
        _ = controller.observe(
            timestampMicros: 0,
            fillFrames: 4_000,
            sampleRateHz: 48_000,
            tuning: tuning,
            targetFillFrames: 3_840)
        let correction = controller.observe(
            timestampMicros: 1_000_000,
            fillFrames: 4_000,
            sampleRateHz: 48_000,
            tuning: tuning,
            targetFillFrames: 3_840)
        XCTAssertGreaterThan(
            correction, 0,
            "a queue above the configured latency target must be consumed faster")
    }

    func testJitterBufferReordersBeforePlayout() {
        func packet(_ sequence: UInt16, counter: UInt32) -> AudioProtocol.PCM {
            AudioProtocol.PCM(
                kind: .pcmUplink,
                sequence: sequence,
                streamGeneration: 5,
                sampleRateHz: 16_000,
                sampleCounter: counter,
                timestampMicros: counter * 62,
                frameCount: 2,
                channels: 1,
                samples: Data(repeating: UInt8(sequence), count: 4))
        }
        var jitter = AudioJitterBuffer(
            targetFrames: 4,
            ceilingFrames: 12,
            reorderWindowPackets: 2,
            reorderTimeoutNanos: 20_000_000)

        XCTAssertEqual(jitter.insert(packet(10, counter: 100), nowNanos: 0), [])
        XCTAssertEqual(
            jitter.insert(packet(12, counter: 104), nowNanos: 1_000_000),
            [],
            "future audio must not count toward contiguous startup")
        XCTAssertEqual(jitter.contiguousBufferedFrames, 2)
        XCTAssertEqual(
            jitter.insert(packet(11, counter: 102), nowNanos: 2_000_000),
            [
                .pcm(packet(10, counter: 100)),
                .pcm(packet(11, counter: 102)),
                .pcm(packet(12, counter: 104)),
            ])
        XCTAssertEqual(jitter.reorderedPackets, 1)
        XCTAssertEqual(jitter.lostFrames, 0)
    }

    func testJitterStartupResolvesEarlyLossBeforeReleasingAudio() {
        func packet(_ sequence: UInt16, counter: UInt32) -> AudioProtocol.PCM {
            AudioProtocol.PCM(
                kind: .pcmUplink,
                sequence: sequence,
                streamGeneration: 7,
                sampleRateHz: 16_000,
                sampleCounter: counter,
                timestampMicros: counter * 62,
                frameCount: 2,
                channels: 1,
                samples: Data(repeating: UInt8(sequence), count: 4))
        }
        var jitter = AudioJitterBuffer(
            targetFrames: 4,
            ceilingFrames: 12,
            reorderWindowPackets: 2,
            reorderTimeoutNanos: 20_000_000)

        XCTAssertEqual(jitter.insert(packet(30, counter: 200), nowNanos: 0), [])
        XCTAssertEqual(
            jitter.insert(packet(32, counter: 204), nowNanos: 1_000_000),
            [])
        XCTAssertEqual(jitter.poll(nowNanos: 20_999_999), [])

        let startup = jitter.poll(nowNanos: 21_000_000)
        XCTAssertEqual(
            startup,
            [
                .pcm(packet(30, counter: 200)),
                .silence(frames: 2),
                .pcm(packet(32, counter: 204)),
            ])
        XCTAssertGreaterThanOrEqual(
            startup.reduce(0) { frames, chunk in
                switch chunk {
                case .pcm(let pcm): return frames + Int(pcm.frameCount)
                case .silence(let count): return frames + count
                }
            },
            jitter.targetFrames,
            "startup must schedule the target duration without a gap")
        XCTAssertEqual(jitter.lostFrames, 2)
        XCTAssertEqual(
            AudioTiming.jitterPollMilliseconds(tuning: AudioRuntimeTuning()),
            20)
    }

    func testJitterBufferPreservesExpiredGapAsSilence() {
        func packet(_ sequence: UInt16, counter: UInt32) -> AudioProtocol.PCM {
            AudioProtocol.PCM(
                kind: .pcmUplink,
                sequence: sequence,
                streamGeneration: 9,
                sampleRateHz: 16_000,
                sampleCounter: counter,
                timestampMicros: counter * 62,
                frameCount: 2,
                channels: 1,
                samples: Data(repeating: UInt8(sequence), count: 4))
        }
        var jitter = AudioJitterBuffer(
            targetFrames: 2,
            ceilingFrames: 8,
            reorderWindowPackets: 2,
            reorderTimeoutNanos: 20_000_000)

        XCTAssertEqual(
            jitter.insert(packet(20, counter: 0), nowNanos: 0),
            [.pcm(packet(20, counter: 0))])
        XCTAssertEqual(
            jitter.insert(packet(22, counter: 4), nowNanos: 1_000_000),
            [])
        XCTAssertEqual(
            jitter.poll(nowNanos: 21_000_001),
            [.silence(frames: 2), .pcm(packet(22, counter: 4))])
        XCTAssertEqual(jitter.lostFrames, 2)
    }

    func testAudioDemandReducesOnlyTheVideoShare() {
        var budget = AudioFirstRadioBudget(tuning: AudioRuntimeTuning())
        XCTAssertEqual(
            budget.videoSpacingNanos(
                baseSpacingMicros: 200,
                packetBytes: 1_472,
                nowNanos: 1_000_000_000),
            200_000)

        budget.recordAudioDatagram(bytes: 700, nowNanos: 1_000_000_000)
        XCTAssertGreaterThan(
            budget.videoSpacingNanos(
                baseSpacingMicros: 200,
                packetBytes: 1_472,
                nowNanos: 1_000_000_000),
            200_000)
        XCTAssertEqual(
            budget.videoSpacingNanos(
                baseSpacingMicros: 200,
                packetBytes: 1_472,
                nowNanos: 3_000_000_000),
            200_000,
            "expired audio demand does not reserve a permanent fixed share")
    }

    func testAudioBudgetNeverSpeedsUpAnAlreadySlowerVideoSetting() {
        var budget = AudioFirstRadioBudget(tuning: AudioRuntimeTuning(
            maximumVideoDelayMilliseconds: 1))
        budget.recordAudioDatagram(bytes: 64, nowNanos: 1_000_000_000)
        XCTAssertEqual(
            budget.videoSpacingNanos(
                baseSpacingMicros: 5_000,
                packetBytes: 64,
                nowNanos: 1_000_000_000),
            5_000_000)
    }
}
