import XCTest

@testable import SenderProtocol

/// The `.espdispfw` container, read from bytes written out by hand here.
///
/// Hand-written on purpose, and no fixture file is checked in, for the same
/// reason `BandProtocolTests` asserts the band header bytes that
/// firmware/test/test_band_protocol.cpp also asserts by hand: this is the second
/// implementation of a format whose first implementation lives in
/// tools/espdisp.py and cannot be recompiled from this side. A shared fixture
/// would agree with whatever produced it. Two independent hand-written versions
/// only agree while the format has not moved, and that agreement is the test.
///
/// `testLayoutIsPinned` deliberately asserts the same 22-byte prefix and the same
/// 350-byte manifest that `test_bundle_layout_is_pinned` in
/// tools/test_espdisp.py asserts, so a change to the layout breaks a test on
/// both sides rather than producing files one side silently cannot read.
final class FirmwareBundleTests: XCTestCase {

    // MARK: - the layout, literally

    func testLayoutIsPinned() throws {
        // 24 bytes, and not valid UTF-8: an image is arbitrary binary.
        let payload = Data([0x00, 0x01, 0x02, 0xFF]) + Data("not really firmware\n".utf8)
        XCTAssertEqual(payload.count, 24)

        // The manifest exactly as it appears on disk: sorted keys, no spaces.
        // Written out rather than encoded, so the encoding is pinned too.
        let manifestJSON =
            #"{"built_at":"2026-01-02T03:04:05Z","firmware_version":"9.9.9","format":1,"# +
            #""images":[{"board":"c6","bytes":24,"chip":"esp32c6","# +
            #""filename":"display_stream.ino.bin","fqbn":"esp32:esp32:esp32c6","# +
            #""offset":372,"sha256":"93fcaa5a244cfb4bd4d8255e820062cc"# +
            #"4ff5ffa650e1317546bbee66d8d6c4d8"}],"source_commit":null,"# +
            #""source_dirty":false,"tool":"espdisp.py bundle"}"#
        let manifest = Data(manifestJSON.utf8)
        XCTAssertEqual(manifest.count, 350, "the hand-written manifest is 350 bytes")

        // CryptoKit against a digest computed by Python's hashlib for these same
        // 24 bytes. Two libraries agreeing is what makes the manifest's sha256
        // the number `shasum -a 256` prints for the compiled image.
        XCTAssertEqual(
            FirmwareBundle.sha256Hex(payload),
            "93fcaa5a244cfb4bd4d8255e820062cc4ff5ffa650e1317546bbee66d8d6c4d8")

        let file = Data("ESPDISPFW1\n0000000350\n".utf8) + manifest + payload
        XCTAssertEqual(file.count, 396, "22 + 350 + 24")

        // The 22-byte prefix, byte for byte. Everything after it is reached by
        // arithmetic on those ten digits.
        XCTAssertEqual(file.prefix(22), Data("ESPDISPFW1\n0000000350\n".utf8))
        XCTAssertEqual(file.prefix(11), Data("ESPDISPFW1\n".utf8), "magic and generation")
        XCTAssertEqual(file[11..<21], Data("0000000350".utf8), "ten digits, zero padded")
        XCTAssertEqual(file[21..<22], Data("\n".utf8), "and a newline")
        XCTAssertEqual(FirmwareBundle.headerBytes, 22)
        XCTAssertEqual(FirmwareBundle.magic, Data("ESPDISPFW1\n".utf8))
        XCTAssertEqual(FirmwareBundle.lengthDigits, 10)
        XCTAssertEqual(FirmwareBundle.format, 1)
        XCTAssertEqual(FirmwareBundle.fileExtension, "espdispfw")

        let bundle = try FirmwareBundle.read(file)
        XCTAssertEqual(bundle.format, 1)
        XCTAssertEqual(bundle.firmwareVersion, "9.9.9")
        XCTAssertEqual(bundle.builtAt, "2026-01-02T03:04:05Z")
        XCTAssertNil(bundle.sourceCommit, "JSON null means no git checkout")
        XCTAssertFalse(bundle.sourceDirty)
        XCTAssertEqual(bundle.tool, "espdisp.py bundle")
        XCTAssertEqual(bundle.chips, ["esp32c6"])
        XCTAssertEqual(bundle.images.count, 1)
        let image = try XCTUnwrap(bundle.image(forChip: "esp32c6"))
        XCTAssertEqual(image.board, "c6")
        XCTAssertEqual(image.chip, "esp32c6")
        XCTAssertEqual(image.fqbn, "esp32:esp32:esp32c6")
        XCTAssertEqual(image.filename, "display_stream.ino.bin")
        XCTAssertEqual(image.offset, 372, "22 + 350")
        XCTAssertEqual(image.byteCount, 24)
        XCTAssertEqual(
            image.sha256, "93fcaa5a244cfb4bd4d8255e820062cc4ff5ffa650e1317546bbee66d8d6c4d8")
        // Byte for byte, not merely the right length. An image that survived with
        // the right size and the wrong bytes is the worst outcome available: the
        // panel would take two megabytes before rejecting it.
        XCTAssertEqual(bundle.payload(forChip: "esp32c6"), payload)
    }

