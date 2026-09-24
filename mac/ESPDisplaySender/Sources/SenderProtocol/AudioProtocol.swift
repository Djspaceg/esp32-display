import Foundation

/// Descriptor-driven EAUD v1 wire format shared by the Mac sender and panel.
public enum AudioProtocol {
    public static let version: UInt8 = 1
    public static let port: UInt16 = 5569
    public static let pcm16LittleEndianFlag: UInt8 = 1
    public static let headerBytes = 28
    public static let maximumPayloadBytes = 1_400
    public static let statusPayloadBytes = 48

    public enum Kind: UInt8, Equatable, Sendable {
        case pcmDownlink = 1
        case pcmUplink = 2
        case status = 3
    }

    public struct PCM: Equatable, Sendable {
        public let kind: Kind
        public let sequence: UInt16
        public let streamGeneration: UInt16
        public let sampleRateHz: UInt32
        public let sampleCounter: UInt32
        public let timestampMicros: UInt32
        public let frameCount: UInt16
        public let channels: UInt8
        public let samples: Data

        public init(
            kind: Kind,
            sequence: UInt16,
            streamGeneration: UInt16,
            sampleRateHz: UInt32,
            sampleCounter: UInt32,
            timestampMicros: UInt32,
            frameCount: UInt16,
            channels: UInt8,
            samples: Data
        ) {
            self.kind = kind
            self.sequence = sequence
            self.streamGeneration = streamGeneration
            self.sampleRateHz = sampleRateHz
            self.sampleCounter = sampleCounter
            self.timestampMicros = timestampMicros
            self.frameCount = frameCount
            self.channels = channels
            self.samples = samples
        }
    }

    public struct Status: Equatable, Sendable {
        public let fillFrames: UInt32
        public let targetFrames: UInt32
        public let minimumFillFrames: UInt32
        public let underruns: UInt32
        public let underrunDurationMilliseconds: UInt32
        public let latePackets: UInt32
        public let lostFrames: UInt32
        public let hardCorrections: UInt32
        public let ingressDrops: UInt32
        public let queueDrops: UInt32
        public let engineDrops: UInt32
        public let captureOverruns: UInt32

        public init(
            fillFrames: UInt32,
            targetFrames: UInt32,
            minimumFillFrames: UInt32,
            underruns: UInt32,
            underrunDurationMilliseconds: UInt32,
            latePackets: UInt32,
            lostFrames: UInt32,
            hardCorrections: UInt32,
            ingressDrops: UInt32,
            queueDrops: UInt32,
            engineDrops: UInt32,
            captureOverruns: UInt32
        ) {
            self.fillFrames = fillFrames
            self.targetFrames = targetFrames
            self.minimumFillFrames = minimumFillFrames
            self.underruns = underruns
            self.underrunDurationMilliseconds = underrunDurationMilliseconds
            self.latePackets = latePackets
            self.lostFrames = lostFrames
            self.hardCorrections = hardCorrections
            self.ingressDrops = ingressDrops
            self.queueDrops = queueDrops
            self.engineDrops = engineDrops
            self.captureOverruns = captureOverruns
        }
    }

    public struct StatusDatagram: Equatable, Sendable {
        public let sequence: UInt16
        public let streamGeneration: UInt16
        public let sampleRateHz: UInt32
        public let timestampMicros: UInt32
        public let status: Status

        public init(
            sequence: UInt16,
            streamGeneration: UInt16,
            sampleRateHz: UInt32,
            timestampMicros: UInt32,
            status: Status
        ) {
            self.sequence = sequence
            self.streamGeneration = streamGeneration
            self.sampleRateHz = sampleRateHz
            self.timestampMicros = timestampMicros
            self.status = status
        }
    }

    public enum Datagram: Equatable, Sendable {
        case pcm(PCM)
        case status(StatusDatagram)
    }

    public static func encode(_ pcm: PCM) throws -> Data {
        guard pcm.kind == .pcmDownlink || pcm.kind == .pcmUplink else {
            throw AudioProtocolError.unknownKind(pcm.kind.rawValue)
        }
        guard valid(sampleRateHz: pcm.sampleRateHz),
              (UInt8(1)...UInt8(2)).contains(pcm.channels),
              pcm.frameCount > 0
        else { throw AudioProtocolError.badFormat }
        let payloadBytes = Int(pcm.frameCount) * Int(pcm.channels) * 2
        guard payloadBytes == pcm.samples.count,
              payloadBytes <= maximumPayloadBytes
        else {
            throw AudioProtocolError.badLength(
                declared: payloadBytes, actual: pcm.samples.count)
        }

        var data = Data(capacity: headerBytes + payloadBytes)
        data.append(contentsOf: "EAUD".utf8)
        data.append(version)
        data.append(pcm.kind.rawValue)
        data.append(pcm16LittleEndianFlag)
        data.append(pcm.channels)
        append(pcm.sequence, to: &data)
        append(pcm.streamGeneration, to: &data)
        append(pcm.sampleRateHz, to: &data)
        append(pcm.sampleCounter, to: &data)
        append(pcm.timestampMicros, to: &data)
        append(pcm.frameCount, to: &data)
        append(UInt16(payloadBytes), to: &data)
        data.append(pcm.samples)
        return data
    }

