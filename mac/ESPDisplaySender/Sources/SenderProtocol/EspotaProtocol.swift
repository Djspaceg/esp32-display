import CommonCrypto
import CryptoKit
import Foundation

/// The `espota` push protocol: every part of it that is a decision rather than a
/// socket.
///
/// This is a second implementation of a wire protocol whose only other
/// implementations are the two files it was read out of, so it is written to
/// agree with them rather than to be tidy:
///
///   - `<core>/tools/espota.py` - the pusher, and the reference for what the
///     host sends and how it reads what comes back.
///   - `<core>/libraries/ArduinoOTA/src/ArduinoOTA.cpp` - the panel, and the
///     reference for what it actually requires. Line numbers below are from
///     esp32 core 3.3.11, which is the core this repo's firmware is built with.
///
/// THE EIGHT STEPS, in order, with the two things about them that are easy to
/// get wrong called out where they arise:
///
///  1. The host binds a TCP listener and keeps its port.
///  2. The host sends ONE UDP datagram to `<panel>:3232` reading
///     `"<FLASH> <hostTcpPort> <imageBytes> <md5hex>\n"`. `espota` retries this
///     up to ten times, one fresh socket per attempt, with a per-attempt
///     timeout. Only the port travels: the panel dials back to the UDP source
///     address (`_ota_ip = _udp_ota.remoteIP()`, ArduinoOTA.cpp:259 and :305),
///     so the host never has to know or state its own address.
///  3. The panel replies by UDP with `OK` when it has no password, or
///     `AUTH <nonce>`. Core 3.3.11 builds the nonce with SHA256 (line 244-248),
///     so it is 64 hex characters; a 32-character nonce is pre-3.3.1 firmware
///     doing MD5 challenge/response, which this app refuses rather than
///     implements - see `ChallengeKind`.
///  4. The host answers `"<AUTH> <cnonce> <response>\n"`, computed as in
///     `authResponse`. The panel recomputes exactly that (lines 285-300) and
///     requires cnonce and response to be 64 characters each (line 272).
///  5. The panel replies `OK`, or `Authentication Failed` (line 309) and returns
///     to its idle state.
///  6. The panel then opens a TCP connection to the host's listener. `espota`
///     allows ten seconds for the accept.
///  7. The host sends the image in 1024-byte chunks, waiting for a reply after
///     each one. The reply is the DECIMAL COUNT of bytes the panel wrote
///     (`client.printf("%" PRIu32, written)`, line 426), not `OK`. Only after
///     `Update.end()` succeeds does it print `OK` (line 436), so `OK` means
///     finished and a number means keep going - and because both arrive on one
///     stream, a single read can legitimately return `1024OK`. That is why
///     `classifyChunkReply` looks for `OK` before it looks for a number.
///  8. A successful push reboots the panel (line 441-444).
///
/// Everything here is pure: same inputs, same string out, no sockets and no
/// clock. `FirmwarePusher` in SenderCore owns the I/O half.
public enum EspotaProtocol {
    // MARK: - constants
    //
    // Named rather than inlined because each one has to match the panel exactly
    // and a bare literal at a call site is not checkable against the core.

    /// ArduinoOTA's own default port, and what the firmware passes to
    /// `ArduinoOTA.setPort` (`OTA_PORT` in display_stream.ino).
    public static let port: UInt16 = 3232
    /// `FLASH` in espota.py: write the application partition.
    public static let flashCommand = 0
    /// `AUTH` in espota.py, and `U_AUTH` on the panel.
    public static let authCommand = 200
    /// What the host sends per round trip. Not a network constant - the panel
    /// reads whatever is available up to 1460 bytes - but the transfer is
    /// lock-step, one reply per chunk, so this is the round-trip size.
    public static let chunkBytes = 1024
    /// PBKDF2 rounds. Hardcoded on the panel (ArduinoOTA.cpp:288), so it is not
    /// negotiable and a mismatch fails as a wrong password would.
    public static let pbkdf2Iterations = 10_000
    /// Length of the PBKDF2 output, in bytes. Matches SHA256's digest size,
    /// which is what `hashlib.pbkdf2_hmac` produces when no `dklen` is given
    /// and what the panel's `PBKDF2_HMACBuilder` produces over a SHA256 hash.
    public static let derivedKeyBytes = 32
    /// Hex digits in a SHA256 digest. The length the panel requires of both the
    /// cnonce and the response.
    public static let sha256HexLength = 64
    /// Hex digits in an MD5 digest. The panel refuses an invitation whose md5
    /// field is not this long (ArduinoOTA.cpp:237).
    public static let md5HexLength = 32

