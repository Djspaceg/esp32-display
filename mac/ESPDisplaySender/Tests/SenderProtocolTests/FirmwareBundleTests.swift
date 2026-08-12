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
        // The four payloads, none of them valid firmware and none of them valid
        // UTF-8 either: these are arbitrary binary and nothing in this path may
        // treat them as text. The leading bytes are each kind of file's real magic
        // - 0xE9 for an ESP image, 0xAA 0x50 for a partition table - so no payload
        // here is accidentally plausible in the wrong role.
        let app = Data([0x00, 0x01, 0x02, 0xFF]) + Data("not really firmware\n".utf8)
        let bootloader = Data([0xE9]) + Data("fake bootloader\n".utf8)
        let partitions = Data([0xAA, 0x50]) + Data("table\n".utf8)
        let bootApp0 = Data("ota\n".utf8)
        XCTAssertEqual(app.count, 24)
        XCTAssertEqual(bootloader.count, 17)
        XCTAssertEqual(partitions.count, 8)
        XCTAssertEqual(bootApp0.count, 4)

        // The manifest exactly as it appears on disk: sorted keys, no spaces.
        // Written out rather than encoded, so the encoding is pinned too.
        //
        // THE OFFSETS WERE SOLVED BY HAND from the format's definition, not read
        // out of a file this code produced: a pin taken from an implementation's
        // own output passes with the implementation wrong, which is the whole
        // failure it exists to catch. The arithmetic, with every offset three
        // digits wide so the manifest's length is stable at 914: the manifest ends
        // at 22 + 914 = 936, which is where the app lands; 936 + 24 = 960 the
        // bootloader; 960 + 17 = 977 the partition table; 977 + 8 = 985 boot_app0;
        // 985 + 4 = 989 the whole file.
        //
        // Sorted keys puts `app_address` first inside an image and `address` first
        // inside a part, and lands `flash_parts` between `filename` and `fqbn` -
        // which is exactly why payload order is defined by the LIST and not by
        // where the keys fall in the encoding.
        let manifestJSON =
            #"{"built_at":"2026-01-02T03:04:05Z","firmware_version":"9.9.9","format":2,"# +
            #""images":[{"app_address":65536,"board":"c6","bytes":24,"chip":"esp32c6","# +
            #""filename":"display_stream.ino.bin","flash_parts":["# +
            #"{"address":0,"bytes":17,"filename":"display_stream.ino.bootloader.bin","# +
            #""offset":960,"role":"bootloader","sha256":"# +
            #""382ef4f8036d992da0de16313b77e69ea18846f63f1fc8f1d1288947657c94d6"},"# +
            #"{"address":32768,"bytes":8,"filename":"display_stream.ino.partitions.bin","# +
            #""offset":977,"role":"partitions","sha256":"# +
            #""e58a7c4fc196c9463c577a8efa1be0b455b2cfc09a93a7195c93bf24b94cb20c"},"# +
            #"{"address":57344,"bytes":4,"filename":"boot_app0.bin","# +
            #""offset":985,"role":"boot_app0","sha256":"# +
            #""86cc25f7b4e15df03acb972f5399782cd72c3a208e772a3f5b1fa5a38af5a8fc"}],"# +
            #""fqbn":"esp32:esp32:esp32c6","offset":936,"# +
            #""sha256":"93fcaa5a244cfb4bd4d8255e820062cc4ff5ffa650e1317546bbee66d8d6c4d8"}],"# +
            #""source_commit":null,"source_dirty":false,"tool":"espdisp.py bundle"}"#
        let manifest = Data(manifestJSON.utf8)
        XCTAssertEqual(manifest.count, 914, "the hand-written manifest is 914 bytes")

        // CryptoKit against digests `shasum -a 256` printed for these same bytes,
        // so the number pinned here was computed by neither implementation. That
        // is what makes the manifest's sha256 the number a user can check with
        // ordinary tools, for the flash parts as well as for the image.
        XCTAssertEqual(
            FirmwareBundle.sha256Hex(app),
            "93fcaa5a244cfb4bd4d8255e820062cc4ff5ffa650e1317546bbee66d8d6c4d8")
        XCTAssertEqual(
            FirmwareBundle.sha256Hex(bootloader),
            "382ef4f8036d992da0de16313b77e69ea18846f63f1fc8f1d1288947657c94d6")
        XCTAssertEqual(
            FirmwareBundle.sha256Hex(partitions),
            "e58a7c4fc196c9463c577a8efa1be0b455b2cfc09a93a7195c93bf24b94cb20c")
        XCTAssertEqual(
            FirmwareBundle.sha256Hex(bootApp0),
            "86cc25f7b4e15df03acb972f5399782cd72c3a208e772a3f5b1fa5a38af5a8fc")

        let file = Data("ESPDISPFW2\n0000000914\n".utf8) + manifest
            + app + bootloader + partitions + bootApp0
        XCTAssertEqual(file.count, 989, "22 + 914 + 24 + 17 + 8 + 4")

        // The 22-byte prefix, byte for byte. Everything after it is reached by
        // arithmetic on those ten digits.
        XCTAssertEqual(file.prefix(22), Data("ESPDISPFW2\n0000000914\n".utf8))
        XCTAssertEqual(file.prefix(11), Data("ESPDISPFW2\n".utf8), "magic and generation")
        XCTAssertEqual(file[11..<21], Data("0000000914".utf8), "ten digits, zero padded")
        XCTAssertEqual(file[21..<22], Data("\n".utf8), "and a newline")
        XCTAssertEqual(FirmwareBundle.headerBytes, 22)
        XCTAssertEqual(FirmwareBundle.magic, Data("ESPDISPFW2\n".utf8))
        XCTAssertEqual(FirmwareBundle.lengthDigits, 10)
        XCTAssertEqual(FirmwareBundle.format, 2)
        XCTAssertEqual(FirmwareBundle.fileExtension, "espdispfw")
        // Payload order, byte for byte: the app, then this image's parts in listed
        // order. A reader that put the parts first, or sorted them by flash
        // address, would fail here rather than on a board.
        XCTAssertEqual(file[936..<960], app, "the app is first")
        XCTAssertEqual(file[960..<977], bootloader, "then the bootloader")
        XCTAssertEqual(file[977..<985], partitions, "then the partition table")
        XCTAssertEqual(file[985..<989], bootApp0, "then boot_app0")

        let bundle = try FirmwareBundle.read(file)
        XCTAssertEqual(bundle.format, 2)
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
        XCTAssertEqual(image.offset, 936, "22 + 914")
        XCTAssertEqual(image.byteCount, 24)
        XCTAssertEqual(
            image.sha256, "93fcaa5a244cfb4bd4d8255e820062cc4ff5ffa650e1317546bbee66d8d6c4d8")
        // Byte for byte, not merely the right length. An image that survived with
        // the right size and the wrong bytes is the worst outcome available: the
        // panel would take two megabytes before rejecting it.
        XCTAssertEqual(bundle.payload(forChip: "esp32c6"), app)

        // THE ADDRESSES COME OUT OF THE FILE. 0x10000 for the app and 0x0 for the
        // bootloader are what this bundle says, not what this reader believes:
        // `boards.txt` puts the bootloader at 0x0 for both of this repo's chips and
        // at 0x1000 for the classic ESP32, so a constant here would be wrong for
        // some board later, and wrong in a way the flash would accept.
        XCTAssertEqual(image.appAddress, 0x10000, "and 65536 is 0x10000")
        XCTAssertEqual(image.flashParts.map(\.role), ["bootloader", "partitions", "boot_app0"])
        XCTAssertEqual(image.flashParts.map(\.address), [0x0, 0x8000, 0xE000])
        XCTAssertEqual(image.flashParts.map(\.offset), [960, 977, 985])
        XCTAssertEqual(image.flashParts.map(\.byteCount), [17, 8, 4])
        XCTAssertEqual(
            image.flashParts.map(\.filename),
            ["display_stream.ino.bootloader.bin", "display_stream.ino.partitions.bin",
             "boot_app0.bin"])
        XCTAssertEqual(bundle.flashPayload(forChip: "esp32c6", role: "bootloader"), bootloader)
        XCTAssertEqual(bundle.flashPayload(forChip: "esp32c6", role: "partitions"), partitions)
        XCTAssertEqual(bundle.flashPayload(forChip: "esp32c6", role: "boot_app0"), bootApp0)
        XCTAssertNil(bundle.flashPayload(forChip: "esp32c6", role: "spiffs"))
        XCTAssertNil(bundle.flashPayload(forChip: "esp32s3", role: "bootloader"))

        // And the whole write sequence, in ascending flash address order, which for
        // this chip is the same order the core's own upload recipe uses.
        let plan = try XCTUnwrap(bundle.flashPlan(forChip: "esp32c6"))
        XCTAssertEqual(plan.map(\.role), ["bootloader", "partitions", "boot_app0", "app"])
        XCTAssertEqual(plan.map(\.address), [0x0, 0x8000, 0xE000, 0x10000])
        XCTAssertEqual(plan.map(\.payload), [bootloader, partitions, bootApp0, app])
        XCTAssertTrue(bundle.canFlashBlankDevice(chip: "esp32c6"))
        XCTAssertFalse(bundle.canFlashBlankDevice(chip: "esp32s3"))
    }

    /// A generation-1 file, byte for byte, and it is still read.
    ///
    /// These bytes are what the shipped app writes and reads today, so they are
    /// pinned rather than described: the OTA feature works over files that already
    /// exist and cannot be rebuilt without this repo at the commit they came from.
    /// A reader that quietly stopped taking them would break that with no error
    /// anyone could act on. This is the same 350-byte manifest and the same
    /// 396-byte file `testLayoutIsPinned` pinned before generation 2 existed, and
    /// `test_generation_one_layout_is_pinned_and_still_read` in
    /// tools/test_espdisp.py pins it independently.
    func testGenerationOneIsStillReadAndCarriesNoFlashParts() throws {
        let app = Data([0x00, 0x01, 0x02, 0xFF]) + Data("not really firmware\n".utf8)
        let manifestJSON =
            #"{"built_at":"2026-01-02T03:04:05Z","firmware_version":"9.9.9","format":1,"# +
            #""images":[{"board":"c6","bytes":24,"chip":"esp32c6","# +
            #""filename":"display_stream.ino.bin","fqbn":"esp32:esp32:esp32c6","# +
            #""offset":372,"sha256":"93fcaa5a244cfb4bd4d8255e820062cc"# +
            #"4ff5ffa650e1317546bbee66d8d6c4d8"}],"source_commit":null,"# +
            #""source_dirty":false,"tool":"espdisp.py bundle"}"#
        let manifest = Data(manifestJSON.utf8)
        XCTAssertEqual(manifest.count, 350, "the hand-written v1 manifest is 350 bytes")

        let file = Data("ESPDISPFW1\n0000000350\n".utf8) + manifest + app
        XCTAssertEqual(file.count, 396, "22 + 350 + 24")
        XCTAssertEqual(file.prefix(22), Data("ESPDISPFW1\n0000000350\n".utf8))
        XCTAssertEqual(FirmwareBundle.magicV1, Data("ESPDISPFW1\n".utf8))
        XCTAssertEqual(FirmwareBundle.formatV1, 1)
        // Both magics are the same width, which is what keeps the manifest at
        // offset 22 for every generation and lets `headerBytes` stay one number.
        XCTAssertEqual(FirmwareBundle.magicV1.count, FirmwareBundle.magic.count)
        XCTAssertEqual(
            FirmwareBundle.generations,
            [FirmwareBundle.magicV1: 1, FirmwareBundle.magic: 2],
            "the generations this build reads are part of the format")

        let bundle = try FirmwareBundle.read(file)
        XCTAssertEqual(bundle.format, 1, "it records which generation it read")
        XCTAssertEqual(bundle.firmwareVersion, "9.9.9")
        // THE OTA PATH IS UNCHANGED BY GENERATION 2, which is what makes reading
        // both generations cost the update path nothing: `payload(forChip:)` is
        // what FirmwareUpdateSheet asks for, and this file still answers it.
        XCTAssertEqual(bundle.payload(forChip: "esp32c6"), app)
        XCTAssertEqual(bundle.chips, ["esp32c6"])
        let image = try XCTUnwrap(bundle.image(forChip: "esp32c6"))
        XCTAssertEqual(image.offset, 372, "22 + 350")

        // And the one thing it cannot do, answered as "no" rather than as an empty
        // list of writes: a generation-1 file says nothing about flash addresses,
        // so there is no honest plan to be had from it.
        XCTAssertNil(image.appAddress, "a v1 file says nothing about flash addresses")
        XCTAssertEqual(image.flashParts, [])
        XCTAssertNil(image.flashPart(role: "bootloader"))
        XCTAssertEqual(bundle.flashPayloads, [:])
        XCTAssertNil(bundle.flashPayload(forChip: "esp32c6", role: "bootloader"))
        XCTAssertNil(bundle.flashPlan(forChip: "esp32c6"))
        XCTAssertFalse(bundle.canFlashBlankDevice(chip: "esp32c6"))
    }

    // MARK: - round trips

    func testTwoImageBundleRoundTrips() throws {
        let file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec, Self.s3Spec]),
            payloads: Self.area([Self.c6Spec, Self.s3Spec]))
        let bundle = try FirmwareBundle.read(file)

        XCTAssertEqual(bundle.images.map(\.chip), ["esp32c6", "esp32s3"], "manifest order")
        XCTAssertEqual(bundle.chips, ["esp32c6", "esp32s3"])
        XCTAssertEqual(bundle.payload(forChip: "esp32c6"), Self.c6Payload)
        XCTAssertEqual(bundle.payload(forChip: "esp32s3"), Self.s3Payload)
        XCTAssertNil(bundle.payload(forChip: "esp32p4"))
        XCTAssertNil(bundle.image(forChip: "esp32p4"))
        XCTAssertEqual(bundle.firmwareVersion, "1.2.0")
        XCTAssertEqual(bundle.sourceCommit, String(repeating: "a", count: 40))
        // The second image starts where the first image's LAST FLASH PART ends,
        // with no gap. Payload order is a flat walk - each image, then that image's
        // parts - so the second image does not follow the first application image,
        // and the arithmetic is written out rather than assumed.
        let firstImage = bundle.images[0]
        let firstParts = firstImage.flashParts.reduce(0) { $0 + $1.byteCount }
        XCTAssertEqual(
            bundle.images[1].offset, firstImage.offset + firstImage.byteCount + firstParts)
        XCTAssertEqual(firstImage.flashParts[0].offset, firstImage.offset + firstImage.byteCount)
        XCTAssertEqual(
            bundle.images[1].flashParts[0].offset,
            bundle.images[1].offset + bundle.images[1].byteCount)
        // Every payload accounted for exactly once, which is the same statement the
        // trailing-bytes refusal makes from the other end.
        let lastPart = try XCTUnwrap(bundle.images[1].flashParts.last)
        XCTAssertEqual(lastPart.offset + lastPart.byteCount, file.count)
        // And the two boards' parts are not each other's: a reader that mixed them
        // up would write one board's bootloader to the other.
        XCTAssertEqual(
            bundle.flashPayload(forChip: "esp32c6", role: "bootloader"),
            Self.c6Spec.flashParts[0].payload)
        XCTAssertEqual(
            bundle.flashPayload(forChip: "esp32s3", role: "bootloader"),
            Self.s3Spec.flashParts[0].payload)
        XCTAssertNotEqual(
            bundle.flashPayload(forChip: "esp32c6", role: "bootloader"),
            bundle.flashPayload(forChip: "esp32s3", role: "bootloader"))
        XCTAssertTrue(bundle.canFlashBlankDevice(chip: "esp32c6"))
        XCTAssertTrue(bundle.canFlashBlankDevice(chip: "esp32s3"))
        XCTAssertFalse(bundle.canFlashBlankDevice(chip: "esp32p4"))
        XCTAssertNil(bundle.flashPlan(forChip: "esp32p4"))
        // A payload containing the magic is framed by the offsets rather than by
        // scanning for a marker, which is why the format can carry raw images.
        XCTAssertTrue(Self.c6Payload.range(of: FirmwareBundle.magic) != nil,
                      "this fixture is only interesting if it contains the magic")
    }

    func testSingleImageBundleIsNormal() throws {
        // `bundle --board c6` writes one of these, and it is a valid file rather
        // than a special case - it simply has nothing to offer an S3.
        let file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]), payloads: Self.area([Self.c6Spec]))
        let bundle = try FirmwareBundle.read(file)
        XCTAssertEqual(bundle.chips, ["esp32c6"])
        XCTAssertEqual(bundle.payload(forChip: "esp32c6"), Self.c6Payload)
    }

    func testManifestKeyOrderAndWhitespaceDoNotMatter() throws {
        // espdisp.py writes the manifest sorted and compact, but that is the
        // writer's business: a future writer emitting the same object with keys
        // in another order and spaces after the colons has to be readable here.
        // Nothing in the reader may depend on the encoding - including the
        // generation-2 fields, whose sorted position puts `flash_parts` in the
        // middle of an image while payload order follows the LIST.
        let payload = Data("image bytes".utf8)
        let bootloader = Data("bootloader bytes".utf8)
        let partitions = Data("table".utf8)
        let bootApp0 = Data("ota".utf8)
        let head =
            #"{ "tool" : "another writer", "format" : 2, "source_dirty" : true, "# +
            #""images" : [ { "sha256" : ""# + FirmwareBundle.sha256Hex(payload)
            + #"", "bytes" : 11, "chip" : "esp32c6", "board" : "c6", "fqbn" : "f", "#
            + #""filename" : "n", "app_address" : 65536, "flash_parts" : [ "#
        // The parts out of role order and with their own keys shuffled, because a
        // reader must take the write order from the list and the flash address from
        // the entry rather than from either one's position.
        func part(
            _ role: String, _ address: Int, _ blob: Data, _ offset: Int
        ) -> String {
            #"{ "bytes" : \#(blob.count), "role" : "\#(role)", "# +
                #""sha256" : "\#(FirmwareBundle.sha256Hex(blob))", "# +
                #""filename" : "\#(role).bin", "offset" : \#(offset), "# +
                #""address" : \#(address) }"#
        }
        let tail =
            #" } ], "firmware_version" : "3.1", "built_at" : "now", "# +
            #""source_commit" : null }"#

        // The manifest states its own payloads' absolute offsets, so its length has
        // to settle. Solved by search over the one free number - every other offset
        // follows from it and from the payload sizes - which keeps this fixture
        // hand-written rather than produced by the solver the reader is checked
        // against.
        var appOffset = 0
        var encoded = Data()
        for candidate in 1...9999 {
            let parts = [
                part("bootloader", 0x0, bootloader, candidate + payload.count),
                part("partitions", 0x8000, partitions,
                     candidate + payload.count + bootloader.count),
                part("boot_app0", 0xE000, bootApp0,
                     candidate + payload.count + bootloader.count + partitions.count),
            ].joined(separator: ", ")
            let attempt = Data(
                (head + parts + #" ], "offset" : \#(candidate)"# + tail).utf8)
            if FirmwareBundle.headerBytes + attempt.count == candidate {
                appOffset = candidate
                encoded = attempt
                break
            }
        }
        XCTAssertNotEqual(appOffset, 0, "no offset settled; adjust the manifest text")

        let bundle = try FirmwareBundle.read(
            FirmwareBundle.magic + Self.lengthLine(encoded.count) + encoded
                + payload + bootloader + partitions + bootApp0)
        XCTAssertEqual(bundle.firmwareVersion, "3.1")
        XCTAssertEqual(bundle.tool, "another writer")
        XCTAssertTrue(bundle.sourceDirty)
        XCTAssertEqual(bundle.images[0].offset, appOffset)
        XCTAssertEqual(bundle.payload(forChip: "esp32c6"), payload)
        XCTAssertEqual(bundle.images[0].appAddress, 0x10000)
        XCTAssertEqual(
            bundle.images[0].flashParts.map(\.role),
            ["bootloader", "partitions", "boot_app0"],
            "write order comes from the list, whatever order the keys are in")
        XCTAssertEqual(bundle.flashPayload(forChip: "esp32c6", role: "boot_app0"), bootApp0)
        XCTAssertEqual(bundle.flashPlan(forChip: "esp32c6")?.map(\.role),
                       ["bootloader", "partitions", "boot_app0", "app"])
    }

    func testReadsFromASlicedData() throws {
        // A `Data` that came from a slice does not start at index 0, and this
        // reader is all absolute offsets. Indexing from 0 instead of from
        // startIndex would trap here rather than fail a comparison.
        let file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]), payloads: Self.area([Self.c6Spec]))
        let padded = Data([0xDE, 0xAD, 0xBE, 0xEF]) + file
        let bundle = try FirmwareBundle.read(padded[4...])
        XCTAssertEqual(bundle.payload(forChip: "esp32c6"), Self.c6Payload)
    }

    func testReadsFromAFile() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("espdisp-firmware-1.2.0.espdispfw")
        try Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]), payloads: Self.area([Self.c6Spec])).write(to: url)

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
            Self.manifest(images: [Self.c6Spec]), payloads: Self.area([Self.c6Spec]))
        wrong[2] = UInt8(ascii: "X")
        expect(.notABundle, reading: wrong)
    }

    func testRefusesAFutureGeneration() {
        // Named both ways round, so someone holding a newer file learns it is
        // the app that is behind rather than the file that is broken. Both
        // generations this build reads are named, because the answer to "what can
        // this app open" is now two things rather than one.
        let file = Data("ESPDISPFW9\n0000000350\n".utf8) + Data(repeating: 0x20, count: 350)
        expect(.unsupportedGeneration(found: "ESPDISPFW9",
                                      supported: "ESPDISPFW1 and ESPDISPFW2"),
               reading: file)
        // Generation 3 is the one that does not exist yet. Generation 1 does and is
        // accepted, so this also pins that the dispatch is a lookup over known
        // magics rather than a comparison against whichever is newest.
        let next = Data("ESPDISPFW3\n0000000350\n".utf8) + Data(repeating: 0x20, count: 350)
        expect(.unsupportedGeneration(found: "ESPDISPFW3",
                                      supported: "ESPDISPFW1 and ESPDISPFW2"),
               reading: next)
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
                payloads: Self.area([Self.c6Spec]),
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

    /// THE MAGIC AND THE MANIFEST'S OWN `format` HAVE TO AGREE, both ways round.
    ///
    /// They are two statements of one fact, so a file where they differ is
    /// self-contradictory whichever one is right, and believing either would mean
    /// reading one generation's body as the other's - a generation-1 manifest read
    /// as generation 2 would be refused for missing keys it was never meant to
    /// have, and the reverse would silently ignore the flash parts.
    func testRefusesAFormatThatContradictsTheMagic() {
        let future = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]), payloads: Self.area([Self.c6Spec])) {
                $0["format"] = 3
            }
        expect(.unsupportedFormat(found: 3, supported: 2), reading: future)

        // A generation-1 manifest behind generation 2's magic.
        let behind = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]), payloads: Self.area([Self.c6Spec])) {
                $0["format"] = 1
            }
        expect(.unsupportedFormat(found: 1, supported: 2), reading: behind)

        // And a generation-2 manifest behind generation 1's magic.
        let ahead = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]), payloads: Self.area([Self.c6Spec]),
            magic: FirmwareBundle.magicV1)
        expect(.unsupportedFormat(found: 2, supported: 1), reading: ahead)
    }

    func testRefusesABundleWithNoImages() {
        let file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: Self.area([Self.c6Spec]),
            solveOffsets: false) { $0["images"] = [Any]() }
        expect(.noImages, reading: file)
    }

    func testRefusesAnImageThatIsNotAnObject() {
        let file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: Self.area([Self.c6Spec]),
            solveOffsets: false) { $0["images"] = ["not an object"] }
        expect(.imageNotAnObject(index: 0), reading: file)
    }

    func testRefusesAnImageMissingAnyRequiredKey() {
        for key in FirmwareBundle.imageKeysV2 {
            let file = Self.bundleBytes(
                Self.manifest(images: [Self.c6Spec]),
                payloads: Self.area([Self.c6Spec]),
                solveOffsets: false) { manifest in
                    var images = manifest["images"] as! [[String: Any]]
                    images[0][key] = nil
                    manifest["images"] = images
                }
            expect(.imageMissingKeys(index: 0, keys: [key]), reading: file,
                   "removing \(key) must be refused by name")
        }
        // Both key sets are part of the format, and the relationship between them
        // is the whole of what generation 2 added to an image entry.
        XCTAssertEqual(
            FirmwareBundle.imageKeys.sorted(),
            ["board", "bytes", "chip", "filename", "fqbn", "offset", "sha256"])
        XCTAssertEqual(
            FirmwareBundle.imageKeysV2.sorted(),
            ["app_address", "board", "bytes", "chip", "filename", "flash_parts",
             "fqbn", "offset", "sha256"])
        XCTAssertEqual(
            Set(FirmwareBundle.imageKeysV2).subtracting(FirmwareBundle.imageKeys),
            ["app_address", "flash_parts"],
            "generation 2 adds two keys and changes none")
        XCTAssertEqual(
            FirmwareBundle.flashPartKeys.sorted(),
            ["address", "bytes", "filename", "offset", "role", "sha256"])
        XCTAssertEqual(
            FirmwareBundle.requiredFlashRoles, ["bootloader", "partitions", "boot_app0"],
            "the three roles a blank board needs, in write order")

        // A GENERATION-1 IMAGE IS NOT HELD TO THE NEW KEYS. Removing one of them
        // from a v1 file changes nothing, because a v1 entry never carried them.
        for key in ["app_address", "flash_parts"] {
            let file = Self.bundleBytes(
                Self.manifest(images: [Self.c6Spec], generation: FirmwareBundle.formatV1),
                payloads: Self.area([Self.c6Spec], generation: FirmwareBundle.formatV1),
                magic: FirmwareBundle.magicV1,
                solveOffsets: false) { manifest in
                    var images = manifest["images"] as! [[String: Any]]
                    images[0][key] = nil
                    manifest["images"] = images
                }
            XCTAssertNoThrow(try FirmwareBundle.read(file),
                             "a v1 file needs no \(key)")
        }
    }

    // MARK: - refusals about the flash parts, one per validation

    func testRefusesAGenerationTwoImageWithNoFlashParts() {
        // An empty list, which is a different thing from the key being absent: the
        // file says it is one that can set up a new board and then lists nothing to
        // write, so it cannot do the only thing that distinguishes its generation.
        let file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: Self.c6Payload) { manifest in
                var images = manifest["images"] as! [[String: Any]]
                images[0]["flash_parts"] = [Any]()
                manifest["images"] = images
            }
        expect(.noFlashParts(index: 0, chip: "esp32c6"), reading: file)

        // And a `flash_parts` that is not a list at all.
        let notAList = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: Self.c6Payload) { manifest in
                var images = manifest["images"] as! [[String: Any]]
                images[0]["flash_parts"] = ["bootloader": "yes"]
                manifest["images"] = images
            }
        expect(.noFlashParts(index: 0, chip: "esp32c6"), reading: notAList)
    }

    func testRefusesAFlashPartThatIsNotAnObject() {
        let file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: Self.area([Self.c6Spec])) { manifest in
                var images = manifest["images"] as! [[String: Any]]
                images[0]["flash_parts"] = ["bootloader"]
                manifest["images"] = images
            }
        expect(.flashPartNotAnObject(index: 0, partIndex: 0), reading: file)
    }

    func testRefusesAFlashPartMissingAnyRequiredKey() {
        for key in FirmwareBundle.flashPartKeys where key != "offset" {
            let file = Self.bundleBytes(
                Self.manifest(images: [Self.c6Spec]),
                payloads: Self.area([Self.c6Spec])) { manifest in
                    var images = manifest["images"] as! [[String: Any]]
                    var parts = images[0]["flash_parts"] as! [[String: Any]]
                    parts[0][key] = nil
                    images[0]["flash_parts"] = parts
                    manifest["images"] = images
                }
            expect(.flashPartMissingKeys(index: 0, partIndex: 0, keys: [key]),
                   reading: file, "removing a part's \(key) must be refused by name")
        }
        // `offset` is the one key the solver writes, so it has to be taken away
        // after every pass rather than before the first one.
        let noOffset = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: Self.area([Self.c6Spec]),
            editAfterEachSolve: { manifest in
                var images = manifest["images"] as! [[String: Any]]
                var parts = images[0]["flash_parts"] as! [[String: Any]]
                parts[0]["offset"] = nil
                images[0]["flash_parts"] = parts
                manifest["images"] = images
            })
        expect(.flashPartMissingKeys(index: 0, partIndex: 0, keys: ["offset"]),
               reading: noOffset, "removing a part's offset must be refused by name")
    }

    func testRefusesAFlashPartWithNoUsableRole() {
        // A part that does not say what it is cannot be written anywhere sensible,
        // and cannot be reported on either.
        for role in ["", "   ", "\n"] {
            let file = Self.bundleBytes(
                Self.manifest(images: [Self.c6Spec]),
                payloads: Self.area([Self.c6Spec])) { manifest in
                    var images = manifest["images"] as! [[String: Any]]
                    var parts = images[0]["flash_parts"] as! [[String: Any]]
                    parts[0]["role"] = role
                    images[0]["flash_parts"] = parts
                    manifest["images"] = images
                }
            expect(.flashPartHasNoRole(index: 0, partIndex: 0), reading: file,
                   "a role of \(role.debugDescription)")
        }
        // A role that is not a string is a typed-field problem rather than an empty
        // one, and is reported as such.
        let numeric = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: Self.area([Self.c6Spec])) { manifest in
                var images = manifest["images"] as! [[String: Any]]
                var parts = images[0]["flash_parts"] as! [[String: Any]]
                parts[0]["role"] = 7
                images[0]["flash_parts"] = parts
                manifest["images"] = images
            }
        expect(.fieldHasWrongType(where: "image 0 flash part 0", key: "role",
                                 wanted: "a string"),
               reading: numeric)
    }

    func testRefusesTheSameFlashRoleTwice() {
        // Two bootloaders leave no way to tell which one to write, which is a
        // different problem from either of them being wrong.
        let file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: Self.area([Self.c6Spec])) { manifest in
                var images = manifest["images"] as! [[String: Any]]
                var parts = images[0]["flash_parts"] as! [[String: Any]]
                parts.insert(parts[0], at: 1)
                images[0]["flash_parts"] = parts
                manifest["images"] = images
            }
        expect(.duplicateFlashRole(chip: "esp32c6", role: "bootloader"), reading: file)
    }

    func testRefusesAnImageMissingAnyRequiredFlashRole() {
        // A file that is internally consistent and simply cannot do the job it
        // claims. Refused because the generation exists so that "this can bring up
        // a blank board" is true of every file claiming to be one - a caller left
        // to check role by role would be answering "maybe".
        for role in FirmwareBundle.requiredFlashRoles {
            var spec = Self.c6Spec
            spec.flashParts = spec.flashParts.filter { $0.role != role }
            let file = Self.bundleBytes(
                Self.manifest(images: [spec]), payloads: Self.area([spec]))
            expect(.missingFlashRoles(chip: "esp32c6", roles: [role]), reading: file,
                   "a bundle with no \(role)")
        }
        // An extra role is accepted, so a later writer can add a filesystem image
        // without another generation.
        var withExtra = Self.c6Spec
        withExtra.flashParts.append(
            FlashPartSpec(role: "spiffs", address: 0x290000,
                          filename: "display_stream.spiffs.bin",
                          payload: Data("filesystem\n".utf8)))
        let extra = Self.bundleBytes(
            Self.manifest(images: [withExtra]), payloads: Self.area([withExtra]))
        let bundle = try? FirmwareBundle.read(extra)
        XCTAssertEqual(
            bundle?.images[0].flashParts.map(\.role),
            ["bootloader", "partitions", "boot_app0", "spiffs"],
            "an unknown role is carried rather than refused")
        XCTAssertEqual(
            bundle?.flashPlan(forChip: "esp32c6")?.map(\.role),
            ["bootloader", "partitions", "boot_app0", "app", "spiffs"],
            "and it takes its place in the plan by address, at 0x290000")
    }

    func testRefusesNonsensicalFlashAddresses() {
        for address in [-1, -0x1000] {
            let file = Self.bundleBytes(
                Self.manifest(images: [Self.c6Spec]),
                payloads: Self.area([Self.c6Spec])) { manifest in
                    var images = manifest["images"] as! [[String: Any]]
                    var parts = images[0]["flash_parts"] as! [[String: Any]]
                    parts[0]["address"] = address
                    images[0]["flash_parts"] = parts
                    manifest["images"] = images
                }
            expect(.nonsensicalFlashAddress(chip: "esp32c6", role: "bootloader",
                                           address: address),
                   reading: file)
        }
        let app = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: Self.area([Self.c6Spec])) { manifest in
                var images = manifest["images"] as! [[String: Any]]
                images[0]["app_address"] = -1
                manifest["images"] = images
            }
        expect(.nonsensicalFlashAddress(chip: "esp32c6", role: "app", address: -1),
               reading: app)
        // A flash address written as a float or a boolean goes through the same
        // number spelling the offsets do, so a file this reader takes cannot be one
        // `bundle-info` rejects.
        let float = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: Self.area([Self.c6Spec])) { manifest in
                var images = manifest["images"] as! [[String: Any]]
                images[0]["app_address"] = true
                manifest["images"] = images
            }
        expect(.fieldHasWrongType(where: "image 0", key: "app_address",
                                 wanted: "a whole number"),
               reading: float)
    }

    func testRefusesTwoPayloadsAtOneFlashAddress() {
        // Only the last write would survive, so this is a contradiction rather than
        // a preference, and refusing is the only answer that does not depend on
        // which order a writer happened to list them in.
        let clash = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: Self.area([Self.c6Spec])) { manifest in
                var images = manifest["images"] as! [[String: Any]]
                var parts = images[0]["flash_parts"] as! [[String: Any]]
                parts[1]["address"] = parts[0]["address"]
                images[0]["flash_parts"] = parts
                manifest["images"] = images
            }
        expect(.conflictingFlashAddresses(chip: "esp32c6", address: 0x0,
                                         first: "bootloader", second: "partitions"),
               reading: clash)

        // And against the application image, which is in the same address space
        // even though it is not a flash part.
        let onTheApp = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: Self.area([Self.c6Spec])) { manifest in
                var images = manifest["images"] as! [[String: Any]]
                var parts = images[0]["flash_parts"] as! [[String: Any]]
                parts[2]["address"] = Self.appFlashAddress
                images[0]["flash_parts"] = parts
                manifest["images"] = images
            }
        expect(.conflictingFlashAddresses(chip: "esp32c6", address: 0x10000,
                                         first: "app", second: "boot_app0"),
               reading: onTheApp)
    }

    func testRefusesAFlashPartWithANonsensicalExtentOrOffset() {
        let zeroBytes = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: Self.area([Self.c6Spec])) { manifest in
                var images = manifest["images"] as! [[String: Any]]
                var parts = images[0]["flash_parts"] as! [[String: Any]]
                parts[0]["bytes"] = 0
                images[0]["flash_parts"] = parts
                manifest["images"] = images
            }
        XCTAssertThrowsError(try FirmwareBundle.read(zeroBytes)) { error in
            guard case .flashPartNonsensicalExtent(_, let role, _, let bytes)?
                = error as? FirmwareBundleError
            else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(role, "bootloader")
            XCTAssertEqual(bytes, 0, "a zero-byte bootloader is not a bootloader")
        }

        let negativeOffset = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: Self.area([Self.c6Spec]),
            editAfterEachSolve: { manifest in
                var images = manifest["images"] as! [[String: Any]]
                var parts = images[0]["flash_parts"] as! [[String: Any]]
                parts[0]["offset"] = -1
                images[0]["flash_parts"] = parts
                manifest["images"] = images
            })
        XCTAssertThrowsError(try FirmwareBundle.read(negativeOffset)) { error in
            guard case .flashPartNonsensicalExtent(_, _, let offset, _)?
                = error as? FirmwareBundleError
            else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(offset, -1)
        }
    }

    func testRefusesAFlashPartThatBreaksContiguity() throws {
        // One byte of slack between the application image and its bootloader. Every
        // hash would still be right for the bytes at the stated offsets, so only the
        // contiguity check catches this - and it is what catches a truncation that
        // leaves a plausible-looking manifest.
        let solved = Self.manifest(images: [Self.c6Spec])
        var images = solved["images"] as! [[String: Any]]
        var parts = images[0]["flash_parts"] as! [[String: Any]]
        let correct = parts[0]["offset"] as! Int
        // +1 keeps the digit count, so the manifest is the same length and the only
        // thing wrong with the file is that one offset.
        parts[0]["offset"] = correct + 1
        images[0]["flash_parts"] = parts
        var mutated = solved
        mutated["images"] = images
        expect(.flashPartNotContiguous(chip: "esp32c6", role: "bootloader",
                                      offset: correct + 1, expected: correct),
               reading: Self.bundleBytes(mutated, payloads: Self.area([Self.c6Spec]),
                                         solveOffsets: false))

        // And between two parts, so the walk is checked at every step rather than
        // only where the image ends.
        var second = solved["images"] as! [[String: Any]]
        var secondParts = second[0]["flash_parts"] as! [[String: Any]]
        let expected = secondParts[2]["offset"] as! Int
        secondParts[2]["offset"] = expected - 1
        second[0]["flash_parts"] = secondParts
        var betweenParts = solved
        betweenParts["images"] = second
        expect(.flashPartNotContiguous(chip: "esp32c6", role: "boot_app0",
                                      offset: expected - 1, expected: expected),
               reading: Self.bundleBytes(betweenParts,
                                         payloads: Self.area([Self.c6Spec]),
                                         solveOffsets: false))
    }

    func testRefusesAFlashPartWhoseHashDoesNotMatch() throws {
        // One flipped byte in a bootloader, which is the failure this format exists
        // to catch and the worst one to miss: it is written to address 0x0 of a
        // board that has nothing else working on it.
        var file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec, Self.s3Spec]),
            payloads: Self.area([Self.c6Spec, Self.s3Spec]))
        let intact = try FirmwareBundle.read(file)
        let part = try XCTUnwrap(intact.images[1].flashPart(role: "bootloader"))
        file[part.offset + 2] ^= 0x01
        XCTAssertThrowsError(try FirmwareBundle.read(file)) { error in
            guard case .flashPartHashMismatch(let chip, let role, let expected, let actual)?
                = error as? FirmwareBundleError
            else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(chip, "esp32s3", "named by chip, not by image index")
            XCTAssertEqual(role, "bootloader", "and by role, so the right payload is looked at")
            XCTAssertNotEqual(expected, actual)
            XCTAssertEqual(expected, FirmwareBundle.sha256Hex(Self.s3Spec.flashParts[0].payload))
        }

        // A manifest hash that is not the payload's, with the payload untouched:
        // the same refusal from the other direction.
        let rehashed = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: Self.area([Self.c6Spec])) { manifest in
                var images = manifest["images"] as! [[String: Any]]
                var parts = images[0]["flash_parts"] as! [[String: Any]]
                parts[1]["sha256"] = String(repeating: "0", count: 64)
                images[0]["flash_parts"] = parts
                manifest["images"] = images
            }
        XCTAssertThrowsError(try FirmwareBundle.read(rehashed)) { error in
            guard case .flashPartHashMismatch(_, let role, let expected, _)?
                = error as? FirmwareBundleError
            else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(role, "partitions")
            XCTAssertEqual(expected, String(repeating: "0", count: 64))
        }
    }

    func testAFlashPlanIsOnlyOfferedWhenItIsComplete() throws {
        // Nil rather than a short list of writes, in every case where the file
        // cannot answer the question: "there is nothing to write" and "this file
        // cannot do that" are different answers and only one of them should ever
        // reach a board.
        let good = try FirmwareBundle.read(
            Self.bundleBytes(Self.manifest(images: [Self.c6Spec]),
                             payloads: Self.area([Self.c6Spec])))
        XCTAssertNotNil(good.flashPlan(forChip: "esp32c6"))
        XCTAssertNil(good.flashPlan(forChip: "esp32s3"), "a chip this bundle does not carry")
        XCTAssertNil(good.flashPlan(forChip: ""), "and an empty chip token")

        // ASCENDING FLASH ADDRESS ORDER, derived from the addresses in the file
        // rather than from the roles, so a board whose map differs still gets a
        // sensible sequence. Listing the parts backwards changes the plan not at all.
        var reversed = Self.c6Spec
        reversed.flashParts.reverse()
        let backwards = try FirmwareBundle.read(
            Self.bundleBytes(Self.manifest(images: [reversed]),
                             payloads: Self.area([reversed])))
        XCTAssertEqual(
            backwards.images[0].flashParts.map(\.role),
            ["boot_app0", "partitions", "bootloader"],
            "the manifest order is preserved as given")
        XCTAssertEqual(
            backwards.flashPlan(forChip: "esp32c6")?.map(\.role),
            ["bootloader", "partitions", "boot_app0", "app"],
            "and the plan is by address regardless")
        XCTAssertEqual(
            backwards.flashPlan(forChip: "esp32c6")?.map(\.address),
            [0x0, 0x8000, 0xE000, 0x10000])
        // Every write carries the bytes and the hash the manifest gave for them, so
        // whatever spawns esptool needs to look nothing up.
        for write in try XCTUnwrap(backwards.flashPlan(forChip: "esp32c6")) {
            XCTAssertEqual(FirmwareBundle.sha256Hex(write.payload), write.sha256,
                           "\(write.role) carries its own verified bytes")
            XCTAssertFalse(write.filename.isEmpty, "\(write.role) says where it came from")
        }
    }

    func testRefusesAFieldOfTheWrongType() {
        // A string field holding a number. Nothing in the format says a reader
        // must be typed, but this one is, so it says which field rather than
        // failing later on a comparison the user cannot interpret.
        let numericHash = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]), payloads: Self.area([Self.c6Spec])) { manifest in
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
            payloads: Self.area([Self.c6Spec]),
            solveOffsets: false) { manifest in
                var images = manifest["images"] as! [[String: Any]]
                images[0]["offset"] = true
                manifest["images"] = images
            }
        expect(.fieldHasWrongType(where: "image 0", key: "offset", wanted: "a whole number"),
               reading: booleanOffset)

        let stringVersion = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]), payloads: Self.area([Self.c6Spec])) {
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
                       manifestText: patched, payloads: Self.area([Self.c6Spec])),
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
            Self.bundleBytes(manifestText: text, payloads: Self.area([Self.c6Spec])))
        XCTAssertEqual(bundle.images.count, 1)
    }

    func testRefusesANonsensicalExtent() {
        let zeroBytes = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]),
            payloads: Self.area([Self.c6Spec])) { manifest in
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
            payloads: Self.area([Self.c6Spec]),
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
        let file = Self.bundleBytes(
            mutated, payloads: Self.area([Self.c6Spec]), solveOffsets: false)
        expect(.notContiguous(index: 0, chip: "esp32c6",
                              offset: correct + 1, expected: correct),
               reading: file)
    }

    func testRefusesAnImageRunningPastTheEndOfTheFile() {
        // A file truncated inside its application image: the manifest is intact and
        // says more bytes follow than actually do. The cut has to be deeper than
        // the flash parts that come after the image, or it is a part that runs past
        // the end and not the image - which is the next test.
        let file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]), payloads: Self.area([Self.c6Spec]))
        let parts = Self.c6Spec.flashParts.reduce(0) { $0 + $1.payload.count }
        let cut = parts + 5
        let truncated = file.prefix(file.count - cut)
        XCTAssertThrowsError(try FirmwareBundle.read(truncated)) { error in
            guard case .pastEndOfFile(_, let chip, let end, let fileBytes)?
                = error as? FirmwareBundleError
            else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(chip, "esp32c6")
            XCTAssertEqual(end, file.count - parts, "the image's own end")
            XCTAssertEqual(fileBytes, file.count - cut)
        }
    }

    func testRefusesAFlashPartRunningPastTheEndOfTheFile() {
        // The same truncation five bytes in, which now lands inside the last flash
        // part rather than inside the image. Reported as that part, by role: a
        // person told "the image runs past the end" would go looking at the wrong
        // payload, and the fix is the same either way only if they know which.
        let file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec]), payloads: Self.area([Self.c6Spec]))
        let truncated = file.prefix(file.count - 2)
        XCTAssertThrowsError(try FirmwareBundle.read(truncated)) { error in
            guard case .flashPartPastEndOfFile(let chip, let role, let end, let fileBytes)?
                = error as? FirmwareBundleError
            else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(chip, "esp32c6")
            XCTAssertEqual(role, "boot_app0", "the part the cut landed in")
            XCTAssertEqual(end, file.count)
            XCTAssertEqual(fileBytes, file.count - 2)
        }
    }

    func testRefusesTheSameChipTwice() {
        let file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec, Self.c6Spec]),
            payloads: Self.area([Self.c6Spec, Self.c6Spec]))
        expect(.duplicateChip("esp32c6"), reading: file)
    }

    func testRefusesAHashThatDoesNotMatch() throws {
        // One flipped byte in the middle of an image, which is the failure this
        // format exists to catch: a copy that went wrong, or an edit.
        var file = Self.bundleBytes(
            Self.manifest(images: [Self.c6Spec, Self.s3Spec]),
            payloads: Self.area([Self.c6Spec, Self.s3Spec]))
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
            Self.manifest(images: [Self.c6Spec]), payloads: Self.area([Self.c6Spec]))
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
            .noFlashParts(index: 0, chip: "esp32c6"),
            .flashPartNotAnObject(index: 0, partIndex: 1),
            .flashPartMissingKeys(index: 0, partIndex: 1, keys: ["address"]),
            .flashPartHasNoRole(index: 0, partIndex: 1),
            .duplicateFlashRole(chip: "esp32c6", role: "bootloader"),
            .missingFlashRoles(chip: "esp32c6", roles: ["boot_app0"]),
            .nonsensicalFlashAddress(chip: "esp32c6", role: "bootloader", address: -1),
            .conflictingFlashAddresses(chip: "esp32c6", address: 0x8000,
                                       first: "partitions", second: "boot_app0"),
            .flashPartNonsensicalExtent(chip: "esp32c6", role: "bootloader",
                                        offset: -1, bytes: 0),
            .flashPartNotContiguous(chip: "esp32c6", role: "bootloader",
                                    offset: 5, expected: 4),
            .flashPartPastEndOfFile(chip: "esp32c6", role: "bootloader",
                                    end: 99, fileBytes: 50),
            .flashPartHashMismatch(chip: "esp32c6", role: "bootloader",
                                   expected: "aa", actual: "bb"),
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
        // A flash part's message has to name the part, because "the bundle is
        // damaged" leaves a person with three payloads and no idea which one to
        // look at - and an address, because that is where it was going.
        XCTAssertTrue(
            FirmwareBundleError.flashPartHashMismatch(
                chip: "esp32c6", role: "bootloader", expected: "aa", actual: "bb")
                .localizedDescription.contains("bootloader"))
        XCTAssertTrue(
            FirmwareBundleError.conflictingFlashAddresses(
                chip: "esp32c6", address: 0x8000, first: "partitions", second: "boot_app0")
                .localizedDescription.contains("0x8000"),
            "an address is spelled the way esptool and the datasheets spell one")
        XCTAssertTrue(
            FirmwareBundleError.missingFlashRoles(chip: "esp32c6", roles: ["boot_app0"])
                .localizedDescription.contains("never been flashed"),
            "and says what the file cannot be used for rather than only what is absent")
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

    /// One of the three payloads a board with nothing on it needs.
    private struct FlashPartSpec {
        let role: String
        let address: Int
        let filename: String
        let payload: Data
    }

    private struct ImageSpec {
        let board: String
        let chip: String
        let payload: Data
        var flashParts: [FlashPartSpec]

        /// This image's slice of the payload area: its application image, then its
        /// flash parts in listed order. The format's one rule about where payloads
        /// go, written here so every fixture obeys it the same way.
        var area: Data {
            flashParts.reduce(payload) { $0 + $1.payload }
        }
    }

    /// Payloads that are not valid firmware and do not need to be. The C6 one
    /// contains the magic on purpose - see `testTwoImageBundleRoundTrips`.
    private static let c6Payload =
        Data("c6 image ".utf8) + magicInPayload + Data([0x00, 0xFF, 0x7F])
    private static let s3Payload = Data(repeating: 0xA5, count: 61) + Data("s3".utf8)
    private static let magicInPayload =
        Data("ESPDISPFW2\n".utf8) + Data("ESPDISPFW1\n".utf8)

    /// Stand-ins for a board's flash parts, distinct per board on purpose:
    /// identical bytes would let a reader that handed the C6 the S3's bootloader
    /// pass, and that is a payload written to address 0x0 of a board with nothing
    /// else working on it. The addresses are the real ones - `boards.txt` gives
    /// both of this repo's chips `build.bootloader_addr=0x0`, and the partition
    /// table at 0x8000 and boot_app0 at 0xe000 come from the core's own upload
    /// recipe (platform.txt:346).
    private static func flashParts(_ tag: String) -> [FlashPartSpec] {
        [
            FlashPartSpec(
                role: "bootloader", address: 0x0,
                filename: "display_stream.ino.bootloader.bin",
                payload: Data([0xE9]) + Data("\(tag) bootloader\n".utf8)),
            FlashPartSpec(
                role: "partitions", address: 0x8000,
                filename: "display_stream.ino.partitions.bin",
                payload: Data([0xAA, 0x50]) + Data("\(tag) table\n".utf8)),
            FlashPartSpec(
                role: "boot_app0", address: 0xE000, filename: "boot_app0.bin",
                payload: Data("ota \(tag)\n".utf8)),
        ]
    }

    private static let appFlashAddress = 0x10000

    private static let c6Spec = ImageSpec(
        board: "c6", chip: "esp32c6", payload: c6Payload, flashParts: flashParts("c6"))
    private static let s3Spec = ImageSpec(
        board: "s3", chip: "esp32s3", payload: s3Payload, flashParts: flashParts("s3"))

    /// The whole payload area for a set of images, in file order. A generation-1
    /// file carries the application images and nothing else, which is the entire
    /// difference between the two generations expressed in bytes.
    private static func area(
        _ images: [ImageSpec], generation: Int = FirmwareBundle.format
    ) -> Data {
        images.reduce(Data()) {
            generation == FirmwareBundle.formatV1 ? $0 + $1.payload : $0 + $1.area
        }
    }

    /// A manifest for `images`, with correct sizes and hashes and offsets that
    /// have been settled against its own encoded length.
    ///
    /// `generation` is what the manifest claims to be; a generation-1 manifest
    /// carries no `app_address` and no `flash_parts`, which is exactly the
    /// difference between the two generations.
    private static func manifest(
        images: [ImageSpec], version: String = "1.2.0",
        generation: Int = FirmwareBundle.format
    ) -> [String: Any] {
        var manifest: [String: Any] = [
            "format": generation,
            "firmware_version": version,
            "built_at": "2026-01-02T03:04:05Z",
            "source_commit": String(repeating: "a", count: 40),
            "source_dirty": false,
            "tool": "espdisp.py bundle",
            "images": images.map { spec -> [String: Any] in
                var entry: [String: Any] = [
                    "board": spec.board,
                    "chip": spec.chip,
                    "fqbn": "esp32:esp32:\(spec.chip)",
                    "filename": "display_stream.ino.bin",
                    "offset": 0,
                    "bytes": spec.payload.count,
                    "sha256": FirmwareBundle.sha256Hex(spec.payload),
                ]
                if generation != FirmwareBundle.formatV1 {
                    entry["app_address"] = appFlashAddress
                    entry["flash_parts"] = spec.flashParts.map { part -> [String: Any] in
                        [
                            "role": part.role,
                            "address": part.address,
                            "filename": part.filename,
                            "offset": 0,
                            "bytes": part.payload.count,
                            "sha256": FirmwareBundle.sha256Hex(part.payload),
                        ]
                    }
                }
                return entry
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
    ///
    /// The walk is the payload order: each image, then that image's flash parts.
    /// A second hand-written implementation of the same rule the pinned layout
    /// test states literally.
    ///
    /// `edit` runs after every assignment pass, which is how a test breaks an
    /// OFFSET - the one thing this function writes - and still ends up with a
    /// manifest whose length has settled. Without that, an edit applied afterwards
    /// changes the manifest's length, the application image's own offset no longer
    /// describes the file, and every such test is refused for contiguity instead of
    /// for the thing it set out to break.
    private static func settle(
        _ manifest: [String: Any], edit: ((inout [String: Any]) -> Void)? = nil
    ) -> [String: Any] {
        var manifest = manifest
        for _ in 0..<8 {
            let before = json(manifest).count
            guard var images = manifest["images"] as? [[String: Any]] else { return manifest }
            var cursor = FirmwareBundle.headerBytes + before
            for index in images.indices {
                images[index]["offset"] = cursor
                cursor += (images[index]["bytes"] as? Int) ?? 0
                if var parts = images[index]["flash_parts"] as? [[String: Any]] {
                    for partIndex in parts.indices {
                        parts[partIndex]["offset"] = cursor
                        cursor += (parts[partIndex]["bytes"] as? Int) ?? 0
                    }
                    images[index]["flash_parts"] = parts
                }
            }
            manifest["images"] = images
            edit?(&manifest)
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
        payloads: Data,
        magic: Data = FirmwareBundle.magic,
        solveOffsets: Bool = true,
        editAfterEachSolve: ((inout [String: Any]) -> Void)? = nil,
        mutate: (inout [String: Any]) -> Void = { _ in }
    ) -> Data {
        var manifest = manifest
        mutate(&manifest)
        if solveOffsets { manifest = settle(manifest, edit: editAfterEachSolve) }
        let encoded = json(manifest)
        return magic + lengthLine(encoded.count) + encoded + payloads
    }

    /// Assemble a file from manifest TEXT rather than a dictionary.
    ///
    /// For the cases where the exact spelling of a JSON value is the subject, and
    /// a round trip through `JSONSerialization` would normalise it away. The
    /// length line is computed from the text given, so the header stays honest
    /// about a manifest this deliberately made wrong somewhere else.
    private static func bundleBytes(manifestText: String, payloads: Data) -> Data {
        let encoded = Data(manifestText.utf8)
        return FirmwareBundle.magic + lengthLine(encoded.count) + encoded + payloads
    }

    private static func readBundle(
        version: String, images: [ImageSpec],
        generation: Int = FirmwareBundle.format
    ) throws -> FirmwareBundle {
        try FirmwareBundle.read(
            bundleBytes(
                manifest(images: images, version: version, generation: generation),
                payloads: area(images, generation: generation),
                magic: generation == FirmwareBundle.formatV1
                    ? FirmwareBundle.magicV1 : FirmwareBundle.magic))
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
