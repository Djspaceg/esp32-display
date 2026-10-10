import CryptoKit
import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// The stream-channel push end to end against a simulated panel that loses,
/// duplicates and reorders datagrams in both directions.
///
/// The fake panel is written from `stream_update.h`'s rules, not from the
/// pusher: it refuses data before the password, files chunks by sequence
/// into a slot window, acknowledges cumulatively with selective bits, checks
/// each chunk's CRC and the image's SHA-256 before saying it activated.
final class StreamFirmwarePusherTests: XCTestCase {
    private static let password = "correct horse battery"

    private static func image(bytes: Int) -> Data {
        var rng = SplitMixCore(seed: UInt64(bytes))
        return Data((0..<bytes).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
    }

    private static let fast: StreamFirmwarePusher.Timing = {
        var t = StreamFirmwarePusher.Timing()
        t.beginAttempts = 3
        t.beginReplyWait = 0.2
        t.authTimeout = 3
        t.authResendInterval = 0.3
        t.stallTimeout = 3
        t.resultTimeout = 3
        t.resultPollInterval = 0.1
        return t
    }()

    func testDeliversTheImageOverALossyLink() async throws {
        let image = Self.image(bytes: 300_000)
        let panel = FakeStreamPanel(password: Self.password, loss: 0.05, duplication: 0.03)
        let pusher = StreamFirmwarePusher(link: panel, timing: Self.fast)
        let seen = ProgressLog()
        let measured = try await pusher.push(
            image: image, filename: "p4.bin", to: "192.0.2.1",
            password: Self.password) { seen.add($0) }
        XCTAssertEqual(panel.flashed, image, "the panel wrote the exact image")
        XCTAssertEqual(panel.activations, 1)
        XCTAssertEqual(panel.dataBeforeAuth, 0, "no chunk went out before the password")
        XCTAssertGreaterThan(panel.maxInFlight, 2, "not stop-and-wait: the sender ran ahead of the panel")
        print("stream push over the lossy fake: \(measured.summary), timeouts \(measured.timeouts)")
        XCTAssertGreaterThan(measured.retransmissions, 0, "the run really lost chunks")
        XCTAssertEqual(measured.imageBytes, image.count)
        XCTAssertGreaterThan(measured.megabytesPerSecond, 0)
        XCTAssertTrue(seen.all.contains(.authenticating))
        XCTAssertTrue(seen.all.contains(.sending(bytesSent: image.count, of: image.count)))
        XCTAssertEqual(seen.all.last, .finishing)
    }

    /// Review finding: the verdict can overtake the last acks. It used to be
    /// ignored, and an activated panel was reported as having kept its firmware.
    func testActivationWithoutTheFinalAcksIsSuccess() async throws {
        let image = Self.image(bytes: 30_000)
        let panel = FakeStreamPanel(password: Self.password)
        panel.loseFinalAcks = true
        let pusher = StreamFirmwarePusher(link: panel, timing: Self.fast)
        _ = try await pusher.push(
            image: image, filename: "p4.bin", to: "192.0.2.1",
            password: Self.password) { _ in }
        XCTAssertEqual(panel.activations, 1)
    }

    /// Review finding: a lost verdict followed by the restart read as "kept
    /// the firmware it booted".
    func testRestartWithoutVerdictIsNotReportedAsKeptFirmware() async {
        let panel = FakeStreamPanel(password: Self.password)
        panel.loseVerdictAndRestart = true
        let pusher = StreamFirmwarePusher(link: panel, timing: Self.fast)
        do {
            _ = try await pusher.push(
                image: Self.image(bytes: 20_000), filename: "p4.bin", to: "192.0.2.1",
                password: Self.password) { _ in }
            XCTFail("an unconfirmed result is not a success")
        } catch {
            XCTAssertEqual(
                error as? StreamFirmwarePusher.Failure, .restartedBeforeConfirming)
            XCTAssertFalse(error.localizedDescription.contains("keeps running"))
        }
    }

    /// Round-two finding: a panel that restarted with chunks still unwritten
    /// was reported as "only restarts after a successful update".
    func testRestartMidTransferMakesNoClaimOfSuccess() async {
        let panel = FakeStreamPanel(password: Self.password)
        panel.forgetAfterWritten = 18  // of 21
        let pusher = StreamFirmwarePusher(link: panel, timing: Self.fast)
        do {
            _ = try await pusher.push(
                image: Self.image(bytes: 30_000), filename: "p4.bin", to: "192.0.2.1",
                password: Self.password) { _ in }
            XCTFail("a panel that forgot the update mid-transfer is not a success")
        } catch {
            XCTAssertEqual(error as? StreamFirmwarePusher.Failure, .panelForgotSession)
            XCTAssertFalse(error.localizedDescription.contains("successful update"))
        }
        XCTAssertEqual(panel.activations, 0)
    }

    func testWrongPasswordIsItsOwnError() async {
        let panel = FakeStreamPanel(password: "a different one")
        let pusher = StreamFirmwarePusher(link: panel, timing: Self.fast)
        do {
            _ = try await pusher.push(
                image: Self.image(bytes: 5_000), filename: "p4.bin", to: "192.0.2.1",
                password: Self.password) { _ in }
            XCTFail("a wrong password must not succeed")
        } catch {
            XCTAssertEqual(error as? StreamFirmwarePusher.Failure, .authenticationFailed)
            XCTAssertEqual(error.localizedDescription, "The panel rejected the password.")
        }
        XCTAssertTrue(panel.flashed.isEmpty)
    }

    func testHashMismatchIsReportedAndNeverActivates() async {
        let panel = FakeStreamPanel(password: Self.password)
        panel.corruptSilently = true
        let pusher = StreamFirmwarePusher(link: panel, timing: Self.fast)
        do {
            _ = try await pusher.push(
                image: Self.image(bytes: 20_000), filename: "p4.bin", to: "192.0.2.1",
                password: Self.password) { _ in }
            XCTFail("a mismatched image must not succeed")
        } catch {
            XCTAssertEqual(error as? StreamFirmwarePusher.Failure, .hashMismatch)
        }
        XCTAssertEqual(panel.activations, 0)
    }

    func testSilentPanelFailsWithoutHanging() async {
        let panel = FakeStreamPanel(password: Self.password)
        panel.silent = true
        let pusher = StreamFirmwarePusher(link: panel, timing: Self.fast)
        do {
            _ = try await pusher.push(
                image: Self.image(bytes: 5_000), filename: "p4.bin", to: "192.0.2.1",
                password: Self.password) { _ in }
            XCTFail("a silent panel must not succeed")
        } catch {
            XCTAssertEqual(error as? StreamFirmwarePusher.Failure, .noReplyToBegin(attempts: 3))
        }
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [FirmwarePusher.Progress] = []
    func add(_ p: FirmwarePusher.Progress) { lock.withLock { items.append(p) } }
    var all: [FirmwarePusher.Progress] { lock.withLock { items } }
}

private struct SplitMixCore {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func chance(_ p: Double) -> Bool { Double(next() >> 11) / Double(1 << 53) < p }
}

/// The panel's side of `stream_update.h`, small enough to read in one go.
private final class FakeStreamPanel: StreamUpdateLink, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "fake-stream-panel")
    private var handler: ((Data) -> Void)?
    private var rng = SplitMixCore(seed: 42)
    private let password: String
    private let loss: Double
    private let duplication: Double
    private let slots = 48
    private let nonce = String(repeating: "5a", count: 32)

