import XCTest
@testable import SenderProtocol

/// Choosing a file: what is accepted as a Doom WAD or a Quake pak, and every
/// refusal in words a person can act on; and the selection that becomes the
/// board's store.
final class GameDataTests: XCTestCase {
    private static func le32(_ value: Int) -> [UInt8] {
        (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) }
    }

    /// An IWAD whose lumps are named `lumps`, 4 bytes each, directory last.
    static func wad(_ magic: String = "IWAD", lumps: [String] = ["MAP01", "THINGS"]) -> Data {
        var bytes = Array(magic.utf8) + [UInt8](repeating: 0, count: 8)
        var offsets: [Int] = []
        for _ in lumps {
            offsets.append(bytes.count)
            bytes += [1, 2, 3, 4]
        }
        let directory = bytes.count
        for (index, name) in lumps.enumerated() {
            var raw = Array(name.utf8)
            raw += [UInt8](repeating: 0, count: 8 - raw.count)
            bytes += le32(offsets[index]) + le32(4) + raw
        }
        bytes.replaceSubrange(4..<12, with: le32(lumps.count) + le32(directory))
        return Data(bytes)
    }

    static func pak() -> Data {
        var bytes = Array("PACK".utf8) + [UInt8](repeating: 0, count: 8) + [9, 9, 9, 9]
        let directory = bytes.count
        var name = Array("progs.dat".utf8)
        name += [UInt8](repeating: 0, count: 56 - name.count)
        bytes += name + le32(12) + le32(4)
        bytes.replaceSubrange(4..<12, with: le32(directory) + le32(64))
        return Data(bytes)
    }

    private func refusal(_ data: Data, _ name: String, _ kind: GameStore.Kind) -> GameData.IdentifyError? {
        do {
            _ = try GameData.identify(data, filename: name, kind: kind)
            return nil
        } catch {
            return error as? GameData.IdentifyError
        }
    }

    func testAnIWadIsStoredUnderItsLowercaseName() throws {
        let found = try GameData.identify(Self.wad(), filename: "DOOM2.WAD", kind: .doomWad)
        XCTAssertEqual(found.storedName, "doom2.wad")
        XCTAssertEqual(found.kind, .doomWad)
        XCTAssertTrue(found.summary.contains("Doom II"))
        let e1 = try GameData.identify(
            Self.wad(lumps: ["E1M1"]), filename: "freedoom1.wad", kind: .doomWad)
        XCTAssertTrue(e1.summary.contains("Doom maps"))
    }

    func testWadRefusalsNameTheProblem() {
        XCTAssertEqual(refusal(Self.wad("PWAD"), "mod.wad", .doomWad), .pwad)
        XCTAssertEqual(refusal(Self.pak(), "x.wad", .doomWad), .notAWad(magicHex: "5041434b"))
        XCTAssertEqual(refusal(Self.wad(lumps: ["THINGS"]), "x.wad", .doomWad), .wadHasNoMaps)
        XCTAssertEqual(refusal(Self.wad(), "my doom.wad", .doomWad), .wadName("my doom.wad"))
        XCTAssertEqual(refusal(Self.wad(), "doom2.iwad", .doomWad), .wadName("doom2.iwad"))
        XCTAssertEqual(
            refusal(Self.wad(), "a-very-long-wad-name.wad", .doomWad),
            .wadName("a-very-long-wad-name.wad"))
        var broken = [UInt8](Self.wad())
        broken[8] = 0xF0  // directory past the end
        XCTAssertEqual(refusal(Data(broken), "x.wad", .doomWad), .wadDirectory)
        var lump = [UInt8](Self.wad())
        let directory = Int(lump[8]) | Int(lump[9]) << 8
        lump[directory + 4] = 0x7F  // first lump's size past the end
        XCTAssertEqual(refusal(Data(lump), "x.wad", .doomWad), .wadLumpOutside(index: 0))
        for error in [GameData.IdentifyError.pwad, .wadHasNoMaps, .bundledWad, .pakName("x")] {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
        }
    }

    func testTheBundledWadIsRefusedWhereItsDigestMatches() throws {
        let wad = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("firmware/doom/doom1.wad")
        guard FileManager.default.fileExists(atPath: wad.path) else {
            throw XCTSkip("firmware/doom/doom1.wad is not fetched here")
        }
        XCTAssertEqual(refusal(try Data(contentsOf: wad), "doom1.wad", .doomWad), .bundledWad)
    }

    func testAPakTakesItsSlotFromItsName() throws {
        XCTAssertEqual(try GameData.identify(Self.pak(), filename: "PAK1.PAK", kind: .quakePak).slot, 1)
        XCTAssertEqual(try GameData.identify(Self.pak(), filename: "pak0.pak", kind: .quakePak)
            .storedName, "pak0.pak")
        XCTAssertEqual(refusal(Self.pak(), "mymod.pak", .quakePak), .pakName("mymod.pak"))
        XCTAssertEqual(GameData.pakSlot("pak10.pak"), nil)
        guard case .notAPak? = refusal(Self.wad(), "pak0.pak", .quakePak) else {
            return XCTFail("a WAD is not a pak")
        }
    }

    // MARK: - selection

    private func identified(_ data: Data, _ name: String, _ kind: GameStore.Kind) -> GameData.Identified {
        try! GameData.identify(data, filename: name, kind: kind)
    }

    func testCheckedGamesDefineTheirFilesAndUncheckedGamesAreLeftAlone() {
        var selection = GameDataSelection(quakeOffered: true)
        let wad = identified(Self.wad(), "doom2.wad", .doomWad)
        selection.add(wad, source: .chosen(URL(fileURLWithPath: "/tmp/doom2.wad")))
        XCTAssertTrue(selection.doomChecked, "choosing a file checks its game")
        XCTAssertFalse(selection.quakeChecked)
        let board = GameStore.Contents.directory(GameStore.Directory(
            areaBytes: 0x1200000, generation: 2,
            entries: [
                GameStore.Entry(kind: .quakePak, offset: 0, length: 500, name: "pak0.pak",
                                sha256: String(repeating: "a", count: 64)),
                GameStore.Entry(kind: .doomWad, offset: 0x1000, length: 600, name: "old.wad",
                                sha256: String(repeating: "b", count: 64)),
            ]))
        selection.noteBoard(board)
        XCTAssertEqual(selection.items(of: .doomWad).map(\.identified.storedName),
                       ["doom2.wad", "old.wad"])
        XCTAssertEqual(selection.items(of: .doomWad).last?.source, .board)
        // Quake unchecked: the board's pak stays, kept in place.
        var files = selection.desiredFiles(board: board)
        XCTAssertEqual(files.map(\.name), ["doom2.wad", "old.wad", "pak0.pak"])
        XCTAssertEqual(files.last?.boardOnly, true)
        // Unchecking a board file of a checked game removes it.
        selection.setChecked("board/1/old.wad", false)
        files = selection.desiredFiles(board: board)
        XCTAssertEqual(files.map(\.name), ["doom2.wad", "pak0.pak"])
        // A board without Quake ignores Quake files entirely.
        var noQuake = GameDataSelection(quakeOffered: false)
        noQuake.add(identified(Self.pak(), "pak0.pak", .quakePak), source: .board)
        XCTAssertTrue(noQuake.items.isEmpty)
        XCTAssertFalse(noQuake.isGameChecked(.quakePak))
    }

    func testChoosingAnotherPak0ReplacesTheFirstAndOnBoardIsByDigest() {
        var selection = GameDataSelection(quakeOffered: true)
        let first = identified(Self.pak(), "pak0.pak", .quakePak)
        selection.add(first, source: .cache(URL(fileURLWithPath: "/c/pak0.pak")))
        var other = [UInt8](Self.pak())
        other[12] = 7
        let second = identified(Data(other), "PAK0.PAK", .quakePak)
        selection.add(second, source: .chosen(URL(fileURLWithPath: "/u/PAK0.PAK")))
        XCTAssertEqual(selection.items(of: .quakePak).count, 1)
        XCTAssertEqual(selection.items(of: .quakePak).first?.identified.sha256, second.sha256)
        let board = GameStore.Contents.directory(GameStore.Directory(
            areaBytes: 0x1200000, generation: 1,
            entries: [GameStore.Entry(kind: .quakePak, offset: 0, length: first.byteCount,
                                      name: "pak0.pak", sha256: first.sha256)]))
        selection.noteBoard(board)
        let rows = selection.items(of: .quakePak)
        XCTAssertEqual(rows.map(\.source), [.chosen(URL(fileURLWithPath: "/u/PAK0.PAK")), .board],
                       "the board's other pak0 is listed beside the chosen one")
        XCTAssertFalse(GameDataSelection.isOnBoard(rows[0], contents: board),
                       "different bytes under the same name are not on the board")
        XCTAssertFalse(rows[1].isChecked, "the chosen pak0 is to replace it")
        XCTAssertEqual(selection.desiredFiles(board: board).map(\.sha256), [second.sha256])
        selection.remove(rows[0].id)
        XCTAssertEqual(selection.items(of: .quakePak).map(\.source), [.board])
        XCTAssertTrue(selection.items(of: .quakePak)[0].isChecked,
                      "removing the chosen file keeps the board's")
        XCTAssertEqual(selection.desiredFiles(board: board).first?.boardOnly, true)
    }

    func testABoardFileUncheckedStaysUncheckedWhenTheBoardIsNotedAgain() {
        var selection = GameDataSelection(quakeOffered: false, doomChecked: true)
        let board = GameStore.Contents.directory(GameStore.Directory(
            areaBytes: 0x1200000, generation: 1,
            entries: [GameStore.Entry(kind: .doomWad, offset: 0, length: 600, name: "old.wad",
                                      sha256: String(repeating: "b", count: 64))]))
        selection.noteBoard(board)
        selection.setChecked("board/1/old.wad", false)
        selection.add(identified(Self.wad(), "doom2.wad", .doomWad),
                      source: .chosen(URL(fileURLWithPath: "/tmp/doom2.wad")))
        selection.noteBoard(board)
        XCTAssertEqual(selection.items(of: .doomWad).first { $0.source == .board }?.isChecked,
                       false)
        XCTAssertEqual(selection.desiredFiles(board: board).map(\.name), ["doom2.wad"])
    }
}