    public static func decode(_ data: Data) throws -> Datagram {
        guard data.count >= headerBytes else {
            throw AudioProtocolError.truncated
        }
        guard Data(data.prefix(4)) == Data("EAUD".utf8) else {
            throw AudioProtocolError.badMagic
        }
        guard data[4] == version else {
            throw AudioProtocolError.versionMismatch(data[4])
        }
        guard let kind = Kind(rawValue: data[5]) else {
            throw AudioProtocolError.unknownKind(data[5])
        }
        let flags = data[6]
        let channels = data[7]
        let sequence = readUInt16(data, at: 8)
        let streamGeneration = readUInt16(data, at: 10)
        let sampleRateHz = readUInt32(data, at: 12)
        let sampleCounter = readUInt32(data, at: 16)
        let timestampMicros = readUInt32(data, at: 20)
        let frameCount = readUInt16(data, at: 24)
        let payloadBytes = Int(readUInt16(data, at: 26))
        guard data.count == headerBytes + payloadBytes else {
            throw AudioProtocolError.badLength(
                declared: headerBytes + payloadBytes, actual: data.count)
        }
        guard valid(sampleRateHz: sampleRateHz) else {
            throw AudioProtocolError.badFormat
        }
        let payload = data.subdata(in: headerBytes..<data.count)

        switch kind {
        case .pcmDownlink, .pcmUplink:
            guard flags == pcm16LittleEndianFlag,
                  (UInt8(1)...UInt8(2)).contains(channels),
                  frameCount > 0
            else { throw AudioProtocolError.badFormat }
            let expected = Int(frameCount) * Int(channels) * 2
            guard payloadBytes == expected, payloadBytes <= maximumPayloadBytes else {
                throw AudioProtocolError.badLength(
                    declared: expected, actual: payloadBytes)
            }
            return .pcm(PCM(
                kind: kind,
                sequence: sequence,
                streamGeneration: streamGeneration,
                sampleRateHz: sampleRateHz,
                sampleCounter: sampleCounter,
                timestampMicros: timestampMicros,
                frameCount: frameCount,
                channels: channels,
                samples: payload))

        case .status:
            guard flags == 0, channels == 0, sampleCounter == 0,
                  frameCount == 0, payloadBytes == statusPayloadBytes
            else { throw AudioProtocolError.badFormat }
            let fields = stride(from: 0, to: statusPayloadBytes, by: 4)
                .map { readUInt32(payload, at: $0) }
            return .status(StatusDatagram(
                sequence: sequence,
                streamGeneration: streamGeneration,
                sampleRateHz: sampleRateHz,
                timestampMicros: timestampMicros,
                status: Status(
                    fillFrames: fields[0],
                    targetFrames: fields[1],
                    minimumFillFrames: fields[2],
                    underruns: fields[3],
                    underrunDurationMilliseconds: fields[4],
                    latePackets: fields[5],
                    lostFrames: fields[6],
                    hardCorrections: fields[7],
                    ingressDrops: fields[8],
                    queueDrops: fields[9],
                    engineDrops: fields[10],
                    captureOverruns: fields[11])))
        }
    }

    public static func valid(sampleRateHz: UInt32) -> Bool {
        (UInt32(8_000)...UInt32(96_000)).contains(sampleRateHz)
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8(value >> 24))
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

public enum AudioProtocolError: Error, LocalizedError, Equatable {
    case truncated
    case badMagic
    case versionMismatch(UInt8)
    case unknownKind(UInt8)
    case badFormat
    case badLength(declared: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .truncated:
            return "The audio datagram is shorter than its header."
        case .badMagic:
            return "The audio datagram has the wrong magic."
        case .versionMismatch(let version):
            return "The panel sent unsupported audio version \(version)."
        case .unknownKind(let kind):
            return "The panel sent unknown audio datagram kind \(kind)."
        case .badFormat:
            return "The audio datagram has an invalid PCM or status format."
        case .badLength(let declared, let actual):
            return "The audio datagram declares \(declared) bytes but contains \(actual)."
        }
    }
}

/// Complete mDNS format contract for one panel's full-duplex audio stream.
public struct AudioStreamDescriptor: Equatable, Hashable, Sendable {
    public let port: UInt16
    public let version: UInt8
    public let sampleRateHz: UInt32
    public let playbackChannels: UInt8
    public let captureChannels: UInt8

    public init(
        port: UInt16,
        version: UInt8,
        sampleRateHz: UInt32,
        playbackChannels: UInt8,
        captureChannels: UInt8
    ) {
        self.port = port
        self.version = version
        self.sampleRateHz = sampleRateHz
        self.playbackChannels = playbackChannels
        self.captureChannels = captureChannels
    }

    public var isSupported: Bool {
        port == AudioProtocol.port
            && version == AudioProtocol.version
            && AudioProtocol.valid(sampleRateHz: sampleRateHz)
            && (UInt8(1)...UInt8(2)).contains(playbackChannels)
            && (UInt8(1)...UInt8(2)).contains(captureChannels)
    }
}

/// Runtime audio constants. SenderSettings persists this value so capture,
/// networking, and playback adapters do not grow independent timing literals.
public struct AudioRuntimeTuning: Codable, Equatable, Sendable {
    public var packetMilliseconds: Double
    public var downlinkTargetMilliseconds: Double
    public var downlinkCeilingMilliseconds: Double
    public var downlinkPanelTargetMilliseconds: Double
    public var uplinkTargetMilliseconds: Double
    public var uplinkCeilingMilliseconds: Double
    public var uplinkJitterMilliseconds: Double
    public var uplinkJitterCeilingMilliseconds: Double
    public var statusPublishMilliseconds: Double
    public var panelClockPPM: Double
    public var macClockPPM: Double
    public var estimatorErrorPPM: Double
    public var correctionMargin: Double
    public var driftFilterWeight: Double
    public var driftRecoveryMilliseconds: Double
    public var uplinkReorderPackets: Int
    public var uplinkReorderMilliseconds: Double
    public var responseTimeoutMilliseconds: Double
    public var radioWindowMilliseconds: Double
    public var radioSafetyMargin: Double
    public var radioPacketOverheadBytes: Int
    public var maximumVideoDelayMilliseconds: Double
    public var captureRingSlots: Int
    public var captureRingSlotMilliseconds: Double
    public var captureWorkerMilliseconds: Double

