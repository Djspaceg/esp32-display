import Network
import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// The push itself, driven against a fake panel over loopback.
///
/// WHAT THIS IS AND IS NOT. No ESP32 board is attached to this machine, so a real
/// push is **UNVERIFIED** and stays that way. What is verified here is the part
/// that is otherwise only described in comments: that the listener comes up and
/// its port travels in the invitation, that the panel's reply is read, that the
/// challenge is answered in the shape the panel parses, that the panel's
/// connection BACK to this Mac is accepted, that the image arrives byte for byte
/// in 1024-byte chunks, and that a wrong password and a refusal come back as
/// their own errors rather than as a timeout.
///
/// The fake panel is written from `ArduinoOTA.cpp`, not from `FirmwarePusher`: it
/// replies with a decimal byte count per write and a separate `OK` only at the
/// end, which is the behaviour the pusher's chunk classifier exists for. It
/// verifies the response with `EspotaProtocol` rather than independently -
/// `EspotaProtocolTests` is where that arithmetic is checked against python3's
/// hashlib, and repeating the oracle here would prove nothing new.
final class FirmwarePusherTests: XCTestCase {

    /// The happy path, end to end: invitation, challenge, response, connect back,
    /// transfer, final OK.
    func testPushDeliversTheImage() async throws {
        let image = Self.image(bytes: 2_600)
        let panel = try FakePanel(password: "a-real-password")
        defer { panel.stop() }
        var lastSent = 0
        var sawWaitingForPanel = false

        try await FirmwarePusher(otaPort: panel.port).push(
            image: image, filename: "display_stream.ino.bin",
            to: "127.0.0.1", password: "a-real-password"
        ) { update in
            switch update {
            case .waitingForPanel: sawWaitingForPanel = true
            case .sending(let sent, _): lastSent = max(lastSent, sent)
            default: break
            }
        }

        XCTAssertEqual(panel.receivedImage, image, "the image arrived byte for byte")
        XCTAssertEqual(lastSent, image.count, "progress reached every byte")
        XCTAssertTrue(sawWaitingForPanel)
        // 2600 bytes is three chunks: 1024, 1024, 552. The panel counts the
        // writes it was asked to make, so this is also a check that the transfer
        // is chunked rather than sent in one go.
        XCTAssertEqual(panel.chunkSizes, [1024, 1024, 552])
    }

    /// Progress is throttled by bytes, not by chunks, and still lands exactly on
    /// the total.
    ///
    /// The endpoints are what a progress bar is judged on - a bar that stops at
    /// 97% is a bug report - so both are pinned, and the count is bounded well
    /// under one report per chunk.
    func testProgressIsThrottledButStillReachesEveryByte() async throws {
        let bytes = 200_000
        let image = Self.image(bytes: bytes)
        let panel = try FakePanel(password: "a-real-password")
        defer { panel.stop() }
        var sends: [Int] = []

        try await FirmwarePusher(otaPort: panel.port).push(
            image: image, filename: "display_stream.ino.bin",
            to: "127.0.0.1", password: "a-real-password"
        ) { update in
            if case .sending(let sent, let total) = update {
                XCTAssertEqual(total, bytes)
                sends.append(sent)
            }
        }

        let chunks = (bytes + EspotaProtocol.chunkBytes - 1) / EspotaProtocol.chunkBytes
        XCTAssertEqual(sends.first, 0, "the bar starts at zero")
        XCTAssertEqual(sends.last, bytes, "and finishes on the last byte")
        XCTAssertEqual(sends, sends.sorted(), "and never goes backwards")
        // 200000 bytes is 196 chunks but only three 64KiB thresholds, so five
        // reports at the outside. The point is the ratio, not the exact number.
        XCTAssertLessThanOrEqual(sends.count, 6, "got \(sends.count) for \(chunks) chunks")
    }

