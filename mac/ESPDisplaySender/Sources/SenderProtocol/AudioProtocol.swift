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
    public var uplinkTargetMilliseconds: Double
    public var uplinkCeilingMilliseconds: Double
    public var statusPublishMilliseconds: Double
    public var panelClockPPM: Double
    public var macClockPPM: Double
    public var estimatorErrorPPM: Double
    public var correctionMargin: Double

    public init(
        packetMilliseconds: Double = 20,
        downlinkTargetMilliseconds: Double = 150,
        downlinkCeilingMilliseconds: Double = 220,
        uplinkTargetMilliseconds: Double = 80,
        uplinkCeilingMilliseconds: Double = 120,
        statusPublishMilliseconds: Double = 250,
        panelClockPPM: Double = 50,
        macClockPPM: Double = 100,
        estimatorErrorPPM: Double = 50,
        correctionMargin: Double = 2
    ) {
        self.packetMilliseconds = packetMilliseconds
        self.downlinkTargetMilliseconds = downlinkTargetMilliseconds
        self.downlinkCeilingMilliseconds = downlinkCeilingMilliseconds
        self.uplinkTargetMilliseconds = uplinkTargetMilliseconds
        self.uplinkCeilingMilliseconds = uplinkCeilingMilliseconds
        self.statusPublishMilliseconds = statusPublishMilliseconds
        self.panelClockPPM = panelClockPPM
        self.macClockPPM = macClockPPM
        self.estimatorErrorPPM = estimatorErrorPPM
        self.correctionMargin = correctionMargin
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
        return AudioRuntimeTuning(
            packetMilliseconds: Self.clamp(
                packetMilliseconds, lower: 1, upper: 100),
            downlinkTargetMilliseconds: downlinkTarget,
            downlinkCeilingMilliseconds: Self.clamp(
                downlinkCeilingMilliseconds,
                lower: downlinkTarget,
                upper: 2_000),
            uplinkTargetMilliseconds: uplinkTarget,
            uplinkCeilingMilliseconds: Self.clamp(
                uplinkCeilingMilliseconds,
                lower: uplinkTarget,
                upper: 2_000),
            statusPublishMilliseconds: Self.clamp(
                statusPublishMilliseconds, lower: 50, upper: 5_000),
            panelClockPPM: Self.clamp(
                abs(panelClockPPM), lower: 1, upper: 2_000),
            macClockPPM: Self.clamp(
                abs(macClockPPM), lower: 1, upper: 2_000),
            estimatorErrorPPM: Self.clamp(
                abs(estimatorErrorPPM), lower: 1, upper: 2_000),
            correctionMargin: Self.clamp(
                correctionMargin, lower: 1, upper: 10))
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
}

/// Monotonic deadline scheduler for descriptor-sized PCM packets.
///
/// CoreAudio normally calls the tap at the requested cadence, but it may
/// deliver a larger buffer after a scheduling stall. Advancing one packet
/// deadline at a time prevents those chunks from becoming a UDP burst.
public struct AudioPacketPacer: Equatable, Sendable {
    private var nextDeadlineNanos: UInt64?

    public init() {}

    public mutating func deadlineNanos(
        nowNanos: UInt64,
        frameCount: Int,
        sampleRateHz: UInt32
    ) -> UInt64 {
        let deadline = max(nextDeadlineNanos ?? nowNanos, nowNanos)
        let duration = UInt64(max(1, frameCount)) * 1_000_000_000
            / UInt64(max(1, sampleRateHz))
        nextDeadlineNanos = deadline &+ max(1, duration)
        return deadline
    }

    public mutating func reset() {
        nextDeadlineNanos = nil
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