    // MARK: - step 2: the invitation

    /// The invitation datagram's payload, newline included.
    ///
    /// The panel parses this field by field with `parseInt`/`readStringUntil`
    /// (ArduinoOTA.cpp:227-236), so the single spaces and the trailing newline
    /// are structural: without the newline `_md5` would swallow whatever
    /// followed in the datagram and fail the 32-character check.
    public static func invitationLine(
        hostPort: UInt16, imageBytes: Int, md5Hex: String
    ) -> String {
        "\(flashCommand) \(hostPort) \(imageBytes) \(md5Hex)\n"
    }

    // MARK: - step 3: what came back

    /// What the panel said about an invitation.
    ///
    /// Three cases, and the third carries the panel's own words rather than a
    /// phrase of ours. Anything that is not `OK` and not a well-formed challenge
    /// is something this app did not anticipate, and quoting the device is the
    /// only way the user finds out what - `espota` does the same
    /// (`logging.error("Bad Answer: %s", data)`).
    public enum InvitationReply: Equatable, Sendable {
        /// No password is set on the panel. It is already waiting to be dialled.
        case accepted
        /// A password is set. This nonce has to be answered.
        case challenge(nonce: String)
        /// Anything else, verbatim and trimmed.
        case refused(deviceText: String)
    }

    /// Classify the panel's UDP reply to an invitation.
    ///
    /// Trimmed first because the panel writes `OK` and `AUTH %s` with no
    /// terminator (`_udp_ota.print`/`printf`, ArduinoOTA.cpp:255-266) while a
    /// datagram may still arrive with trailing whitespace from a future core; a
    /// reply that differs only in a newline is not a refusal.
    ///
    /// `AUTH` with no second field lands in `refused` rather than getting a case
    /// of its own: it is not a challenge that can be answered, and there is
    /// nothing to say about it beyond what the panel sent. (`espota` raises an
    /// IndexError on that input, which is not a behaviour worth copying.)
    public static func parseInvitationReply(_ raw: String) -> InvitationReply {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "OK" { return .accepted }
        // `split(separator:)` on whitespace, matching Python's bare `.split()`,
        // so the field is found the same way in both implementations.
        let fields = text.split(whereSeparator: { $0.isWhitespace })
        if fields.first == "AUTH", fields.count >= 2 {
            return .challenge(nonce: String(fields[1]))
        }
        return .refused(deviceText: text)
    }

    /// Which challenge/response scheme a nonce implies.
    ///
    /// Length is the whole signal, and that is `espota`'s rule too: 32 means the
    /// pre-3.3.1 MD5 protocol, 64 means PBKDF2-HMAC-SHA256. The characters are
    /// deliberately NOT checked for being hex, because the nonce is only ever
    /// used as a string - it goes into the salt and into the response's input as
    /// text - so a non-hex nonce of the right length would work on both ends,
    /// and refusing it here would make this app fail where `espota` succeeds.
    public enum ChallengeKind: Equatable, Sendable {
        /// 64 characters: core 3.3.1 and newer.
        case pbkdf2Sha256
        /// 32 characters: core older than 3.3.1, MD5 challenge/response.
        ///
        /// Not implemented here on purpose. Every panel this app can update is
        /// running firmware from this repo, which is built against 3.3.11, so
        /// reaching this case means the panel is running something much older
        /// than the app - and MD5 is the reason the core changed it. Refusing
        /// with a message that names the situation beats carrying a second
        /// crypto path that nothing exercises.
        case legacyMD5
        /// Any other length. Carries what it was, since that is the only useful
        /// thing to say about it.
        case malformed(length: Int)
    }

    public static func classifyNonce(_ nonce: String) -> ChallengeKind {
        switch nonce.count {
        case sha256HexLength: return .pbkdf2Sha256
        case md5HexLength: return .legacyMD5
        default: return .malformed(length: nonce.count)
        }
    }