    public init(
        packetMilliseconds: Double = 20,
        downlinkTargetMilliseconds: Double = 150,
        downlinkCeilingMilliseconds: Double = 220,
        downlinkPanelTargetMilliseconds: Double = 120,
        uplinkTargetMilliseconds: Double = 80,
        uplinkCeilingMilliseconds: Double = 120,
        uplinkJitterMilliseconds: Double = 40,
        uplinkJitterCeilingMilliseconds: Double = 80,
        statusPublishMilliseconds: Double = 250,
        panelClockPPM: Double = 50,
        macClockPPM: Double = 100,
        estimatorErrorPPM: Double = 50,
        correctionMargin: Double = 2,
        driftFilterWeight: Double = 0.125,
        driftRecoveryMilliseconds: Double = 2_000,
        uplinkReorderPackets: Int = 4,
        uplinkReorderMilliseconds: Double = 40,
        responseTimeoutMilliseconds: Double = 1_500,
        radioWindowMilliseconds: Double = 1_000,
        radioSafetyMargin: Double = 0.15,
        radioPacketOverheadBytes: Int = 64,
        maximumVideoDelayMilliseconds: Double = 50,
        captureRingSlots: Int = 8,
        captureRingSlotMilliseconds: Double = 100,
        captureWorkerMilliseconds: Double = 5
    ) {
        self.packetMilliseconds = packetMilliseconds
        self.downlinkTargetMilliseconds = downlinkTargetMilliseconds
        self.downlinkCeilingMilliseconds = downlinkCeilingMilliseconds
        self.downlinkPanelTargetMilliseconds = downlinkPanelTargetMilliseconds
        self.uplinkTargetMilliseconds = uplinkTargetMilliseconds
        self.uplinkCeilingMilliseconds = uplinkCeilingMilliseconds
        self.uplinkJitterMilliseconds = uplinkJitterMilliseconds
        self.uplinkJitterCeilingMilliseconds = uplinkJitterCeilingMilliseconds
        self.statusPublishMilliseconds = statusPublishMilliseconds
        self.panelClockPPM = panelClockPPM
        self.macClockPPM = macClockPPM
        self.estimatorErrorPPM = estimatorErrorPPM
        self.correctionMargin = correctionMargin
        self.driftFilterWeight = driftFilterWeight
        self.driftRecoveryMilliseconds = driftRecoveryMilliseconds
        self.uplinkReorderPackets = uplinkReorderPackets
        self.uplinkReorderMilliseconds = uplinkReorderMilliseconds
        self.responseTimeoutMilliseconds = responseTimeoutMilliseconds
        self.radioWindowMilliseconds = radioWindowMilliseconds
        self.radioSafetyMargin = radioSafetyMargin
        self.radioPacketOverheadBytes = radioPacketOverheadBytes
        self.maximumVideoDelayMilliseconds = maximumVideoDelayMilliseconds
        self.captureRingSlots = captureRingSlots
        self.captureRingSlotMilliseconds = captureRingSlotMilliseconds
        self.captureWorkerMilliseconds = captureWorkerMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case packetMilliseconds
        case downlinkTargetMilliseconds
        case downlinkCeilingMilliseconds
        case downlinkPanelTargetMilliseconds
        case uplinkTargetMilliseconds
        case uplinkCeilingMilliseconds
        case uplinkJitterMilliseconds
        case uplinkJitterCeilingMilliseconds
        case statusPublishMilliseconds
        case panelClockPPM
        case macClockPPM
        case estimatorErrorPPM
        case correctionMargin
        case driftFilterWeight
        case driftRecoveryMilliseconds
        case uplinkReorderPackets
        case uplinkReorderMilliseconds
        case responseTimeoutMilliseconds
        case radioWindowMilliseconds
        case radioSafetyMargin
        case radioPacketOverheadBytes
        case maximumVideoDelayMilliseconds
        case captureRingSlots
        case captureRingSlotMilliseconds
        case captureWorkerMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let defaults = Self()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packetMilliseconds =
            (try? container.decode(Double.self, forKey: .packetMilliseconds))
            ?? defaults.packetMilliseconds
        downlinkTargetMilliseconds =
            (try? container.decode(Double.self, forKey: .downlinkTargetMilliseconds))
            ?? defaults.downlinkTargetMilliseconds
        downlinkCeilingMilliseconds =
            (try? container.decode(Double.self, forKey: .downlinkCeilingMilliseconds))
            ?? defaults.downlinkCeilingMilliseconds
        downlinkPanelTargetMilliseconds =
            (try? container.decode(
                Double.self, forKey: .downlinkPanelTargetMilliseconds))
            ?? defaults.downlinkPanelTargetMilliseconds
        uplinkTargetMilliseconds =
            (try? container.decode(Double.self, forKey: .uplinkTargetMilliseconds))
            ?? defaults.uplinkTargetMilliseconds
        uplinkCeilingMilliseconds =
            (try? container.decode(Double.self, forKey: .uplinkCeilingMilliseconds))
            ?? defaults.uplinkCeilingMilliseconds
        uplinkJitterMilliseconds =
            (try? container.decode(Double.self, forKey: .uplinkJitterMilliseconds))
            ?? defaults.uplinkJitterMilliseconds
        uplinkJitterCeilingMilliseconds =
            (try? container.decode(
                Double.self, forKey: .uplinkJitterCeilingMilliseconds))
            ?? defaults.uplinkJitterCeilingMilliseconds
        statusPublishMilliseconds =
            (try? container.decode(Double.self, forKey: .statusPublishMilliseconds))
            ?? defaults.statusPublishMilliseconds
        panelClockPPM =
            (try? container.decode(Double.self, forKey: .panelClockPPM))
            ?? defaults.panelClockPPM
        macClockPPM =
            (try? container.decode(Double.self, forKey: .macClockPPM))
            ?? defaults.macClockPPM
        estimatorErrorPPM =
            (try? container.decode(Double.self, forKey: .estimatorErrorPPM))
            ?? defaults.estimatorErrorPPM
        correctionMargin =
            (try? container.decode(Double.self, forKey: .correctionMargin))
            ?? defaults.correctionMargin
        driftFilterWeight =
            (try? container.decode(Double.self, forKey: .driftFilterWeight))
            ?? defaults.driftFilterWeight
        driftRecoveryMilliseconds =
            (try? container.decode(Double.self, forKey: .driftRecoveryMilliseconds))
            ?? defaults.driftRecoveryMilliseconds
        uplinkReorderPackets =
            (try? container.decode(Int.self, forKey: .uplinkReorderPackets))
            ?? defaults.uplinkReorderPackets
        uplinkReorderMilliseconds =
            (try? container.decode(Double.self, forKey: .uplinkReorderMilliseconds))
            ?? defaults.uplinkReorderMilliseconds
        responseTimeoutMilliseconds =
            (try? container.decode(Double.self, forKey: .responseTimeoutMilliseconds))
            ?? defaults.responseTimeoutMilliseconds
        radioWindowMilliseconds =
            (try? container.decode(Double.self, forKey: .radioWindowMilliseconds))
            ?? defaults.radioWindowMilliseconds
        radioSafetyMargin =
            (try? container.decode(Double.self, forKey: .radioSafetyMargin))
            ?? defaults.radioSafetyMargin
        radioPacketOverheadBytes =
            (try? container.decode(Int.self, forKey: .radioPacketOverheadBytes))
            ?? defaults.radioPacketOverheadBytes
        maximumVideoDelayMilliseconds =
            (try? container.decode(
                Double.self, forKey: .maximumVideoDelayMilliseconds))
            ?? defaults.maximumVideoDelayMilliseconds
        captureRingSlots =
            (try? container.decode(Int.self, forKey: .captureRingSlots))
            ?? defaults.captureRingSlots
        captureRingSlotMilliseconds =
            (try? container.decode(
                Double.self, forKey: .captureRingSlotMilliseconds))
            ?? defaults.captureRingSlotMilliseconds
        captureWorkerMilliseconds =
            (try? container.decode(
                Double.self, forKey: .captureWorkerMilliseconds))
            ?? defaults.captureWorkerMilliseconds
    }

