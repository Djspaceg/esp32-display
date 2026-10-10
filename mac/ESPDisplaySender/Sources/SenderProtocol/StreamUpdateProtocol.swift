import CryptoKit
import Foundation

/// Firmware update over the stream channel: the packets, byte for byte as
/// `firmware/display_stream/stream_update.h` writes and reads them.
///
/// WHY THIS EXISTS. ArduinoOTA has the panel open a TCP connection back to the
/// Mac, and a Mac whose firewall drops connections the LAN starts can never be
/// updated that way. These packets ride the UDP flow the Mac already opened to
/// stream frames, which the firewall lets the panel answer.
///
/// Authentication is ArduinoOTA's challenge unchanged: the panel sends a
/// 64-hex nonce and checks `EspotaProtocol.authResponse` for it.
public enum StreamUpdateProtocol {
    public static let version: UInt8 = 1
    public static let beginBytes = 48
    public static let authBytes = 136
    public static let dataHeaderBytes = 16
    public static let abortBytes = 8
    public static let challengeBytes = 76
    public static let ackBytes = 28
    public static let statusHeaderBytes = 13
    public static let statusDetailMax = 48
    /// 1440 + 16 = 1456 bytes on the wire, under the 1472 every frame keeps to.
    public static let maxChunkBytes = 1440
    public static let sackBits = 64

    public enum Status: UInt8, Sendable, Equatable {
        case authAccepted = 1
        case authRefused = 2
        case busy = 3
        case notConfigured = 4
        case badRequest = 5
        case beginFailed = 6
        case writeFailed = 7
        case hashMismatch = 8
        case imageRefused = 9
        case activated = 10
        case aborted = 11
        case unknownSession = 12
    }

    public struct Challenge: Equatable, Sendable {
        public let session: UInt16
        public let chunkBytes: Int
        public let nonce: String
    }

    public struct Ack: Equatable, Sendable {
        public let phase: UInt8
        public let session: UInt16
        /// The first sequence number the panel does not have.
        public let cumulative: Int
        /// The first sequence number the panel will not accept yet.
        public let windowEnd: Int
        /// Bit i: the panel has `cumulative + 1 + i`.
        public let sack: UInt64
        public let bytesWritten: Int

        public init(
            phase: UInt8 = 4, session: UInt16, cumulative: Int, windowEnd: Int,
            sack: UInt64, bytesWritten: Int
        ) {
            self.phase = phase
            self.session = session
            self.cumulative = cumulative
            self.windowEnd = windowEnd
            self.sack = sack
            self.bytesWritten = bytesWritten
        }
    }

    public struct StatusReply: Equatable, Sendable {
        public let code: Status
        public let session: UInt16
        public let value: UInt32
        public let detail: String
    }

    public enum Reply: Equatable, Sendable {
        case challenge(Challenge)
        case ack(Ack)
        case status(StatusReply)
    }

    /// Whether a datagram from the panel belongs to an update at all.
    public static func isUpdatePacket(_ data: Data) -> Bool {
        data.count >= 4 && data.starts(with: [0x45, 0x55, 0x50])  // "EUP"
    }

    // MARK: - Mac to panel

    public static func begin(
        session: UInt16, imageBytes: Int, chunkBytes: Int, sha256: Data
    ) -> Data {
        var out = head("B", byte5: 0, session: session)
        appendU32(&out, UInt32(imageBytes))
        appendU16(&out, UInt16(chunkBytes))
        appendU16(&out, 0)
        out.append(sha256.prefix(32))
        return out
    }

    public static func auth(session: UInt16, cnonce: String, response: String) -> Data {
        var out = head("A", byte5: 0, session: session)
        out.append(Data(cnonce.utf8))
        out.append(Data(response.utf8))
        return out
    }

    public static func data(session: UInt16, seq: Int, payload: Data) -> Data {
        var out = head("D", byte5: 0, session: session)
        appendU32(&out, UInt32(seq))
        appendU32(&out, crc32(payload))
        out.append(payload)
        return out
    }

    public static func abort(session: UInt16) -> Data {
        head("X", byte5: 0, session: session)
    }

    // MARK: - panel to Mac

