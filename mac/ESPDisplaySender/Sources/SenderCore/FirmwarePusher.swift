import Foundation
import Network
import SenderProtocol

/// Pushes one firmware image to one panel, over the LAN, speaking `espota`.
///
/// The decisions live in `EspotaProtocol`; this is the sockets, the retries and
/// the timeouts. It is a direct transcription of what `espota.py serve()` does,
/// including the retry counts, because those counts are the only description
/// anyone has of how patient a panel needs you to be.
///
/// THE DIRECTION IS THE SURPRISING PART. The host does not connect to the panel
/// to send the image: it tells the panel a port over UDP and the panel dials
/// BACK. So this needs an inbound TCP listener, and the app has to be reachable
/// from the panel rather than merely able to reach it. Two consequences:
///
///   - The app is not sandboxed (there is no entitlements file and no
///     CODE_SIGN_ENTITLEMENTS in the xcodeproj), so no
///     `com.apple.security.network.server` entitlement is involved. Info.plist
///     already carries NSLocalNetworkUsageDescription, which is what the local
///     network permission prompt reads from.
///   - Whether the macOS application firewall prompts on the first incoming
///     connection is **UNVERIFIED**: no ESP32 board is attached to this machine,
///     so no panel has ever dialled back and no prompt has been observed. If it
///     does prompt, the push stalls at "waiting for the panel to connect" until
///     it is allowed. The README says as much rather than claiming either way.
///
/// A push is also **UNVERIFIED end to end** for the same reason. What is tested
/// is every computation and classification this drives (see
/// EspotaProtocolTests); what is not is a transfer to real hardware.
final class FirmwarePusher {
    /// Where a push has got to. Reported often enough to drive a progress bar and
    /// no more often than that: `sending` is throttled to one report per
    /// `progressByteInterval`, plus one at zero and one for the final chunk, so a
    /// 1.1MB image produces about twenty rather than the eleven hundred a report
    /// per chunk would.
    enum Progress: Equatable {
        /// Listener is up; the invitation is going out.
        case inviting(attempt: Int, of: Int)
        /// The panel asked for authentication and the answer is on its way.
        case authenticating
        /// Authenticated (or no password needed). Waiting for the panel to dial
        /// back.
        case waitingForPanel
        case sending(bytesSent: Int, of: Int)
        /// Every byte is out; waiting for the panel to finish writing flash and
        /// say so.
        case finishing
    }

    enum Failure: Error, LocalizedError, Equatable {
        case couldNotListen(String)
        case noReplyToInvitation(attempts: Int)
        case panelRefusedInvitation(deviceText: String)
        case passwordRequired
        case legacyMD5Firmware
        case malformedChallenge(length: Int)
        case couldNotComputeResponse
        case noReplyToAuthentication
        case authenticationFailed(deviceText: String)
        case panelNeverConnected(seconds: Int)
        case transferFailed(bytesSent: Int, of: Int, reason: String)
        case unexpectedReply(String)
        /// Every byte arrived and the panel then refused the image. `Update.end()`
        /// failed, which is where the MD5 and the image header's chip id are
        /// checked, so this is where a wrong-chip push lands. Carries the panel's
        /// own error string.
        case panelRefusedImage(deviceText: String)
        /// The panel answered with something that is neither `OK` nor a byte
        /// count, and did not close the connection either. espota's "this may
        /// still be successful": not claimed as a failure, not claimed as a win.
        case unconfirmedResult(deviceText: String)
        /// A read that ran out of time, naming what it was waiting for. Its own
        /// case because a silence and a surprise are different things and a
        /// timeout reported as "the panel sent something unexpected: nothing at
        /// all" would send someone looking for the wrong problem.
        case replyTimedOut(waitingFor: String)
        case noResultAfterUpload