    /// abs(panel) + abs(Mac) + abs(estimator), as required by the ADR.
    public var derivedDriftBoundPPM: Double {
        abs(panelClockPPM) + abs(macClockPPM) + abs(estimatorErrorPPM)
    }

    public var maximumCorrectionPPM: Double {
        derivedDriftBoundPPM * max(1, correctionMargin)
    }

    public var validated: AudioRuntimeTuning {
        let downlinkTarget = Self.clamp(
            downlinkTargetMilliseconds, lower: 1, upper: 1_000)
        let uplinkTarget = Self.clamp(
            uplinkTargetMilliseconds, lower: 1, upper: 1_000)
        let uplinkCeiling = Self.clamp(
            uplinkCeilingMilliseconds,
            lower: uplinkTarget,
            upper: 2_000)
        let uplinkJitter = Self.clamp(
            uplinkJitterMilliseconds, lower: 1, upper: uplinkTarget)
        return AudioRuntimeTuning(
            packetMilliseconds: Self.clamp(
                packetMilliseconds, lower: 1, upper: 100),
            downlinkTargetMilliseconds: downlinkTarget,
            downlinkCeilingMilliseconds: Self.clamp(
                downlinkCeilingMilliseconds,
                lower: downlinkTarget,
                upper: 2_000),
            downlinkPanelTargetMilliseconds: Self.clamp(
                downlinkPanelTargetMilliseconds,
                lower: 1,
                upper: downlinkTarget),
            uplinkTargetMilliseconds: uplinkTarget,
            uplinkCeilingMilliseconds: uplinkCeiling,
            uplinkJitterMilliseconds: uplinkJitter,
            uplinkJitterCeilingMilliseconds: Self.clamp(
                uplinkJitterCeilingMilliseconds,
                lower: uplinkJitter,
                upper: uplinkCeiling),
            statusPublishMilliseconds: Self.clamp(
                statusPublishMilliseconds, lower: 50, upper: 5_000),
            panelClockPPM: Self.clamp(
                abs(panelClockPPM), lower: 1, upper: 2_000),
            macClockPPM: Self.clamp(
                abs(macClockPPM), lower: 1, upper: 2_000),
            estimatorErrorPPM: Self.clamp(
                abs(estimatorErrorPPM), lower: 1, upper: 2_000),
            correctionMargin: Self.clamp(
                correctionMargin, lower: 1, upper: 10),
            driftFilterWeight: Self.clamp(
                driftFilterWeight, lower: 0.01, upper: 1),
            driftRecoveryMilliseconds: Self.clamp(
                driftRecoveryMilliseconds, lower: 250, upper: 30_000),
            uplinkReorderPackets: min(max(uplinkReorderPackets, 1), 64),
            uplinkReorderMilliseconds: Self.clamp(
                uplinkReorderMilliseconds, lower: 1, upper: 500),
            responseTimeoutMilliseconds: Self.clamp(
                responseTimeoutMilliseconds, lower: 250, upper: 30_000),
            radioWindowMilliseconds: Self.clamp(
                radioWindowMilliseconds, lower: 100, upper: 10_000),
            radioSafetyMargin: Self.clamp(
                radioSafetyMargin, lower: 0, upper: 0.75),
            radioPacketOverheadBytes: min(
                max(radioPacketOverheadBytes, 0), 1_024),
            maximumVideoDelayMilliseconds: Self.clamp(
                maximumVideoDelayMilliseconds, lower: 1, upper: 500),
            captureRingSlots: min(max(captureRingSlots, 2), 64),
            captureRingSlotMilliseconds: Self.clamp(
                captureRingSlotMilliseconds, lower: 10, upper: 500),
            captureWorkerMilliseconds: Self.clamp(
                captureWorkerMilliseconds, lower: 1, upper: 50))
    }

