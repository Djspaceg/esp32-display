import Darwin
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
/// THE WHOLE OTA TRANSPORT USES POSIX SOCKETS, not Network.framework, and that
/// is the point of this file. The invitation and the authentication reply go out
/// over a fresh connected `AF_INET`/`SOCK_DGRAM` socket per exchange (see
/// `UDPExchange`), exactly as espota does; the panel's return TCP connection is
/// now taken by an explicit `AF_INET`/`SOCK_STREAM` server (see `PanelTCPServer`)
/// and its accepted socket, rather than an `NWListener`/`NWConnection`.
///
/// Both halves moved for the same reason. On the live network an `NWConnection`
/// UDP invitation to a panel got no reply while a connected POSIX datagram from
/// the same Mac to the same address and port received `AUTH <nonce>` immediately;
/// separately, an `NWListener` accepting the panel's dial-back - tried with an
/// implicit dual-stack bind, a fail-open peer filter, an explicit IPv4
/// `requiredLocalEndpoint` and `.ready` gating - still ended in the panel logging
/// `OTA_CONNECT_ERROR` and this side reporting that the panel never connected.
/// The panel and the protocol were good in both cases, so the failing layer was
/// Network.framework's readiness/interoperability. Mirroring espota.py's plain
/// `socket(AF_INET, SOCK_STREAM); bind(('0.0.0.0', 0)); listen(1); accept()`
/// removes that layer from the transfer path the same way it was removed from the
/// handshake, without touching the protocol, the crypto or the update safety.
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
        /// The invitation could not be put on the wire at all: resolving the
        /// address, opening the socket, connecting it to the panel, or the send
        /// itself failed. Its own case, distinct from `noReplyToInvitation`,
        /// because silence means "try again" and a local transport failure means
        /// "something on this Mac stopped the datagram leaving" - a different
        /// problem with a different fix. Carries the underlying POSIX error.
        case invitationTransportFailed(reason: String)
        case panelRefusedInvitation(deviceText: String)
        case passwordRequired
        case legacyMD5Firmware
        case malformedChallenge(length: Int)
        case couldNotComputeResponse
        case noReplyToAuthentication
        /// The authentication reply could not be put on the wire, the same local
        /// transport failure as `invitationTransportFailed` but on the auth
        /// socket. Kept apart from `noReplyToAuthentication`, which is the panel
        /// staying silent, for the same reason the invitation cases are split.
        case authenticationTransportFailed(reason: String)
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
            case .invitationTransportFailed(let reason):
                return "This Mac could not send the update invitation over the "
                    + "network: \(reason). Check this Mac's network connection "
                    + "and that Local Network access is allowed for this app in "
                    + "System Settings > Privacy & Security."
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
            case .authenticationTransportFailed(let reason):
                return "This Mac could not send the password over the network: "
                    + "\(reason). Check this Mac's network connection and that "
                    + "Local Network access is allowed for this app in System "
                    + "Settings > Privacy & Security."
            case .authenticationFailed(let text):
                return "The panel rejected the password"
                    + (text == "Authentication Failed"
                        ? "." : ": \(Self.quote(text, whenEmpty: "it replied with nothing"))")
            case .panelNeverConnected(let seconds):
                return "The panel accepted the update invitation but did not "
                    + "establish its return connection within \(seconds) seconds. "
                    + "That is the only fact the app can observe here. Network "
                    + "isolation, routing, Local Network permission, a panel-side "
                    + "connection failure, or a Mac firewall can all cause it."
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

    /// The serial queue the blocking TCP send/receive run on. Every `write`,
    /// `poll` and `recv` on the accepted socket is dispatched here, one at a time:
    /// the transfer is lock-step (send a chunk, then read its reply), so only one
    /// blocking call is ever parked on this queue and the `poll` timeout bounds
    /// how long that is. Kept apart from the accept and UDP queues so a parked
    /// read cannot hold up anything else.
    private let tcpQueue = DispatchQueue(label: "espdisp.ota.tcp")
    /// A dedicated queue for the blocking `accept()` wait. The wait can sit for
    /// the whole connect-back timeout, so it must not share a queue with the
    /// transfer's reads.
    private let acceptQueue = DispatchQueue(label: "espdisp.ota.accept")
    /// A separate queue for the blocking POSIX UDP exchanges. Kept apart from the
    /// TCP queues so a `poll`/`recv` that is parked waiting for a datagram cannot
    /// hold up the return connection's machinery. The handshake is sequential
    /// (invite, then auth), so one exchange blocks this queue at a time and the
    /// `poll` timeout bounds how long that is.
    private let udpQueue = DispatchQueue(label: "espdisp.ota.udp")
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
        // Open the listening socket BEFORE the invitation goes out. espota.py
        // does the same: `socket(); bind(('0.0.0.0', 0)); listen(1)` and only
        // then reads the kernel-assigned port to put in the line the panel dials
        // back to. `PanelTCPServer.start()` returns fully bound and listening, so
        // the port it hands back is one the panel can already connect to - there
        // is no readiness to wait for the way there was with NWListener.
        let server = try PanelTCPServer.start()
        // Closed on every exit from here, including the throwing ones. It is
        // closed again explicitly once `accept()` returns; `close()` is
        // idempotent so the second call is a no-op.
        defer { server.close() }
        let hostPort = server.port

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
        let fd = try await server.accept(
            from: address, timeout: Self.connectBackTimeout, on: acceptQueue)
        // espota closes the server socket the moment it has the one connection it
        // is waiting for; nothing else is going to dial back. The accepted socket
        // is closed on every exit from here on.
        server.close()
        defer { close(fd) }
        try await transfer(image, over: fd, progress: progress)
    }

    // MARK: - steps 2 and 3: invitation

    /// Send the invitation, retrying as espota does.
    ///
    /// A fresh connected POSIX datagram socket per attempt, deliberately: the
    /// panel answers to the source address and port of the datagram it received,
    /// and a socket that has already timed out once is closed and replaced.
    /// espota opens a new socket each time round for the same reason.
    ///
    /// SILENCE AND AN UNREACHABLE REPLY ARE RETRIED; A LOCAL FAILURE IS NOT. A
    /// receive timeout is the panel not having answered yet, and an ICMP
    /// unreachable (ECONNREFUSED/EHOSTUNREACH/ENETUNREACH surfaced on the
    /// connected socket) is the panel or a router saying nothing reached a
    /// listener this time - both mean "no reply this attempt", and asking again
    /// is the whole point of the ten attempts. A local transport failure - the
    /// address would not resolve, the socket would not open, connect or send - is
    /// not silence and is not retried: it would fail the same way ten times over
    /// and then be reported as "the panel did not answer", which sends someone to
    /// check the panel when the problem is on this Mac. It is thrown straight out
    /// as its own error carrying the POSIX reason. An answer, even a refusal, is
    /// not retried either: a panel that said something has heard us.
    private func invite(
        _ invitation: String,
        to address: String,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> EspotaProtocol.InvitationReply {
        for attempt in 1...Self.invitationAttempts {
            progress(.inviting(attempt: attempt, of: Self.invitationAttempts))
            do {
                let data = try await UDPExchange.perform(
                    payload: Data(invitation.utf8), host: address, port: otaPort,
                    timeout: Self.invitationTimeout, on: udpQueue)
                return EspotaProtocol.parseInvitationReply(
                    String(decoding: data, as: UTF8.self))
            } catch UDPExchange.TransportError.timedOut {
                continue
            } catch UDPExchange.TransportError.unreachable {
                // An ICMP unreachable for this datagram: the panel's host or a
                // router answered that nothing reached a listener. Like silence
                // it means no reply this attempt, so it spends one invitation
                // attempt and tries again rather than failing out as a local
                // transport problem.
                continue
            } catch let UDPExchange.TransportError.failed(reason) {
                throw Failure.invitationTransportFailed(reason: reason)
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

        // A fresh socket for the auth exchange, separate from the invitation's,
        // matching espota/ArduinoOTA: the invitation socket has done its job and
        // the panel replies to whichever source port this datagram comes from.
        let line = EspotaProtocol.authLine(cnonce: cnonce, response: response)
        let data: Data
        do {
            data = try await UDPExchange.perform(
                payload: Data(line.utf8), host: address, port: otaPort,
                timeout: Self.authTimeout, on: udpQueue)
        } catch UDPExchange.TransportError.timedOut {
            // The panel stayed silent. Distinct from the transport failure below,
            // which is this Mac being unable to send at all.
            throw Failure.noReplyToAuthentication
        } catch UDPExchange.TransportError.unreachable {
            // An ICMP unreachable for the auth datagram is the panel not
            // answering this exchange - the same observable outcome as silence.
            // The auth reply is sent once and never retried (espota does not
            // retry it), so this maps to the no-reply case rather than the local
            // transport failure below.
            throw Failure.noReplyToAuthentication
        } catch let UDPExchange.TransportError.failed(reason) {
            throw Failure.authenticationTransportFailed(reason: reason)
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
        over fd: Int32,
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
                try await send(chunk, over: fd)
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
                    on: fd, maximum: Self.replyBytes,
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
            over: fd, tail: tail, panelHungUp: panelHungUp)
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
        over fd: Int32, tail initialTail: String,
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
                        on: fd, maximum: Self.replyBytes,
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

    // MARK: - who connected back

    /// Whether an accepted peer came from the panel this push is for.
    ///
    /// DELIBERATELY FAILS OPEN. A peer address this cannot render numerically is
    /// accepted, not refused, and that asymmetry is the point: this is hardening
    /// on a path that cannot be verified from here without a panel, and the cost
    /// of a false negative is a push that never starts on somebody's desk. Only a
    /// peer positively identified as a DIFFERENT address is turned away.
    ///
    /// The image is not a secret and espota's listener is open to anyone, so this
    /// is not an authorisation boundary. What it buys is that a stray connection
    /// on the LAN cannot take the transfer slot from the panel and turn a push
    /// into a hang.
    ///
    /// The peer sockaddr from `accept()` is rendered to a numeric string with
    /// `getnameinfo(NI_NUMERICHOST)` - no DNS, no reverse lookup - and then run
    /// through the same `sameHost` normalisation the listener always used, so the
    /// zone-id, elided-IPv6 and IPv4-mapped cases stay covered by the existing
    /// tests. A `getnameinfo` this cannot render is the fail-open case: accept.
    static func peer(
        _ storage: sockaddr_storage, length: socklen_t, isFrom address: String
    ) -> Bool {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var storage = storage
        let status = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addr in
                getnameinfo(
                    addr, length, &host, socklen_t(host.count),
                    nil, 0, NI_NUMERICHOST)
            }
        }
        guard status == 0 else { return true }
        return sameHost(NWEndpoint.Host(String(cString: host)), as: address)
    }

    /// Compare a connection's host against the address the invitation went to.
    ///
    /// Compared as parsed addresses rather than as strings, because the same host
    /// has several spellings and any of them can turn up here: a zone id on a
    /// link-local address (`fe80::1%en0`), the elided and unelided forms of an
    /// IPv6 address, and an IPv4-mapped IPv6 peer (`::ffff:192.168.1.120`) from a
    /// listener bound to `.any`. That last one is the one that would have bitten:
    /// a string comparison rejects the panel that is right there.
    static func sameHost(_ host: NWEndpoint.Host, as address: String) -> Bool {
        let peerText: String
        switch host {
        case .ipv4(let value): peerText = "\(value)"
        case .ipv6(let value): peerText = "\(value)"
        case .name(let value, _): peerText = value
        @unknown default: return true
        }
        let peer = ipAddress(peerText)
        let target = ipAddress(address)
        switch (peer, target) {
        case (let peer?, let target?):
            // Both are addresses: this is the only case that can be a definite
            // mismatch, so compare the raw addresses exactly. Zone ids and the
            // IPv4-mapped form are already normalised away by `ipAddress`.
            return peer.rawValue == target.rawValue
        case (nil, nil):
            // Neither is an address - two names, or two unparseable shapes.
            // Compare bare host names case-insensitively.
            return bareHost(peerText).caseInsensitiveCompare(bareHost(address))
                == .orderedSame
        default:
            // Exactly one side is an address and the other is a name or an
            // unparseable shape - e.g. a reverse-resolved `silver-round.local`
            // peer against a numeric `192.168.1.83` target. That cannot be told
            // apart from here without resolving, so it is not a definite mismatch;
            // per the fail-open rule, accept it. The listener is not an auth
            // boundary, so accepting is the safe direction.
            return true
        }
    }

    /// The host with any interface zone id removed. `IPv6Address` accepts a zone
    /// but two spellings of the same address must not differ by one.
    private static func bareHost(_ text: String) -> String {
        text.split(separator: "%").first.map(String.init) ?? text
    }

    /// An address, with an IPv4-mapped IPv6 address reduced to its IPv4 form so
    /// the two families compare equal when they name the same host.
    private static func ipAddress(_ text: String) -> IPAddress? {
        let bare = bareHost(text)
        if let value = IPv4Address(bare) { return value }
        if let value = IPv6Address(bare) { return value.asIPv4 ?? value }
        return nil
    }

    // MARK: - socket plumbing

    /// Send the whole chunk, blocking on `tcpQueue`.
    ///
    /// `write` can return short - it wrote some of the buffer and the kernel's
    /// send window is full - and that is not an error, so this loops until every
    /// byte is gone the way espota's `connection.sendall` does. EINTR restarts the
    /// write from where it stopped. The transfer is lock-step, so only one send is
    /// ever queued on `tcpQueue` at a time.
    private func send(_ data: Data, over fd: Int32) async throws {
        try await withCheckedThrowingContinuation { continuation in
            tcpQueue.async {
                continuation.resume(with: Result { try Self.writeAll(fd, data) })
            }
        }
    }

    /// `write` the whole buffer, looping on partial writes and EINTR.
    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base + offset, raw.count - offset)
                if written < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw SocketError(reason: posixMessage(code))
                }
                // A zero-length `write` of a nonempty buffer is not defined to
                // happen on a stream socket; treat it as a broken connection
                // rather than spin.
                if written == 0 {
                    throw SocketError(reason: "the connection accepted no bytes")
                }
                offset += written
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

    /// Whatever has arrived on the TCP stream, up to `maximum` bytes, blocking on
    /// `tcpQueue`.
    ///
    /// `poll` carries the timeout the way it does in `UDPExchange`: a silent panel
    /// ends the wait with `replyTimedOut` instead of parking the queue forever,
    /// and there is no separate timer racing the read. One `recv` after the poll
    /// takes whatever short reply is there - the panel's replies are unframed byte
    /// counts, so waiting for a full buffer would wait forever.
    ///
    /// EOF IS CARRIED, NOT COLLAPSED INTO EMPTY DATA. `recv` returning 0 is the
    /// panel's `client.stop()` and means the stream is over; `recv` returning
    /// bytes is data with the stream still open. The two mean opposite things and
    /// only the caller knows which it is looking at, so `isClosed` is reported
    /// alongside the data rather than inferred from an empty buffer. Unlike the
    /// old `NWConnection.receive`, a POSIX `recv` never returns data and EOF in
    /// the same call - the close arrives as a subsequent zero-length read - which
    /// the accumulating tail logic already handles.
    private func receive(
        on fd: Int32, maximum: Int, timeout: Double
    ) async throws -> Reply {
        try await withCheckedThrowingContinuation { continuation in
            tcpQueue.async {
                continuation.resume(with: Result {
                    try Self.readReply(fd, maximum: maximum, timeout: timeout)
                })
            }
        }
    }

    /// The blocking read body: poll to the deadline, then one `recv`.
    private static func readReply(
        _ fd: Int32, maximum: Int, timeout: Double
    ) throws -> Reply {
        let deadline = DispatchTime.now() + timeout
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let now = DispatchTime.now()
            if now >= deadline { throw timedOut }
            let remaining = deadline.uptimeNanoseconds - now.uptimeNanoseconds
            // Never below 1ms: poll treats a negative timeout as "wait forever",
            // and the deadline guard above has already handled expiry.
            let remainingMs = max(Int(remaining / 1_000_000), 1)
            let ready = poll(&descriptor, 1, Int32(clamping: remainingMs))
            if ready < 0 {
                let code = errno
                if code == EINTR { continue }
                throw SocketError(reason: posixMessage(code))
            }
            if ready == 0 { throw timedOut }
            break
        }
        var buffer = [UInt8](repeating: 0, count: maximum)
        while true {
            let received = recv(fd, &buffer, maximum, 0)
            if received < 0 {
                let code = errno
                if code == EINTR { continue }
                throw SocketError(reason: posixMessage(code))
            }
            // recv == 0 is EOF: the panel closed the stream, no bytes.
            if received == 0 { return Reply(data: Data(), isClosed: true) }
            return Reply(data: Data(buffer.prefix(received)), isClosed: false)
        }
    }

    /// The read timeout, worded exactly as the old `NWConnection` path worded it
    /// so the transfer and tail classification report it unchanged.
    private static var timedOut: Failure {
        .replyTimedOut(waitingFor: "acknowledging the data it had been sent")
    }

    /// A `errno` value as its localized system string, shared with the accept and
    /// write paths.
    fileprivate static func posixMessage(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

/// A local socket failure carrying a POSIX message. The transfer loop wraps
/// whatever `send`/`receive` throw into `transferFailed(reason:)` using
/// `localizedDescription`, so this exists to give that reason the system's own
/// wording for the errno rather than a Swift bridging string.
private struct SocketError: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

/// A POSIX IPv4 TCP server the panel dials back to, and the wait for it.
///
/// This is espota.py's listener transcribed with public Darwin/POSIX calls:
/// `socket(AF_INET, SOCK_STREAM)`, `SO_REUSEADDR`, `bind(('0.0.0.0', 0))`,
/// `listen(1)`, then `settimeout(10); accept()`. It replaces the `NWListener`
/// that, on the live network, left the panel logging `OTA_CONNECT_ERROR` however
/// its local endpoint and readiness were configured. Binding `AF_INET` directly
/// also means the accepted peer is a plain IPv4 sockaddr rather than the
/// dual-stack IPv4-mapped form, so the family the panel connects on is no longer
/// in question.
private final class PanelTCPServer: @unchecked Sendable {
    /// The listening socket. IPv4, bound to `0.0.0.0` on a kernel-assigned port.
    private let fd: Int32
    /// The kernel-assigned port, read back with `getsockname`. Safe to advertise
    /// synchronously: the socket is already listening when this type is created.
    let port: UInt16
    private let lock = NSLock()
    private var isClosed = false

    private init(fd: Int32, port: UInt16) {
        self.fd = fd
        self.port = port
    }

    /// Create the socket, bind to `0.0.0.0:0`, listen, and read back the port.
    ///
    /// Fully listening on return, so the caller can put the port in the invitation
    /// at once - there is no readiness to poll for the way `NWListener` needed.
    /// Any failing step closes the socket and throws `couldNotListen` with the
    /// POSIX reason, matching the error the old listener path produced.
    static func start() throws -> PanelTCPServer {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw FirmwarePusher.Failure.couldNotListen(
                FirmwarePusher.posixMessage(errno))
        }
        // The only option set, and the one espota sets: let the port be reused
        // promptly across pushes rather than sit in TIME_WAIT. Safe - it does not
        // widen who can connect - and a failure to set it is not worth aborting a
        // push over, so it is best-effort.
        var reuse: Int32 = 1
        _ = setsockopt(
            fd, SOL_SOCKET, SO_REUSEADDR, &reuse,
            socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY.bigEndian  // 0.0.0.0
        address.sin_port = 0  // let the kernel choose the port
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addr in
                bind(fd, addr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw FirmwarePusher.Failure.couldNotListen(
                FirmwarePusher.posixMessage(code))
        }
        // Backlog of 1, as espota uses: exactly one panel is expected to dial
        // back. A stray that arrives alongside it queues behind, and the accept
        // loop rejects the stray without giving up the wait.
        guard listen(fd, 1) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw FirmwarePusher.Failure.couldNotListen(
                FirmwarePusher.posixMessage(code))
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addr in
                getsockname(fd, addr, &length)
            }
        }
        guard named == 0 else {
            let code = errno
            Darwin.close(fd)
            throw FirmwarePusher.Failure.couldNotListen(
                FirmwarePusher.posixMessage(code))
        }
        return PanelTCPServer(fd: fd, port: UInt16(bigEndian: actual.sin_port))
    }

    /// Close the listening socket. Idempotent: `push` defers a close and also
    /// closes explicitly once `accept` has returned, so this runs twice.
    func close() {
        lock.lock()
        let shouldClose = !isClosed
        isClosed = true
        lock.unlock()
        if shouldClose { Darwin.close(fd) }
    }

    /// Wait for the panel's return connection, running the blocking `poll`/
    /// `accept` loop on `queue` and handing the accepted fd back through a checked
    /// continuation.
    ///
    /// `poll` carries the connect-back timeout, so a panel that never dials back
    /// ends the wait with `panelNeverConnected` rather than parking the queue.
    /// EINTR restarts the wait with the time that is left. A peer that is a
    /// DEFINITE different address is closed and the wait CONTINUES on the
    /// remaining budget - a stray on the LAN cannot consume the panel's one slot -
    /// while anything indeterminate is accepted, per `FirmwarePusher.peer`'s
    /// fail-open rule. The accepted fd is the caller's to close.
    func accept(
        from address: String, timeout: Double, on queue: DispatchQueue
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try self.acceptLoop(from: address, timeout: timeout)
                })
            }
        }
    }

    private func acceptLoop(from address: String, timeout: Double) throws -> Int32 {
        let deadline = DispatchTime.now() + timeout
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let now = DispatchTime.now()
            if now >= deadline { throw timedOut(timeout) }
            let remaining = deadline.uptimeNanoseconds - now.uptimeNanoseconds
            let remainingMs = max(Int(remaining / 1_000_000), 1)
            let ready = poll(&descriptor, 1, Int32(clamping: remainingMs))
            if ready < 0 {
                let code = errno
                if code == EINTR { continue }
                // A hard poll failure on the listening socket is this Mac's
                // listening side failing, not the panel being slow, so it is the
                // same class of error as a bind that would not take.
                throw FirmwarePusher.Failure.couldNotListen(
                    FirmwarePusher.posixMessage(code))
            }
            if ready == 0 { throw timedOut(timeout) }

            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addr in
                    Darwin.accept(fd, addr, &length)
                }
            }
            if client < 0 {
                let code = errno
                // EINTR is a signal; ECONNABORTED is a peer that hung up between
                // the SYN and the accept. Neither is the panel and neither ends
                // the wait - poll again on the time that is left.
                if code == EINTR || code == ECONNABORTED { continue }
                throw FirmwarePusher.Failure.couldNotListen(
                    FirmwarePusher.posixMessage(code))
            }
            if FirmwarePusher.peer(storage, length: length, isFrom: address) {
                return client
            }
            // A definite different address. Close it and keep waiting so the
            // stray does not take the one transfer slot from the panel.
            Darwin.close(client)
        }
    }

    private func timedOut(_ seconds: Double) -> FirmwarePusher.Failure {
        .panelNeverConnected(seconds: Int(seconds))
    }
}

