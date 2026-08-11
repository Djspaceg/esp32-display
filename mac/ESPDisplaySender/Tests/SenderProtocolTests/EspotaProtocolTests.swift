import XCTest

@testable import SenderProtocol

/// The espota push, checked against something other than itself.
///
/// WHERE THE EXPECTED VALUES COME FROM, and why it matters here more than
/// elsewhere: this is a re-implementation of a challenge/response whose only
/// other implementations are `espota.py` and `ArduinoOTA.cpp`, and a wrong
/// derivation is invisible from this side - the panel answers
/// `Authentication Failed`, exactly as it would for a mistyped password. So
/// every hash in this file was produced by python3's `hashlib`, which is the
/// same library `espota.py` computes with, and the command that produced it is
/// pasted above the literal. Asserting the Swift code against a constant the
/// Swift code produced would pass with the arithmetic wrong.
///
/// The parsing tests are checked against the two upstream files by hand instead,
/// since there is no oracle to run for "what does the panel send".
final class EspotaProtocolTests: XCTestCase {

    // MARK: - constants

    /// These have to match the panel, and none of them is negotiable at runtime,
    /// so they are pinned against the two files they came from.
    func testConstantsMatchTheCore() {
        // ArduinoOTA's default, and what display_stream.ino passes to setPort.
        XCTAssertEqual(EspotaProtocol.port, 3232)
        // espota.py: FLASH = 0, AUTH = 200.
        XCTAssertEqual(EspotaProtocol.flashCommand, 0)
        XCTAssertEqual(EspotaProtocol.authCommand, 200)
        // espota.py: f.read(1024) per round trip.
        XCTAssertEqual(EspotaProtocol.chunkBytes, 1024)
        // ArduinoOTA.cpp:288 - PBKDF2_HMACBuilder(&sha256, _password, salt, 10000)
        XCTAssertEqual(EspotaProtocol.pbkdf2Iterations, 10_000)
        XCTAssertEqual(EspotaProtocol.derivedKeyBytes, 32)
        XCTAssertEqual(EspotaProtocol.sha256HexLength, 64)
        XCTAssertEqual(EspotaProtocol.md5HexLength, 32)
    }

    // MARK: - step 2: the invitation line

    /// The exact bytes espota.py's `"%d %d %d %s\n"` produces for these inputs.
    /// Single spaces and a trailing newline, because the panel parses the fields
    /// positionally and terminates the md5 on the newline.
    func testInvitationLineIsTheExactTextThePanelParses() {
        let line = EspotaProtocol.invitationLine(
            hostPort: 51_234, imageBytes: 1_168_784,
            md5Hex: "0123456789abcdef0123456789abcdef")

        XCTAssertEqual(
            line, "0 51234 1168784 0123456789abcdef0123456789abcdef\n")
        // Spelled out separately: a change that dropped the newline or doubled a
        // space would still contain the fields.
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(line.filter { $0 == " " }.count, 3)
        XCTAssertEqual(
            line.trimmingCharacters(in: .newlines).split(separator: " ").count, 4)
    }

    func testInvitationLineCarriesTheAssignedPortNotTheOtaPort() {
        // The port in the line is the HOST's listener, which the panel dials
        // back to. Sending 3232 here would tell the panel to connect to itself.
        let line = EspotaProtocol.invitationLine(
            hostPort: 61_000, imageBytes: 42, md5Hex: "d41d8cd98f00b204e9800998ecf8427e")

        XCTAssertEqual(line, "0 61000 42 d41d8cd98f00b204e9800998ecf8427e\n")
    }

    // MARK: - step 3: the invitation reply

    func testUnauthenticatedPanelRepliesOK() {
        // ArduinoOTA.cpp:264 - _udp_ota.print("OK"), no terminator.
        XCTAssertEqual(EspotaProtocol.parseInvitationReply("OK"), .accepted)
        // A future core adding a newline must not read as a refusal.
        XCTAssertEqual(EspotaProtocol.parseInvitationReply("OK\n"), .accepted)
        XCTAssertEqual(EspotaProtocol.parseInvitationReply(" OK "), .accepted)
    }