    /// The invitation is what carries the listener's port, and the panel dials
    /// back to it. If the port were wrong nothing would connect, so this asserts
    /// the field rather than inferring it from the transfer working.
    func testInvitationCarriesTheListenerPortAndTheImageDigest() async throws {
        let image = Self.image(bytes: 1_500)
        let panel = try FakePanel(password: "a-real-password")
        defer { panel.stop() }

        try await FirmwarePusher(otaPort: panel.port).push(
            image: image, filename: "display_stream.ino.bin",
            to: "127.0.0.1", password: "a-real-password") { _ in }

        let invitation = try XCTUnwrap(panel.invitation)
        let fields = invitation.trimmingCharacters(in: .newlines)
            .split(separator: " ").map(String.init)
        XCTAssertEqual(fields.count, 4)
        XCTAssertEqual(fields[0], "0", "FLASH")
        XCTAssertEqual(
            fields[1], String(panel.dialledBackPort ?? 0),
            "the port in the invitation is the one the panel connected back to")
        XCTAssertEqual(fields[2], String(image.count))
        XCTAssertEqual(fields[3], EspotaProtocol.md5Hex(image))
        // And the auth line the panel parsed: two 64-character hex fields, which
        // is what ArduinoOTA.cpp:272 requires of them.
        XCTAssertEqual(panel.receivedCnonce?.count, 64)
        XCTAssertEqual(panel.receivedResponse?.count, 64)
    }

    /// A panel with no password at all: the reply is `OK` and the transfer starts
    /// without an auth exchange. Not reachable through the UI - a panel in that
    /// state does not advertise CAP_OTA - but it is the protocol's other branch.
    func testPushWithoutAPasswordSkipsAuthentication() async throws {
        let image = Self.image(bytes: 900)
        let panel = try FakePanel(password: nil)
        defer { panel.stop() }

        try await FirmwarePusher(otaPort: panel.port).push(
            image: image, filename: "display_stream.ino.bin",
            to: "127.0.0.1", password: nil) { _ in }

        XCTAssertEqual(panel.receivedImage, image)
        XCTAssertNil(panel.receivedCnonce, "nothing was authenticated")
    }

    /// A wrong password is the panel's own refusal, and it has to arrive as one:
    /// the whole point is that the user can tell it apart from an unreachable
    /// panel.
    func testWrongPasswordIsReportedAsARejection() async throws {
        let panel = try FakePanel(password: "the-real-password")
        defer { panel.stop() }

        do {
            try await FirmwarePusher(otaPort: panel.port).push(
                image: Self.image(bytes: 64), filename: "display_stream.ino.bin",
                to: "127.0.0.1", password: "the-wrong-password") { _ in }
            XCTFail("a wrong password must not report success")
        } catch let failure as FirmwarePusher.Failure {
            XCTAssertEqual(
                failure,
                .authenticationFailed(deviceText: "Authentication Failed"))
            XCTAssertTrue(
                failure.localizedDescription.contains("rejected the password"),
                "got: \(failure.localizedDescription)")
        }
        XCTAssertNil(panel.receivedImage, "nothing was transferred")
    }

    /// Firmware older than ESP32 core 3.3.1 challenges with a 32-character MD5
    /// nonce. The app refuses it by name instead of computing something the panel
    /// will reject.
    func testLegacyMD5PanelIsRefusedByName() async throws {
        let panel = try FakePanel(password: "a-real-password", legacyNonce: true)
        defer { panel.stop() }

        do {
            try await FirmwarePusher(otaPort: panel.port).push(
                image: Self.image(bytes: 64), filename: "display_stream.ino.bin",
                to: "127.0.0.1", password: "a-real-password") { _ in }
            XCTFail("a legacy panel must be refused")
        } catch let failure as FirmwarePusher.Failure {
            XCTAssertEqual(failure, .legacyMD5Firmware)
            XCTAssertTrue(
                failure.localizedDescription.contains("3.3.1"),
                "got: \(failure.localizedDescription)")
        }
        XCTAssertNil(panel.receivedCnonce, "no response was sent")
    }