    private static func clamp(
        _ value: Double, lower: Double, upper: Double
    ) -> Double {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }
}

public enum AudioTiming {
    public static func frames(
        milliseconds: Double, sampleRateHz: UInt32
    ) -> Int {
        max(1, Int((milliseconds * Double(sampleRateHz) / 1_000).rounded()))
    }

    public static func packetFrames(
        descriptor: AudioStreamDescriptor,
        tuning: AudioRuntimeTuning
    ) -> Int {
        let wanted = frames(
            milliseconds: tuning.validated.packetMilliseconds,
            sampleRateHz: descriptor.sampleRateHz)
        let maximum = AudioProtocol.maximumPayloadBytes
            / (Int(descriptor.playbackChannels) * 2)
        return min(wanted, maximum)
    }

    public static func correctionPPM(
        fillDeltaFrames: Int,
        elapsedFrames: Int,
        tuning: AudioRuntimeTuning
    ) -> Double {
        guard elapsedFrames > 0 else { return 0 }
        let observed = Double(fillDeltaFrames) / Double(elapsedFrames) * 1_000_000
        let bound = tuning.validated.maximumCorrectionPPM
        return min(max(observed, -bound), bound)
    }

    public static func jitterPollMilliseconds(
        tuning: AudioRuntimeTuning
    ) -> Int {
        let validated = tuning.validated
        let interval = min(
            validated.uplinkReorderMilliseconds / 2,
            validated.responseTimeoutMilliseconds / 4)
        return max(1, Int(interval.rounded(.down)))
    }
}

/// Bounded fill-slope estimator. A positive correction means the queue is
/// growing, so the caller must consume faster or produce fewer frames.
public struct AudioDriftController: Equatable, Sendable {
    private var lastTimestampMicros: UInt32?
    private var lastFillFrames: Int?
    public private(set) var correctionPPM: Double = 0

    public init() {}

    public var rateMultiplier: Double {
        1 + correctionPPM / 1_000_000
    }

    public mutating func observe(
        timestampMicros: UInt32,
        fillFrames: Int,
        sampleRateHz: UInt32,
        tuning: AudioRuntimeTuning,
        targetFillFrames: Int? = nil
    ) -> Double {
        defer {
            lastTimestampMicros = timestampMicros
            lastFillFrames = fillFrames
        }
        guard let previousTimestamp = lastTimestampMicros,
              let previousFill = lastFillFrames
        else {
            correctionPPM = 0
            return correctionPPM
        }
        let elapsedMicros = timestampMicros &- previousTimestamp
        guard elapsedMicros > 0 else { return correctionPPM }
        let elapsedFrames = max(
            1,
            Int(
                Double(elapsedMicros)
                    * Double(sampleRateHz)
                    / 1_000_000))
        let slope = AudioTiming.correctionPPM(
            fillDeltaFrames: fillFrames - previousFill,
            elapsedFrames: elapsedFrames,
            tuning: tuning)
        let validated = tuning.validated
        let recoveryFrames =
            Double(sampleRateHz)
                * validated.driftRecoveryMilliseconds
                / 1_000
        let targetCorrection = targetFillFrames.map {
            Double(fillFrames - $0) / max(1, recoveryFrames) * 1_000_000
        } ?? 0
        let bound = validated.maximumCorrectionPPM
        let observed = min(max(slope + targetCorrection, -bound), bound)
        let weight = validated.driftFilterWeight
        let filtered = correctionPPM * (1 - weight) + observed * weight
        correctionPPM = min(
            max(filtered, -validated.maximumCorrectionPPM),
            validated.maximumCorrectionPPM)
        return correctionPPM
    }

    public mutating func reset() {
        lastTimestampMicros = nil
        lastFillFrames = nil
        correctionPPM = 0
    }
}

/// Small continuously variable resampler used off the CoreAudio render thread.
public enum AudioLinearResampler {
    public static func outputFrameCount(
        inputFrames: Int, rateMultiplier: Double
    ) -> Int {
        guard inputFrames > 0, rateMultiplier.isFinite else { return 0 }
        let ratio = min(max(rateMultiplier, 0.5), 2)
        return max(1, Int((Double(inputFrames) / ratio).rounded()))
    }

    public static func resample(
        interleavedSamples: [Float],
        channels: Int,
        rateMultiplier: Double
    ) -> [Float] {
        guard channels > 0,
              interleavedSamples.count >= channels
        else { return [] }
        let inputFrames = interleavedSamples.count / channels
        let outputFrames = outputFrameCount(
            inputFrames: inputFrames, rateMultiplier: rateMultiplier)
        return resample(
            interleavedSamples: interleavedSamples,
            channels: channels,
            outputFrames: outputFrames)
    }
}

/// Carries fractional output frames across buffers so sub-frame ppm
/// corrections remain effective at normal 10-20 ms callback sizes.
public struct AudioVariableRateResampler: Equatable, Sendable {
    private var fractionalFrames: Double = 0

    public init() {}