/// One espota UDP round trip over a fresh connected POSIX datagram socket.
///
/// espota.py opens a new socket for the invitation and another for the auth
/// reply, `connect`s it to the panel, sends one line and waits one timeout for
/// one datagram. This mirrors that with public Darwin/POSIX calls rather than
/// `NWConnection`, because on the live network the Network.framework UDP path did
/// not interoperate with the panel - the invitation went out and nothing came
/// back - while a connected `SOCK_DGRAM` socket from the same Mac to the same
/// address and port got `AUTH <nonce>` at once. The panel and the invitation
/// syntax were both fine; the datagram layer was the problem.
///
/// The socket is CONNECTED before the send on purpose: a connected datagram
/// socket only delivers datagrams from the peer it is connected to, so the kernel
/// does the source-address and source-port filtering that an unconnected socket
/// would need `recvfrom` and a manual comparison to do. The reply can therefore
/// only be the panel's.
enum UDPExchange {
    /// Why an exchange did not return a datagram.
    enum TransportError: Error, Equatable {
        /// `poll` ran out of time with nothing to read. The panel said nothing;
        /// the caller decides whether that is worth retrying (the invitation
        /// retries, the auth reply does not).
        case timedOut
        /// The connected socket surfaced an ICMP error while waiting for or
        /// taking the reply: the panel's host answered "port unreachable"
        /// (ECONNREFUSED), or a router answered "host unreachable"
        /// (EHOSTUNREACH) or "network unreachable" (ENETUNREACH). A connected
        /// datagram socket delivers these asynchronously through `poll`/`recv`
        /// as the error from an earlier send. Like `timedOut` this means "no
        /// reply from the panel this attempt", not "this Mac cannot send", so
        /// the caller treats it the same as silence - the invitation spends one
        /// attempt and tries again, the auth reply gives up without retrying -
        /// rather than as a local transport failure. Carries the POSIX message.
        case unreachable(reason: String)
        /// A local step failed - resolve, socket, connect or send - carrying the
        /// POSIX (or getaddrinfo) message. Never silence, so never retried as if
        /// it were.
        case failed(reason: String)
    }

