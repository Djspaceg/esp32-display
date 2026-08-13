import XCTest
@testable import SenderProtocol

/// Byte-exact tests for the tile-stream grid, header, run merging, and
/// packer.
///
/// Every wire vector here is written out by hand from the format comments in
/// TileProtocol.swift, independently of the firmware suite's vectors
/// (firmware/test/test_band_protocol.cpp asserts the same wire from the
/// other side) - deliberately never a shared fixture, so a protocol change
/// that breaks interoperability fails a test on at least one side instead of
/// silently updating both.
final class TileProtocolTests: XCTestCase {
    private let g466 = TileGeometry(width: 466, height: 466)

    // MARK: - Grid geometry

    func testGridFor466Panel() {
        // These numbers ARE the wire format for tile indices and run sizes.
        XCTAssertTrue(g466.isStreamable)
        XCTAssertEqual(g466.tileCols, 30)
        XCTAssertEqual(g466.tileRows, 30)
        XCTAssertEqual(g466.tileCount, 900)
        XCTAssertEqual(g466.frameBytes, 434_312)
        XCTAssertEqual(g466.colWidth(28), 16)
        XCTAssertEqual(g466.colWidth(29), 2)  // 466 = 29*16 + 2
        XCTAssertEqual(g466.rowHeight(29), 2)
        XCTAssertEqual(g466.col(899), 29)     // the 2x2 corner tile
        XCTAssertEqual(g466.row(899), 29)
        XCTAssertEqual(g466.col(30), 0)       // row-major indexing
        XCTAssertEqual(g466.row(30), 1)
    }

    func testOtherSquareGridsDeriveSoundly() {
        let g480 = TileGeometry(width: 480, height: 480)
        XCTAssertTrue(g480.isStreamable)
        XCTAssertEqual(g480.tileCount, 900)
        XCTAssertEqual(g480.colWidth(29), 16)  // divides evenly
        let g412 = TileGeometry(width: 412, height: 412)
        XCTAssertTrue(g412.isStreamable)
        XCTAssertEqual(g412.tileCols, 26)
        XCTAssertEqual(g412.colWidth(25), 12)  // 412 = 25*16 + 12
    }

    func testUnstreamableGeometriesAreRefused() {
        // 511 is the widest valid panel: 32 tile columns and a full-row raw
        // run of 511*16*2 = 16352 B, under the record length field's 16383.
        XCTAssertFalse(TileGeometry(width: 0, height: 0).isStreamable)
        XCTAssertFalse(TileGeometry(width: 466, height: 0).isStreamable)
        XCTAssertTrue(TileGeometry(width: 511, height: 466).isStreamable)
        XCTAssertFalse(TileGeometry(width: 512, height: 466).isStreamable)
        XCTAssertFalse(TileGeometry(width: 528, height: 466).isStreamable)
    }

    func testRunArithmetic() {
        XCTAssertTrue(g466.runValid(startTile: 0, runLength: 30))
        XCTAssertFalse(g466.runValid(startTile: 0, runLength: 31))
        XCTAssertFalse(g466.runValid(startTile: 1, runLength: 30))  // crosses
        XCTAssertTrue(g466.runValid(startTile: 899, runLength: 1))
        XCTAssertFalse(g466.runValid(startTile: 900, runLength: 1))
        XCTAssertFalse(g466.runValid(startTile: 0, runLength: 0))
        XCTAssertEqual(g466.runPixelWidth(startTile: 0, runLength: 30), 466)
        XCTAssertEqual(g466.runRawBytes(startTile: 0, runLength: 30), 14_912)
        XCTAssertEqual(g466.runPixelWidth(startTile: 28, runLength: 2), 18)
        XCTAssertEqual(g466.runRawBytes(startTile: 899, runLength: 1), 8)
        XCTAssertEqual(g466.runRawBytes(startTile: 870, runLength: 30), 1_864)
    }

    // MARK: - Packet header