    public static func parse(_ data: Data) -> Reply? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0] == 0x45, bytes[1] == 0x55, bytes[2] == 0x50,
              bytes[4] == version
        else { return nil }
        let session = u16(bytes, 6)
        switch bytes[3] {
        case UInt8(ascii: "C"):
            guard bytes.count == challengeBytes else { return nil }
            let nonce = String(decoding: bytes[12..<76], as: UTF8.self)
            return .challenge(Challenge(
                session: session, chunkBytes: Int(u16(bytes, 8)), nonce: nonce))
        case UInt8(ascii: "K"):
            guard bytes.count == ackBytes else { return nil }
            let sack = UInt64(u32(bytes, 16)) | (UInt64(u32(bytes, 20)) << 32)
            return .ack(Ack(
                phase: bytes[5], session: session, cumulative: Int(u32(bytes, 8)),
                windowEnd: Int(u32(bytes, 12)), sack: sack,
                bytesWritten: Int(u32(bytes, 24))))
        case UInt8(ascii: "S"):
            guard bytes.count >= statusHeaderBytes,
                  let code = Status(rawValue: bytes[5])
            else { return nil }
            let n = Int(bytes[12])
            guard n <= statusDetailMax, bytes.count == statusHeaderBytes + n else {
                return nil
            }
            let detail = String(
                decoding: bytes[statusHeaderBytes..<(statusHeaderBytes + n)],
                as: UTF8.self)
            return .status(StatusReply(
                code: code, session: session, value: u32(bytes, 8), detail: detail))
        default:
            return nil
        }
    }

    // MARK: - helpers

    /// IEEE CRC-32, the zlib one, as the panel computes it per chunk.
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return ~crc
    }

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func head(_ kind: Character, byte5: UInt8, session: UInt16) -> Data {
        var out = Data([0x45, 0x55, 0x50, kind.asciiValue!, version, byte5])
        appendU16(&out, session)
        return out
    }

    private static func appendU16(_ out: inout Data, _ v: UInt16) {
        out.append(UInt8(v & 0xFF))
        out.append(UInt8(v >> 8))
    }

    private static func appendU32(_ out: inout Data, _ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8((v >> shift) & 0xFF)) }
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16)
            | (UInt32(b[i + 3]) << 24)
    }
}

/// The sender's sliding window: which chunk goes next, and when one is lost.
///
/// Pure, so tests drive it with their own clock and their own lossy link. Not
/// stop-and-wait: up to `min(cwnd, receiver window)` chunks are in flight.
///
/// - The receiver window is the panel's: `windowEnd` from its last ack is the
///   first sequence number it has no slot for, so a flash erase stall closes
///   it and nothing is sent into a buffer that would drop it.
/// - A chunk is lost when `lossThreshold` chunks sent after it have been acked
///   (the selective bits make that visible at once), or when it has gone
///   unacknowledged for the retransmit timeout. Only lost chunks are resent;
///   an acked chunk never is.
/// - The congestion window grows per acked chunk and halves on a loss, at most
///   once per window of data, so a burst of losses does not collapse it.
public struct StreamUpdateWindow: Sendable {
    public struct Config: Sendable, Equatable {
        public var maxInFlight = 128
        public var initialCongestionWindow = 16.0
        public var minCongestionWindow = 4.0
        public var lossThreshold = 3
        public var initialRTO: Double = 0.25
        /// Loss is found from the selective bits long before this; the floor
        /// is for a panel inside a flash block erase, which stalls its acks
        /// for a hundred milliseconds or more without anything being lost.
        public var minRTO: Double = 0.15
        public var maxRTO: Double = 2.0
        public init() {}
    }

    public let totalChunks: Int
    public let config: Config
    public private(set) var cumulative = 0
    public private(set) var receiverWindowEnd: Int
    public private(set) var congestionWindow: Double

    public private(set) var transmissions = 0
    public private(set) var retransmissions = 0
    public private(set) var timeouts = 0
    public private(set) var fastRetransmits = 0

    private var acked: [Bool]
    private var sentAt: [Double]
    private var sendOrder: [UInt64]
    private var sendCount: [Int]
    private var lost: Set<Int> = []
    private var nextNew = 0
    private var orderCounter: UInt64 = 0
    private var slowStartThreshold = Double.infinity
    private var reductionOrder: UInt64 = 0
    private var smoothedRTT: Double?
    private var rttVariance: Double = 0
    private var backoff: Double = 1

    public init(totalChunks: Int, receiverWindowEnd: Int, config: Config = Config()) {
        self.totalChunks = totalChunks
        self.config = config
        self.receiverWindowEnd = receiverWindowEnd
        self.congestionWindow = config.initialCongestionWindow
        acked = Array(repeating: false, count: totalChunks)
        sentAt = Array(repeating: 0, count: totalChunks)
        sendOrder = Array(repeating: 0, count: totalChunks)
        sendCount = Array(repeating: 0, count: totalChunks)
    }

    public var isComplete: Bool { cumulative >= totalChunks }

    /// Sent, not acknowledged, and not yet judged lost.
    public var inFlight: Int {
        var n = 0
        for seq in cumulative..<nextNew where !acked[seq] && !lost.contains(seq) { n += 1 }
        return n
    }

    public var retransmitTimeout: Double {
        let base = smoothedRTT.map { $0 + 4 * rttVariance } ?? config.initialRTO
        return min(config.maxRTO, max(config.minRTO, base) * backoff)
    }