    /// The maximum datagram taken in one read. The panel's replies are short
    /// (`AUTH ` plus 64 hex, `OK`, or a refusal string), so a single MTU-sized
    /// buffer holds any of them whole.
    private static let receiveBufferBytes = 1500

    /// Send `payload` to `host`:`port` and wait up to `timeout` seconds for one
    /// reply datagram, running the blocking socket work on `queue`.
    ///
    /// The whole exchange - resolve, socket, connect, send, poll, recv - runs in
    /// one block dispatched to `queue` and hands its result back through a checked
    /// continuation. `poll` carries the timeout itself, so the block cannot park
    /// indefinitely and there is no separate timer racing the recv.
    static func perform(
        payload: Data, host: String, port: UInt16, timeout: Double,
        on queue: DispatchQueue
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try exchange(
                        payload: payload, host: host, port: port, timeout: timeout)
                })
            }
        }
    }

    /// The blocking body. Every path closes the socket exactly once through the
    /// `defer`, including the throwing ones.
    private static func exchange(
        payload: Data, host: String, port: UInt16, timeout: Double
    ) throws -> Data {
        var hints = addrinfo()
        // Numeric host and numeric service only: the address handed in is the
        // panel's live resolved address, so there is no name to look up and no
        // reason to let getaddrinfo make a DNS query. AF_UNSPEC lets a numeric
        // IPv4 literal resolve to AF_INET and a numeric IPv6 one to AF_INET6
        // without either being forced.
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP

        var info: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &info)
        guard status == 0, let resolved = info else {
            throw TransportError.failed(
                reason: String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(info) }
        guard let addr = resolved.pointee.ai_addr else {
            throw TransportError.failed(reason: "the address could not be read")
        }

        let fd = socket(
            resolved.pointee.ai_family,
            resolved.pointee.ai_socktype,
            resolved.pointee.ai_protocol)
        guard fd >= 0 else {
            throw TransportError.failed(reason: posixMessage(errno))
        }
        defer { close(fd) }

        try connectSocket(fd, addr, resolved.pointee.ai_addrlen)
        try sendDatagram(fd, payload)
        return try receiveDatagram(fd, timeout: timeout)
    }

    /// `connect`, retrying on EINTR. On a datagram socket this only records the
    /// peer, so it returns at once, but a signal can still interrupt it.
    private static func connectSocket(
        _ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t
    ) throws {
        while true {
            if connect(fd, addr, len) == 0 { return }
            let code = errno
            if code == EINTR { continue }
            throw TransportError.failed(reason: posixMessage(code))
        }
    }

    /// `send` the whole datagram, retrying on EINTR. A short write on a datagram
    /// socket is not a partial success - the datagram is atomic - so anything
    /// other than the full length is a failure.
    private static func sendDatagram(_ fd: Int32, _ payload: Data) throws {
        let outcome: (sent: Int, code: Int32) = payload.withUnsafeBytes { raw in
            while true {
                let sent = send(fd, raw.baseAddress, raw.count, 0)
                if sent < 0 && errno == EINTR { continue }
                return (sent, errno)
            }
        }
        if outcome.sent < 0 {
            throw TransportError.failed(reason: posixMessage(outcome.code))
        }
        guard outcome.sent == payload.count else {
            throw TransportError.failed(
                reason: "only \(outcome.sent) of \(payload.count) bytes were sent")
        }
    }

    /// Wait up to `timeout` for the socket to become readable, then take one
    /// datagram. `poll` gets the timeout so a silent panel ends the wait instead
    /// of hanging it; EINTR restarts the wait with the time that is left rather
    /// than the whole budget again.
    ///
    /// A connected datagram socket also reports the ICMP errors the panel's host
    /// or a router sends back for an earlier datagram, and they surface here on
    /// `poll` or `recv` rather than on send. Those errno values are classified as
    /// `.unreachable` (see `receiveError`) so the caller can treat them as "no
    /// reply this attempt" rather than as a local transport failure; every other
    /// errno stays `.failed`.
    private static func receiveDatagram(_ fd: Int32, timeout: Double) throws -> Data {
        let deadline = DispatchTime.now() + timeout
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let now = DispatchTime.now()
            if now >= deadline { throw TransportError.timedOut }
            let remaining = deadline.uptimeNanoseconds - now.uptimeNanoseconds
            // Never below 1ms: poll treats a negative timeout as "wait forever",
            // and the `now >= deadline` guard above has already handled expiry, so
            // clamping up cannot turn a finished wait into an endless one.
            let remainingMs = max(Int(remaining / 1_000_000), 1)
            let ready = poll(&descriptor, 1, Int32(clamping: remainingMs))
            if ready < 0 {
                let code = errno
                if code == EINTR { continue }
                throw receiveError(code)
            }
            if ready == 0 { throw TransportError.timedOut }
            break
        }
        var buffer = [UInt8](repeating: 0, count: receiveBufferBytes)
        while true {
            let received = recv(fd, &buffer, buffer.count, 0)
            if received < 0 {
                let code = errno
                if code == EINTR { continue }
                throw receiveError(code)
            }
            return Data(buffer.prefix(received))
        }
    }

    /// Classify an errno seen on `poll`/`recv` of the connected socket. The three
    /// unreachable codes are the ICMP errors the panel's host or a router returns
    /// for a datagram that reached no listener - "no reply this attempt", not a
    /// fault on this Mac - so they become `.unreachable`; anything else is a
    /// genuine local failure and stays `.failed`.
    private static func receiveError(_ code: Int32) -> TransportError {
        switch code {
        case ECONNREFUSED, EHOSTUNREACH, ENETUNREACH:
            return .unreachable(reason: posixMessage(code))
        default:
            return .failed(reason: posixMessage(code))
        }
    }

    /// A `errno` value as its localized system string. `strerror` is per-locale,
    /// which is what makes these messages readable rather than a bare number.
    private static func posixMessage(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