    func testPacketHeaderWireLayout() {
        // frame 0x1234, first tile 5, 80 dirty tiles, landscape.
        // first_tile field: 0x0005 | 0x8000 = 0x8005 LE -> 05 80.
        // dirty_count field: 80 | 0x8000 = 0x8050 LE -> 50 80.
        let header = TileProtocol.packetHeader(
            frameId: 0x1234, firstTile: 5, dirtyCount: 80, landscape: true)
        XCTAssertEqual([UInt8](header), [0x34, 0x12, 0x05, 0x80, 0x50, 0x80])
        let portrait = TileProtocol.packetHeader(
            frameId: 7, firstTile: 899, dirtyCount: 900, landscape: false)
        // 899 = 0x383; | 0x8000 = 0x8383 -> 83 83. 900 = 0x384 -> 84 03.
        XCTAssertEqual([UInt8](portrait), [0x07, 0x00, 0x83, 0x83, 0x84, 0x03])
    }

    // MARK: - Run merging

    func testMergeRunsCoalescesWithinRowsOnly() {
        XCTAssertTrue(TileProtocol.mergeRuns(dirtyTiles: [], geometry: g466).isEmpty)
        let single = TileProtocol.mergeRuns(dirtyTiles: [5], geometry: g466)
        XCTAssertEqual(single.count, 1)
        XCTAssertTrue(single[0] == (start: 5, length: 1))
        // 29 and 30 are index-adjacent but in different tile-rows: the run
        // must split there or the draw rect would wrap around the panel.
        let wrap = TileProtocol.mergeRuns(dirtyTiles: [28, 29, 30], geometry: g466)
        XCTAssertEqual(wrap.count, 2)
        XCTAssertTrue(wrap[0] == (start: 28, length: 2))
        XCTAssertTrue(wrap[1] == (start: 30, length: 1))
        let mixed = TileProtocol.mergeRuns(
            dirtyTiles: [3, 4, 5, 9, 65, 66], geometry: g466)
        XCTAssertEqual(mixed.count, 3)
        XCTAssertTrue(mixed[0] == (start: 3, length: 3))
        XCTAssertTrue(mixed[1] == (start: 9, length: 1))
        XCTAssertTrue(mixed[2] == (start: 65, length: 2))
        // A full row merges to one run of 30.
        let fullRow = TileProtocol.mergeRuns(
            dirtyTiles: Array(30..<60), geometry: g466)
        XCTAssertEqual(fullRow.count, 1)
        XCTAssertTrue(fullRow[0] == (start: 30, length: 30))
    }

    // MARK: - Tile diffing

    func testDirtyTilesFindsExactlyTheChangedTiles() {
        let clean = [UInt8](repeating: 0x11, count: g466.frameBytes)
        var frame = clean
        // Identical frames: nothing dirty.
        XCTAssertEqual(
            TileProtocol.dirtyTiles(new: frame, previous: clean, geometry: g466),
            [])
        // One pixel at (20, 20) - inside tile (1,1) = index 31 - dirties
        // exactly that tile.
        frame[(20 * 466 + 20) * 2] ^= 0xFF
        XCTAssertEqual(
            TileProtocol.dirtyTiles(new: frame, previous: clean, geometry: g466),
            [31])
        // A pixel pair straddling a tile boundary (x = 15 and 16, y = 0)
        // dirties tiles 0 and 1 - and the result is sorted.
        frame = clean
        frame[(0 * 466 + 15) * 2] ^= 0xFF
        frame[(0 * 466 + 16) * 2] ^= 0xFF
        XCTAssertEqual(
            TileProtocol.dirtyTiles(new: frame, previous: clean, geometry: g466),
            [0, 1])
        // The last pixel of the frame lives in the 2x2 corner tile (899);
        // the edge arithmetic must reach it.
        frame = clean
        frame[g466.frameBytes - 1] ^= 0xFF
        XCTAssertEqual(
            TileProtocol.dirtyTiles(new: frame, previous: clean, geometry: g466),
            [899])
        // A change in the last COLUMN's 2 px strip (x = 464, y = 100 ->
        // tile row 6, col 29 = tile 209).
        frame = clean
        frame[(100 * 466 + 464) * 2] ^= 0xFF
        XCTAssertEqual(
            TileProtocol.dirtyTiles(new: frame, previous: clean, geometry: g466),
            [6 * 30 + 29])
    }

    // MARK: - Run extraction