    // MARK: - step 4: answering the challenge

    /// The text the client nonce is the SHA256 of.
    ///
    /// `filename` and `panelAddress` CONTRIBUTE NOTHING BUT ENTROPY. The panel
    /// never recomputes the cnonce - it reads it off the wire
    /// (ArduinoOTA.cpp:270) and feeds it into the salt as given - so it cannot
    /// check, and would not care, what went into it. The composition is kept
    /// byte-identical to `espota.py`'s `"%s%u%s%s" % (filename, content_size,
    /// file_md5, remote_addr)` anyway, so that anyone holding both files can diff
    /// the two implementations line by line instead of having to reason about
    /// which differences are safe.
    ///
    /// `imageBytes` is interpolated as a plain decimal, which is what `%u` gives
    /// for the sizes involved.
    public static func cnonceSeed(
        filename: String, imageBytes: Int, md5Hex: String, panelAddress: String
    ) -> String {
        "\(filename)\(imageBytes)\(md5Hex)\(panelAddress)"
    }

    /// The client nonce: SHA256 of `cnonceSeed`, as lowercase hex.
    public static func cnonce(
        filename: String, imageBytes: Int, md5Hex: String, panelAddress: String
    ) -> String {
        sha256Hex(cnonceSeed(
            filename: filename, imageBytes: imageBytes, md5Hex: md5Hex,
            panelAddress: panelAddress))
    }

    /// The PBKDF2 output, as lowercase hex, or nil if CommonCrypto refused the
    /// parameters.
    ///
    /// THE EASY MISTAKE, and the reason this takes the password rather than a
    /// hash: the PBKDF2 password is not the password's bytes, it is the 64-byte
    /// ASCII SHA256 HEX STRING of the password. The panel stores
    /// `sha256hex(password)` in `_password` (`setPassword`, ArduinoOTA.cpp:82-90,
    /// which the firmware calls at display_stream.ino:1528) and hands that
    /// String straight to `PBKDF2_HMACBuilder` (line 288). Deriving from the raw
    /// password instead produces a well-formed response that always fails, with
    /// the panel reporting nothing more specific than `Authentication Failed`.
    ///
    /// Returns nil only on a CommonCrypto parameter error, which for these
    /// inputs would be a bug here rather than anything a user did; the caller
    /// reports it as such instead of it silently becoming a wrong answer.
    public static func derivedKeyHex(
        password: String, nonce: String, cnonce: String
    ) -> String? {
        let salt = "\(nonce):\(cnonce)"
        guard let derived = pbkdf2SHA256(
            password: sha256Hex(password), salt: salt,
            iterations: pbkdf2Iterations, keyBytes: derivedKeyBytes)
        else { return nil }
        return hex(derived)
    }

    /// The response the panel compares against, as lowercase hex.
    ///
    /// `sha256hex(derivedKeyHex + ":" + nonce + ":" + cnonce)` - note that what
    /// is hashed is the derived key's HEX SPELLING, not its bytes, because that
    /// is what the panel concatenates (`derived_key` there is
    /// `PBKDF2_HMACBuilder::toString()`).
    public static func authResponse(
        password: String, nonce: String, cnonce: String
    ) -> String? {
        guard let derived = derivedKeyHex(
            password: password, nonce: nonce, cnonce: cnonce)
        else { return nil }
        return sha256Hex("\(derived):\(nonce):\(cnonce)")
    }

    /// The authentication datagram's payload, newline included.
    ///
    /// The panel reads the cnonce up to a space and the response up to the
    /// newline (ArduinoOTA.cpp:269-271), so both separators are structural here
    /// in the same way the invitation's are.
    public static func authLine(cnonce: String, response: String) -> String {
        "\(authCommand) \(cnonce) \(response)\n"
    }

    // MARK: - step 5: was the password right

    /// What the panel said about an authentication attempt.
    public enum AuthReply: Equatable, Sendable {
        case accepted
        /// The panel's own words. `Authentication Failed` is the one it sends for
        /// a wrong password; anything else means the exchange went off the rails
        /// somewhere this app does not model, and either way quoting it is more
        /// use than replacing it.
        case refused(deviceText: String)
    }