        var errorDescription: String? {
            switch self {
            case .couldNotListen(let reason):
                return "This Mac could not open a port for the panel to connect "
                    + "back to: \(reason)"
            case .noReplyToInvitation(let attempts):
                return "The panel did not answer \(attempts) update invitations. "
                    + "Check that it is on this network and that OTA is enabled."
            case .panelRefusedInvitation(let text):
                return "The panel refused the update: "
                    + "\(Self.quote(text, whenEmpty: "it replied with nothing"))"
            case .passwordRequired:
                return "The panel asked for a password and none was given."
            case .legacyMD5Firmware:
                return "This panel is running firmware older than ESP32 core "
                    + "3.3.1, which authenticates updates with MD5. This app only "
                    + "speaks the newer PBKDF2 exchange. Update it over USB with "
                    + "tools/espdisp.py flash."
            case .malformedChallenge(let length):
                return "The panel sent a \(length)-character challenge, which is "
                    + "neither of the two lengths its firmware can produce."
            case .couldNotComputeResponse:
                return "The authentication response could not be computed on this "
                    + "Mac. This is a bug in the app rather than a wrong password."
            case .noReplyToAuthentication:
                return "The panel did not answer the password."
            case .authenticationFailed(let text):
                return "The panel rejected the password"
                    + (text == "Authentication Failed"
                        ? "." : ": \(Self.quote(text, whenEmpty: "it replied with nothing"))")
            case .panelNeverConnected(let seconds):
                return "The panel accepted the update but never connected back "
                    + "within \(seconds) seconds. A firewall on this Mac blocking "
                    + "incoming connections would look like this."
            case .transferFailed(let sent, let total, let reason):
                return "The transfer stopped after \(sent) of \(total) bytes: "
                    + "\(reason). The panel keeps running the firmware it booted."
            case .unexpectedReply(let text):
                return "The panel sent something unexpected during the transfer: "
                    + "\(Self.quote(text, whenEmpty: "nothing at all"))"
            case .panelRefusedImage(let text):
                return "The panel received the whole image and then refused it: "
                    + "\(Self.quote(text, whenEmpty: "it did not say why")). It is "
                    + "still running the firmware it booted, so nothing was lost. "
                    + "An image built for a different chip is refused this way, "
                    + "and so is one that arrived corrupted."
            case .unconfirmedResult(let text):
                return "Every byte was sent, and the panel answered "
                    + "\(Self.quote(text, whenEmpty: "nothing")) rather than "
                    + "confirming the update. It may still have worked - check its "
                    + "version once it comes back."
            case .replyTimedOut(let waitingFor):
                return "The panel stopped answering while \(waitingFor)."
            case .noResultAfterUpload:
                return "Every byte was sent, but the panel never confirmed it "
                    + "wrote them. It may have rebooted onto the new firmware "
                    + "anyway - check its version once it comes back."
            }
        }

        private static func quote(_ text: String, whenEmpty: String) -> String {
            text.isEmpty ? whenEmpty : "\"\(text)\""
        }
    }

    // Retry and timeout budgets, all of them espota.py's own numbers.
    /// espota sends the invitation up to ten times, one socket per attempt.
    static let invitationAttempts = 10
    /// espota's `-t/--timeout` default, per invitation attempt.
    static let invitationTimeout: Double = 10
    /// espota gives the auth reply a fixed ten seconds.
    static let authTimeout: Double = 10
    /// espota's `sock.settimeout(10)` before `accept()`.
    static let connectBackTimeout: Double = 10
    /// espota's per-chunk `connection.settimeout(10)`.
    static let chunkTimeout: Double = 10
    /// After the last chunk espota waits up to ten times thirty seconds for the
    /// separate `OK`. Writing the last of the flash and computing the image MD5
    /// takes the panel a while, so this is deliberately long.
    static let resultAttempts = 10
    static let resultTimeout: Double = 30
    /// How much of the panel's reply to take in one read.
    ///
    /// NOT espota's number, and this is the one place a bigger buffer is worth the
    /// divergence: espota reads 10 bytes per chunk and 32 in the tail, which is
    /// why a coalesced count-plus-verdict reaches it truncated too. Sized to hold
    /// a four-digit count, the longest string `_err2str` can print (`Could Not
    /// Activate The Firmware`, 31 characters) and the CRLF `println` adds, so the
    /// panel's reason arrives whole. Framing does not depend on it - replies are
    /// accumulated - so this only decides how many reads the same bytes take.
    static let replyBytes = 64
    /// How much has to be sent before progress is reported again.
    ///
    /// One report per chunk is about 1,140 main-actor hops for a C6 image, each
    /// invalidating a SwiftUI Form, to advance a bar by under a tenth of a
    /// percent. 64 KiB gives about eighteen updates for the same image, which is
    /// more than a progress bar can show anyway. The final chunk always reports
    /// regardless, so this changes the resolution and not the endpoints.
    static let progressByteInterval = 64 * 1024