    /// Anything the panel says that is not `OK` and not a challenge comes back
    /// verbatim. `bad md5 length` is a real one from ArduinoOTA.cpp:238.
    func testPanelRefusalIsQuoted() async throws {
        let panel = try FakePanel(password: nil, refusal: "bad md5 length")
        defer { panel.stop() }

        do {
            try await FirmwarePusher(otaPort: panel.port).push(
                image: Self.image(bytes: 64), filename: "display_stream.ino.bin",
                to: "127.0.0.1", password: nil) { _ in }
            XCTFail("a refusal must not report success")
        } catch let failure as FirmwarePusher.Failure {
            XCTAssertEqual(
                failure, .panelRefusedInvitation(deviceText: "bad md5 length"))
            XCTAssertTrue(
                failure.localizedDescription.contains("bad md5 length"),
                "got: \(failure.localizedDescription)")
        }
    }

    /// THE ONE THIS SUITE EXISTS FOR NOW. The panel takes every byte and then
    /// refuses the image, which is what `Update.end()` does when the MD5 does not
    /// match or the header names a different chip - the wrong-chip case this
    /// feature deliberately leaves to the panel to catch.
    ///
    /// Before this was fixed the push reported "has the new firmware and is
    /// restarting onto it" here, and the panel's own explanation was discarded. A
    /// failure that reads as a success is worse than a failure, because the user
    /// stops looking.
    func testRefusedImageIsReportedAsAFailureQuotingThePanel() async throws {
        let image = Self.image(bytes: 2_600)
        // One of Updater.cpp's own strings (line 37), and the one a corrupted
        // transfer produces.
        let panel = try FakePanel(
            password: "a-real-password", ending: .refuseImage("MD5 Check Failed"))
        defer { panel.stop() }

        do {
            try await FirmwarePusher(otaPort: panel.port).push(
                image: image, filename: "display_stream.ino.bin",
                to: "127.0.0.1", password: "a-real-password") { _ in }
            XCTFail("a refused image must not be reported as a successful update")
        } catch let failure as FirmwarePusher.Failure {
            XCTAssertEqual(
                failure, .panelRefusedImage(deviceText: "MD5 Check Failed"))
            let message = failure.localizedDescription
            XCTAssertTrue(
                message.contains("MD5 Check Failed"),
                "the panel's own words are what say why: \(message)")
            XCTAssertTrue(
                message.contains("still running the firmware it booted"),
                "and the panel is not left sounding bricked: \(message)")
        }
        // The whole image did arrive - this is a verdict on the image, not a
        // transfer that broke - so the distinction is the reply, not the bytes.
        XCTAssertEqual(panel.receivedImage, image)
    }

    /// The same refusal, framed the other way: the verdict arrives as its own
    /// segment after the last chunk's count rather than coalesced with it.
    ///
    /// BOTH FRAMINGS ARE REAL and they used to fail differently, which is why they
    /// are two tests. `Update.end()` runs between the count and the verdict, so
    /// how long it takes decides whether one read sees both. Coalesced, the old
    /// code reported `unexpectedReply("552MD5 Che")` - a failure, but truncated to
    /// the read size and blamed on the transfer. Separated, it reported a
    /// SUCCESS: the tail loop returned on the first non-empty reply. This is the
    /// one that told the user their panel was restarting onto firmware it had just
    /// rejected.
    func testRefusalArrivingAfterTheCountIsAlsoAFailure() async throws {
        let image = Self.image(bytes: 2_600)
        let panel = try FakePanel(
            password: "a-real-password",
            ending: .refuseImage("Could Not Activate The Firmware"),
            // Long enough to land in its own read, short enough not to slow the
            // suite. A real `Update.end()` takes considerably longer.
            endingDelay: 0.15)
        defer { panel.stop() }

        do {
            try await FirmwarePusher(otaPort: panel.port).push(
                image: image, filename: "display_stream.ino.bin",
                to: "127.0.0.1", password: "a-real-password") { _ in }
            XCTFail("a refused image must not be reported as a successful update")
        } catch let failure as FirmwarePusher.Failure {
            // The wrong-chip refusal by name: esp_ota_set_boot_partition checks
            // the image header before the boot slot moves.
            XCTAssertEqual(
                failure,
                .panelRefusedImage(deviceText: "Could Not Activate The Firmware"))
        }
        XCTAssertEqual(panel.receivedImage, image)
    }

