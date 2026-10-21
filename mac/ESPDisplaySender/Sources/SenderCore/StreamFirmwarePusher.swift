import Foundation
import SenderProtocol

/// Pushes one firmware image to one panel over the session's own stream link.
///
/// The ArduinoOTA path (`FirmwarePusher`) needs the panel to dial back to the
/// Mac, and on a Mac whose firewall drops every connection the LAN starts that
/// can never succeed. This sends the image on the UDP flow the Mac already
/// opened to stream frames, so every packet is either one the Mac started or
/// the panel's reply to it.
///
/// The decisions live in `StreamUpdateProtocol` and `StreamUpdateWindow`
/// (SenderProtocol); this is the clock, the pacing and the waiting. It runs on
/// its own thread rather than as async code because pacing a thousand
/// datagrams a second wants a sleep that is not rounded to a scheduler tick.
final class StreamFirmwarePusher: @unchecked Sendable {
    struct Timing: Equatable {
        var beginAttempts = 10
        var beginReplyWait: Double = 1.0
        /// PBKDF2 costs the panel a second or two, so the answer waits longer.
        var authTimeout: Double = 20
        var authResendInterval: Double = 3
        /// No acknowledged progress for this long ends the transfer.
        var stallTimeout: Double = 10
        /// Every byte acked; how long Update.end and its verdict may take.
        var resultTimeout: Double = 30
        /// Under the panel's 1 s restart delay, so a lost verdict is asked
        /// for at least twice before the panel goes.
        var resultPollInterval: Double = 0.25
        /// The least gap between two datagrams, about 1600 a second: above
        /// the ~725 a second streaming sustains, so the window and the
        /// panel's flash set the pace rather than this.
        var minSpacing: Double = 0.000_6

        static let standard = Timing()
    }

    struct Measurement: Equatable, Sendable {
        let imageBytes: Int
        /// From the panel accepting the password to the last chunk acked.
        let transferSeconds: Double
        /// From the first BEGIN to the panel saying it activated the image.
        let totalSeconds: Double
        let datagrams: Int
        let retransmissions: Int
        let timeouts: Int

        var megabytesPerSecond: Double {
            transferSeconds > 0 ? Double(imageBytes) / 1_000_000 / transferSeconds : 0
        }

        var summary: String {
            String(
                format: "%.2f MB in %.1f s (%.2f MB/s); %.1f s in all; %d datagrams, %d resent",
                Double(imageBytes) / 1_000_000, transferSeconds, megabytesPerSecond,
                totalSeconds, datagrams, retransmissions)
        }
    }