    public mutating func resample(
        interleavedSamples: [Float],
        channels: Int,
        rateMultiplier: Double
    ) -> [Float] {
        guard channels > 0,
              interleavedSamples.count >= channels,
              rateMultiplier.isFinite
        else { return [] }
        let inputFrames = interleavedSamples.count / channels
        let ratio = min(max(rateMultiplier, 0.5), 2)
        let exactFrames = Double(inputFrames) / ratio + fractionalFrames
        let outputFrames = max(0, Int(exactFrames.rounded(.down)))
        fractionalFrames = exactFrames - Double(outputFrames)
        return AudioLinearResampler.resample(
            interleavedSamples: interleavedSamples,
            channels: channels,
            outputFrames: outputFrames)
    }

    public mutating func reset() {
        fractionalFrames = 0
    }
}

private extension AudioLinearResampler {
    static func resample(
        interleavedSamples: [Float],
        channels: Int,
        outputFrames: Int
    ) -> [Float] {
        let inputFrames = interleavedSamples.count / channels
        guard inputFrames > 0, outputFrames > 0 else { return [] }
        if inputFrames == 1 {
            return Array(
                repeating: Array(interleavedSamples.prefix(channels)),
                count: outputFrames
            ).flatMap { $0 }
        }
        guard outputFrames > 1 else {
            return Array(interleavedSamples.prefix(channels))
        }
        let scale = Double(inputFrames - 1) / Double(outputFrames - 1)
        var output = [Float]()
        output.reserveCapacity(outputFrames * channels)
        for outputFrame in 0..<outputFrames {
            let position = Double(outputFrame) * scale
            let lower = min(Int(position), inputFrames - 1)
            let upper = min(lower + 1, inputFrames - 1)
            let fraction = Float(position - Double(lower))
            for channel in 0..<channels {
                let low = interleavedSamples[lower * channels + channel]
                let high = interleavedSamples[upper * channels + channel]
                output.append(low + (high - low) * fraction)
            }
        }
        return output
    }
}

public enum AudioPlayoutChunk: Equatable, Sendable {
    case pcm(AudioProtocol.PCM)
    case silence(frames: Int)
}

/// Atomic admission policy shared by jitter startup and the playback queue.
public enum AudioPlayoutCeiling {
    public static func frameCount(_ chunk: AudioPlayoutChunk) -> Int {
        switch chunk {
        case .pcm(let pcm):
            return Int(pcm.frameCount)
        case .silence(let frames):
            return max(0, frames)
        }
    }

    public static func accepts(
        scheduledFrames: Int,
        incomingFrames: Int,
        ceilingFrames: Int
    ) -> Bool {
        guard scheduledFrames >= 0,
              incomingFrames > 0,
              ceilingFrames > 0,
              scheduledFrames <= ceilingFrames
        else { return false }
        return incomingFrames <= ceilingFrames - scheduledFrames
    }

    public static func scheduledFrames(
        for chunks: [AudioPlayoutChunk],
        initiallyScheduledFrames: Int = 0,
        ceilingFrames: Int
    ) -> Int {
        var scheduledFrames = max(0, initiallyScheduledFrames)
        for chunk in chunks {
            let incomingFrames = frameCount(chunk)
            if accepts(
                scheduledFrames: scheduledFrames,
                incomingFrames: incomingFrames,
                ceilingFrames: ceilingFrames)
            {
                scheduledFrames += incomingFrames
            }
        }
        return scheduledFrames
    }

    public static func startupBatch(
        from chunks: [AudioPlayoutChunk],
        targetFrames: Int,
        ceilingFrames: Int
    ) -> [AudioPlayoutChunk] {
        let target = max(1, targetFrames)
        let ceiling = max(target, ceilingFrames)
        var retainedPCM = [Bool](repeating: false, count: chunks.count)
        var retainedPCMFrames = 0

        for (index, chunk) in chunks.enumerated() {
            guard case .pcm = chunk else { continue }
            let frames = frameCount(chunk)
            guard accepts(
                scheduledFrames: retainedPCMFrames,
                incomingFrames: frames,
                ceilingFrames: ceiling)
            else { continue }
            retainedPCM[index] = true
            retainedPCMFrames += frames
        }

        var silenceFramesRemaining =
            max(target, retainedPCMFrames) - retainedPCMFrames
        var output = [AudioPlayoutChunk]()
        output.reserveCapacity(chunks.count + 1)
        for (index, chunk) in chunks.enumerated() {
            switch chunk {
            case .pcm:
                if retainedPCM[index] {
                    output.append(chunk)
                }
            case .silence(let frames):
                let retainedFrames = min(
                    max(0, frames), silenceFramesRemaining)
                if retainedFrames > 0 {
                    output.append(.silence(frames: retainedFrames))
                    silenceFramesRemaining -= retainedFrames
                }
            }
        }
        if silenceFramesRemaining > 0 {
            output.append(.silence(frames: silenceFramesRemaining))
        }
        return output
    }
}

/// Sequence/sample-counter jitter queue with a bounded reorder deadline.
public struct AudioJitterBuffer: Equatable, Sendable {
    private struct Pending: Equatable, Sendable {
        let pcm: AudioProtocol.PCM
    }

    public let targetFrames: Int
    public let ceilingFrames: Int
    public let reorderWindowPackets: Int
    public let reorderTimeoutNanos: UInt64

    private var generation: UInt16?
    private var expectedSequence: UInt16?
    private var expectedSampleCounter: UInt32?
    private var pending: [UInt16: Pending] = [:]
    private var gapDeadlineNanos: UInt64?
    private var startupGapDeadlineNanos: UInt64?
    private var started = false

    public private(set) var lostFrames: UInt64 = 0
    public private(set) var latePackets: UInt64 = 0
    public private(set) var duplicatePackets: UInt64 = 0
    public private(set) var reorderedPackets: UInt64 = 0
    public private(set) var generationChanges: UInt64 = 0