    public static func parseAuthReply(_ raw: String) -> AuthReply {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "OK" ? .accepted : .refused(deviceText: text)
    }

    // MARK: - step 7: the transfer

    /// What a reply to one chunk means.
    public enum ChunkReply: Equatable, Sendable {
        /// The panel has finished: `Update.end()` succeeded and it printed `OK`.
        /// A push is complete at this point and the panel is about to reboot.
        case finished
        /// Bytes written for the chunk just sent. Keep going.
        case wrote(Int)
        /// Neither. Carries the trimmed text, which is all there is to say.
        case unexpected(String)
    }

    /// Classify a reply to one chunk.
    ///
    /// THE CASE THAT SHAPES THIS FUNCTION is `1024OK`. The panel's per-write count
    /// and its final `OK` are two writes to the same TCP stream, so one read can
    /// legitimately return both, and reading that as "wrote 1024, still going"
    /// would leave the pusher waiting for a reply that had already arrived. Two
    /// things make it come out as `finished`, and it is worth being precise about
    /// which, because a mutation test showed the obvious answer to be the wrong
    /// one:
    ///
    ///   - `OK` is matched as a SUBSTRING, not compared for equality. This is the
    ///     load-bearing half - `espota` tests the same way (`"OK" in
    ///     response_text`) - and an equality check breaks `1024OK`.
    ///   - the count is only accepted when every character is an ASCII digit, so
    ///     `1024OK` is not a count either way round.
    ///
    /// Given both, the ORDER of the two checks does not matter, and the earlier
    /// version of this comment claiming it did was wrong. `OK` stays first anyway
    /// because it reads as the terminating condition it is, and because the order
    /// would become load-bearing again if the digit check were ever loosened back
    /// to a bare `Int(_:)`.
    ///
    /// That digit check is stricter than `Int(_:)` for its own reason: Swift's
    /// initialiser accepts a leading `+` or `-`, and the panel prints `%PRIu32`,
    /// so a signed field did not come from the panel and is not a count.
    public static func classifyChunkReply(_ raw: String) -> ChunkReply {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("OK") { return .finished }
        if !text.isEmpty,
           text.allSatisfy({ $0.isASCII && $0.isNumber }),
           let written = Int(text) {
            return .wrote(written)
        }
        return .unexpected(text)
    }

    // MARK: - hashes

    /// Lowercase hex SHA256 of a string's UTF-8 bytes.
    ///
    /// UTF-8 matters for the password: the panel hashes the bytes it was given
    /// over the serial line, and `tools/espdisp.py set-password` transports those
    /// bytes base64-encoded, so a password with an accent in it agrees on both
    /// ends only if this side hashes UTF-8 too. There is a test with one.
    public static func sha256Hex(_ text: String) -> String {
        hex(Data(SHA256.hash(data: Data(text.utf8))))
    }

    /// Lowercase hex MD5 of the image.
    ///
    /// MD5 here is not authentication: it is the integrity check the Update
    /// library runs over the received image (`_updater->setMD5`,
    /// ArduinoOTA.cpp:354), and the panel refuses an invitation that does not
    /// carry one. Insecure by name in CryptoKit, and correctly so, but this is
    /// the panel's format and not a choice this app gets to make.
    public static func md5Hex(_ data: Data) -> String {
        hex(Data(Insecure.MD5.hash(data: data)))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// PBKDF2-HMAC-SHA256, via CommonCrypto.
    ///
    /// CryptoKit has HKDF but no PBKDF2, so this is CommonCrypto's
    /// `CCKeyDerivationPBKDF`. The password is passed as an explicit byte count
    /// rather than as a C string so that its bytes are used as-is; nothing here
    /// depends on NUL termination.
    private static func pbkdf2SHA256(
        password: String, salt: String, iterations: Int, keyBytes: Int
    ) -> Data? {
        let passwordBytes = Array(password.utf8).map { Int8(bitPattern: $0) }
        let saltBytes = Array(salt.utf8)
        var derived = [UInt8](repeating: 0, count: keyBytes)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBytes, passwordBytes.count,
            saltBytes, saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            UInt32(iterations),
            &derived, keyBytes)
        guard status == kCCSuccess else { return nil }
        return Data(derived)
    }
}