    func testExtractRunReadsTheRightRect() {
        // Frame filled with 0x00; tile 31's rect (row 1, col 1: x 16..31,
        // y 16..31) painted 0xAB. Extracting the run [31] must return 512
        // bytes of 0xAB and extracting its neighbours must return none.
        var pixels = [UInt8](repeating: 0, count: g466.frameBytes)
        for y in 16..<32 {
            for x in 16..<32 {
                pixels[(y * 466 + x) * 2] = 0xAB
                pixels[(y * 466 + x) * 2 + 1] = 0xAB
            }
        }
        let run = TileProtocol.extractRun(
            pixels: pixels, geometry: g466, startTile: 31, runLength: 1)
        XCTAssertEqual(run.count, 512)
        XCTAssertTrue(run.allSatisfy { $0 == 0xAB })
        let neighbour = TileProtocol.extractRun(
            pixels: pixels, geometry: g466, startTile: 32, runLength: 1)
        XCTAssertTrue(neighbour.allSatisfy { $0 == 0x00 })
        // A 2-tile run spanning the painted tile and its clean neighbour.
        let both = TileProtocol.extractRun(
            pixels: pixels, geometry: g466, startTile: 31, runLength: 2)
        XCTAssertEqual(both.count, 1024)  // 32x16 px x 2 B
        // Row-major within the run: first 32 bytes are tile 31's row 0.
        XCTAssertTrue(both[0..<32].allSatisfy { $0 == 0xAB })
        XCTAssertTrue(both[32..<64].allSatisfy { $0 == 0x00 })
        // The corner tile extracts 2x2.
        let corner = TileProtocol.extractRun(
            pixels: pixels, geometry: g466, startTile: 899, runLength: 1)
        XCTAssertEqual(corner.count, 8)
    }

    // MARK: - Packer

    func testPackedDatagramWireLayout() {
        // One flat dirty tile -> one datagram: header + one RLE565 record.
        // Tile 5's 16x16 black rect RLE-encodes to runs of 129,127:
        // [0xFF 00 00] [0xFD 00 00] = 6 bytes < 512 raw.
        let pixels = [UInt8](repeating: 0, count: g466.frameBytes)
        let packets = TilePacker.packets(
            frameId: 7, dirtyTiles: [5], pixels: pixels,
            geometry: g466, landscape: false, policy: .aggressive)
        XCTAssertEqual(packets.count, 1)
        let expected: [UInt8] = [
            0x07, 0x00,              // frame_id 7
            0x05, 0x80,              // first_tile 5 | stream flag
            0x01, 0x00,              // dirty_count 1, portrait
            0x05, 0x00,              // record: tile 5, run length 1
            0x06, 0x40,              // len 6 | codec 1 (RLE565) << 14
            0xFF, 0x00, 0x00, 0xFD, 0x00, 0x00,
        ]
        XCTAssertEqual([UInt8](packets[0]), expected)
    }

    func testLosslessOnlyNeverEmitsBc1() {
        // Noise content (every pixel distinct): raw beats RLE, and BC1 -
        // though 4x smaller - must not appear when lossy is off.
        var pixels = [UInt8](repeating: 0, count: g466.frameBytes)
        var v: UInt16 = 1
        for y in 0..<16 {
            for x in 0..<16 {
                v &+= 7
                pixels[(y * 466 + x) * 2] = UInt8(v >> 8)
                pixels[(y * 466 + x) * 2 + 1] = UInt8(v & 0xFF)
            }
        }
        let lossless = TilePacker.packets(
            frameId: 1, dirtyTiles: [0], pixels: pixels,
            geometry: g466, landscape: false, policy: .losslessOnly)
        XCTAssertEqual(lossless.count, 1)
        let bytes = [UInt8](lossless[0])
        // Record len field at offset 8: 512 | raw codec 0 -> 0x0200.
        XCTAssertEqual(bytes[8], 0x00)
        XCTAssertEqual(bytes[9], 0x02)
        XCTAssertEqual(bytes.count, 6 + 4 + 512)
        // The same tile with lossy allowed goes BC1: 128 B, codec 2.
        let lossy = TilePacker.packets(
            frameId: 1, dirtyTiles: [0], pixels: pixels,
            geometry: g466, landscape: false, policy: .aggressive)
        let lossyBytes = [UInt8](lossy[0])
        XCTAssertEqual(lossyBytes[8], 0x80)  // 128 | 2 << 14 = 0x8080
        XCTAssertEqual(lossyBytes[9], 0x80)
        XCTAssertEqual(lossyBytes.count, 6 + 4 + 128)
    }