    enum Failure: Error, LocalizedError, Equatable {
        case noReplyToBegin(attempts: Int)
        case notConfigured
        case busy(String)
        case refused(String)
        case couldNotComputeResponse
        case noReplyToAuthentication
        case authenticationFailed
        case couldNotBegin(String)
        case writeFailed(String)
        case transferStalled(bytesAcked: Int, of: Int)
        case panelForgotSession
        case panelAborted(String)
        case hashMismatch
        case panelRefusedImage(String)
        case noResult
        /// Every chunk was acknowledged, then the panel answered as one that
        /// no longer knows the session, without its verdict reaching this Mac.
        /// Says nothing about which firmware it runs: a restart after success
        /// and a lost failure verdict look the same from here.
        case restartedBeforeConfirming
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noReplyToBegin(let attempts):
                return "The device did not answer \(attempts) update requests. Check "
                    + "that it is still streaming from this Mac."
            case .notConfigured:
                return "The device has no OTA password set, so it refuses updates "
                    + "over WiFi. Set one over USB."
            case .busy(let detail):
                return "The device is busy with another update: \(detail)."
            case .refused(let detail):
                return "The device refused the update: \(detail)."
            case .couldNotComputeResponse:
                return "The authentication response could not be computed on this "
                    + "Mac. This is a bug in the app rather than a wrong password."
            case .noReplyToAuthentication:
                return "The device did not answer the password."
            case .authenticationFailed:
                return "The device rejected the password."
            case .couldNotBegin(let detail):
                return "The device could not start writing the update: \(detail). "
                    + "Nothing was written."
            case .writeFailed(let detail):
                return "The device could not write the update to flash: \(detail). "
                    + "It keeps running the firmware it booted."
            case .transferStalled(let acked, let total):
                return "The transfer stopped after \(acked) of \(total) bytes: the "
                    + "device stopped answering. It keeps running the firmware it booted."
            case .panelForgotSession:
                return "The device stopped knowing this update before every byte was "
                    + "acknowledged: it may have restarted, or the link to it was "
                    + "reopened. It activates only a complete image whose SHA-256 "
                    + "matched, so check its version once it comes back."
            case .panelAborted(let detail):
                return "The device ended the update: \(detail). It keeps running the "
                    + "firmware it booted."
            case .hashMismatch:
                return "Every byte arrived, but the image's SHA-256 did not match, so "
                    + "the device discarded it. It keeps running the firmware it booted."
            case .panelRefusedImage(let detail):
                return "The device received the whole image and then refused it: "
                    + "\(detail). It keeps running the firmware it booted."
            case .noResult:
                return "Every byte was sent and acknowledged, but the device never "
                    + "said whether it activated the image. Check its version once "
                    + "it comes back."
            case .restartedBeforeConfirming:
                return "Every byte was acknowledged, but the device stopped knowing this "
                    + "update before its verdict reached this Mac. It may be running "
                    + "either firmware; check its version once it comes back."
            case .cancelled:
                return "The update was cancelled. The device keeps running the "
                    + "firmware it booted."
            }
        }
    }

    private let link: StreamUpdateLink
    private let timing: Timing
    private let inbox = Inbox()
    private let cancelled = CancelFlag()

    init(link: StreamUpdateLink, timing: Timing = .standard) {
        self.link = link
        self.timing = timing
    }

    func push(
        image: Data,
        filename: String,
        to address: String,
        password: String,
        progress: @escaping @Sendable (FirmwarePusher.Progress) -> Void
    ) async throws -> Measurement {
        link.setUpdatePacketHandler { [inbox] data in inbox.put(data) }
        defer { link.setUpdatePacketHandler(nil) }
        let cancelled = self.cancelled
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let thread = Thread { [self] in
                    do {
                        continuation.resume(returning: try run(
                            image: image, filename: filename, address: address,
                            password: password, progress: progress))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                thread.name = "espdisp.stream-update"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        } onCancel: {
            cancelled.set()
        }
    }

    // MARK: - the engine

    private func run(
        image: Data, filename: String, address: String, password: String,
        progress: @Sendable (FirmwarePusher.Progress) -> Void
    ) throws -> Measurement {
        let startedAt = Self.now()
        let session = UInt16.random(in: 1...UInt16.max)
        let digest = StreamUpdateProtocol.sha256(image)
        let chunkBytes = StreamUpdateProtocol.maxChunkBytes
        print("OTA(stream): \(address) session \(String(format: "%04x", session)) "
            + "\(filename) \(image.count) bytes sha256 \(Self.hex(digest))")

        let challenge = try requestChallenge(
            session: session, image: image, digest: digest, chunkBytes: chunkBytes,
            progress: progress)

        progress(.authenticating)
        // Bound to the image (stream_update.h cnonceSeed), so the
        // password-derived answer also vouches for this image and cannot be
        // borrowed by a BEGIN that names another one.
        let cnonce = EspotaProtocol.sha256Hex("\(Self.hex(digest)):\(challenge.nonce)")
        guard let response = EspotaProtocol.authResponse(
            password: password, nonce: challenge.nonce, cnonce: cnonce)
        else { throw Failure.couldNotComputeResponse }
        // From the AUTH on, the panel may begin an update; any failure on this
        // side tells it to abort rather than leaving it to time out holding
        // the screen.
        do {
            let firstWindowEnd = try authenticate(
                session: session, cnonce: cnonce, response: response)
            let transferStart = Self.now()
            let (stats, activated) = try transfer(
                image: image, session: session, chunkBytes: challenge.chunkBytes,
                windowEnd: firstWindowEnd, progress: progress)
            let transferSeconds = Self.now() - transferStart
            progress(.finishing)
            if !activated {
                try awaitVerdict(
                    image: image, session: session, chunkBytes: challenge.chunkBytes)
            }
            let measurement = Measurement(
                imageBytes: image.count, transferSeconds: transferSeconds,
                totalSeconds: Self.now() - startedAt, datagrams: stats.transmissions,
                retransmissions: stats.retransmissions, timeouts: stats.timeouts)
            print("OTA(stream): \(address) activated: \(measurement.summary)")
            return measurement
        } catch let failure as Failure {
            if Self.owesAbort(failure) {
                for _ in 0..<3 { link.sendUpdatePacket(StreamUpdateProtocol.abort(session: session)) }
            }
            print("OTA(stream): \(address) failed: \(failure)")
            throw failure
        }
    }

    private func requestChallenge(
        session: UInt16, image: Data, digest: Data, chunkBytes: Int,
        progress: @Sendable (FirmwarePusher.Progress) -> Void
    ) throws -> StreamUpdateProtocol.Challenge {
        let begin = StreamUpdateProtocol.begin(
            session: session, imageBytes: image.count, chunkBytes: chunkBytes,
            sha256: digest)
        for attempt in 1...timing.beginAttempts {
            try checkCancelled()
            progress(.inviting(attempt: attempt, of: timing.beginAttempts))
            link.sendUpdatePacket(begin)
            let deadline = Self.now() + timing.beginReplyWait
            while let reply = next(until: deadline) {
                switch reply {
                case .challenge(let c) where c.session == session:
                    guard c.chunkBytes > 0, c.chunkBytes <= chunkBytes,
                          c.nonce.count == EspotaProtocol.sha256HexLength
                    else { throw Failure.refused("its challenge was malformed") }
                    return c
                case .status(let s) where s.session == session || s.session == 0:
                    switch s.code {
                    case .notConfigured: throw Failure.notConfigured
                    case .busy: throw Failure.busy(s.detail)
                    default: throw Failure.refused(s.detail.isEmpty ? "\(s.code)" : s.detail)
                    }
                default:
                    continue
                }
            }
        }
        throw Failure.noReplyToBegin(attempts: timing.beginAttempts)
    }

    private func authenticate(
        session: UInt16, cnonce: String, response: String
    ) throws -> Int {
        let packet = StreamUpdateProtocol.auth(
            session: session, cnonce: cnonce, response: response)
        let deadline = Self.now() + timing.authTimeout
        var resendAt = Self.now()
        while Self.now() < deadline {
            try checkCancelled()
            if Self.now() >= resendAt {
                link.sendUpdatePacket(packet)
                resendAt = Self.now() + timing.authResendInterval
            }
            guard let reply = next(until: min(deadline, resendAt)) else { continue }
            guard case .status(let s) = reply, s.session == session else { continue }
            switch s.code {
            case .authAccepted: return Int(s.value)
            case .authRefused: throw Failure.authenticationFailed
            case .beginFailed: throw Failure.couldNotBegin(s.detail)
            case .unknownSession: throw Failure.panelForgotSession
            default: throw Failure.panelAborted(s.detail.isEmpty ? "\(s.code)" : s.detail)
            }
        }
        throw Failure.noReplyToAuthentication
    }

    private func transfer(
        image: Data, session: UInt16, chunkBytes: Int, windowEnd: Int,
        progress: @Sendable (FirmwarePusher.Progress) -> Void
    ) throws -> (window: StreamUpdateWindow, activated: Bool) {
        let total = (image.count + chunkBytes - 1) / chunkBytes
        var window = StreamUpdateWindow(totalChunks: total, receiverWindowEnd: windowEnd)
        var lastProgressAt = Self.now()
        var lastCumulative = -1
        var reportedBytes = -1
        var nextSendAt = Self.now()
        progress(.sending(bytesSent: 0, of: image.count))
        while !window.isComplete {
            try checkCancelled()
            // Everything already received, without waiting.
            while let reply = next(until: 0) {
                if try handle(reply, session: session, window: &window) {
                    return (window, true)
                }
            }
            if window.isComplete { break }
            let now = Self.now()
            if window.cumulative != lastCumulative {
                lastCumulative = window.cumulative
                lastProgressAt = now
                let acked = min(image.count, window.cumulative * chunkBytes)
                if acked - reportedBytes >= FirmwarePusher.progressByteInterval
                    || acked == image.count {
                    reportedBytes = acked
                    progress(.sending(bytesSent: acked, of: image.count))
                }
            } else if now - lastProgressAt > timing.stallTimeout {
                throw Failure.transferStalled(
                    bytesAcked: min(image.count, window.cumulative * chunkBytes),
                    of: image.count)
            }
            if now < nextSendAt {
                Self.sleep(nextSendAt - now)
                continue
            }
            if let seq = window.nextToSend(now: now) {
                let start = seq * chunkBytes
                let payload = image.subdata(in: start..<min(image.count, start + chunkBytes))
                link.sendUpdatePacket(
                    StreamUpdateProtocol.data(session: session, seq: seq, payload: payload))
                window.markSent(seq, now: now)
                // A rate, not a gap: a send that ran late may catch up by at
                // most two milliseconds' worth, never by a burst.
                nextSendAt = max(nextSendAt, now - 0.002) + timing.minSpacing
            } else {
                // Window full: wait for an ack or the earliest timeout.
                let wake = min(window.nextDeadline() ?? now + 0.05, now + 0.05)
                if let reply = next(until: wake),
                   try handle(reply, session: session, window: &window) {
                    return (window, true)
                }
            }
        }
        progress(.sending(bytesSent: image.count, of: image.count))
        return (window, false)
    }

    /// Applies one reply. True when it is the panel's activation verdict,
    /// which can overtake the last acks (they may all have been lost).
    private func handle(
        _ reply: StreamUpdateProtocol.Reply, session: UInt16,
        window: inout StreamUpdateWindow
    ) throws -> Bool {
        switch reply {
        case .ack(let ack) where ack.session == session:
            window.apply(ack, now: Self.now())
        case .status(let s) where s.session == session:
            if s.code == .activated { return true }
            // Unknown session before every chunk is acknowledged is
            // panelForgotSession (throwIfFailure): sent is not received.
            try throwIfFailure(s)
        default:
            break
        }
        return false
    }

    private func awaitVerdict(image: Data, session: UInt16, chunkBytes: Int) throws {
        let deadline = Self.now() + timing.resultTimeout
        let lastSeq = (image.count - 1) / chunkBytes
        let lastStart = lastSeq * chunkBytes
        let probe = StreamUpdateProtocol.data(
            session: session, seq: lastSeq,
            payload: image.subdata(in: lastStart..<image.count))
        // Ask at once: the verdict may already have been lost, and the panel
        // restarts a second after sending it.
        var pollAt = Self.now()
        while Self.now() < deadline {
            try checkCancelled()
            if Self.now() >= pollAt {
                // A duplicate of the last chunk asks the panel to repeat its
                // verdict, in case the first one was lost.
                link.sendUpdatePacket(probe)
                pollAt = Self.now() + timing.resultPollInterval
            }
            guard let reply = next(until: min(deadline, pollAt)) else { continue }
            switch reply {
            case .status(let s) where s.session == session:
                if s.code == .activated { return }
                // Every chunk was acknowledged before this wait began.
                if s.code == .unknownSession { throw Failure.restartedBeforeConfirming }
                try throwIfFailure(s)
            default:
                break
            }
        }
        throw Failure.noResult
    }

    private func throwIfFailure(_ s: StreamUpdateProtocol.StatusReply) throws {
        switch s.code {
        case .writeFailed: throw Failure.writeFailed(s.detail)
        case .hashMismatch: throw Failure.hashMismatch
        case .imageRefused: throw Failure.panelRefusedImage(s.detail)
        case .aborted: throw Failure.panelAborted(s.detail)
        case .unknownSession: throw Failure.panelForgotSession
        case .beginFailed: throw Failure.couldNotBegin(s.detail)
        case .authRefused: throw Failure.authenticationFailed
        case .busy, .badRequest, .notConfigured:
            throw Failure.refused(s.detail.isEmpty ? "\(s.code)" : s.detail)
        case .authAccepted, .activated:
            return
        }
    }

    /// Whether the panel may still hold an open update that an abort releases.
    private static func owesAbort(_ failure: Failure) -> Bool {
        switch failure {
        // An abort for a session the panel no longer knows is ignored there, so
        // the forgotten-session cases cost nothing to cover: one of them is a
        // live panel answering a reopened link, which would otherwise hold its
        // progress screen until it times out.
        case .cancelled, .transferStalled, .noResult, .noReplyToAuthentication,
             .panelForgotSession, .restartedBeforeConfirming:
            return true
        default: return false
        }
    }

    private func checkCancelled() throws {
        if cancelled.isSet { throw Failure.cancelled }
    }

    /// The next parsed reply, or nil once `deadline` (monotonic seconds) passes.
    private func next(until deadline: Double) -> StreamUpdateProtocol.Reply? {
        while true {
            guard let data = inbox.take(until: deadline) else { return nil }
            if let reply = StreamUpdateProtocol.parse(data) { return reply }
        }
    }

    static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private static func sleep(_ seconds: Double) {
        guard seconds > 0 else { return }
        usleep(UInt32(min(seconds, 0.05) * 1_000_000))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

/// Replies from the link's receive queue to the engine thread.
private final class Inbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var queue: [Data] = []

    func put(_ data: Data) {
        condition.lock()
        queue.append(data)
        condition.signal()
        condition.unlock()
    }

    func take(until deadline: Double) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        while queue.isEmpty {
            let remaining = deadline - StreamFirmwarePusher.now()
            guard remaining > 0 else { return nil }
            _ = condition.wait(until: Date(timeIntervalSinceNow: remaining))
        }
        return queue.removeFirst()
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