    func testChallengeCarriesTheNonce() {
        let nonce = String(repeating: "ab", count: 32)

        XCTAssertEqual(
            EspotaProtocol.parseInvitationReply("AUTH \(nonce)"),
            .challenge(nonce: nonce))
        XCTAssertEqual(
            EspotaProtocol.parseInvitationReply("AUTH \(nonce)\n"),
            .challenge(nonce: nonce))
    }

    /// A 64-character nonce is the PBKDF2 protocol; 32 is pre-3.3.1 MD5, which
    /// this app refuses rather than implements; anything else is malformed and
    /// says what it was.
    func testNonceLengthSelectsTheProtocol() {
        XCTAssertEqual(
            EspotaProtocol.classifyNonce(String(repeating: "a", count: 64)),
            .pbkdf2Sha256)
        XCTAssertEqual(
            EspotaProtocol.classifyNonce(String(repeating: "a", count: 32)),
            .legacyMD5)
        XCTAssertEqual(
            EspotaProtocol.classifyNonce(String(repeating: "a", count: 63)),
            .malformed(length: 63))
        XCTAssertEqual(EspotaProtocol.classifyNonce(""), .malformed(length: 0))
    }

    /// A legacy panel's challenge parses fine and is only refused by the
    /// classifier, so the two steps have to be checked together: the nonce
    /// reaches the caller, and the caller is told it cannot be answered.
    func testLegacyPanelChallengeIsParsedThenRefused() throws {
        let legacy = String(repeating: "9", count: 32)

        guard case .challenge(let nonce) =
            EspotaProtocol.parseInvitationReply("AUTH \(legacy)")
        else { return XCTFail("a 32-character challenge is still a challenge") }
        XCTAssertEqual(nonce, legacy)
        XCTAssertEqual(EspotaProtocol.classifyNonce(nonce), .legacyMD5)
    }

    /// Anything else is quoted rather than translated, because this app does not
    /// know what it means and the panel's own words are the only clue.
    func testUnknownReplyIsARefusalCarryingTheDeviceText() {
        XCTAssertEqual(
            EspotaProtocol.parseInvitationReply("bad md5 length"),
            .refused(deviceText: "bad md5 length"))
        XCTAssertEqual(
            EspotaProtocol.parseInvitationReply("Authentication Failed"),
            .refused(deviceText: "Authentication Failed"))
        // Not OK, however close.
        XCTAssertEqual(
            EspotaProtocol.parseInvitationReply("OKAY"),
            .refused(deviceText: "OKAY"))
        // An empty datagram: nothing to quote, and not a challenge either.
        XCTAssertEqual(
            EspotaProtocol.parseInvitationReply(""), .refused(deviceText: ""))
    }

    /// `AUTH` with nothing after it cannot be answered, so it is a refusal and
    /// not a challenge with an empty nonce - which would go on to compute a
    /// response against a nonce the panel never sent.
    func testAuthWithoutANonceIsNotAChallenge() {
        XCTAssertEqual(
            EspotaProtocol.parseInvitationReply("AUTH"),
            .refused(deviceText: "AUTH"))
        XCTAssertEqual(
            EspotaProtocol.parseInvitationReply("AUTH   "),
            .refused(deviceText: "AUTH"))
    }

    /// espota.py takes `data.split()[1]`, so extra fields are ignored rather
    /// than making the reply unusable. Kept identical.
    func testExtraFieldsAfterTheNonceAreIgnored() {
        let nonce = String(repeating: "c", count: 64)

        XCTAssertEqual(
            EspotaProtocol.parseInvitationReply("AUTH \(nonce) extra"),
            .challenge(nonce: nonce))
    }

    // MARK: - step 4: the auth computation

