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

    // MARK: - partition tables

    private struct Entry {
        var label: String
        var type: UInt8
        var subtype: UInt8
        var address: Int
        var size: Int
    }

    private static let p4Entries = [
        Entry(label: "nvs", type: 0x01, subtype: 0x02, address: 0x9000, size: 0x5000),
        Entry(label: "otadata", type: 0x01, subtype: 0x00, address: 0xE000, size: 0x2000),
        Entry(label: "app0", type: 0x00, subtype: 0x10, address: 0x10000, size: 0x4F0000),
        Entry(label: "app1", type: 0x00, subtype: 0x11, address: 0x500000, size: 0x4F0000),
        Entry(label: "doom_wad", type: 0x42, subtype: 0x06, address: 0x9F0000, size: 0x401000),
        Entry(label: "quake_pak", type: 0x42, subtype: 0x07, address: 0xE00000, size: 0x1200000),
    ]

    private static let s3Entries = [
        Entry(label: "nvs", type: 0x01, subtype: 0x02, address: 0x9000, size: 0x5000),
        Entry(label: "otadata", type: 0x01, subtype: 0x00, address: 0xE000, size: 0x2000),
        Entry(label: "app0", type: 0x00, subtype: 0x10, address: 0x10000, size: 0x1F0000),
        Entry(label: "app1", type: 0x00, subtype: 0x11, address: 0x200000, size: 0x1F0000),
        Entry(label: "doom_wad", type: 0x42, subtype: 0x06, address: 0x3FF000, size: 0x401000),
    ]

    /// 0xC00 bytes as read off flash: packed entries, then erased flash.
    private static func table(_ entries: [Entry]) -> Data {
        var bytes = [UInt8](repeating: 0xFF, count: QuakePak.partitionTableBytes)
        for (index, entry) in entries.enumerated() {
            let offset = index * 32
            var row: [UInt8] = [0xAA, 0x50, entry.type, entry.subtype]
            row += le32(entry.address) + le32(entry.size)
            var label = [UInt8](entry.label.utf8.prefix(16))
            label += [UInt8](repeating: 0, count: 16 - label.count)
            row += label + [0, 0, 0, 0]
            bytes.replaceSubrange(offset..<(offset + 32), with: row)
        }
        return Data(bytes)
    }

    private let mib = 0x100000

    // MARK: - P4

    func testTheP4WritesAtItsTablesQuakePartition() {
        XCTAssertEqual(
            QuakePak.plan(
                chip: "esp32p4", partitionTable: Self.table(Self.p4Entries),
                flashBytes: nil, payloadBytes: QuakePak.sharewareBytes),
            .write(address: 0xE00000))
    }

    func testTheP4TableMustBeThisReposLayout() {
        var moved = Self.p4Entries
        moved[5].address = 0xDF1000
        var noQuake = Self.p4Entries
        noQuake.removeLast()
        var oldSlots = Self.p4Entries
        oldSlots[2].size = 0x3F0000
        var wrongSubtype = Self.p4Entries
        wrongSubtype[5].subtype = 0x06
        for entries in [moved, noQuake, oldSlots, wrongSubtype, Self.s3Entries] {
            guard case .refuse(let title, _) = QuakePak.plan(
                chip: "esp32p4", partitionTable: Self.table(entries),
                flashBytes: 32 * mib, payloadBytes: 1000)
            else { return XCTFail("an unexpected P4 table was accepted") }
            XCTAssertEqual(title, "Partition layout not current")
        }
        guard case .refuse = QuakePak.plan(
            chip: "esp32p4", partitionTable: Data(repeating: 0xFF, count: 0xC00),
            flashBytes: nil, payloadBytes: 1000)
        else { return XCTFail("an erased table was accepted") }
    }

    func testTheP4RefusesAFileLargerThanItsPartition() {
        XCTAssertEqual(
            QuakePak.plan(
                chip: "esp32p4", partitionTable: Self.table(Self.p4Entries),
                flashBytes: nil, payloadBytes: 0x1200000),
            .write(address: 0xE00000), "a file exactly the partition's size fits")
        guard case .refuse(let title, let message) = QuakePak.plan(
            chip: "esp32p4", partitionTable: Self.table(Self.p4Entries),
            flashBytes: nil, payloadBytes: 0x1200001)
        else { return XCTFail("an oversize file was accepted") }
        XCTAssertEqual(title, "The file is too large")
        XCTAssertTrue(message.contains("\(0x1200000)"), message)
    }

    // MARK: - S3

    func testA32MiBS3WritesTheRawRegion() {
        XCTAssertEqual(
            QuakePak.plan(
                chip: "esp32s3", partitionTable: Self.table(Self.s3Entries),
                flashBytes: 32 * mib, payloadBytes: QuakePak.sharewareBytes),
            .write(address: 0x800000))
    }

    func testA16MiBS3IsRefusedInPlainWords() {
        guard case .refuse(let title, let message) = QuakePak.plan(
            chip: "esp32s3", partitionTable: Self.table(Self.s3Entries),
            flashBytes: 16 * mib, payloadBytes: QuakePak.sharewareBytes)
        else { return XCTFail("a 16 MiB S3 was accepted") }
        XCTAssertEqual(title, "Not enough flash for Quake")
        XCTAssertTrue(message.contains("16 MiB"), message)
        XCTAssertTrue(message.contains("32 MiB"), message)
    }

    func testTheS3ThresholdIsTheRegionsEnd() {
        XCTAssertEqual(QuakePak.s3RequiredFlashBytes, 0x1A00000)
        let table = Self.table(Self.s3Entries)
        XCTAssertEqual(
            QuakePak.plan(chip: "esp32s3", partitionTable: table,
                          flashBytes: 0x1A00000, payloadBytes: 1000),
            .write(address: 0x800000))
        guard case .refuse = QuakePak.plan(
            chip: "esp32s3", partitionTable: table,
            flashBytes: 0x1A00000 - 1, payloadBytes: 1000)
        else { return XCTFail("a chip short of the region's end was accepted") }
        guard case .refuse(let title, _) = QuakePak.plan(
            chip: "esp32s3", partitionTable: table, flashBytes: nil, payloadBytes: 1000)
        else { return XCTFail("an unknown flash size was accepted") }
        XCTAssertEqual(title, "Flash size unknown")
    }

    func testTheS3TableMustBeTheUniversalLayout() {
        var extra = Self.s3Entries
        extra.append(Entry(
            label: "quake_pak", type: 0x42, subtype: 0x07, address: 0x800000, size: 0x1200000))
        var movedWad = Self.s3Entries
        movedWad[4].address = 0x400000
        for entries in [extra, movedWad, Self.p4Entries] {
            guard case .refuse(let title, _) = QuakePak.plan(
                chip: "esp32s3", partitionTable: Self.table(entries),
                flashBytes: 32 * mib, payloadBytes: 1000)
            else { return XCTFail("an unexpected S3 table was accepted") }
            XCTAssertEqual(title, "Partition layout not current")
        }
    }

    func testTheS3RefusesAFileLargerThanItsRegion() {
        guard case .refuse(let title, _) = QuakePak.plan(
            chip: "esp32s3", partitionTable: Self.table(Self.s3Entries),
            flashBytes: 32 * mib, payloadBytes: 0x1200001)
        else { return XCTFail("an oversize file was accepted") }
        XCTAssertEqual(title, "The file is too large")
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
        XCTAssertNil(QuakePak.chipRefusal("esp32s3"))
        for chip in ["esp32c6", "esp32c3", "esp32", ""] {
            guard case .refuse(let title, let message) = QuakePak.plan(
                chip: chip, partitionTable: Self.table(Self.p4Entries),
                flashBytes: 32 * mib, payloadBytes: 1000)
            else { return XCTFail("\(chip) was accepted") }
            XCTAssertEqual(title, "Quake is not available on this board")
            XCTAssertTrue(message.contains("ESP32-P4"), message)
            XCTAssertEqual(QuakePak.chipRefusal(chip), .refuse(title: title, message: message))
        }
    }

    func testTheWriteIsOneQuakePakPart() {
        let payload = Self.pack()
        let write = QuakePak.flashWrite(
            payload: payload, address: 0x800000, filename: "pak0.pak",
            sha256: FirmwareBundle.sha256Hex(payload))
        XCTAssertEqual(write.role, "quake_pak")
        XCTAssertEqual(write.address, 0x800000)
        XCTAssertEqual(write.payload, payload)
    }
}
