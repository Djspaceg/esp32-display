import XCTest
@testable import SenderProtocol

/// The Quake pak rules, held to what `tools/espdisp.py write-data quake_pak`
/// does: `validate_quake_pak`, `data_partition_target` and
/// `quake_pak_s3_target`.
final class QuakePakTests: XCTestCase {

    // MARK: - the file

    /// A minimal well-formed pack: header, `files` payloads of 4 bytes each,
    /// then the directory.
    private static func pack(files: Int = 2) -> Data {
        var bytes = [UInt8]("PACK".utf8) + [UInt8](repeating: 0, count: 8)
        var offsets: [Int] = []
        for index in 0..<files {
            offsets.append(bytes.count)
            bytes += [UInt8(index), 1, 2, 3]
        }
        let directory = bytes.count
        for (index, offset) in offsets.enumerated() {
            var name = [UInt8]("file\(index).lmp".utf8)
            name += [UInt8](repeating: 0, count: 56 - name.count)
            bytes += name + le32(offset) + le32(4)
        }
        bytes.replaceSubrange(4..<12, with: le32(directory) + le32(files * 64))
        return Data(bytes)
    }

    private static func le32(_ value: Int) -> [UInt8] {
        (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) }
    }

    private static func patched(_ data: Data, at offset: Int, u32 value: Int) -> Data {
        var bytes = [UInt8](data)
        bytes.replaceSubrange(offset..<(offset + 4), with: le32(value))
        return Data(bytes)
    }

    func testAWellFormedPackValidates() throws {
        let data = Self.pack(files: 3)
        let validated = try QuakePak.validate(data)
        XCTAssertEqual(validated.byteCount, data.count)
        XCTAssertEqual(validated.entryCount, 3)
        XCTAssertEqual(validated.sha256, FirmwareBundle.sha256Hex(data))
        XCTAssertFalse(validated.isShareware, "any well-formed pack, reported as not shareware")
    }

    func testTheMagicMustBePACK() {
        var bytes = [UInt8](Self.pack())
        bytes[0] = UInt8(ascii: "I")
        XCTAssertThrowsError(try QuakePak.validate(Data(bytes))) {
            XCTAssertEqual($0 as? QuakePak.ValidationError, .notAPack(magicHex: "4941434b"))
        }
        XCTAssertThrowsError(try QuakePak.validate(Data("PACK".utf8)), "shorter than the header")
        XCTAssertThrowsError(try QuakePak.validate(Data()))
    }

    func testTheDirectoryMustBeWholeEntriesInsideTheFile() {
        let data = Self.pack(files: 2)
        let directory = 12 + 2 * 4
        // An empty directory, a partial entry, one before the header, one past
        // the end, and one that overruns the end.
        for (offset, length) in [
            (directory, 0), (directory, 63), (8, 128),
            (data.count + 1, 64), (directory, 192),
        ] {
            let broken = Self.patched(
                Self.patched(data, at: 4, u32: offset), at: 8, u32: length)
            XCTAssertThrowsError(try QuakePak.validate(broken), "\(offset)+\(length)") {
                XCTAssertEqual(
                    $0 as? QuakePak.ValidationError,
                    .directoryOutsideFile(offset: offset, length: length, fileBytes: data.count))
            }
        }
    }

    func testEveryEntryMustBeInsideTheFile() {
        let data = Self.pack(files: 2)
        let secondEntry = 12 + 2 * 4 + 64
        let pastEnd = Self.patched(data, at: secondEntry + 60, u32: data.count)
        XCTAssertThrowsError(try QuakePak.validate(pastEnd)) {
            XCTAssertEqual($0 as? QuakePak.ValidationError, .entryPastEnd(entryOffset: secondEntry))
        }
        let offsetPastEnd = Self.patched(data, at: secondEntry + 56, u32: data.count + 1)
        XCTAssertThrowsError(try QuakePak.validate(offsetPastEnd))
        // An entry that ends exactly at the end of the file is inside it.
        let exact = Self.patched(
            Self.patched(data, at: secondEntry + 56, u32: data.count - 4),
            at: secondEntry + 60, u32: 4)
        XCTAssertNoThrow(try QuakePak.validate(exact))
    }

    func testTheSharewareConstantsAreTheCLIs() {
        XCTAssertEqual(QuakePak.sharewareBytes, 18_689_235)
        XCTAssertEqual(
            QuakePak.sharewareSHA256,
            "35a9c55e5e5a284a159ad2a62e0e8def23d829561fe2f54eb402dbc0a9a946af")
    }

    /// tools/fetch_game_data.sh puts the shareware pak here; it is never
    /// committed, so this runs only where it has been fetched.
    func testTheFetchedSharewarePakIsRecognised() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("firmware/quake/id1/pak0.pak")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("no fetched pak0.pak at \(url.path)")
        }
        let validated = try QuakePak.validate(Data(contentsOf: url))
        XCTAssertTrue(validated.isShareware)
        XCTAssertEqual(validated.byteCount, QuakePak.sharewareBytes)
    }

    // MARK: - other chips

    func testQuakeRunsOnlyOnTheP4AndTheS3() {
        XCTAssertTrue(QuakePak.supports(chip: "esp32p4"))
        XCTAssertTrue(QuakePak.supports(chip: "esp32s3"))
        XCTAssertFalse(QuakePak.supports(chip: "esp32c6"))
        // The S3 boards whose panel holds Quake's frame, and a profile not yet
        // reported; never the small-panel S3 boards.
        XCTAssertTrue(QuakePak.supports(chip: "esp32s3", profile: "co5300"))
        XCTAssertTrue(QuakePak.supports(chip: "esp32s3", profile: "st77916"))
        XCTAssertTrue(QuakePak.supports(chip: "esp32s3", profile: nil))
        XCTAssertFalse(QuakePak.supports(chip: "esp32s3", profile: "gc9107"))
        XCTAssertFalse(QuakePak.supports(chip: "esp32s3", profile: "st7789-154"))
        XCTAssertTrue(QuakePak.supports(chip: "esp32p4", profile: "st7703-4b"))
        XCTAssertFalse(QuakePak.supports(chip: "esp32c3", profile: nil))
        XCTAssertFalse(QuakePak.supports(chip: nil))
    }

    /// Which boards get Quake is a capability of the board, never a list of
    /// profiles: every S3 and P4 profile in the board catalog is offered it
    /// exactly when its panel holds the engine's 320x240 frame.
    func testQuakeIsOfferedByCapabilityNotByProfileList() {
        var offered: Set<String> = []
        for family in ["s3", "p4"] {
            let chip = family == "s3" ? QuakePak.s3Chip : QuakePak.p4Chip
            for profile in GeneratedBoardCatalog.profilesByTarget[family] ?? [] {
                let geometry = try! XCTUnwrap(GeneratedBoardCatalog.geometryByProfile[profile])
                let holds = geometry.width >= 320 && geometry.height >= 240
                XCTAssertEqual(QuakePak.supports(chip: chip, profile: profile), holds, profile)
                if holds { offered.insert(profile) }
            }
        }
        XCTAssertEqual(offered, ["co5300", "st77916", "st7703-4b", "jd9365-4c", "jd9365-34c"])
        // The rule itself, for a panel no board has yet.
        XCTAssertTrue(QuakePak.panelHoldsFrame(PanelGeometry(width: 480, height: 320)))
        XCTAssertFalse(QuakePak.panelHoldsFrame(PanelGeometry(width: 240, height: 320)))
        XCTAssertFalse(QuakePak.panelHoldsFrame(PanelGeometry(width: 240, height: 240)))
        // A profile this app does not know yet (newer firmware): offered, and
        // the board and the write decide.
        XCTAssertTrue(QuakePak.supports(chip: QuakePak.s3Chip, profile: "future-panel"))
        // A profile of a family without Quake, on any chip, is not offered.
        XCTAssertFalse(QuakePak.supports(chip: QuakePak.s3Chip, profile: "jd9853"))
    }
}