    /// THE CENTRAL VECTOR. Produced with:
    ///
    ///     python3 -c "import hashlib;pw='a-real-password';n='ab'*32;c='cd'*32;\
    ///     ph=hashlib.sha256(pw.encode()).hexdigest();\
    ///     dk=hashlib.pbkdf2_hmac('sha256',ph.encode(),(n+':'+c).encode(),10000).hex();\
    ///     print(ph);print(dk);\
    ///     print(hashlib.sha256((dk+':'+n+':'+c).encode()).hexdigest())"
    ///
    /// which printed, in order:
    ///
    ///     980061b57e53c2de71a544b88d868652220a5f638b654459743bc497df202f9e
    ///     b7a2bf1029f505602abfc2362e593d50150a2407c9095f96f5c6efe9789e21d6
    ///     4d63ba8b1efa8949a0c5caefe7e8bc77db582e5531bdf2667c663394b4551b93
    ///
    /// All three stages are pinned separately so a failure says WHICH one is
    /// wrong: the password hash, the key derivation, or the final challenge.
    func testAuthResponseMatchesPythonHashlib() throws {
        let password = "a-real-password"
        let nonce = String(repeating: "ab", count: 32)
        let cnonce = String(repeating: "cd", count: 32)

        XCTAssertEqual(
            EspotaProtocol.sha256Hex(password),
            "980061b57e53c2de71a544b88d868652220a5f638b654459743bc497df202f9e",
            "the PBKDF2 password is the SHA256 HEX of the password")
        XCTAssertEqual(
            EspotaProtocol.derivedKeyHex(
                password: password, nonce: nonce, cnonce: cnonce),
            "b7a2bf1029f505602abfc2362e593d50150a2407c9095f96f5c6efe9789e21d6",
            "PBKDF2-HMAC-SHA256, 10000 rounds, salt is nonce:cnonce")
        XCTAssertEqual(
            EspotaProtocol.authResponse(
                password: password, nonce: nonce, cnonce: cnonce),
            "4d63ba8b1efa8949a0c5caefe7e8bc77db582e5531bdf2667c663394b4551b93")
    }

    /// A second vector with a password that is 8 characters but 10 UTF-8 bytes,
    /// so the hash is pinned over BYTES rather than characters. Produced with:
    ///
    ///     python3 -c "import hashlib;pw='pässwörd';n='0'*63+'1';c='f'*64;\
    ///     ph=hashlib.sha256(pw.encode()).hexdigest();\
    ///     dk=hashlib.pbkdf2_hmac('sha256',ph.encode(),(n+':'+c).encode(),10000).hex();\
    ///     print(dk);print(hashlib.sha256((dk+':'+n+':'+c).encode()).hexdigest())"
    ///
    ///     101b53afdeba9d73b246e5821a9fa333a069c990755306dce30a04531979d810
    ///     1204503bb3cb3b37e29ebea07da39553e70e1c1b23b4ad1ec7068550046754ae
    func testAuthResponseHashesUTF8BytesOfThePassword() {
        let password = "pässwörd"
        let nonce = String(repeating: "0", count: 63) + "1"
        let cnonce = String(repeating: "f", count: 64)

        XCTAssertEqual(password.count, 8)
        XCTAssertEqual(password.utf8.count, 10)
        XCTAssertEqual(
            EspotaProtocol.derivedKeyHex(
                password: password, nonce: nonce, cnonce: cnonce),
            "101b53afdeba9d73b246e5821a9fa333a069c990755306dce30a04531979d810")
        XCTAssertEqual(
            EspotaProtocol.authResponse(
                password: password, nonce: nonce, cnonce: cnonce),
            "1204503bb3cb3b37e29ebea07da39553e70e1c1b23b4ad1ec7068550046754ae")
    }

    /// The salt is `nonce:cnonce` in that order. Swapping them derives a
    /// perfectly well-formed key that the panel will reject, so the asymmetry is
    /// worth a test of its own rather than trusting the vector above to catch it.
    func testSaltOrderIsNonceThenCnonce() {
        let a = String(repeating: "ab", count: 32)
        let b = String(repeating: "cd", count: 32)

        XCTAssertNotEqual(
            EspotaProtocol.derivedKeyHex(password: "a-real-password", nonce: a, cnonce: b),
            EspotaProtocol.derivedKeyHex(password: "a-real-password", nonce: b, cnonce: a))
    }