    private let queue = DispatchQueue(label: "espdisp.ota")
    /// Which port the invitation goes to. Always 3232 in the app; a parameter so
    /// a test can run the whole exchange against a fake panel on a loopback port
    /// of its own rather than binding the real one, which is a shared resource on
    /// the machine running the tests.
    private let otaPort: UInt16

    init(otaPort: UInt16 = EspotaProtocol.port) {
        self.otaPort = otaPort
    }

    /// Push `image` to `address`.
    ///
    /// `filename` only contributes entropy to the client nonce (the panel never
    /// recomputes it), but the bundle's own filename is passed anyway so this
    /// side composes the nonce exactly as espota.py does - see
    /// `EspotaProtocol.cnonceSeed`.
    ///
    /// `password` may be nil for a panel with no OTA password, which is what
    /// `espota` does with no `-a`. A panel in that state does not advertise
    /// CAP_OTA and so cannot be reached through the UI, but the protocol has the
    /// case and pretending otherwise would mean a wrong error message if it ever
    /// arose.
    func push(
        image: Data,
        filename: String,
        to address: String,
        password: String?,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        let md5 = EspotaProtocol.md5Hex(image)
        let listener = try startListener()
        defer { listener.cancel() }
        let inbound = InboundConnection()
        // THE HANDLER GOES ON BEFORE start(), and this is not a style choice:
        // NWListener fails with EINVAL - "Invalid argument", which says nothing
        // about the cause - if it is started without a newConnectionHandler. That
        // was written the other way round here first, and every push would have
        // died with "This Mac could not open a port"; FirmwarePusherTests is what
        // found it, on loopback, with no panel.
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            inbound.accept(connection)
        }
        let hostPort = try await assignedPort(of: listener)

        let invitation = EspotaProtocol.invitationLine(
            hostPort: hostPort, imageBytes: image.count, md5Hex: md5)
        let reply = try await invite(invitation, to: address, progress: progress)

        switch reply {
        case .accepted:
            break
        case .refused(let text):
            throw Failure.panelRefusedInvitation(deviceText: text)
        case .challenge(let nonce):
            progress(.authenticating)
            try await authenticate(
                nonce: nonce, password: password, address: address,
                filename: filename, imageBytes: image.count, md5Hex: md5)
        }