    func testOversizeRunsSplitSoRecordsNeverSpanDatagrams() {
        // A full-width noise run raw is 14912 B - far over one datagram.
        // With lossy off it must split into records that each fit, cover
        // every tile exactly once, and decode back to the source.
        var pixels = [UInt8](repeating: 0, count: g466.frameBytes)
        var seed: UInt32 = 99
        for i in stride(from: 0, to: 466 * 16 * 2, by: 2) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[i] = UInt8((seed >> 24) & 0xFF)
            pixels[i + 1] = UInt8((seed >> 16) & 0xFF)
        }
        let packets = TilePacker.packets(
            frameId: 3, dirtyTiles: Array(0..<30), pixels: pixels,
            geometry: g466, landscape: false, policy: .losslessOnly)
        var tilesCovered = [Int]()
        for packet in packets {
            XCTAssertLessThanOrEqual(packet.count, TileGeometry.maxPacketBytes)
            let bytes = [UInt8](packet)
            XCTAssertEqual(bytes[3] & 0x80, 0x80)  // stream flag
            var at = 6
            var isFirst = true
            while at < bytes.count {
                let tileField = Int(bytes[at]) | (Int(bytes[at + 1]) << 8)
                let lenField = Int(bytes[at + 2]) | (Int(bytes[at + 3]) << 8)
                let start = tileField & 0x03FF
                let runLength = ((tileField & 0x7C00) >> 10) + 1
                let codec = lenField >> 14
                let len = lenField & 0x3FFF
                at += 4
                if isFirst {
                    isFirst = false
                    // Header cross-check: first_tile matches record one.
                    XCTAssertEqual(
                        Int(bytes[2]) | (Int(bytes[3] & 0x03) << 8), start)
                }
                let payload = Array(bytes[at..<(at + len)])
                at += len
                let rawLen = g466.runRawBytes(startTile: start, runLength: runLength)
                let raw: [UInt8]?
                switch codec {
                case 0: raw = payload
                case 1: raw = RLE565.decode(payload, expectedBytes: rawLen)
                default: raw = nil  // BC1 must not appear: lossless only
                }
                XCTAssertNotNil(raw)
                XCTAssertEqual(raw, TileProtocol.extractRun(
                    pixels: pixels, geometry: g466,
                    startTile: start, runLength: runLength))
                tilesCovered.append(contentsOf: start..<(start + runLength))
            }
            XCTAssertEqual(at, bytes.count)
        }
        XCTAssertEqual(tilesCovered.sorted(), Array(0..<30))
        XCTAssertEqual(Set(tilesCovered).count, 30)
    }

    // MARK: - Lossy policy and the variance gate

    func testRunVarianceIsPinned() {
        // Flat content has zero variance whatever the color.
        let flat = [UInt8](repeating: 0xAA, count: 16 * 16 * 2)
        XCTAssertEqual(TilePacker.runVariance(flat), 0)
        XCTAssertEqual(TilePacker.runVariance([]), 0)
        // Half black, half white: per channel in 888 space, sum = 128*255,
        // sumSq = 128*255^2 over 256 px -> population variance 16256 (the
        // integer truncation is part of the pinned definition), x3 channels.
        var half = [UInt8]()
        for i in 0..<256 {
            half.append(contentsOf: (i < 128 ? [0x00, 0x00] : [0xFF, 0xFF]) as [UInt8])
        }
        XCTAssertEqual(TilePacker.runVariance(half), 16256 * 3)
    }

    func testAutoKeepsGradientsLosslessButCompressesTexture() {
        // A gentle red gradient: 4 levels across the tile, variance in the
        // tens - BC1 (128 B) would beat raw (512 B), but under .auto the
        // variance gate keeps it lossless, because gradients are exactly
        // where BC1's 4:1 shows as banding.
        var pixels = [UInt8](repeating: 0, count: g466.frameBytes)
        for y in 0..<16 {
            for x in 0..<16 {
                let r5 = UInt16(x / 4)  // 0..3: gentle
                let p = r5 << 11
                pixels[(y * 466 + x) * 2] = UInt8(p >> 8)
                pixels[(y * 466 + x) * 2 + 1] = UInt8(p & 0xFF)
            }
        }
        func codecOfFirstRecord(_ packets: [Data]) -> Int {
            let bytes = [UInt8](packets[0])
            return (Int(bytes[8]) | (Int(bytes[9]) << 8)) >> 14
        }
        let auto = TilePacker.packets(
            frameId: 1, dirtyTiles: [0], pixels: pixels,
            geometry: g466, landscape: false, policy: .auto)
        XCTAssertNotEqual(codecOfFirstRecord(auto), 2)  // not BC1
        // The same tile under .aggressive, or under .auto with the
        // over-budget override, goes BC1.
        let aggressive = TilePacker.packets(
            frameId: 1, dirtyTiles: [0], pixels: pixels,
            geometry: g466, landscape: false, policy: .aggressive)
        XCTAssertEqual(codecOfFirstRecord(aggressive), 2)
        let forced = TilePacker.packets(
            frameId: 1, dirtyTiles: [0], pixels: pixels,
            geometry: g466, landscape: false, policy: .auto, forceLossy: true)
        XCTAssertEqual(codecOfFirstRecord(forced), 2)
        // Noise (photo-like texture, variance in the thousands) goes BC1
        // under plain .auto - the gate admits busy content.
        var seed: UInt32 = 7
        for y in 0..<16 {
            for x in 0..<16 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                pixels[(y * 466 + x) * 2] = UInt8((seed >> 24) & 0xFF)
                pixels[(y * 466 + x) * 2 + 1] = UInt8((seed >> 16) & 0xFF)
            }
        }
        let noisy = TilePacker.packets(
            frameId: 1, dirtyTiles: [0], pixels: pixels,
            geometry: g466, landscape: false, policy: .auto)
        XCTAssertEqual(codecOfFirstRecord(noisy), 2)
        // ...but never under .losslessOnly, override or not.
        let lossless = TilePacker.packets(
            frameId: 1, dirtyTiles: [0], pixels: pixels,
            geometry: g466, landscape: false, policy: .losslessOnly,
            forceLossy: true)
        XCTAssertNotEqual(codecOfFirstRecord(lossless), 2)
    }

    func testScatteredTilesShareAPacket() {
        // Non-consecutive dirty tiles - the common diff shape - pack
        // together because records carry their own indices.
        let pixels = [UInt8](repeating: 0x1F, count: g466.frameBytes)
        let packets = TilePacker.packets(
            frameId: 3, dirtyTiles: [0, 450, 899], pixels: pixels,
            geometry: g466, landscape: false, policy: .aggressive)
        XCTAssertEqual(packets.count, 1)
    }

    // MARK: - Constants

    func testWireConstantsMatchTheFirmware() {
        XCTAssertEqual(TileGeometry.tileDim, 16)
        XCTAssertEqual(TileGeometry.maxTiles, 1024)
        XCTAssertEqual(TileGeometry.maxRunTiles, 32)
        XCTAssertEqual(TileGeometry.headerBytes, 6)
        XCTAssertEqual(TileGeometry.maxPacketBytes, 1472)
        XCTAssertEqual(TileGeometry.recordHeaderBytes, 4)
        XCTAssertEqual(TileProtocol.firstTileStreamFlag, 0x8000)
        XCTAssertEqual(TileProtocol.recordLengthMask, 0x3FFF)
        XCTAssertEqual(TileProtocol.recordCodecShift, 14)
        XCTAssertEqual(TileProtocol.recordRunShift, 10)
        XCTAssertEqual(TileProtocol.Codec.raw.rawValue, 0)
        XCTAssertEqual(TileProtocol.Codec.rle565.rawValue, 1)
        XCTAssertEqual(TileProtocol.Codec.bc1.rawValue, 2)
        // Pinned because the firmware spells the same number out by hand
        // (deviceproto::CAP_TILE_STREAM).
        XCTAssertEqual(DeviceProtocol.Capabilities.tileStream.rawValue, 1 << 15)
        XCTAssertTrue(DeviceProtocol.Capabilities.tileStream
            .isDisjoint(with: [.power, .compressedBands]))
    }
}