    /// Every input has to reach the response. A change that dropped one would
    /// still produce 64 hex characters and still look like an answer.
    func testEveryInputChangesTheResponse() throws {
        let nonce = String(repeating: "ab", count: 32)
        let cnonce = String(repeating: "cd", count: 32)
        let base = try XCTUnwrap(EspotaProtocol.authResponse(
            password: "a-real-password", nonce: nonce, cnonce: cnonce))

        XCTAssertNotEqual(base, EspotaProtocol.authResponse(
            password: "a-real-passworD", nonce: nonce, cnonce: cnonce))
        XCTAssertNotEqual(base, EspotaProtocol.authResponse(
            password: "a-real-password",
            nonce: String(repeating: "ab", count: 31) + "ac", cnonce: cnonce))
        XCTAssertNotEqual(base, EspotaProtocol.authResponse(
            password: "a-real-password", nonce: nonce,
            cnonce: String(repeating: "cd", count: 31) + "ce"))
    }

    /// The cnonce seed, against a Python-computed value. Produced with:
    ///
    ///     python3 -c "import hashlib;print(hashlib.sha256(('display_stream.ino.bin'\
    ///     +'1168784'+'0123456789abcdef0123456789abcdef'+'192.168.1.120').encode()).hexdigest())"
    ///
    ///     7fe5dda683cc085643a885bfbfbad73ad83abbc3a18bd315e5fdcd3cb6777553
    ///
    /// The composition is `filename + str(bytes) + md5hex + address`, with no
    /// separators, exactly as espota.py's `"%s%u%s%s"` gives it. The panel never
    /// recomputes this - it takes the cnonce off the wire - so what is being
    /// pinned is agreement with the other implementation, not a requirement of
    /// the device.
    func testCnonceMatchesEspotaComposition() {
        let seed = EspotaProtocol.cnonceSeed(
            filename: "display_stream.ino.bin", imageBytes: 1_168_784,
            md5Hex: "0123456789abcdef0123456789abcdef",
            panelAddress: "192.168.1.120")

        XCTAssertEqual(
            seed,
            "display_stream.ino.bin11687840123456789abcdef0123456789abcdef192.168.1.120")
        XCTAssertEqual(
            EspotaProtocol.cnonce(
                filename: "display_stream.ino.bin", imageBytes: 1_168_784,
                md5Hex: "0123456789abcdef0123456789abcdef",
                panelAddress: "192.168.1.120"),
            "7fe5dda683cc085643a885bfbfbad73ad83abbc3a18bd315e5fdcd3cb6777553")
    }

    /// A second seed, from a different shape of input, so the field ORDER is
    /// pinned and not just the concatenation. Produced with:
    ///
    ///     python3 -c "import hashlib;print(hashlib.sha256(('a.bin'+'1'\
    ///     +'d41d8cd98f00b204e9800998ecf8427e'+'10.0.0.7').encode()).hexdigest())"
    ///
    ///     8de02f817afef70e821e87481d16791ba2f7704002db0767adb439e2acb49faf
    func testCnonceFieldOrder() {
        XCTAssertEqual(
            EspotaProtocol.cnonce(
                filename: "a.bin", imageBytes: 1,
                md5Hex: "d41d8cd98f00b204e9800998ecf8427e",
                panelAddress: "10.0.0.7"),
            "8de02f817afef70e821e87481d16791ba2f7704002db0767adb439e2acb49faf")
    }

    /// The cnonce is always 64 characters, which is what the panel requires of
    /// it (ArduinoOTA.cpp:272), whatever went into the seed.
    func testCnonceIsAlwaysSixtyFourCharacters() {
        XCTAssertEqual(
            EspotaProtocol.cnonce(
                filename: "", imageBytes: 0, md5Hex: "", panelAddress: "").count, 64)
    }

    func testAuthLineIsTheExactTextThePanelParses() {
        let cnonce = String(repeating: "cd", count: 32)
        let response = String(repeating: "ef", count: 32)

        XCTAssertEqual(
            EspotaProtocol.authLine(cnonce: cnonce, response: response),
            "200 \(cnonce) \(response)\n")
    }

    // MARK: - step 5: the auth reply

    func testAuthReplyIsOKOrTheDeviceText() {
        XCTAssertEqual(EspotaProtocol.parseAuthReply("OK"), .accepted)
        XCTAssertEqual(EspotaProtocol.parseAuthReply("OK\n"), .accepted)
        // ArduinoOTA.cpp:309, the wrong-password answer.
        XCTAssertEqual(
            EspotaProtocol.parseAuthReply("Authentication Failed"),
            .refused(deviceText: "Authentication Failed"))
        XCTAssertEqual(EspotaProtocol.parseAuthReply(""), .refused(deviceText: ""))
    }