    /// The over-correction guard. The panel's read loop re-prints the previous
    /// byte count when the host is slow between chunks (`_ota_timeout`,
    /// ArduinoOTA.cpp:32), which shifts the phase and puts a stale decimal count
    /// where the verdict is expected. A stale count is not a refusal, and treating
    /// every non-`OK` reply as one would fail a push that worked.
    func testAStaleByteCountBeforeTheOKIsNotMistakenForARefusal() async throws {
        let image = Self.image(bytes: 2_600)
        let panel = try FakePanel(
            password: "a-real-password", repeatFinalCount: true)
        defer { panel.stop() }

        try await FirmwarePusher(otaPort: panel.port).push(
            image: image, filename: "display_stream.ino.bin",
            to: "127.0.0.1", password: "a-real-password") { _ in }

        XCTAssertEqual(panel.receivedImage, image)
    }

    /// A panel that takes the image and vanishes without confirming. That is what
    /// a successful push whose `OK` was lost to the reboot looks like, so it is
    /// reported as unconfirmed rather than as either outcome.
    ///
    /// The elapsed-time assertion is the real subject: the close has to end the
    /// wait. Without `isComplete` carried through the read, this loops the full
    /// ten 30-second attempts and the sheet sits there for five minutes.
    func testASilentHangUpAfterTheImageIsUnconfirmedAndImmediate() async throws {
        let image = Self.image(bytes: 2_600)
        let panel = try FakePanel(password: "a-real-password", ending: .silence)
        defer { panel.stop() }
        let started = Date()

        do {
            try await FirmwarePusher(otaPort: panel.port).push(
                image: image, filename: "display_stream.ino.bin",
                to: "127.0.0.1", password: "a-real-password") { _ in }
            XCTFail("an unconfirmed push must not be reported as confirmed")
        } catch let failure as FirmwarePusher.Failure {
            XCTAssertEqual(failure, .noResultAfterUpload)
            XCTAssertTrue(
                failure.localizedDescription.contains("rebooted onto the new"),
                "got: \(failure.localizedDescription)")
        }
        // One result attempt is 30s and the budget is ten of them. Anything under
        // the first attempt's timeout proves the hang-up ended the wait.
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 20,
            "the panel closing the connection has to end the wait, not time it out")
    }

    /// A challenge arriving with no password to answer it with is its own error,
    /// not a timeout and not an authentication failure.
    func testChallengeWithNoPasswordIsItsOwnError() async throws {
        let panel = try FakePanel(password: "a-real-password")
        defer { panel.stop() }

        do {
            try await FirmwarePusher(otaPort: panel.port).push(
                image: Self.image(bytes: 64), filename: "display_stream.ino.bin",
                to: "127.0.0.1", password: nil) { _ in }
            XCTFail("there is nothing to authenticate with")
        } catch let failure as FirmwarePusher.Failure {
            XCTAssertEqual(failure, .passwordRequired)
        }
    }

    // MARK: - who is allowed to take the image

    /// The panel's own address, in the spellings it can arrive in.
    ///
    /// The IPv4-mapped case is the one that matters most, because getting it wrong
    /// does not weaken anything - it stops every push. A listener on `.any` is
    /// dual-stack, so an IPv4 panel can be reported as `::ffff:192.168.1.120`
    /// while the invitation went to `192.168.1.120`, and a string comparison turns
    /// the panel itself away.
    func testTheRightPanelIsRecognisedInEverySpelling() {
        XCTAssertTrue(FirmwarePusher.sameHost(.ipv4(.loopback), as: "127.0.0.1"))
        XCTAssertTrue(
            FirmwarePusher.sameHost(
                .init("192.168.1.120"), as: "192.168.1.120"))
        XCTAssertTrue(
            FirmwarePusher.sameHost(
                .init("::ffff:192.168.1.120"), as: "192.168.1.120"),
            "an IPv4-mapped peer is the same panel")
        XCTAssertTrue(
            FirmwarePusher.sameHost(.init("fe80::1%en0"), as: "fe80::1"),
            "a zone id is not a different host")
        XCTAssertTrue(
            FirmwarePusher.sameHost(
                .init("fd00:0:0:0:0:0:0:1"), as: "fd00::1"),
            "elided and unelided are the same address")
    }

    /// A different address is refused. This is the finding: without it the first
    /// connection to the listener won, whoever it was, and the panel's own
    /// connection was then dropped as a stray.
    func testAnotherHostIsRefused() {
        XCTAssertFalse(
            FirmwarePusher.sameHost(.init("192.168.1.121"), as: "192.168.1.120"))
        XCTAssertFalse(
            FirmwarePusher.sameHost(.ipv4(.loopback), as: "192.168.1.120"))
        XCTAssertFalse(
            FirmwarePusher.sameHost(.init("fe80::2"), as: "fe80::1"))
    }

    /// Fails OPEN, on purpose, and that decision is pinned rather than left to be
    /// discovered: this is hardening on a path no board can be attached to, so a
    /// peer it cannot interpret is accepted. Refusing the unparseable would turn a
    /// low-severity gap into a push that never starts.
    func testAnUnreadablePeerIsAccepted() {
        XCTAssertTrue(
            FirmwarePusher.sameHost(.init("panel.local"), as: "panel.local"),
            "a name matching by name is fine")
        XCTAssertTrue(
            FirmwarePusher.sameHost(.init("panel.LOCAL"), as: "panel.local"),
            "and case in a hostname is not a difference")
        // A name against a numeric target cannot be resolved from here, so it is
        // refused only because the two strings differ - the fail-open rule covers
        // endpoint SHAPES it cannot read, not hosts it can read and tell apart.
        XCTAssertFalse(
            FirmwarePusher.sameHost(.init("panel.local"), as: "192.168.1.120"))
    }

    /// Not firmware, and it does not need to be: what is being checked is that
    /// the bytes that go in are the bytes that come out. Deliberately not
    /// uniform, so a chunk sent twice or in the wrong order would show up.
    private static func image(bytes: Int) -> Data {
        var data = Data(capacity: bytes)
        for index in 0..<bytes {
            data.append(UInt8((index * 31 + 7) % 251))
        }
        return data
    }
}