    public init(
        targetFrames: Int,
        ceilingFrames: Int,
        reorderWindowPackets: Int,
        reorderTimeoutNanos: UInt64
    ) {
        let target = max(1, targetFrames)
        self.targetFrames = target
        self.ceilingFrames = max(target, ceilingFrames)
        self.reorderWindowPackets = min(max(reorderWindowPackets, 1), 64)
        self.reorderTimeoutNanos = max(1, reorderTimeoutNanos)
    }

    public var bufferedFrames: Int {
        pending.values.reduce(0) { $0 + Int($1.pcm.frameCount) }
    }

    public var contiguousBufferedFrames: Int {
        guard var sequence = expectedSequence else { return 0 }
        var frames = 0
        for _ in 0..<pending.count {
            guard let item = pending[sequence] else { break }
            frames += Int(item.pcm.frameCount)
            sequence &+= 1
        }
        return frames
    }

    public mutating func insert(
        _ pcm: AudioProtocol.PCM, nowNanos: UInt64
    ) -> [AudioPlayoutChunk] {
        if generation != pcm.streamGeneration {
            if generation != nil { generationChanges &+= 1 }
            generation = pcm.streamGeneration
            expectedSequence = pcm.sequence
            expectedSampleCounter = pcm.sampleCounter
            pending.removeAll(keepingCapacity: true)
            gapDeadlineNanos = nil
            startupGapDeadlineNanos = nil
            started = false
        }
        guard let expectedSequence else { return [] }
        let distance = Int(pcm.sequence &- expectedSequence)
        if distance >= 0x8000 {
            latePackets &+= 1
            return []
        }
        if pending[pcm.sequence] != nil {
            duplicatePackets &+= 1
            return []
        }
        if let firstMissingSequence {
            let reorderDistance = Int(pcm.sequence &- firstMissingSequence)
            if reorderDistance > 0, reorderDistance < 0x8000 {
                reorderedPackets &+= 1
            }
        }
        pending[pcm.sequence] = Pending(pcm: pcm)
        if !started {
            return startIfReady(nowNanos: nowNanos) ?? []
        }
        return drain(nowNanos: nowNanos)
    }

    public mutating func poll(nowNanos: UInt64) -> [AudioPlayoutChunk] {
        if !started {
            return startIfReady(nowNanos: nowNanos) ?? []
        }
        return drain(nowNanos: nowNanos)
    }

    public mutating func reset() {
        generation = nil
        expectedSequence = nil
        expectedSampleCounter = nil
        pending.removeAll(keepingCapacity: true)
        gapDeadlineNanos = nil
        startupGapDeadlineNanos = nil
        started = false
    }

    private var firstMissingSequence: UInt16? {
        guard var sequence = expectedSequence else { return nil }
        for _ in 0..<pending.count {
            guard pending[sequence] != nil else { break }
            sequence &+= 1
        }
        return sequence
    }

    /// Returns whether startup must resolve the observed gap before releasing
    /// audio. Nil means the target is not yet continuously playable.
    private mutating func startupReady(
        nowNanos: UInt64
    ) -> Bool? {
        let contiguousFrames = contiguousBufferedFrames
        if contiguousFrames >= targetFrames {
            startupGapDeadlineNanos = nil
            return false
        }
        guard bufferedFrames > contiguousFrames else {
            startupGapDeadlineNanos = nil
            return nil
        }
        if startupGapDeadlineNanos == nil {
            startupGapDeadlineNanos = nowNanos &+ reorderTimeoutNanos
        }
        guard let expectedSequence else { return nil }
        let farthest = pending.keys.map {
            Int($0 &- expectedSequence)
        }.filter {
            $0 < 0x8000
        }.max() ?? 0
        let expired =
            nowNanos >= (startupGapDeadlineNanos ?? UInt64.max)
            || farthest > reorderWindowPackets
            || bufferedFrames >= ceilingFrames
        return expired ? true : nil
    }

    private mutating func startIfReady(
        nowNanos: UInt64
    ) -> [AudioPlayoutChunk]? {
        guard let forceGapResolution = startupReady(
            nowNanos: nowNanos)
        else { return nil }
        let output = AudioPlayoutCeiling.startupBatch(
            from: drain(
                nowNanos: nowNanos,
                forceGapResolution: forceGapResolution),
            targetFrames: targetFrames,
            ceilingFrames: ceilingFrames)
        started = true
        startupGapDeadlineNanos = nil
        return output
    }

    private mutating func drain(
        nowNanos: UInt64,
        forceGapResolution: Bool = false
    ) -> [AudioPlayoutChunk] {
        var output = [AudioPlayoutChunk]()
        while !pending.isEmpty {
            guard let expectedSequence,
                  let expectedSampleCounter
            else { break }
            guard let item = pending.removeValue(forKey: expectedSequence) else {
                let future = pending.keys.map {
                    (distance: Int($0 &- expectedSequence), sequence: $0)
                }.filter { $0.distance < 0x8000 }
                guard let nearest = future.min(by: {
                    $0.distance < $1.distance
                }) else { break }
                let farthest = future.map(\.distance).max() ?? 0
                if gapDeadlineNanos == nil {
                    gapDeadlineNanos = nowNanos &+ reorderTimeoutNanos
                }
                let expired = forceGapResolution
                    || nowNanos >= (gapDeadlineNanos ?? UInt64.max)
                    || farthest > reorderWindowPackets
                    || bufferedFrames >= ceilingFrames
                guard expired else { break }
                self.expectedSequence = nearest.sequence
                gapDeadlineNanos = nil
                continue
            }

            let sampleDistance = item.pcm.sampleCounter &- expectedSampleCounter
            if sampleDistance > 0, sampleDistance < 0x80000000 {
                output.append(.silence(
                    frames: min(Int(sampleDistance), ceilingFrames)))
                lostFrames &+= UInt64(sampleDistance)
            } else if sampleDistance >= 0x80000000 {
                latePackets &+= 1
                self.expectedSequence = expectedSequence &+ 1
                continue
            }
            output.append(.pcm(item.pcm))
            self.expectedSampleCounter =
                item.pcm.sampleCounter &+ UInt32(item.pcm.frameCount)
            self.expectedSequence = expectedSequence &+ 1
            gapDeadlineNanos = nil
        }
        return output
    }
}