    var silent = false
    var corruptSilently = false
    /// The last acks never arrive; only the verdict does.
    var loseFinalAcks = false
    /// The verdict never arrives, and the panel restarts (forgets the session).
    var loseVerdictAndRestart = false
    /// The panel restarts after writing this many chunks: from then on it
    /// knows no session, as a rebooted panel does.
    var forgetAfterWritten: Int?
    private var forgotten = false
    private(set) var flashed = Data()
    private(set) var activations = 0
    private(set) var dataBeforeAuth = 0
    private(set) var maxInFlight = 0

    private var session: UInt16 = 0
    private var imageBytes = 0
    private var chunkBytes = 0
    private var expected = Data()
    private var authed = false
    private var filed: [Int: Data] = [:]
    private var written = 0
    private var done = false

    init(password: String, loss: Double = 0, duplication: Double = 0) {
        self.password = password
        self.loss = loss
        self.duplication = duplication
    }

    func setUpdatePacketHandler(_ handler: ((Data) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    func sendUpdatePacket(_ data: Data) {
        let (drop, dup) = lock.withLock { (rng.chance(loss), rng.chance(duplication)) }
        if silent || drop { return }
        queue.async { self.receive(data) }
        if dup { queue.asyncAfter(deadline: .now() + 0.002) { self.receive(data) } }
    }

    private func reply(_ data: Data) {
        let (drop, h) = lock.withLock { (rng.chance(loss), handler) }
        if drop { return }
        queue.asyncAfter(deadline: .now() + 0.001) { h?(data) }
    }

    private func status(_ code: UInt8, value: UInt32 = 0, _ detail: String = "") {
        var out = Data([0x45, 0x55, 0x50, 0x53, 1, code, UInt8(session & 0xFF), UInt8(session >> 8)])
        for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8((value >> UInt32(shift)) & 0xFF)) }
        out.append(UInt8(detail.utf8.count))
        out.append(Data(detail.utf8))
        reply(out)
    }