    // MARK: - step 7: chunk replies

    /// A decimal reply is the count the panel wrote, and it keeps going.
    func testDecimalChunkReplyIsAByteCount() {
        XCTAssertEqual(EspotaProtocol.classifyChunkReply("1024"), .wrote(1024))
        XCTAssertEqual(EspotaProtocol.classifyChunkReply("1024\n"), .wrote(1024))
        XCTAssertEqual(EspotaProtocol.classifyChunkReply("607"), .wrote(607))
        XCTAssertEqual(EspotaProtocol.classifyChunkReply("0"), .wrote(0))
    }

    func testOKChunkReplyMeansFinished() {
        XCTAssertEqual(EspotaProtocol.classifyChunkReply("OK"), .finished)
        XCTAssertEqual(EspotaProtocol.classifyChunkReply("OK\n"), .finished)
    }

    /// The coalesced case, and the reason `OK` is looked for first. The panel
    /// writes the last chunk's count and then its final `OK` as two writes to one
    /// TCP stream, so a single read can return both. Reading this as "wrote 1024"
    /// would leave the pusher waiting for an `OK` that already arrived.
    func testCountAndOKInOneReadMeansFinished() {
        XCTAssertEqual(EspotaProtocol.classifyChunkReply("1024OK"), .finished)
        XCTAssertEqual(EspotaProtocol.classifyChunkReply("607OK"), .finished)
    }

    func testGarbageChunkReplyIsUnexpectedAndQuoted() {
        XCTAssertEqual(
            EspotaProtocol.classifyChunkReply("ERROR[4]: Not Enough Space"),
            .unexpected("ERROR[4]: Not Enough Space"))
        XCTAssertEqual(EspotaProtocol.classifyChunkReply(""), .unexpected(""))
        XCTAssertEqual(EspotaProtocol.classifyChunkReply("  \n"), .unexpected(""))
        XCTAssertEqual(EspotaProtocol.classifyChunkReply("12a4"), .unexpected("12a4"))
    }

    /// The panel prints `%PRIu32`, so a signed field did not come from it.
    /// `Int("+1024")` is 1024 in Swift, which is why this needs its own check.
    func testSignedChunkReplyIsNotACount() {
        XCTAssertEqual(EspotaProtocol.classifyChunkReply("+1024"), .unexpected("+1024"))
        XCTAssertEqual(EspotaProtocol.classifyChunkReply("-1024"), .unexpected("-1024"))
    }

    /// Non-ASCII digits are numbers to `Character.isNumber` but not to the
    /// panel's printf, so they must not read as a count either.
    func testNonASCIIDigitsAreNotACount() {
        // ARABIC-INDIC DIGIT ONE ZERO TWO FOUR.
        XCTAssertEqual(
            EspotaProtocol.classifyChunkReply("\u{0661}\u{0660}\u{0662}\u{0664}"),
            .unexpected("\u{0661}\u{0660}\u{0662}\u{0664}"))
    }

    // MARK: - hashes

    /// The image MD5 the invitation carries, from an independent oracle:
    ///
    ///     python3 -c "import hashlib;print(hashlib.md5(b'').hexdigest());\
    ///     print(hashlib.md5(b'abc').hexdigest())"
    ///
    ///     d41d8cd98f00b204e9800998ecf8427e
    ///     900150983cd24fb0d6963f7d28e17f72
    func testMD5HexMatchesPythonHashlib() {
        XCTAssertEqual(
            EspotaProtocol.md5Hex(Data()), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(
            EspotaProtocol.md5Hex(Data("abc".utf8)),
            "900150983cd24fb0d6963f7d28e17f72")
        // 32 lowercase hex characters, which is what the panel checks for.
        XCTAssertEqual(EspotaProtocol.md5Hex(Data("abc".utf8)).count, 32)
    }

    /// python3 -c "import hashlib;print(hashlib.sha256(b'abc').hexdigest())"
    ///     ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    func testSHA256HexMatchesPythonHashlib() {
        XCTAssertEqual(
            EspotaProtocol.sha256Hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