    // MARK: - round trips

    func testTwoImageBundleRoundTrips() throws {
        let file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec, Self.s3Spec]),
            payloads: [Self.c6Payload, Self.s3Payload])
        let bundle = try FirmwareBundle.read(file)

        XCTAssertEqual(bundle.images.map(\.chip), ["esp32c6", "esp32s3"], "manifest order")
        XCTAssertEqual(bundle.chips, ["esp32c6", "esp32s3"])
        XCTAssertEqual(bundle.payload(forChip: "esp32c6"), Self.c6Payload)
        XCTAssertEqual(bundle.payload(forChip: "esp32s3"), Self.s3Payload)
        XCTAssertNil(bundle.payload(forChip: "esp32p4"))
        XCTAssertNil(bundle.image(forChip: "esp32p4"))
        XCTAssertEqual(bundle.firmwareVersion, "1.2.0")
        XCTAssertEqual(bundle.sourceCommit, String(repeating: "a", count: 40))
        // The second image starts where the first ends, with no gap.
        XCTAssertEqual(
            bundle.images[1].offset, bundle.images[0].offset + bundle.images[0].byteCount)
        // A payload containing the magic is framed by the offsets rather than by
        // scanning for a marker, which is why the format can carry raw images.
        XCTAssertTrue(Self.c6Payload.range(of: FirmwareBundle.magic) != nil,
                      "this fixture is only interesting if it contains the magic")
    }

    func testSingleImageBundleIsNormal() throws {
        // `bundle --board c6` writes one of these, and it is a valid file rather
        // than a special case - it simply has nothing to offer an S3.
        let file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]), payloads: [Self.c6Payload])
        let bundle = try FirmwareBundle.read(file)
        XCTAssertEqual(bundle.chips, ["esp32c6"])
        XCTAssertEqual(bundle.payload(forChip: "esp32c6"), Self.c6Payload)
    }

    func testManifestKeyOrderAndWhitespaceDoNotMatter() throws {
        // espdisp.py writes the manifest sorted and compact, but that is the
        // writer's business: a future writer emitting the same object with keys
        // in another order and spaces after the colons has to be readable here.
        // Nothing in the reader may depend on the encoding.
        let payload = Data("image bytes".utf8)
        let digest = FirmwareBundle.sha256Hex(payload)
        let head =
            #"{ "tool" : "another writer", "format" : 1, "source_dirty" : true, "# +
            #""images" : [ { "sha256" : ""# + digest + #"", "bytes" : 11, "# +
            #""chip" : "esp32c6", "board" : "c6", "fqbn" : "f", "filename" : "n", "# +
            #""offset" : "#
        let tail =
            #" } ], "firmware_version" : "3.1", "built_at" : "now", "# +
            #""source_commit" : null }"#
        // The manifest states its own image's absolute offset, so its length has
        // to settle: written out long-hand here rather than solved, by choosing a
        // filler that makes the offset land on a known three-digit number.
        var offset = 0
        var manifest = Data()
        for candidate in 1...9999 {
            let attempt = Data((head + "\(candidate)" + tail).utf8)
            if FirmwareBundle.headerBytes + attempt.count == candidate {
                offset = candidate
                manifest = attempt
                break
            }
        }
        XCTAssertNotEqual(offset, 0, "no offset settled; adjust the manifest text")

        let bundle = try FirmwareBundle.read(
            FirmwareBundle.magic + Self.lengthLine(manifest.count) + manifest + payload)
        XCTAssertEqual(bundle.firmwareVersion, "3.1")
        XCTAssertEqual(bundle.tool, "another writer")
        XCTAssertTrue(bundle.sourceDirty)
        XCTAssertEqual(bundle.images[0].offset, offset)
        XCTAssertEqual(bundle.payload(forChip: "esp32c6"), payload)
    }

    func testReadsFromASlicedData() throws {
        // A `Data` that came from a slice does not start at index 0, and this
        // reader is all absolute offsets. Indexing from 0 instead of from
        // startIndex would trap here rather than fail a comparison.
        let file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]), payloads: [Self.c6Payload])
        let padded = Data([0xDE, 0xAD, 0xBE, 0xEF]) + file
        let bundle = try FirmwareBundle.read(padded[4...])
        XCTAssertEqual(bundle.payload(forChip: "esp32c6"), Self.c6Payload)
    }

    func testReadsFromAFile() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("espdisp-firmware-1.2.0.espdispfw")
        try Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]), payloads: [Self.c6Payload]).write(to: url)

        let bundle = try FirmwareBundle.read(contentsOf: url)
        XCTAssertEqual(bundle.payload(forChip: "esp32c6"), Self.c6Payload)

        // A path the user picked that has since gone away reads as a bundle
        // problem, not as a Foundation error the UI would have to translate.
        let missing = directory.appendingPathComponent("gone.espdispfw")
        XCTAssertThrowsError(try FirmwareBundle.read(contentsOf: missing)) { error in
            guard case .unreadableFile(let path, _)? = error as? FirmwareBundleError else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(path, missing.path)
        }
    }

    // MARK: - refusals, one per validation

    func testRefusesAFileTooShortToHaveAHeader() {
        expect(.tooShort(bytes: 0), reading: Data())
        // 21 bytes: the whole header bar its newline, so even the length line
        // cannot be read yet.
        expect(.tooShort(bytes: 21), reading: Data("ESPDISPFW1\n0000000350".utf8))
    }

    func testRefusesSomethingThatIsNotABundle() {
        expect(.notABundle, reading: Data(repeating: 0x41, count: 400))
        // A near miss is still not a bundle: one wrong byte in the magic, chosen
        // outside the "ESPDISPFW" prefix so this is not mistaken for a future
        // generation.
        var wrong = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]), payloads: [Self.c6Payload])
        wrong[2] = UInt8(ascii: "X")
        expect(.notABundle, reading: wrong)
    }

    func testRefusesAFutureGeneration() {
        // Named both ways round, so someone holding a newer file learns it is
        // the app that is behind rather than the file that is broken.
        let file = Data("ESPDISPFW9\n0000000350\n".utf8) + Data(repeating: 0x20, count: 350)
        expect(.unsupportedGeneration(found: "ESPDISPFW9", supported: "ESPDISPFW1"),
               reading: file)
    }

    func testRefusesAMalformedLengthLine() {
        // The `found` string in these is the 11 bytes as read, with anything
        // unprintable - including the line's own newline - shown as a dot, so a
        // file that is not a bundle at all cannot garble the message.
        let manifest = Data(repeating: 0x20, count: 40)
        expect(.malformedLengthLine(found: "00000003x0."),
               reading: FirmwareBundle.magic + Data("00000003x0\n".utf8) + manifest)
        // Ten digits and no newline: the manifest would start one byte late and
        // every offset in it would be one byte out.
        expect(.malformedLengthLine(found: "0000000040."),
               reading: FirmwareBundle.magic + Data("0000000040 0".utf8) + manifest)
        // Not zero padded, so the digits do not fill the field.
        expect(.malformedLengthLine(found: "40........."),
               reading: FirmwareBundle.magic + Data("40         \n".utf8) + manifest)
        // A signed field, which is what `Int(_:)` would take on its own. Both of
        // these are the reason the digits are checked before the number is
        // parsed. "+" would make this reader accept a file espdisp.py refuses
        // (its check is str.isdigit()), and "-" would make the manifest range run
        // backwards from offset 22.
        expect(.malformedLengthLine(found: "+000000350."),
               reading: FirmwareBundle.magic + Data("+000000350\n".utf8) + manifest)
        expect(.malformedLengthLine(found: "-000000350."),
               reading: FirmwareBundle.magic + Data("-000000350\n".utf8) + manifest)
        // A field whose bytes are not ASCII, so it does not even decode to ten
        // characters: "é" then seven digits, a newline, and the first byte of the
        // manifest making up the eleventh byte of the field.
        expect(.malformedLengthLine(found: ".0000000.."),
               reading: FirmwareBundle.magic + Data([0xC3, 0xA9])
                   + Data("0000000".utf8) + Data("\n".utf8) + manifest)
    }

    func testRefusesAManifestLongerThanTheFile() {
        let file = FirmwareBundle.magic + Self.lengthLine(5000)
            + Data(repeating: 0x20, count: 40)
        expect(.truncatedManifest(claimed: 5000, available: 40), reading: file)
    }

    func testRefusesAManifestThatIsNotJSON() {
        let manifest = Data("{not json".utf8)
        XCTAssertThrowsError(
            try FirmwareBundle.read(
                FirmwareBundle.magic + Self.lengthLine(manifest.count) + manifest)
        ) { error in
            guard case .manifestNotJSON? = error as? FirmwareBundleError else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testRefusesAManifestThatIsNotAnObject() {
        let manifest = Data("[1,2,3]".utf8)
        expect(.manifestNotAnObject,
               reading: FirmwareBundle.magic + Self.lengthLine(manifest.count) + manifest)
    }

    func testRefusesAManifestMissingAnyRequiredKey() {
        // Each key separately, so a check deleted for one of them fails here
        // rather than being covered by a neighbour.
        for key in FirmwareBundle.manifestKeys {
            let file = Self.bundleBytes(
                Self.manifest(images: [Self.c6Spec]),
                payloads: [Self.c6Payload],
                solveOffsets: false) { $0[key] = nil }
            expect(.manifestMissingKeys([key]), reading: file,
                   "removing \(key) must be refused by name")
        }
        XCTAssertEqual(
            FirmwareBundle.manifestKeys.sorted(),
            ["built_at", "firmware_version", "format", "images", "source_commit",
             "source_dirty", "tool"],
            "the required set is itself part of the format")
    }

    func testRefusesAnUnsupportedFormatGeneration() {
        let file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]), payloads: [Self.c6Payload]) {
                $0["format"] = 2
            }
        expect(.unsupportedFormat(found: 2, supported: 1), reading: file)
    }

    func testRefusesABundleWithNoImages() {
        let file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: [Self.c6Payload],
            solveOffsets: false) { $0["images"] = [Any]() }
        expect(.noImages, reading: file)
    }

    func testRefusesAnImageThatIsNotAnObject() {
        let file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: [Self.c6Payload],
            solveOffsets: false) { $0["images"] = ["not an object"] }
        expect(.imageNotAnObject(index: 0), reading: file)
    }

    func testRefusesAnImageMissingAnyRequiredKey() {
        for key in FirmwareBundle.imageKeys {
            let file = Self.bundleBytes(
                Self.manifest(images: [Self.c6Spec]),
                payloads: [Self.c6Payload],
                solveOffsets: false) { manifest in
                    var images = manifest["images"] as! [[String: Any]]
                    images[0][key] = nil
                    manifest["images"] = images
                }
            expect(.imageMissingKeys(index: 0, keys: [key]), reading: file,
                   "removing \(key) must be refused by name")
        }
        XCTAssertEqual(
            FirmwareBundle.imageKeys.sorted(),
            ["board", "bytes", "chip", "filename", "fqbn", "offset", "sha256"])
    }

    func testRefusesAFieldOfTheWrongType() {
        // A string field holding a number. Nothing in the format says a reader
        // must be typed, but this one is, so it says which field rather than
        // failing later on a comparison the user cannot interpret.
        let numericHash = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]), payloads: [Self.c6Payload]) { manifest in
                var images = manifest["images"] as! [[String: Any]]
                images[0]["sha256"] = 5
                manifest["images"] = images
            }
        expect(.fieldHasWrongType(where: "image 0", key: "sha256", wanted: "a string"),
               reading: numericHash)

        // JSON true where a number belongs. This is the one worth having a case
        // for: JSONSerialization hands back an NSNumber for a boolean too, and
        // `NSNumber(true) as? Int` is 1, so without the explicit exclusion this
        // would be read as offset 1 and refused for not being contiguous - a
        // message pointing at the wrong problem.
        let booleanOffset = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: [Self.c6Payload],
            solveOffsets: false) { manifest in
                var images = manifest["images"] as! [[String: Any]]
                images[0]["offset"] = true
                manifest["images"] = images
            }
        expect(.fieldHasWrongType(where: "image 0", key: "offset", wanted: "a whole number"),
               reading: booleanOffset)

        let stringVersion = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]), payloads: [Self.c6Payload]) {
                $0["firmware_version"] = 120
            }
        expect(.fieldHasWrongType(where: "the manifest", key: "firmware_version",
                                 wanted: "a string"),
               reading: stringVersion)
    }

    /// A number written as a float is refused even when it equals an integer,
    /// because `espdisp.py` refuses it: `json.loads("372.0")` is a float and
    /// `isinstance(offset, int)` says no.
    ///
    /// The asymmetry this closes ran the wrong way for the discipline the rest of
    /// the format keeps. `value as? Int` bridges an integral `NSNumber(double:)`
    /// straight through, so the app took files the CLI's own `bundle-info`
    /// rejects - the exact failure the strict sha256 spelling exists to avoid,
    /// one field over. No writer produces these today; that is why it was cheap
    /// to fix rather than a reason to leave it.
    ///
    /// THE MANIFEST IS PATCHED AS TEXT, and it has to be. Going through the
    /// dictionary loses the very thing under test: `JSONSerialization` writes an
    /// `NSNumber` holding 372.0 back out as `372`, so the file that reached the
    /// reader was an ordinary one and the first version of this test passed
    /// against unfixed code. What decides the type is the SPELLING in the bytes,
    /// so the bytes are what this builds.
    func testRefusesAnOffsetWrittenAsAFloat() {
        for spelling in ["372.0", "1e3", "372.5"] {
            let settled = Self.settle(Self.manifest(images: [Self.c6Spec]))
            let text = String(decoding: Self.json(settled), as: UTF8.self)
            let patched = text.replacingOccurrences(
                of: #""offset":\d+"#, with: "\"offset\":\(spelling)",
                options: .regularExpression)
            XCTAssertNotEqual(
                patched, text, "the offset spelling has to actually change")

            // The longer spelling also makes the offsets wrong, which does not
            // matter and is why the exact error is asserted: a field's type is
            // checked as it is read, so the refusal has to be about the type
            // rather than the contiguity that would otherwise catch it next.
            expect(.fieldHasWrongType(where: "image 0", key: "offset",
                                     wanted: "a whole number"),
                   reading: Self.bundleBytes(
                       manifestText: patched, payloads: [Self.c6Payload]),
                   "offset written as \(spelling)")
        }
    }

    /// An integer spelled as an integer still reads, which is what keeps the float
    /// refusal from being a refusal of everything. Built through the same
    /// text path, so it is the patching that differs between the two tests and not
    /// the assembly.
    func testAcceptsAnOffsetWrittenAsAnInteger() throws {
        let settled = Self.settle(Self.manifest(images: [Self.c6Spec]))
        let text = String(decoding: Self.json(settled), as: UTF8.self)
        XCTAssertTrue(text.contains("\"offset\":"), "the fixture carries the field")
        let bundle = try FirmwareBundle.read(
            Self.bundleBytes(manifestText: text, payloads: [Self.c6Payload]))
        XCTAssertEqual(bundle.images.count, 1)
    }

    func testRefusesANonsensicalExtent() {
        let zeroBytes = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: [Self.c6Payload]) { manifest in
                var images = manifest["images"] as! [[String: Any]]
                images[0]["bytes"] = 0
                manifest["images"] = images
            }
        XCTAssertThrowsError(try FirmwareBundle.read(zeroBytes)) { error in
            guard case .nonsensicalExtent(_, _, _, let bytes)? = error as? FirmwareBundleError
            else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(bytes, 0, "a zero-byte image is not an image")
        }

        let negativeOffset = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: [Self.c6Payload],
            solveOffsets: false) { manifest in
                var images = manifest["images"] as! [[String: Any]]
                images[0]["offset"] = -1
                manifest["images"] = images
            }
        XCTAssertThrowsError(try FirmwareBundle.read(negativeOffset)) { error in
            guard case .nonsensicalExtent(_, _, let offset, _)? = error as? FirmwareBundleError
            else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(offset, -1)
        }
    }

    func testRefusesNonContiguousOffsets() {
        // One byte of slack between the manifest and the first image. The
        // hashes would still be right for the bytes at the stated offsets, so
        // only the contiguity check catches this - and it is what catches a
        // truncation that leaves a plausible-looking manifest.
        let solved = Self.manifest(images: [Self.c6Spec])
        var images = solved["images"] as! [[String: Any]]
        let correct = images[0]["offset"] as! Int
        // +1 keeps the digit count, so the manifest is the same length and the
        // only thing wrong with the file is the offset itself.
        images[0]["offset"] = correct + 1
        var mutated = solved
        mutated["images"] = images
        let file = Self.bundleBytes(mutated, payloads: [Self.c6Payload], solveOffsets: false)
        expect(.notContiguous(index: 0, chip: "esp32c6",
                              offset: correct + 1, expected: correct),
               reading: file)
    }

    func testRefusesAnImageRunningPastTheEndOfTheFile() {
        // A file truncated in the middle of its last image: the manifest is
        // intact and says more bytes follow than actually do.
        var file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]), payloads: [Self.c6Payload])
        let full = file.count
        file = file.prefix(full - 5)
        XCTAssertThrowsError(try FirmwareBundle.read(file)) { error in
            guard case .pastEndOfFile(_, let chip, let end, let fileBytes)?
                = error as? FirmwareBundleError
            else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(chip, "esp32c6")
            XCTAssertEqual(end, full)
            XCTAssertEqual(fileBytes, full - 5)
        }
    }

    func testRefusesTheSameChipTwice() {
        let file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec, Self.c6Spec]),
            payloads: [Self.c6Payload, Self.c6Payload])
        expect(.duplicateChip("esp32c6"), reading: file)
    }

    func testRefusesAHashThatDoesNotMatch() throws {
        // One flipped byte in the middle of an image, which is the failure this
        // format exists to catch: a copy that went wrong, or an edit.
        var file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec, Self.s3Spec]),
            payloads: [Self.c6Payload, Self.s3Payload])
        let intact = try FirmwareBundle.read(file)
        file[intact.images[1].offset + 3] ^= 0x01
        XCTAssertThrowsError(try FirmwareBundle.read(file)) { error in
            guard case .hashMismatch(let index, let chip, let expected, let actual)?
                = error as? FirmwareBundleError
            else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(index, 1)
            XCTAssertEqual(chip, "esp32s3")
            XCTAssertNotEqual(expected, actual)
            XCTAssertEqual(expected, FirmwareBundle.sha256Hex(Self.s3Payload))
        }
    }

    func testRefusesTrailingBytes() {
        let file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]), payloads: [Self.c6Payload])
            + Data("appended".utf8)
        expect(.trailingBytes(8), reading: file)
    }

    func testEveryRefusalHasAMessageAUserCanRead() {
        // The point of the typed errors is what gets shown, so the messages are
        // checked for being present and specific rather than left to a default
        // description of the enum case.
        let errors: [FirmwareBundleError] = [
            .unreadableFile(path: "/tmp/x", reason: "no such file"),
            .tooShort(bytes: 3),
            .notABundle,
            .unsupportedGeneration(found: "ESPDISPFW9", supported: "ESPDISPFW1"),
            .malformedLengthLine(found: "abc"),
            .truncatedManifest(claimed: 900, available: 40),
            .manifestNotJSON("unexpected token"),
            .manifestNotAnObject,
            .manifestMissingKeys(["tool", "images"]),
            .unsupportedFormat(found: 2, supported: 1),
            .noImages,
            .imageNotAnObject(index: 1),
            .imageMissingKeys(index: 1, keys: ["chip"]),
            .fieldHasWrongType(where: "image 0", key: "sha256", wanted: "a string"),
            .nonsensicalExtent(index: 0, chip: "esp32c6", offset: -1, bytes: 0),
            .notContiguous(index: 0, chip: "esp32c6", offset: 5, expected: 4),
            .pastEndOfFile(index: 0, chip: "esp32c6", end: 99, fileBytes: 50),
            .duplicateChip("esp32c6"),
            .hashMismatch(index: 0, chip: "esp32c6", expected: "aa", actual: "bb"),
            .trailingBytes(8),
        ]
        var seen = Set<String>()
        for error in errors {
            let message = error.localizedDescription
            XCTAssertGreaterThan(message.count, 25, "\(error) has no real message")
            // One message per way a file can be wrong. Two cases sharing wording
            // would leave a user unable to tell which happened, which is the
            // whole reason these are separate cases.
            XCTAssertTrue(seen.insert(message).inserted, "duplicate message: \(message)")
        }
        XCTAssertEqual(seen.count, errors.count)
        // Specifics worth pinning, because these are the two a user is most
        // likely to hit and the wording is what tells them what to do next.
        XCTAssertTrue(
            FirmwareBundleError.hashMismatch(
                index: 0, chip: "esp32c6", expected: "a", actual: "b")
                .localizedDescription.contains("damaged or was edited"))
        XCTAssertTrue(
            FirmwareBundleError.unsupportedGeneration(
                found: "ESPDISPFW9", supported: "ESPDISPFW1")
                .localizedDescription.contains("newer version of the app"))
    }

    // MARK: - update availability

    func testOffersAnUpdateWhenTheBundleIsNewer() throws {
        let bundle = try Self.readBundle(version: "1.3.0", images: [Self.c6Spec, Self.s3Spec])
        let outcome = bundle.availability(forChip: "esp32c6", panelVersion: "1.2.0")
        guard case .updateAvailable(let image, let bundleVersion, let panelVersion) = outcome
        else { return XCTFail("expected an update: \(outcome)") }
        XCTAssertEqual(image.chip, "esp32c6")
        XCTAssertEqual(bundleVersion, "1.3.0")
        XCTAssertEqual(panelVersion, "1.2.0")
        XCTAssertTrue(outcome.isUpdate)
        XCTAssertEqual(outcome.image?.chip, "esp32c6")
    }

    func testSaysNothingToDoWhenTheVersionsMatch() throws {
        let bundle = try Self.readBundle(version: "1.2.0", images: [Self.c6Spec])
        let outcome = bundle.availability(forChip: "esp32c6", panelVersion: "1.2.0")
        guard case .upToDate(let image, let version) = outcome else {
            return XCTFail("expected up to date: \(outcome)")
        }
        XCTAssertEqual(version, "1.2.0")
        XCTAssertEqual(image.chip, "esp32c6")
        XCTAssertFalse(outcome.isUpdate)
    }

    func testCallsAnOlderBundleADowngrade() throws {
        // Never offered as an update: it is a thing a user may well want to do
        // after a bad release, and it is a thing they must be told they are
        // doing. Two separate reasons the case has to exist.
        let bundle = try Self.readBundle(version: "1.1.0", images: [Self.c6Spec])
        let outcome = bundle.availability(forChip: "esp32c6", panelVersion: "1.2.0")
        guard case .bundleIsOlder(let image, let bundleVersion, let panelVersion) = outcome
        else { return XCTFail("expected a downgrade: \(outcome)") }
        XCTAssertEqual(image.chip, "esp32c6")
        XCTAssertEqual(bundleVersion, "1.1.0")
        XCTAssertEqual(panelVersion, "1.2.0")
        XCTAssertFalse(outcome.isUpdate, "a downgrade is not an update")
    }

    func testSaysSoWhenTheVersionsCannotBeCompared() throws {
        let bundle = try Self.readBundle(version: "1.2.0", images: [Self.c6Spec])
        for panelVersion in ["", "1.2.0-rc1", "dev"] {
            let outcome = bundle.availability(forChip: "esp32c6", panelVersion: panelVersion)
            guard case .versionsIncomparable(let image, let bundleVersion, let reported)
                = outcome
            else { return XCTFail("expected incomparable for \(panelVersion): \(outcome)") }
            XCTAssertEqual(image.chip, "esp32c6", "the image was still identified")
            XCTAssertEqual(bundleVersion, "1.2.0")
            XCTAssertEqual(reported, panelVersion)
            XCTAssertFalse(outcome.isUpdate)
        }
    }

    func testDistinguishesNoImageForThisChipFromAnUnknownChip() throws {
        // The distinction this type exists for. A panel that named its chip and
        // is not in the bundle is the wrong file - a definite contradiction. A
        // panel that did not name its chip is missing information, and saying
        // "this bundle has nothing for your panel" would be claiming to know
        // something this code does not. Same three-valued stance
        // classify_ota_target takes in tools/espdisp.py.
        let bundle = try Self.readBundle(version: "1.3.0", images: [Self.c6Spec])

        let wrongChip = bundle.availability(forChip: "esp32s3", panelVersion: "1.2.0")
        guard case .noImageForChip(let chip, let available) = wrongChip else {
            return XCTFail("expected no image for chip: \(wrongChip)")
        }
        XCTAssertEqual(chip, "esp32s3")
        XCTAssertEqual(available, ["esp32c6"], "what the bundle does carry")
        XCTAssertNil(wrongChip.image)

        for unknown: String? in [nil, "unknown", ""] {
            let outcome = bundle.availability(forChip: unknown, panelVersion: "1.2.0")
            guard case .chipUnknown(let bundleChips) = outcome else {
                return XCTFail("expected chip unknown for \(unknown ?? "nil"): \(outcome)")
            }
            XCTAssertEqual(bundleChips, ["esp32c6"])
            XCTAssertNil(outcome.image)
            XCTAssertFalse(outcome.isUpdate)
        }
        // The firmware's own token, so the two spellings cannot drift apart.
        XCTAssertEqual(ServiceMetadata.unknownChip, "unknown")
    }

    func testAnUnknownChipIsNotDecidedByTheVersions() throws {
        // Even with a bundle that is plainly newer, an unknown chip has no image
        // to offer, so the chip is answered first. Ordering, asserted, because
        // reversing the two checks would turn "I could not tell which image"
        // into a confident offer of whichever image came first.
        let bundle = try Self.readBundle(version: "9.9.9", images: [Self.c6Spec, Self.s3Spec])
        guard case .chipUnknown = bundle.availability(forChip: nil, panelVersion: "1.0.0")
        else { return XCTFail("a newer bundle must not override an unknown chip") }
    }

    // MARK: - fixtures and helpers

    private struct ImageSpec {
        let board: String
        let chip: String
        let payload: Data
    }

    /// Payloads that are not valid firmware and do not need to be. The C6 one
    /// contains the magic on purpose - see `testTwoImageBundleRoundTrips`.
    private static let c6Payload =
        Data("c6 image ".utf8) + magicInPayload + Data([0x00, 0xFF, 0x7F])
    private static let s3Payload = Data(repeating: 0xA5, count: 61) + Data("s3".utf8)
    private static let magicInPayload = Data("ESPDISPFW1\n".utf8)

    private static let c6Spec = ImageSpec(board: "c6", chip: "esp32c6", payload: c6Payload)
    private static let s3Spec = ImageSpec(board: "s3", chip: "esp32s3", payload: s3Payload)

    /// A manifest for `images`, with correct sizes and hashes and offsets that
    /// have been settled against its own encoded length.
    private static func manifest(
        images: [ImageSpec], version: String = "1.2.0"
    ) -> [String: Any] {
        var manifest: [String: Any] = [
            "format": 1,
            "firmware_version": version,
            "built_at": "2026-01-02T03:04:05Z",
            "source_commit": String(repeating: "a", count: 40),
            "source_dirty": false,
            "tool": "espdisp.py bundle",
            "images": images.map { spec -> [String: Any] in
                [
                    "board": spec.board,
                    "chip": spec.chip,
                    "fqbn": "esp32:esp32:\(spec.chip)",
                    "filename": "display_stream.ino.bin",
                    "offset": 0,
                    "bytes": spec.payload.count,
                    "sha256": FirmwareBundle.sha256Hex(spec.payload),
                ]
            },
        ]
        manifest = settle(manifest)
        return manifest
    }

    /// Assign absolute offsets and re-encode until the length stops moving.
    ///
    /// The same solve espdisp.py does, and it is needed for the same reason: the
    /// offsets are absolute from the start of the file, so the manifest describes
    /// its own length and an offset that gains a digit moves everything after it.
    private static func settle(_ manifest: [String: Any]) -> [String: Any] {
        var manifest = manifest
        guard var images = manifest["images"] as? [[String: Any]] else { return manifest }
        for _ in 0..<8 {
            let before = json(manifest).count
            var cursor = FirmwareBundle.headerBytes + before
            for index in images.indices {
                images[index]["offset"] = cursor
                cursor += (images[index]["bytes"] as? Int) ?? 0
            }
            manifest["images"] = images
            if json(manifest).count == before { return manifest }
        }
        XCTFail("manifest offsets did not settle")
        return manifest
    }

    /// Serialise a manifest the way the writer does: sorted keys, no whitespace.
    /// Sorted for determinism in these tests, not because the reader cares -
    /// `testManifestKeyOrderAndWhitespaceDoNotMatter` is the proof that it does
    /// not.
    private static func json(_ manifest: [String: Any]) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
    }

    private static func lengthLine(_ length: Int) -> Data {
        Data(String(format: "%010d\n", length).utf8)
    }

    /// Assemble a file: magic, length line, manifest, payloads concatenated.
    ///
    /// `mutate` runs before the offsets are settled. `solveOffsets: false` skips
    /// the settle entirely, for the cases whose whole point is a manifest whose
    /// offsets or length are wrong.
    private static func bundleBytes(
        _ manifest: [String: Any],
        payloads: [Data],
        solveOffsets: Bool = true,
        mutate: (inout [String: Any]) -> Void = { _ in }
    ) -> Data {
        var manifest = manifest
        mutate(&manifest)
        if solveOffsets { manifest = settle(manifest) }
        let encoded = json(manifest)
        return FirmwareBundle.magic + lengthLine(encoded.count) + encoded
            + payloads.reduce(Data(), +)
    }

    /// Assemble a file from manifest TEXT rather than a dictionary.
    ///
    /// For the cases where the exact spelling of a JSON value is the subject, and
    /// a round trip through `JSONSerialization` would normalise it away. The
    /// length line is computed from the text given, so the header stays honest
    /// about a manifest this deliberately made wrong somewhere else.
    private static func bundleBytes(manifestText: String, payloads: [Data]) -> Data {
        let encoded = Data(manifestText.utf8)
        return FirmwareBundle.magic + lengthLine(encoded.count) + encoded
            + payloads.reduce(Data(), +)
    }

    private static func readBundle(
        version: String, images: [ImageSpec]
    ) throws -> FirmwareBundle {
        try FirmwareBundle.read(
            bundleBytes(manifest(images: images, version: version),
                        payloads: images.map(\.payload)))
    }

    private static func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("espdisp-bundle-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Assert that reading `data` throws exactly `expected`.
    ///
    /// Equality on the error rather than a substring of its message, so a
    /// refusal that fires for the wrong reason - or names the wrong field, index,
    /// or number - fails here.
    private func expect(
        _ expected: FirmwareBundleError, reading data: Data, _ note: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try FirmwareBundle.read(data), note, file: file, line: line) {
            error in
            XCTAssertEqual(error as? FirmwareBundleError, expected, note,
                           file: file, line: line)
        }
    }
}
