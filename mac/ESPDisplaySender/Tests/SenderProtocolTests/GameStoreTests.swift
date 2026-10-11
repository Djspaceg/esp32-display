import XCTest
@testable import SenderProtocol

/// The game store's format, held to the fixture firmware/test/test_game_store
/// parses, and the layout, space and selection rules the sheet relies on.
final class GameStoreTests: XCTestCase {
    private static let area = GameStore.Area(
        address: 0xE00000, byteCount: 0x1200000, description: "the quake_pak partition")

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "game-store-v1", withExtension: "hex", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return Data(text.split(whereSeparator: \.isWhitespace).map { UInt8($0, radix: 16)! })
    }

    private static let fixtureDirectory = GameStore.Directory(
        areaBytes: 0x1200000, generation: 7,
        entries: [
            GameStore.Entry(
                kind: .quakePak, slot: 0, offset: 0, length: 18_689_235, name: "pak0.pak",
                sha256: QuakePak.sharewareSHA256),
            GameStore.Entry(
                kind: .doomWad, offset: 0x11D3000, length: 4096, name: "miniwad.wad",
                sha256: String(repeating: "5a", count: 32)),
        ])

    // MARK: - format

    func testTheEncoderWritesTheFirmwaresFixtureByteForByte() throws {
        let sector = GameStore.encode(Self.fixtureDirectory)
        let golden = try fixture()
        XCTAssertEqual(sector.count, GameStore.sectorBytes)
        XCTAssertEqual(Array(sector.prefix(golden.count)), Array(golden))
        XCTAssertTrue(sector.dropFirst(golden.count).allSatisfy { $0 == 0xFF })
        XCTAssertEqual(GameStore.crc32(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testDecodeReadsTheFixtureAndTreatsNoMagicAsLegacy() throws {
        var sector = try fixture()
        sector.append(Data(repeating: 0xFF, count: GameStore.sectorBytes - sector.count))
        XCTAssertEqual(try GameStore.decode(sector: sector, areaBytes: 0x1200000),
                       Self.fixtureDirectory)
        XCTAssertNil(try GameStore.decode(
            sector: Data(repeating: 0xFF, count: 4096), areaBytes: 0x1200000))
    }

    func testDecodeRefusesWhatTheFirmwareRefuses() throws {
        var sector = [UInt8](GameStore.encode(Self.fixtureDirectory))
        sector[40] ^= 1  // a length, after the CRC was taken
        XCTAssertThrowsError(try GameStore.decode(sector: Data(sector), areaBytes: 0x1200000)) {
            XCTAssertEqual($0 as? GameStore.DecodeError, .damaged("bad checksum"))
        }
        var newer = [UInt8](GameStore.encode(Self.fixtureDirectory))
        newer[8] = 2
        XCTAssertThrowsError(try GameStore.decode(sector: Data(newer), areaBytes: 0x1200000)) {
            XCTAssertEqual($0 as? GameStore.DecodeError, .newerVersion(2))
        }
        XCTAssertThrowsError(try GameStore.decode(
            sector: GameStore.encode(Self.fixtureDirectory), areaBytes: 0x800000))
        var overlapping = Self.fixtureDirectory
        overlapping.entries[1].offset = 0x11D2000
        XCTAssertNotNil(GameStore.problem(in: overlapping))
        var badName = Self.fixtureDirectory
        badName.entries[0].name = "pak1.pak"
        XCTAssertNotNil(GameStore.problem(in: badName))
        XCTAssertNil(GameStore.problem(in: Self.fixtureDirectory))
    }

    // MARK: - the area

    private static func table(_ rows: [(String, UInt8, UInt8, Int, Int)]) -> Data {
        var data = Data()
        for (label, type, subtype, address, size) in rows {
            var row: [UInt8] = [0xAA, 0x50, type, subtype]
            for value in [address, size] {
                row += (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) }
            }
            var name = Array(label.utf8)
            name += [UInt8](repeating: 0, count: 16 - name.count)
            row += name + [0, 0, 0, 0]
            data.append(contentsOf: row)
        }
        data.append(Data(repeating: 0xFF, count: 32))
        return data
    }

    static let p4Table = table([
        ("nvs", 0x01, 0x02, 0x9000, 0x5000), ("otadata", 0x01, 0x00, 0xE000, 0x2000),
        ("app0", 0x00, 0x10, 0x10000, 0x4F0000), ("app1", 0x00, 0x11, 0x500000, 0x4F0000),
        ("doom_wad", 0x42, 0x06, 0x9F0000, 0x401000),
        ("quake_pak", 0x42, 0x07, 0xE00000, 0x1200000),
    ])
    static let s3Table = table([
        ("nvs", 0x01, 0x02, 0x9000, 0x5000), ("otadata", 0x01, 0x00, 0xE000, 0x2000),
        ("app0", 0x00, 0x10, 0x10000, 0x1F0000), ("app1", 0x00, 0x11, 0x200000, 0x1F0000),
        ("doom_wad", 0x42, 0x06, 0x3FF000, 0x401000),
    ])

    func testTheAreaIsThePartitionOnAP4AndTheFlashPast8MiBOnAnS3() {
        XCTAssertEqual(
            GameStore.area(chip: "esp32p4", partitionTable: Self.p4Table, flashBytes: nil),
            .area(Self.area))
        XCTAssertEqual(Self.area.usableBytes, 18_870_272)
        XCTAssertEqual(Self.area.directoryAddress, 0x1FFF000)
        guard case .area(let s3)? = Optional(GameStore.area(
            chip: "esp32s3", partitionTable: Self.s3Table, flashBytes: 32 << 20))
        else { return XCTFail("a 32 MiB S3 has an area") }
        XCTAssertEqual(s3.address, 0x800000)
        XCTAssertEqual(s3.byteCount, 0x1200000)
        XCTAssertEqual(s3.directoryAddress, 0x19FF000)
        XCTAssertEqual(GameStore.s3AreaBytes(flashBytes: 16 << 20), 0x800000)
        XCTAssertEqual(GameStore.s3AreaBytes(flashBytes: 8 << 20), 0)
        if case .area = GameStore.area(
            chip: "esp32s3", partitionTable: Self.s3Table, flashBytes: 8 << 20) {
            XCTFail("an 8 MiB S3 has no room")
        }
        if case .area = GameStore.area(
            chip: "esp32p4", partitionTable: Self.s3Table, flashBytes: nil) {
            XCTFail("a P4 on another table is refused")
        }
    }

    func testALegacyPakIsMeasuredByItsDirectoryEnd() {
        var head = [UInt8]("PACK".utf8)
        head += [0x00, 0x10, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00]  // 0x1000 + 0x40
        XCTAssertEqual(GameStore.legacyPakBytes(firstBytes: Data(head), areaBytes: 0x1200000),
                       0x1040)
        XCTAssertNil(GameStore.legacyPakBytes(
            firstBytes: Data(repeating: 0xFF, count: 12), areaBytes: 0x1200000))
    }

    // MARK: - planning

    private func file(
        _ kind: GameStore.Kind, _ name: String, _ bytes: Int, slot: Int = 0,
        sha: String? = nil, boardOnly: Bool = false
    ) -> GameStore.File {
        GameStore.File(
            kind: kind, slot: slot, name: name,
            sha256: sha ?? String(repeating: String(name.count % 10), count: 64),
            byteCount: bytes, boardOnly: boardOnly)
    }

    func testPak0GoesFirstAndTheRestFollowSectorAligned() throws {
        let plan = try GameStore.plan(
            current: .legacy(legacyPak0Bytes: nil),
            desired: [file(.doomWad, "small.wad", 5000),
                      file(.quakePak, "pak0.pak", 18_689_235)],
            area: Self.area).get()
        XCTAssertEqual(plan.final.entries.map(\.name), ["pak0.pak", "small.wad"])
        XCTAssertEqual(plan.final.entries[0].offset, 0)
        XCTAssertEqual(plan.final.entries[1].offset, 0x11D3000)
        XCTAssertEqual(plan.writes.count, 2)
        XCTAssertNil(plan.interim, "nothing on the board is disturbed")
        XCTAssertEqual(plan.final.generation, 1)
        XCTAssertEqual(plan.usedBytes, 0x11D3000 + 0x2000)
    }

    func testAFileAlreadyOnTheBoardStaysAndIsNotRewritten() throws {
        let pak = file(.quakePak, "pak0.pak", 18_689_235, sha: QuakePak.sharewareSHA256)
        let current = GameStore.Contents.directory(GameStore.Directory(
            areaBytes: 0x1200000, generation: 4,
            entries: [GameStore.Entry(
                kind: .quakePak, offset: 0, length: pak.byteCount, name: "pak0.pak",
                sha256: pak.sha256)]))
        let plan = try GameStore.plan(
            current: current, desired: [pak, file(.doomWad, "a.wad", 9000)],
            area: Self.area).get()
        XCTAssertEqual(plan.writes.map(\.name), ["a.wad"])
        XCTAssertNil(plan.interim)
        XCTAssertEqual(plan.final.generation, 5)
    }

    func testDroppingAFileClearsItFromTheDirectoryBeforeAnyByteMoves() throws {
        let current = GameStore.Contents.directory(GameStore.Directory(
            areaBytes: 0x1200000, generation: 9,
            entries: [
                GameStore.Entry(kind: .doomWad, offset: 0, length: 9000, name: "old.wad",
                                sha256: String(repeating: "1", count: 64)),
                GameStore.Entry(kind: .doomWad, offset: 0x10000, length: 9000,
                                name: "keep.wad", sha256: String(repeating: "2", count: 64)),
            ]))
        let plan = try GameStore.plan(
            current: current,
            desired: [file(.doomWad, "keep.wad", 9000, sha: String(repeating: "2", count: 64)),
                      file(.doomWad, "new.wad", 9000)],
            area: Self.area).get()
        XCTAssertEqual(plan.interim?.entries.map(\.name), ["keep.wad"])
        XCTAssertEqual(plan.interim?.generation, 10)
        XCTAssertEqual(plan.final.generation, 11)
        XCTAssertEqual(plan.writes.map(\.name), ["new.wad"])
        XCTAssertEqual(plan.writes[0].offset, 0, "new.wad reuses the dropped file's space")
    }

    func testALegacyPakKeptWithoutACopyStaysAtOffsetZero() throws {
        let plan = try GameStore.plan(
            current: .legacy(legacyPak0Bytes: 18_689_235),
            desired: [file(.quakePak, "pak0.pak", 18_689_235, sha: "", boardOnly: true),
                      file(.doomWad, "a.wad", 100_000)],
            area: Self.area).get()
        XCTAssertEqual(plan.writes.map(\.name), ["a.wad"])
        XCTAssertEqual(plan.final.entries.first?.offset, 0)
        XCTAssertEqual(plan.final.entries.first?.sha256, "")
    }

    func testSpaceAndSelectionRefusalsSayWhy() {
        let tooBig = GameStore.plan(
            current: .legacy(legacyPak0Bytes: nil),
            desired: [file(.quakePak, "pak0.pak", 18_689_235),
                      file(.doomWad, "big.wad", 4_000_000)],
            area: Self.area)
        guard case .failure(.doesNotFit(let needed, let usable)) = tooBig else {
            return XCTFail("\(tooBig)")
        }
        XCTAssertEqual(usable, 18_870_272)
        XCTAssertEqual(needed, GameStore.aligned(18_689_235) + GameStore.aligned(4_000_000))
        XCTAssertNotNil(GameStore.selectionProblem([file(.quakePak, "pak1.pak", 9, slot: 1)]))
        XCTAssertNil(GameStore.selectionProblem([
            file(.quakePak, "pak0.pak", 9), file(.quakePak, "pak1.pak", 9, slot: 1)]))
        let nine = (0..<9).map { file(.doomWad, "w\($0).wad", 9000) }
        XCTAssertNotNil(GameStore.selectionProblem(nine))
        // A board-only file that is gone cannot be kept.
        let gone = GameStore.plan(
            current: .legacy(legacyPak0Bytes: nil),
            desired: [file(.doomWad, "gone.wad", 9000, boardOnly: true)], area: Self.area)
        guard case .failure(.invalid) = gone else { return XCTFail("\(gone)") }
    }

    func testFilesInTheWayAreMovedWhenTheAppHasTheirBytes() throws {
        // a.wad sits in the middle of a small area; the new file only fits if
        // a.wad moves, which the app can do because it has a.wad's bytes.
        let small = GameStore.Area(address: 0, byteCount: 0x100000 + 0x1000, description: "")
        let a = file(.doomWad, "a.wad", 0x40000)
        let current = GameStore.Contents.directory(GameStore.Directory(
            areaBytes: small.byteCount, generation: 1,
            entries: [GameStore.Entry(kind: .doomWad, offset: 0x60000, length: a.byteCount,
                                      name: a.name, sha256: a.sha256)]))
        let plan = try GameStore.plan(
            current: current, desired: [a, file(.doomWad, "b.wad", 0x80000)], area: small).get()
        XCTAssertEqual(Set(plan.writes.map(\.name)), ["a.wad", "b.wad"])
        XCTAssertNotNil(plan.interim)
        let pinned = GameStore.plan(
            current: current,
            desired: [file(.doomWad, "a.wad", 0x40000, sha: a.sha256, boardOnly: true),
                      file(.doomWad, "b.wad", 0x80000)],
            area: small)
        guard case .failure(.fragmented("b.wad")) = pinned else { return XCTFail("\(pinned)") }
    }
}