/// Rolling measured audio demand used to leave only the remaining radio
/// capacity to video. With no audio observations, video pacing is unchanged.
public struct AudioFirstRadioBudget: Equatable, Sendable {
    private struct Sample: Equatable, Sendable {
        let timestampNanos: UInt64
        let wireBytes: Int
    }

    private var tuning: AudioRuntimeTuning
    private var samples = [Sample]()

    public init(tuning: AudioRuntimeTuning) {
        self.tuning = tuning.validated
    }

    public mutating func update(tuning: AudioRuntimeTuning) {
        self.tuning = tuning.validated
    }

    public mutating func recordAudioDatagram(bytes: Int, nowNanos: UInt64) {
        guard bytes > 0 else { return }
        prune(nowNanos: nowNanos)
        let overhead = tuning.radioPacketOverheadBytes
        let wireBytes = bytes > Int.max - overhead
            ? Int.max
            : bytes + overhead
        samples.append(Sample(
            timestampNanos: nowNanos,
            wireBytes: wireBytes))
    }

    public mutating func videoSpacingNanos(
        baseSpacingMicros: UInt32,
        packetBytes: Int,
        nowNanos: UInt64
    ) -> UInt64 {
        let base = UInt64(max(1, baseSpacingMicros)) * 1_000
        prune(nowNanos: nowNanos)
        guard !samples.isEmpty, packetBytes > 0 else { return base }

        let fullVideoBytes = Double(
            TileGeometry.maxPacketBytes + tuning.radioPacketOverheadBytes)
        let baseBytesPerSecond =
            fullVideoBytes * 1_000_000 / Double(max(1, baseSpacingMicros))
        let windowSeconds = tuning.radioWindowMilliseconds / 1_000
        let packetSeconds = tuning.packetMilliseconds / 1_000
        let measuredSeconds: Double
        if let first = samples.first, let last = samples.last {
            let span = Double(last.timestampNanos &- first.timestampNanos)
                / 1_000_000_000
            measuredSeconds = min(
                windowSeconds,
                max(packetSeconds, span + packetSeconds))
        } else {
            measuredSeconds = packetSeconds
        }
        let audioBytesPerSecond =
            Double(samples.reduce(0) { $0 + $1.wireBytes })
                / measuredSeconds
        let available = baseBytesPerSecond * (1 - tuning.radioSafetyMargin)
            - audioBytesPerSecond
        let maximum = max(
            base,
            UInt64(tuning.maximumVideoDelayMilliseconds * 1_000_000))
        guard available > 0 else { return max(base, maximum) }
        let packetWireBytes =
            Double(packetBytes + tuning.radioPacketOverheadBytes)
        let required = UInt64(
            (packetWireBytes / available * 1_000_000_000).rounded(.up))
        return min(max(base, required), maximum)
    }

    private mutating func prune(nowNanos: UInt64) {
        let window = UInt64(tuning.radioWindowMilliseconds * 1_000_000)
        let cutoff = nowNanos > window ? nowNanos - window : 0
        samples.removeAll { $0.timestampNanos < cutoff }
    }
}

/// Monotonic deadline scheduler for descriptor-sized PCM packets. The same
/// drift multiplier used by the resampler scales wall-clock packet duration.
///
/// CoreAudio normally calls the tap at the requested cadence, but it may
/// deliver a larger buffer after a scheduling stall. Advancing one packet
/// deadline at a time prevents those chunks from becoming a UDP burst.
public struct AudioPacketPacer: Equatable, Sendable {
    private var nextDeadlineNanos: UInt64?
    private var fractionalDurationNanos: Double = 0

    public init() {}

    public mutating func deadlineNanos(
        nowNanos: UInt64,
        frameCount: Int,
        sampleRateHz: UInt32,
        rateMultiplier: Double = 1
    ) -> UInt64 {
        let deadline = max(nextDeadlineNanos ?? nowNanos, nowNanos)
        let multiplier = rateMultiplier.isFinite
            ? min(max(rateMultiplier, 0.5), 2)
            : 1
        let exactDuration =
            Double(max(1, frameCount))
                * 1_000_000_000
                / Double(max(1, sampleRateHz))
                * multiplier
                + fractionalDurationNanos
        let duration = max(1, UInt64(exactDuration.rounded(.down)))
        fractionalDurationNanos = exactDuration - Double(duration)
        nextDeadlineNanos = deadline &+ max(1, duration)
        return deadline
    }

    public mutating func reset() {
        nextDeadlineNanos = nil
        fractionalDurationNanos = 0
    }
}

/// Sequence accounting for the Mac's uplink jitter queue.
public struct AudioSequenceTracker: Equatable, Sendable {
    private var generation: UInt16?
    private var nextSequence: UInt16?
    public private(set) var latePackets: UInt64 = 0
    public private(set) var lostPackets: UInt64 = 0

    public init() {}

    public mutating func accept(
        sequence: UInt16, streamGeneration: UInt16
    ) -> Bool {
        if generation != streamGeneration || nextSequence == nil {
            generation = streamGeneration
            nextSequence = sequence &+ 1
            return true
        }
        guard let expected = nextSequence else { return false }
        let distance = sequence &- expected
        if distance == 0 {
            nextSequence = sequence &+ 1
            return true
        }
        if distance < 0x8000 {
            lostPackets += UInt64(distance)
            nextSequence = sequence &+ 1
            return true
        }
        latePackets += 1
        return false
    }
}
