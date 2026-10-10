import XCTest

@testable import SenderProtocol

/// The stream-channel update's packets and the sender's window.
///
/// The packet bytes are pinned to `firmware/display_stream/stream_update.h`;
/// the auth vector is the one `firmware/test/test_stream_update.cpp` pins to
/// Python hashlib, so both ends are checked against the same numbers.
final class StreamUpdateProtocolTests: XCTestCase {
    typealias P = StreamUpdateProtocol

    func testCapabilityBitMatchesFirmware() {
        XCTAssertEqual(DeviceProtocol.Capabilities.streamUpdate.rawValue, 1 << 22)
    }

    func testCRC32CheckValue() {
        XCTAssertEqual(P.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testAuthResponseMatchesTheFirmwareVector() {
        let nonce = String(repeating: "a", count: 32)
            + "0123456789abcdef0123456789abcdef"
        let cnonce = String(repeating: "f", count: 64)
        XCTAssertEqual(
            EspotaProtocol.authResponse(
                password: "correct horse battery", nonce: nonce, cnonce: cnonce),
            "12663dc3ba283763d902b9ba5c86360f4f8105f2b5b63684d282cceceb9da29c")
    }

    func testBeginLayout() {
        let sha = Data((0..<32).map { UInt8($0) })
        let packet = [UInt8](P.begin(
            session: 0x1234, imageBytes: 0x0102_0304, chunkBytes: 1440, sha256: sha))
        XCTAssertEqual(packet.count, P.beginBytes)
        XCTAssertEqual(Array(packet[0..<8]), [0x45, 0x55, 0x50, 0x42, 1, 0, 0x34, 0x12])
        XCTAssertEqual(Array(packet[8..<16]), [0x04, 0x03, 0x02, 0x01, 0xA0, 0x05, 0, 0])
        XCTAssertEqual(Array(packet[16...]), [UInt8](sha))
    }

    func testDataLayoutCarriesSequenceAndCRC() {
        let payload = Data("123456789".utf8)
        let packet = [UInt8](P.data(session: 7, seq: 0x0A0B_0C0D, payload: payload))
        XCTAssertEqual(Array(packet[0..<8]), [0x45, 0x55, 0x50, 0x44, 1, 0, 7, 0])
        XCTAssertEqual(Array(packet[8..<12]), [0x0D, 0x0C, 0x0B, 0x0A])
        XCTAssertEqual(Array(packet[12..<16]), [0x26, 0x39, 0xF4, 0xCB])
        XCTAssertEqual(Data(packet[16...]), payload)
    }

    func testAuthAndAbortLayout() {
        let cnonce = String(repeating: "1", count: 64)
        let response = String(repeating: "2", count: 64)
        let auth = [UInt8](P.auth(session: 9, cnonce: cnonce, response: response))
        XCTAssertEqual(auth.count, P.authBytes)
        XCTAssertEqual(String(decoding: auth[8..<72], as: UTF8.self), cnonce)
        XCTAssertEqual(String(decoding: auth[72..<136], as: UTF8.self), response)
        XCTAssertEqual([UInt8](P.abort(session: 9)), [0x45, 0x55, 0x50, 0x58, 1, 0, 9, 0])
    }

    func testParsesPanelReplies() {
        var ack = Data([0x45, 0x55, 0x50, 0x4B, 1, 4, 0x34, 0x12])
        ack.append(contentsOf: [7, 0, 0, 0, 39, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0x80])
        ack.append(contentsOf: [0x0F, 0x27, 0, 0])
        XCTAssertEqual(P.parse(ack), .ack(P.Ack(
            phase: 4, session: 0x1234, cumulative: 7, windowEnd: 39,
            sack: 0x8000_0000_0000_0005, bytesWritten: 9999)))

        var status = Data([0x45, 0x55, 0x50, 0x53, 1, 9, 2, 0, 3, 0, 0, 0, 5])
        status.append(Data("Wrong".utf8))
        XCTAssertEqual(P.parse(status), .status(P.StatusReply(
            code: .imageRefused, session: 2, value: 3, detail: "Wrong")))
        XCTAssertNil(P.parse(status.dropLast()), "a truncated status is refused")

        var challenge = Data([0x45, 0x55, 0x50, 0x43, 1, 0, 2, 0, 0xA0, 0x05, 0, 0])
        challenge.append(Data(String(repeating: "c", count: 64).utf8))
        XCTAssertEqual(P.parse(challenge), .challenge(P.Challenge(
            session: 2, chunkBytes: 1440, nonce: String(repeating: "c", count: 64))))
        XCTAssertNil(P.parse(Data("EPNG".utf8)))
        XCTAssertFalse(P.isUpdatePacket(Data("EINF".utf8)))
    }

    // MARK: - the window

    private func ack(
        _ cumulative: Int, sack: [Int] = [], windowEnd: Int
    ) -> P.Ack {
        var bits: UInt64 = 0
        for seq in sack { bits |= 1 << UInt64(seq - cumulative - 1) }
        return P.Ack(
            session: 1, cumulative: cumulative, windowEnd: windowEnd, sack: bits,
            bytesWritten: 0)
    }

    private func drain(_ w: inout StreamUpdateWindow, now: Double) -> [Int] {
        var sent: [Int] = []
        while let seq = w.nextToSend(now: now) {
            w.markSent(seq, now: now)
            sent.append(seq)
        }
        return sent
    }

    func testNotStopAndWait() {
        var w = StreamUpdateWindow(totalChunks: 100, receiverWindowEnd: 64)
        let first = drain(&w, now: 0)
        XCTAssertEqual(first, Array(0..<16),
            "a full initial congestion window goes out before any ack")
    }

    func testReceiverWindowCapsTheSender() {
        var config = StreamUpdateWindow.Config()
        config.initialCongestionWindow = 100
        var w = StreamUpdateWindow(totalChunks: 100, receiverWindowEnd: 10, config: config)
        XCTAssertEqual(drain(&w, now: 0).count, 10, "nothing past the panel's free slots")
        w.apply(ack(10, windowEnd: 10), now: 0.01)
        XCTAssertTrue(drain(&w, now: 0.01).isEmpty,
            "everything acked but the window closed: wait, do not resend")
        w.apply(ack(10, windowEnd: 14), now: 0.02)
        XCTAssertEqual(drain(&w, now: 0.02), [10, 11, 12, 13],
            "a window update releases exactly the slots it opened")
    }

    func testSelectiveAckResendsOnlyTheHole() {
        var w = StreamUpdateWindow(totalChunks: 40, receiverWindowEnd: 64)
        _ = drain(&w, now: 0)
        // Chunk 2 was lost; 3, 4 and 5 (sent after it) arrived.
        w.apply(ack(2, sack: [3, 4, 5], windowEnd: 64), now: 0.01)
        XCTAssertEqual(w.nextToSend(now: 0.01), 2, "the hole goes first, at once")
        w.markSent(2, now: 0.01)
        let rest = drain(&w, now: 0.01)
        XCTAssertFalse(rest.contains(3) || rest.contains(4) || rest.contains(5),
            "selectively acked chunks are never resent")
        XCTAssertEqual(w.fastRetransmits, 1)
        XCTAssertEqual(w.timeouts, 0, "no timeout was needed to find it")
    }

    func testLossHalvesTheCongestionWindowOncePerEvent() {
        var w = StreamUpdateWindow(totalChunks: 200, receiverWindowEnd: 200)
        _ = drain(&w, now: 0)
        w.apply(ack(16, windowEnd: 200), now: 0.01)  // slow start: 16 -> 32
        _ = drain(&w, now: 0.01)
        XCTAssertEqual(w.congestionWindow, 32)
        // Two holes in the same flight are one congestion event.
        w.apply(ack(17, sack: Array(18..<20) + Array(21..<30), windowEnd: 200), now: 0.02)
        XCTAssertEqual(w.fastRetransmits, 2, "both holes are found from one ack")
        // 32, plus the 12 chunks this ack covered in slow start, halved once.
        // Halving per hole would leave 11.
        XCTAssertEqual(w.congestionWindow, (32 + 12) / 2)
    }

    func testTimeoutRetransmitsWithBackoff() {
        var w = StreamUpdateWindow(totalChunks: 4, receiverWindowEnd: 64)
        _ = drain(&w, now: 0)
        let rto = w.retransmitTimeout
        XCTAssertTrue(drain(&w, now: rto * 0.5).isEmpty, "nothing resent early")
        XCTAssertEqual(drain(&w, now: rto), [0, 1, 2, 3], "every silent chunk is resent")
        XCTAssertEqual(w.timeouts, 4)
        XCTAssertEqual(w.retransmitTimeout, rto * 2, accuracy: 1e-9, "and the timer backs off")
        XCTAssertEqual(w.congestionWindow, w.config.minCongestionWindow)
        w.apply(ack(4, windowEnd: 64), now: rto + 0.01)
        XCTAssertTrue(w.isComplete)
    }

    /// Review finding: after a timeout every expired chunk was released at
    /// once, whatever the congestion window said.
    func testResendsRespectTheCongestionWindow() {
        var config = StreamUpdateWindow.Config()
        config.initialCongestionWindow = 32
        var w = StreamUpdateWindow(totalChunks: 64, receiverWindowEnd: 64, config: config)
        XCTAssertEqual(drain(&w, now: 0).count, 32)
        let resent = drain(&w, now: w.retransmitTimeout)
        XCTAssertEqual(resent, [0, 1, 2, 3],
            "a timeout collapses the window to 4 and only 4 are resent")
        XCTAssertFalse(resent.contains(32), "and no new chunk jumps the queue")
    }

    func testRTTFollowsAcks() {
        var w = StreamUpdateWindow(totalChunks: 400, receiverWindowEnd: 400)
        var now = 0.0
        var cumulative = 0
        for _ in 0..<1000 where !w.isComplete {
            _ = drain(&w, now: now)
            now += 0.010
            cumulative = min(400, cumulative + 8)
            w.apply(ack(cumulative, windowEnd: 400), now: now)
        }
        XCTAssertTrue(w.isComplete)
        XCTAssertLessThan(w.retransmitTimeout, 0.25,
            "a fast steady link brings the timeout down from its initial guess")
        XCTAssertEqual(w.retransmissions, 0, "and nothing was resent on a clean link")
    }

    /// A simulated link and panel with loss, duplication and reordering in both
    /// directions. What it pins: the exact image arrives, nothing acked is
    /// resent, and the cost of loss stays near the number of chunks lost.
    func testLossyLinkDeliversEverythingWithBoundedResends() {
        for seed in 1...6 {
            var rng = SplitMix(seed: UInt64(seed))
            let total = 1200
            let slots = 64
            var w = StreamUpdateWindow(totalChunks: total, receiverWindowEnd: slots)
            var have = Set<Int>()
            var written = 0
            var toPanel: [(at: Double, seq: Int)] = []
            var toMac: [(at: Double, ack: P.Ack)] = []
            var now = 0.0
            var dropped = 0
            var steps = 0
            func panelAck() -> P.Ack {
                var cumulative = written
                while have.contains(cumulative) { cumulative += 1 }
                var bits: UInt64 = 0
                for i in 0..<64 where have.contains(cumulative + 1 + i) {
                    bits |= 1 << UInt64(i)
                }
                return P.Ack(session: 1, cumulative: cumulative,
                             windowEnd: written + slots, sack: bits, bytesWritten: 0)
            }
            while !w.isComplete, steps < 50_000 {
                steps += 1
                if let seq = w.nextToSend(now: now) {
                    w.markSent(seq, now: now)
                    if rng.chance(0.08) {
                        dropped += 1
                    } else {
                        toPanel.append((now + 0.004 + rng.unit() * 0.004, seq))
                        if rng.chance(0.05) { toPanel.append((now + 0.009, seq)) }
                    }
                }
                now += 0.000_7
                toPanel.sort { $0.at < $1.at }
                while let first = toPanel.first, first.at <= now {
                    toPanel.removeFirst()
                    if first.seq >= written + slots || first.seq < written { continue }
                    have.insert(first.seq)
                    // Every arrival is acked; 5% of acks are lost.
                    let a = panelAck()
                    if !rng.chance(0.05) {
                        toMac.append((now + 0.003 + rng.unit() * 0.002, a))
                    }
                }
                // Flash writes about one chunk per 1.5 ms.
                if rng.chance(0.47) {
                    if have.contains(written) {
                        have.remove(written)
                        written += 1
                    }
                }
                toMac.sort { $0.at < $1.at }
                while let first = toMac.first, first.at <= now {
                    toMac.removeFirst()
                    w.apply(first.ack, now: now)
                }
                if toMac.isEmpty, toPanel.isEmpty, w.nextToSend(now: now) == nil {
                    // Keepalive ack every 100 ms, as the panel sends.
                    if Int(now * 1000) % 100 == 0 {
                        toMac.append((now + 0.003, panelAck()))
                    }
                }
            }
            XCTAssertTrue(w.isComplete, "seed \(seed): the transfer completes")
            XCTAssertEqual((0..<total).filter { !w.isAcked($0) }.count, 0,
                "seed \(seed): every chunk acknowledged")
            XCTAssertLessThan(w.retransmissions, dropped * 3 + 40,
                "seed \(seed): \(w.retransmissions) resends for \(dropped) losses")
            XCTAssertLessThan(now, 6.0,
                "seed \(seed): 1200 chunks over 8% loss in \(now) s of simulated time")
        }
    }
}

/// A deterministic generator so a failure reproduces.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}