    private func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    private func u32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
    }

    private func receive(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 8, b[0] == 0x45, b[1] == 0x55, b[2] == 0x50 else { return }
        switch b[3] {
        case UInt8(ascii: "B"):
            session = UInt16(u16(b, 6))
            imageBytes = u32(b, 8)
            chunkBytes = u16(b, 12)
            expected = Data(b[16..<48])
            var out = Data([0x45, 0x55, 0x50, 0x43, 1, 0, b[6], b[7], b[12], b[13], 0, 0])
            out.append(Data(nonce.utf8))
            reply(out)
        case UInt8(ascii: "A"):
            let cnonce = String(decoding: b[8..<72], as: UTF8.self)
            let response = String(decoding: b[72..<136], as: UTF8.self)
            let want = EspotaProtocol.authResponse(
                password: password, nonce: nonce, cnonce: cnonce)
            // The cnonce must commit to the image BEGIN named, as on the panel.
            let imageHex = expected.map { String(format: "%02x", $0) }.joined()
            let bound = cnonce == EspotaProtocol.sha256Hex("\(imageHex):\(nonce)")
            if response == want && bound {
                authed = true
                status(1, value: UInt32(written + slots))
            } else {
                status(2, "Authentication Failed")
            }
        case UInt8(ascii: "D"):
            if forgotten { status(12, "no such update session"); return }
            guard authed else { dataBeforeAuth += 1; return }
            if done {
                if loseVerdictAndRestart { status(12, "no such update session"); return }
                status(corruptSilently ? 8 : 10)
                return
            }
            let seq = u32(b, 8)
            let payload = Data(b[16...])
            guard UInt32(truncatingIfNeeded: u32(b, 12)) == StreamUpdateProtocol.crc32(payload)
            else { return }
            if seq >= written, seq < written + slots { filed[seq] = payload }
            if seq >= written {
            // How far ahead of the panel's first missing chunk the sender
            // ran: stop-and-wait would never exceed 1.
            maxInFlight = max(maxInFlight, seq - written + 1)
            }
            // Flash keeps up instantly in this model; the window still bounds it.
            while let next = filed[written] {
                filed[written] = nil
                flashed.append(corruptSilently && written == 0 ? Data(next.reversed()) : next)
                written += 1
            }
            let total = (imageBytes + chunkBytes - 1) / max(1, chunkBytes)
            if let limit = forgetAfterWritten, written >= limit {
                forgotten = true
                return
            }
            if !(loseFinalAcks && written == total) { sendAck() }
            if written == total && !done {
                done = true
                let digest = Data(SHA256.hash(data: flashed))
                if digest == expected {
                    activations += 1
                    if !loseVerdictAndRestart { status(10, value: UInt32(imageBytes)) }
                } else {
                    status(8, "image SHA-256 differs")
                }
            }
        default:
            return
        }
    }

    private func sendAck() {
        var bits: UInt64 = 0
        for i in 0..<64 where filed[written + 1 + i] != nil { bits |= 1 << UInt64(i) }
        var out = Data([0x45, 0x55, 0x50, 0x4B, 1, 4, UInt8(session & 0xFF), UInt8(session >> 8)])
        func u32(_ v: UInt64) { for s in stride(from: 0, to: 32, by: 8) { out.append(UInt8((v >> UInt64(s)) & 0xFF)) } }
        u32(UInt64(written))
        u32(UInt64(written + slots))
        u32(bits & 0xFFFF_FFFF)
        u32(bits >> 32)
        u32(UInt64(flashed.count))
        reply(out)
    }
}