/// A panel that speaks enough of ArduinoOTA to be pushed to.
///
/// Written from the core's `_onRx` and `_runUpdate` rather than from the pusher:
/// it replies `AUTH <nonce>` with no terminator, requires 64-character fields,
/// dials BACK to the port it was given, answers each write with a decimal count,
/// and prints `OK` only once the whole image has arrived.
private final class FakePanel: @unchecked Sendable {
    private let queue = DispatchQueue(label: "espdisp.fake.panel")
    private let listener: NWListener
    private let password: String?
    private let refusal: String?
    private let ending: Ending
    /// How long `Update.end()` takes, in effect. Zero coalesces the verdict with
    /// the last chunk's count; anything else puts it in its own read.
    private let endingDelay: Double
    /// Print the last chunk's byte count twice. The real panel does this when the
    /// host is slow between chunks - its read loop times out at `_ota_timeout`
    /// (1000 ms, ArduinoOTA.cpp:32) and re-prints the previous count up to three
    /// times - which shifts the phase and puts a stale count in front of the
    /// verdict the host is waiting for.
    private let repeatFinalCount: Bool
    private let nonce: String
    private let lock = NSLock()
    /// Retained because Network drops a connection with no strong reference.
    private var live: [NWConnection] = []
    private var _invitation: String?
    private var _cnonce: String?
    private var _response: String?
    private var _image = Data()
    private var _chunkSizes: [Int] = []
    private var _expectedBytes = 0
    private var _dialledBackPort: UInt16?
    private var _complete = false