    public func isAcked(_ seq: Int) -> Bool { acked[seq] }

    /// The next chunk to put on the wire, or nil when the window is full.
    public mutating func nextToSend(now: Double) -> Int? {
        expireTimeouts(now: now)
        let limit = min(Double(config.maxInFlight), congestionWindow)
        // Resends count against the congestion window like anything else:
        // after a timeout the window is 4, and 4 is what goes out.
        if Double(inFlight) < limit, let seq = lost.min() {
            lost.remove(seq)
            retransmissions += 1
            return seq
        }
        if lost.isEmpty, nextNew < totalChunks, nextNew < receiverWindowEnd, Double(inFlight) < limit {
            let seq = nextNew
            nextNew += 1
            return seq
        }
        return nil
    }

    public mutating func markSent(_ seq: Int, now: Double) {
        orderCounter += 1
        sendOrder[seq] = orderCounter
        sentAt[seq] = now
        sendCount[seq] += 1
        transmissions += 1
    }

    /// When the earliest outstanding chunk times out, if any is outstanding.
    public func nextDeadline() -> Double? {
        var earliest: Double?
        for seq in cumulative..<nextNew where !acked[seq] && !lost.contains(seq) {
            let deadline = sentAt[seq] + retransmitTimeout
            if earliest == nil || deadline < earliest! { earliest = deadline }
        }
        return earliest
    }

    public mutating func apply(_ ack: StreamUpdateProtocol.Ack, now: Double) {
        receiverWindowEnd = max(receiverWindowEnd, ack.windowEnd)
        var newlyAcked = 0
        var sample: Double?
        func mark(_ seq: Int) {
            guard seq >= 0, seq < totalChunks, seq < nextNew, !acked[seq] else { return }
            acked[seq] = true
            lost.remove(seq)
            newlyAcked += 1
            if sendCount[seq] == 1 { sample = now - sentAt[seq] }  // Karn
        }
        let upTo = min(ack.cumulative, totalChunks)
        if upTo > cumulative {
            for seq in cumulative..<upTo { mark(seq) }
        }
        for bit in 0..<StreamUpdateProtocol.sackBits where ack.sack & (1 << UInt64(bit)) != 0 {
            mark(ack.cumulative + 1 + bit)
        }
        while cumulative < totalChunks, acked[cumulative] { cumulative += 1 }
        if let sample { noteRTT(sample) }
        if newlyAcked > 0 {
            backoff = 1
            grow(by: newlyAcked)
        }
        detectLosses()
    }

    // MARK: - private

    private mutating func noteRTT(_ sample: Double) {
        if let srtt = smoothedRTT {
            rttVariance = 0.75 * rttVariance + 0.25 * abs(srtt - sample)
            smoothedRTT = 0.875 * srtt + 0.125 * sample
        } else {
            smoothedRTT = sample
            rttVariance = sample / 2
        }
    }

    private mutating func grow(by chunks: Int) {
        let cap = Double(config.maxInFlight)
        if congestionWindow < slowStartThreshold {
            congestionWindow = min(cap, congestionWindow + Double(chunks))
        } else {
            congestionWindow = min(cap, congestionWindow + Double(chunks) / congestionWindow)
        }
    }

    private mutating func reduce(atOrder order: UInt64, timeout: Bool) {
        // One reduction per window: losses from chunks sent before the last
        // reduction are the same congestion event.
        guard order > reductionOrder else { return }
        reductionOrder = orderCounter
        slowStartThreshold = max(config.minCongestionWindow, congestionWindow / 2)
        congestionWindow = timeout ? config.minCongestionWindow : slowStartThreshold
    }

    private mutating func detectLosses() {
        guard nextNew > cumulative else { return }
        for seq in cumulative..<nextNew where !acked[seq] && !lost.contains(seq) {
            let order = sendOrder[seq]
            var laterAcked = 0
            for other in cumulative..<nextNew where acked[other] && sendOrder[other] > order {
                laterAcked += 1
                if laterAcked >= config.lossThreshold { break }
            }
            if laterAcked >= config.lossThreshold {
                lost.insert(seq)
                fastRetransmits += 1
                reduce(atOrder: order, timeout: false)
            }
        }
    }

    private mutating func expireTimeouts(now: Double) {
        guard nextNew > cumulative else { return }
        let rto = retransmitTimeout
        var fired = false
        for seq in cumulative..<nextNew where !acked[seq] && !lost.contains(seq) {
            if now - sentAt[seq] >= rto {
                lost.insert(seq)
                timeouts += 1
                reduce(atOrder: sendOrder[seq], timeout: true)
                fired = true
            }
        }
        if fired { backoff = min(backoff * 2, 16) }
    }
}