        progress(.waitingForPanel)
        let connection = try await inbound.wait(
            seconds: Self.connectBackTimeout, on: queue)
        defer { connection.cancel() }
        try await transfer(image, over: connection, progress: progress)
    }

    // MARK: - step 1: the listener

    private func startListener() throws -> NWListener {
        do {
            // `.any` asks the system for an ephemeral port, which is then read
            // back below. espota picks a random port itself and can therefore
            // collide with something already bound; letting the system choose
            // cannot.
            return try NWListener(using: .tcp, on: .any)
        } catch {
            throw Failure.couldNotListen(error.localizedDescription)
        }
    }

    /// Start the listener and wait for the port the system gave it.
    ///
    /// Polled rather than awaited through `stateUpdateHandler`, matching
    /// FrameSender's readiness loop: `NWListener.port` is only populated once the
    /// listener is ready, and the invitation cannot be composed without it.
    /// Polling `state` too rather than capturing the failure from a handler keeps
    /// this free of shared mutable state.
    private func assignedPort(of listener: NWListener) async throws -> UInt16 {
        listener.start(queue: queue)
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            if case .failed(let error) = listener.state {
                throw Failure.couldNotListen(error.localizedDescription)
            }
            if let port = listener.port, port.rawValue != 0 {
                return port.rawValue
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure.couldNotListen("the listener did not become ready")
    }

    // MARK: - steps 2 and 3: invitation

    /// Send the invitation, retrying as espota does.
    ///
    /// A fresh UDP connection per attempt, deliberately: the panel answers to the
    /// source address and port of the datagram it received, and a connection that
    /// has already timed out once may have been torn down. espota opens a new
    /// socket each time round for the same reason.
    ///
    /// Silence is retried; an answer, even a refusal, is not. A panel that said
    /// something has heard us, and asking again would only produce the same
    /// answer more slowly.
    private func invite(
        _ invitation: String,
        to address: String,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> EspotaProtocol.InvitationReply {
        for attempt in 1...Self.invitationAttempts {
            progress(.inviting(attempt: attempt, of: Self.invitationAttempts))
            let connection = udpConnection(to: address)
            defer { connection.cancel() }
            do {
                try await send(Data(invitation.utf8), over: connection)
                let data = try await receiveDatagram(
                    on: connection, timeout: Self.invitationTimeout)
                return EspotaProtocol.parseInvitationReply(
                    String(decoding: data, as: UTF8.self))
            } catch {
                // Both a send failure and a timeout land here, and both mean the
                // same thing at this stage: nothing came back. The distinction
                // only matters if every attempt fails, and then the message is
                // about the panel not answering either way.
                continue
            }
        }
        throw Failure.noReplyToInvitation(attempts: Self.invitationAttempts)
    }

    // MARK: - steps 4 and 5: authentication

    private func authenticate(
        nonce: String,
        password: String?,
        address: String,
        filename: String,
        imageBytes: Int,
        md5Hex: String
    ) async throws {
        guard let password, !password.isEmpty else { throw Failure.passwordRequired }
        switch EspotaProtocol.classifyNonce(nonce) {
        case .pbkdf2Sha256:
            break
        case .legacyMD5:
            throw Failure.legacyMD5Firmware
        case .malformed(let length):
            throw Failure.malformedChallenge(length: length)
        }

        let cnonce = EspotaProtocol.cnonce(
            filename: filename, imageBytes: imageBytes, md5Hex: md5Hex,
            panelAddress: address)
        guard let response = EspotaProtocol.authResponse(
            password: password, nonce: nonce, cnonce: cnonce)
        else { throw Failure.couldNotComputeResponse }

        let connection = udpConnection(to: address)
        defer { connection.cancel() }
        let line = EspotaProtocol.authLine(cnonce: cnonce, response: response)
        do {
            try await send(Data(line.utf8), over: connection)
        } catch {
            throw Failure.noReplyToAuthentication
        }
        let data: Data
        do {
            data = try await receiveDatagram(
                on: connection, timeout: Self.authTimeout)
        } catch {
            throw Failure.noReplyToAuthentication
        }
        switch EspotaProtocol.parseAuthReply(String(decoding: data, as: UTF8.self)) {
        case .accepted:
            return
        case .refused(let text):
            throw Failure.authenticationFailed(deviceText: text)
        }
    }

    // MARK: - step 7: the transfer

    /// Send the image in lock-step: one chunk, one reply, repeat.
    ///
    /// The reply is what paces this - the panel writes flash between chunks, so
    /// sending ahead would only fill buffers. `espota` is lock-step too.
    private func transfer(
        _ image: Data,
        over connection: NWConnection,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        let total = image.count
        var sent = 0
        var reported = 0
        progress(.sending(bytesSent: 0, of: total))
        var index = image.startIndex
        // WHAT THE PANEL HAS SAID AND THIS SIDE HAS NOT YET ACCOUNTED FOR.
        //
        // The per-write counts and the final verdict are separate `client.print`
        // calls on one TCP stream, and the last chunk's count is written
        // immediately before `Update.end()` decides, so a single read here
        // legitimately returns `552MD5 Check Failed`. Classifying one read in
        // isolation - which is what this did - reported that as
        // `unexpectedReply("552MD5 Che")`: a real failure, but truncated to the
        // read size, blamed on the transfer, and stripped of the panel's reason.
        // Accumulating means the verdict survives however it is framed.
        var tail = ""
        var panelHungUp = false
        while index < image.endIndex {
            let end = min(index + EspotaProtocol.chunkBytes, image.endIndex)
            let chunk = Data(image[index..<end])
            do {
                try await send(chunk, over: connection)
            } catch {
                throw Failure.transferFailed(
                    bytesSent: sent, of: total, reason: error.localizedDescription)
            }
            sent += chunk.count
            index = end
            // Throttled, because one report per 1024-byte chunk is about 1,140
            // main-actor hops and Form invalidations for a C6 image, all to move a
            // progress bar by a tenth of a percent. The last chunk always reports,
            // so the bar still finishes at 100% rather than near it.
            if sent == total || sent - reported >= Self.progressByteInterval {
                reported = sent
                progress(.sending(bytesSent: sent, of: total))
            }

            let reply: Reply
            do {
                reply = try await receive(
                    on: connection, maximum: Self.replyBytes,
                    timeout: Self.chunkTimeout)
            } catch {
                throw Failure.transferFailed(
                    bytesSent: sent, of: total, reason: error.localizedDescription)
            }
            if reply.data.isEmpty, reply.isClosed {
                // A panel that hit `Receive Failed`, aborted the update and hung
                // up. Named as the hang-up it is: reported as an empty reply it
                // read as "the panel sent something unexpected: nothing at all",
                // which describes neither what happened nor what to do.
                throw Failure.transferFailed(
                    bytesSent: sent, of: total,
                    reason: "the panel closed the connection")
            }
            tail += reply.text
            panelHungUp = reply.isClosed
            switch EspotaProtocol.classifyResultTail(tail) {
            case .finished:
                // The panel has written everything and said so. Coalesced with
                // the last chunk's count is the ordinary way this arrives.
                return
            case .waiting:
                // Nothing but counts, which are the panel's own tally and
                // deliberately not compared against what was sent: `Update.write`
                // may legitimately write less than it was handed
                // (ArduinoOTA.cpp:415 warns and carries on), and the image MD5 is
                // what decides whether the transfer was faithful. Consumed, so
                // the next reply starts from a clean tail.
                tail = ""
            case .refused(let text):
                // Mid-transfer the panel writes nothing but counts, so text here
                // is genuinely a surprise rather than a verdict arriving early.
                guard index >= image.endIndex else {
                    throw Failure.unexpectedReply(text)
                }
                // On the last chunk this is either the verdict or the leading
                // byte of a split `OK`. Not decided here: the loop ends and the
                // tail path has the budget and the accumulated text to tell them
                // apart.
            }
        }

        progress(.finishing)
        try await awaitResult(
            over: connection, tail: tail, panelHungUp: panelHungUp)
    }

    /// Wait for the `OK` the panel sends only after `Update.end()` succeeds.
    ///
    /// THIS USED TO REPORT A REFUSED IMAGE AS A SUCCESSFUL UPDATE, which is worth
    /// recording because the reasoning that got it wrong was superficially sound.
    /// It returned on the first non-empty reply, on the grounds that `espota`
    /// "treats any response after a complete upload as success". espota does end
    /// up returning 0 that way, but only after exhausting all ten attempts
    /// looking for `OK` and printing the device's own words as a warning
    /// (espota.py:429-457) - and a non-`OK` reply here is not noise, it is the
    /// panel's verdict. `Update.end()` validates the image MD5 and the header's
    /// chip id, so the wrong-chip case this feature deliberately leaves to the
    /// panel lands on `printError` (ArduinoOTA.cpp:447), and the user was being
    /// told their panel "has the new firmware and is restarting onto it" while it
    /// carried on running what it booted.
    ///
    /// WHAT IS GENUINELY AMBIGUOUS, and still reported as such: a successful push
    /// reboots the panel about a tenth of a second after the `OK`
    /// (ArduinoOTA.cpp:436-444), so silence is not proof of failure. Three
    /// endings, and the difference between them is which one the user is told:
    ///
    ///   - `OK` anywhere in the tail: it worked.
    ///   - the panel wrote something else and hung up: it refused the image, and
    ///     its own words say why.
    ///   - nothing but per-write counts, or nothing at all: unconfirmed, with a
    ///     message that says to check the version when it comes back.
    private func awaitResult(
        over connection: NWConnection, tail initialTail: String,
        panelHungUp initiallyHungUp: Bool
    ) async throws {
        // Carries on from whatever the transfer loop had already read: see
        // `classifyResultTail` for the stale-count and split-`OK` cases that make
        // accumulating necessary rather than tidy.
        var tail = initialTail
        var panelHungUp = initiallyHungUp
        if case .finished = EspotaProtocol.classifyResultTail(tail) { return }
        // Nothing more is coming from a panel that has already gone, so when the
        // transfer loop saw the close the attempts are skipped rather than spent.
        attempts: if !panelHungUp {
            for _ in 1...Self.resultAttempts {
                let reply: Reply
                do {
                    reply = try await receive(
                        on: connection, maximum: Self.replyBytes,
                        timeout: Self.resultTimeout)
                } catch {
                    // A timeout is not an answer. espota keeps trying too, and the
                    // budget is deliberately long because the panel is writing the
                    // last of the flash and computing the image MD5.
                    continue
                }
                tail += reply.text
                if case .finished = EspotaProtocol.classifyResultTail(tail) { return }
                if reply.isClosed {
                    // `printError` is followed by `client.stop()`, and so is the
                    // `OK` path, so a close means the panel has said everything it
                    // is going to. Waiting out the remaining attempts - up to five
                    // more minutes - would tell nobody anything.
                    panelHungUp = true
                    break attempts
                }
            }
        }
        switch EspotaProtocol.classifyResultTail(tail) {
        case .finished:
            return
        case .refused(let text):
            // The distinction is whether the panel finished speaking. A verdict
            // followed by a hang-up is definite; the same text with the stream
            // still open is espota's "this may still be successful", and saying
            // so beats picking one.
            throw panelHungUp
                ? Failure.panelRefusedImage(deviceText: text)
                : Failure.unconfirmedResult(deviceText: text)
        case .waiting:
            throw Failure.noResultAfterUpload
        }
    }

    // MARK: - socket plumbing

    private func udpConnection(to address: String) -> NWConnection {
        let connection = NWConnection(
            host: NWEndpoint.Host(address),
            port: NWEndpoint.Port(rawValue: otaPort)!,
            using: .udp)
        connection.start(queue: queue)
        return connection
    }

    private func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let resumer = Resumer<Void>(continuation)
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    resumer.finish(.failure(error))
                } else {
                    resumer.finish(.success(()))
                }
            })
        }
    }

    /// One datagram, or a timeout.
    ///
    /// The timeout is a queued `asyncAfter` rather than a racing task on purpose:
    /// a `TaskGroup` that cancels the loser still awaits it at the end of its
    /// scope, and a continuation waiting on a socket that will never answer is not
    /// cancellable, so that shape hangs. `Resumer` guarantees exactly one resume
    /// whichever arrives first.
    private func receiveDatagram(
        on connection: NWConnection, timeout: Double
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let resumer = Resumer<Data>(continuation)
            queue.asyncAfter(deadline: .now() + timeout) {
                resumer.finish(.failure(Failure.replyTimedOut(
                    waitingFor: "waiting for a reply over UDP")))
            }
            connection.receiveMessage { data, _, _, error in
                if let error {
                    resumer.finish(.failure(error))
                } else {
                    resumer.finish(.success(data ?? Data()))
                }
            }
        }
    }

    /// One read from the TCP stream, and whether that stream is now over.
    ///
    /// `isClosed` is carried rather than collapsed into an empty `Data` because
    /// the two mean opposite things and only the caller knows which it is looking
    /// at. Mid-transfer a close is a panel that gave up and hung up; in the tail
    /// it is either the `client.stop()` that follows a verdict or the reboot that
    /// follows a lost `OK`. Reported as one value, all three read as "the panel
    /// sent nothing at all", which is a sentence about the wrong problem.
    private struct Reply {
        let data: Data
        let isClosed: Bool

        var text: String { String(decoding: data, as: UTF8.self) }
    }

    /// Whatever has arrived on the TCP stream, up to `maximum` bytes.
    ///
    /// `minimumIncompleteLength: 1` because the panel's replies are short and
    /// unframed - a byte count with no terminator - so waiting for a full buffer
    /// would wait forever.
    private func receive(
        on connection: NWConnection, maximum: Int, timeout: Double
    ) async throws -> Reply {
        try await withCheckedThrowingContinuation { continuation in
            let resumer = Resumer<Reply>(continuation)
            queue.asyncAfter(deadline: .now() + timeout) {
                resumer.finish(.failure(Failure.replyTimedOut(
                    waitingFor: "acknowledging the data it had been sent")))
            }
            connection.receive(
                minimumIncompleteLength: 1, maximumLength: maximum
            ) { data, _, isComplete, error in
                if let error {
                    resumer.finish(.failure(error))
                } else {
                    // Data and a close can arrive together, and the last thing
                    // the panel says before `client.stop()` is exactly that case,
                    // so both fields are always reported rather than one winning.
                    resumer.finish(.success(Reply(
                        data: data ?? Data(), isClosed: isComplete)))
                }
            }
        }
    }
}