    /// What `Update.end()` decided, once the whole image has arrived.
    ///
    /// The panel has exactly two endings (ArduinoOTA.cpp:433-453) and both are
    /// here, because the failing one is what a wrong-chip or corrupted image gets
    /// and the app used to report it as a success.
    enum Ending {
        /// `client.print("OK")` - `Update.end()` succeeded.
        case ok
        /// `_updater->printError(client)` then `client.stop()`. The text is one of
        /// `_err2str`'s (Updater.cpp:21-58), `println`-terminated.
        case refuseImage(String)
        /// Nothing at all, then the socket goes away. What a reboot that swallowed
        /// its own `OK` looks like from out here.
        case silence
    }

    init(
        password: String?,
        legacyNonce: Bool = false,
        refusal: String? = nil,
        ending: Ending = .ok,
        endingDelay: Double = 0,
        repeatFinalCount: Bool = false
    ) throws {
        self.password = password
        self.refusal = refusal
        self.ending = ending
        self.endingDelay = endingDelay
        self.repeatFinalCount = repeatFinalCount
        // The core builds this with SHA256, so 64 hex characters; 32 is what a
        // pre-3.3.1 core produced.
        self.nonce = String(repeating: "ab", count: legacyNonce ? 16 : 32)
        listener = try NWListener(using: .udp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        // The pusher polls for its own listener's port the same way.
        let deadline = Date(timeIntervalSinceNow: 5)
        while listener.port == nil || listener.port?.rawValue == 0 {
            if Date() > deadline {
                throw NSError(
                    domain: "FakePanel", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
            }
            usleep(10_000)
        }
    }

    var port: UInt16 { listener.port!.rawValue }

    var invitation: String? { withLock { _invitation } }
    var receivedCnonce: String? { withLock { _cnonce } }
    var receivedResponse: String? { withLock { _response } }
    var chunkSizes: [Int] { withLock { _chunkSizes } }
    var dialledBackPort: UInt16? { withLock { _dialledBackPort } }
    /// The image, once all of it has arrived. nil while nothing or only part of it
    /// has, so a test cannot pass on a partial transfer.
    var receivedImage: Data? { withLock { _complete ? _image : nil } }

    func stop() {
        listener.cancel()
        withLock { live }.forEach { $0.cancel() }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// One inbound datagram flow. The pusher opens a fresh UDP connection for the
    /// invitation and another for the authentication, exactly as espota does, so
    /// each arrives here as its own connection.
    private func handle(_ connection: NWConnection) {
        withLock { live.append(connection) }
        connection.start(queue: queue)
        connection.receiveMessage { [weak self] data, _, _, _ in
            guard let self, let data else { return }
            let text = String(decoding: data, as: UTF8.self)
            if text.hasPrefix("\(EspotaProtocol.flashCommand) ") {
                self.onInvitation(text, over: connection)
            } else if text.hasPrefix("\(EspotaProtocol.authCommand) ") {
                self.onAuth(text, over: connection)
            }
        }
    }

    private func onInvitation(_ text: String, over connection: NWConnection) {
        let fields = text.trimmingCharacters(in: .newlines).split(separator: " ")
        guard fields.count == 4, let hostPort = UInt16(fields[1]),
              let size = Int(fields[2])
        else { return }
        withLock {
            _invitation = text
            _expectedBytes = size
        }
        if let refusal {
            send(refusal, over: connection)
            return
        }
        guard password != nil else {
            send("OK", over: connection)
            dialBack(to: hostPort)
            return
        }
        // printf, so no terminator - which is why the pusher trims.
        send("AUTH \(nonce)", over: connection)
    }

    private func onAuth(_ text: String, over connection: NWConnection) {
        let fields = text.trimmingCharacters(in: .newlines).split(separator: " ")
        guard fields.count == 3, let password else { return }
        let cnonce = String(fields[1])
        let response = String(fields[2])
        withLock {
            _cnonce = cnonce
            _response = response
        }
        // The panel's own check: both fields exactly 64 characters, then the
        // response recomputed from the stored password hash.
        guard cnonce.count == 64, response.count == 64,
              let expected = EspotaProtocol.authResponse(
                password: password, nonce: nonce, cnonce: cnonce),
              expected == response
        else {
            send("Authentication Failed", over: connection)
            return
        }
        send("OK", over: connection)
        let hostPort = withLock { _invitation }
            .flatMap { $0.split(separator: " ").dropFirst().first }
            .flatMap { UInt16($0) }
        if let hostPort { dialBack(to: hostPort) }
    }

    private func send(_ text: String, over connection: NWConnection) {
        connection.send(content: Data(text.utf8), completion: .idempotent)
    }

    /// The direction that makes this protocol awkward: the panel connects to the
    /// host, not the other way round.
    private func dialBack(to hostPort: UInt16) {
        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: hostPort)!,
            using: .tcp)
        withLock {
            live.append(connection)
            _dialledBackPort = hostPort
        }
        connection.start(queue: queue)
        readChunk(on: connection)
    }

    private func readChunk(on connection: NWConnection) {
        // 1460 is the core's own buffer size.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1460) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let done: Bool = self.withLock {
                    self._image.append(data)
                    self._chunkSizes.append(data.count)
                    return self._image.count >= self._expectedBytes
                }
                // A decimal count per write (ArduinoOTA.cpp:426), and only after
                // the whole image is in does Update.end() succeed and `OK` go out
                // (line 436). Two separate writes, so the pusher may see them
                // coalesced.
                if done {
                    self.withLock { self._complete = true }
                    // The last count is sent with `.contentProcessed` and the
                    // ending is only started from its completion. Ordering, not
                    // ceremony: `NWConnection.cancel()` discards a send that is
                    // still queued, so a fire-and-forget count followed by an
                    // immediate close loses the count - which the real panel does
                    // not do, since `Update.end()` runs between the two.
                    connection.send(
                        content: Data("\(data.count)".utf8),
                        completion: .contentProcessed { [weak self] _ in
                            guard let self else { return }
                            if self.repeatFinalCount {
                                connection.send(
                                    content: Data("\(data.count)".utf8),
                                    completion: .contentProcessed { _ in
                                        self.finish(on: connection)
                                    })
                            } else {
                                self.finish(on: connection)
                            }
                        })
                    return
                }
                connection.send(content: Data("\(data.count)".utf8),
                                completion: .idempotent)
            }
            if error != nil || isComplete { return }
            self.readChunk(on: connection)
        }
    }

    /// `Update.end()`'s two branches, plus the reboot that eats its own reply.
    ///
    /// The error text is sent and only then is the socket closed, in that order:
    /// cancelling before the send completes would drop the verdict and turn a
    /// refusal into silence, which is a different test.
    private func finish(on connection: NWConnection) {
        guard endingDelay <= 0 else {
            queue.asyncAfter(deadline: .now() + endingDelay) { [weak self] in
                self?.send(ending: connection)
            }
            return
        }
        send(ending: connection)
    }

    private func send(ending connection: NWConnection) {
        switch ending {
        case .ok:
            connection.send(content: Data("OK".utf8), completion: .idempotent)
        case .refuseImage(let text):
            // println, so CRLF - and then client.stop().
            connection.send(
                content: Data("\(text)\r\n".utf8),
                completion: .contentProcessed { _ in connection.cancel() })
        case .silence:
            connection.cancel()
        }
    }
}