extension GameDataTests {
    func testSpaceCountsSectorsAndBlocksWhatDoesNotFit() {
        var selection = GameDataSelection(quakeOffered: true)
        let wad = try! GameData.identify(Self.wad(), filename: "doom2.wad", kind: .doomWad)
        selection.add(wad, source: .chosen(URL(fileURLWithPath: "/tmp/doom2.wad")))
        let usable = GameDataSelection.expectedUsableBytes(chip: "esp32p4")
        XCTAssertEqual(usable, 18_870_272)
        XCTAssertNil(GameDataSelection.expectedUsableBytes(chip: "esp32s3"))
        var space = selection.space(usableBytes: usable, contents: nil)
        XCTAssertEqual(space.neededBytes, 4096, "a file takes whole 4 KiB sectors")
        XCTAssertTrue(space.fits)
        // The board's own files count once it is read: a pak0 that stays.
        let board = GameStore.Contents.legacy(legacyPak0Bytes: 18_869_000)
        selection.noteBoard(board)
        space = selection.space(usableBytes: usable, contents: board)
        XCTAssertEqual(space.neededBytes, 4096 + GameStore.aligned(18_869_000))
        XCTAssertFalse(space.fits)
        XCTAssertTrue(space.problem?.contains("Uncheck") ?? false)
        // Unknown usable bytes (an S3 before it is read) never blocks on space.
        XCTAssertTrue(selection.space(usableBytes: nil, contents: nil).fits)
        // A pak1 with no pak0 is refused whatever the space.
        var paks = GameDataSelection(quakeOffered: true)
        paks.add(try! GameData.identify(Self.pak(), filename: "pak1.pak", kind: .quakePak),
                 source: .chosen(URL(fileURLWithPath: "/tmp/pak1.pak")))
        XCTAssertTrue(paks.space(usableBytes: usable, contents: nil).problem?
            .contains("pak0.pak") ?? false)
    }
}