/// The connection the panel makes back to us, and the wait for it.
///
/// Separate small class because the connection arrives on the listener's queue
/// while the push is suspended waiting for it, and both sides need one lock and
/// one resume.
private final class InboundConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?
    private var waiter: Resumer<NWConnection>?

    func accept(_ connection: NWConnection) {
        lock.lock()
        // Only the first connection is used, and a later one is dropped rather
        // than left open: there is exactly one transfer to do, and anything else
        // arriving on this port is a stray.
        let isFirst = self.connection == nil
        if isFirst { self.connection = connection }
        let waiter = self.waiter
        self.waiter = nil
        let first = self.connection
        lock.unlock()
        if !isFirst { connection.cancel() }
        if let waiter, let first { waiter.finish(.success(first)) }
    }

    func wait(seconds: Double, on queue: DispatchQueue) async throws -> NWConnection {
        try await withCheckedThrowingContinuation { continuation in
            let resumer = Resumer<NWConnection>(continuation)
            lock.lock()
            if let connection {
                lock.unlock()
                resumer.finish(.success(connection))
                return
            }
            waiter = resumer
            lock.unlock()
            queue.asyncAfter(deadline: .now() + seconds) {
                resumer.finish(.failure(FirmwarePusher.Failure.panelNeverConnected(
                    seconds: Int(seconds))))
            }
        }
    }
}

/// A continuation that can be resumed from two places and is resumed exactly
/// once.
///
/// Every await in the pusher has a timeout that fires on a queue while a network
/// callback may fire on another, and resuming a `CheckedContinuation` twice traps.
private final class Resumer<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}
