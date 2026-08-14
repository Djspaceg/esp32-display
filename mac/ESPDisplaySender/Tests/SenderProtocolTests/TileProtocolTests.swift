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

    // MARK: - What autoVarianceThreshold actually separates

    /// A 16x16 tile built from a per-pixel RGB565 function, wire order.
    private func tile(_ pixel: (Int, Int) -> UInt16) -> [UInt8] {
        var out = [UInt8]()
        for y in 0..<16 {
            for x in 0..<16 {
                let p = pixel(x, y)
                out.append(UInt8(p >> 8))
                out.append(UInt8(p & 0xFF))
            }
        }
        return out
    }

    private func rgb(_ r: Int, _ g: Int, _ b: Int) -> UInt16 {
        (UInt16(r & 0x1F) << 11) | (UInt16(g & 0x3F) << 5) | UInt16(b & 0x1F)
    }

    func testVarianceOfRepresentativeContentClasses() {
        // `autoVarianceThreshold` has been 400 since phase 5, described as a
        // first guess and never checked against content. The claim it rests on
        // is in TilePacker's own comment: flat fills are 0, a gentle gradient
        // lands in the tens to low hundreds, and photo texture or antialiased
        // text land in the thousands. Either that is true and 400 sits in a
        // real gap, or it is not and the number is arbitrary. This measures it.
        let flat = tile { _, _ in self.rgb(21, 42, 10) }
        XCTAssertEqual(TilePacker.runVariance(flat), 0)

        // A gentle gradient: 4 red levels across the tile, the case the
        // existing policy test uses. Kept lossless by the gate.
        let gentle = tile { x, _ in self.rgb(x / 4, 0, 0) }
        XCTAssertEqual(TilePacker.runVariance(gentle), 80)

        // A SMOOTH FULL-RANGE gradient - the content BC1 banding is actually
        // feared on, sweeping the whole red axis across 16 px.
        let steep = tile { x, _ in self.rgb(x * 2, 0, 0) }
        XCTAssertEqual(TilePacker.runVariance(steep), 5781)

        // A grey ramp, all three channels moving together.
        let greyRamp = tile { x, _ in self.rgb(x * 2, x * 4, x * 2) }
        XCTAssertEqual(TilePacker.runVariance(greyRamp), 17163)

        // Antialiased text: white ground, a black stroke, one grey pixel of
        // transition on each side.
        let text = tile { x, _ in
            switch x {
            case 7, 10: return self.rgb(16, 32, 16)
            case 8, 9: return self.rgb(0, 0, 0)
            default: return self.rgb(31, 63, 31)
            }
        }
        XCTAssertEqual(TilePacker.runVariance(text), 23397)

        // Photo-like texture.
        var seed: UInt32 = 12_345
        let noise = tile { _, _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return UInt16((seed >> 16) & 0xFFFF)
        }
        XCTAssertEqual(TilePacker.runVariance(noise), 16528)

        // The measured order is the point. Variance separates FLAT from
        // everything else and nothing more: a grey ramp (17163) scores HIGHER
        // than photo noise (16528), and a full-range red gradient (5781) is
        // ten times over the threshold. So the comment's claim that gradients
        // stay lossless holds only for nearly-flat ones; any gradient with
        // real dynamic range is treated as texture and sent as BC1.
        XCTAssertGreaterThan(TilePacker.runVariance(greyRamp),
                             TilePacker.runVariance(noise))
        XCTAssertGreaterThan(TilePacker.runVariance(steep),
                             TilePacker.autoVarianceThreshold * 10)
    }

    /// Worst and mean per-channel error a tile suffers through BC1, in 888
    /// space - the same expansion `BC1.palette` and `runVariance` work in.
    private func bc1Error(_ raw: [UInt8]) -> (max: Int, mean: Double) {
        guard let encoded = BC1.encode(raw[...], width: 16, height: 16),
              let back = BC1.decode(encoded, width: 16, height: 16) else {
            return (Int.max, .infinity)
        }
        func channels(_ hi: UInt8, _ lo: UInt8) -> (Int, Int, Int) {
            let p = (UInt16(hi) << 8) | UInt16(lo)
            let r5 = Int(p >> 11), g6 = Int((p >> 5) & 0x3F), b5 = Int(p & 0x1F)
            return ((r5 << 3) | (r5 >> 2), (g6 << 2) | (g6 >> 4),
                    (b5 << 3) | (b5 >> 2))
        }
        var worst = 0
        var total = 0
        for i in stride(from: 0, to: raw.count, by: 2) {
            let a = channels(raw[i], raw[i + 1])
            let b = channels(back[i], back[i + 1])
            for d in [abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)] {
                worst = max(worst, d)
                total += d
            }
        }
        return (worst, Double(total) / Double(raw.count / 2 * 3))
    }

    func testBc1ErrorIsSmallestOnExactlyTheContentTheGateLetsThrough() {
        // The question the variance measurement raises: if the gate cannot
        // tell a smooth ramp from noise, does letting ramps through actually
        // hurt? Measured per-channel error out of 255, through a real
        // encode/decode round trip.
        let greyRamp = tile { x, _ in self.rgb(x * 2, x * 4, x * 2) }
        let noise: [UInt8] = {
            var seed: UInt32 = 12_345
            return tile { _, _ in
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return UInt16((seed >> 16) & 0xFFFF)
            }
        }()
        let text = tile { x, _ in
            switch x {
            case 7, 10: return self.rgb(16, 32, 16)
            case 8, 9: return self.rgb(0, 0, 0)
            default: return self.rgb(31, 63, 31)
            }
        }

        let ramp = bc1Error(greyRamp)
        let tex = bc1Error(noise)
        let glyph = bc1Error(text)

        // A linear ramp is BC1's best case, not its worst: within a 4x4 block
        // it needs exactly the four levels the endpoint line provides, so the
        // fit is near exact. This is why letting ramps through costs little,
        // and why the banding the gate was built to prevent is a
        // BLOCK-BOUNDARY and endpoint-quantisation effect rather than
        // something variance could ever have predicted.
        XCTAssertEqual(ramp.max, 0)
        XCTAssertEqual(ramp.mean, 0.0)

        // Noise is where BC1 genuinely loses information - four levels cannot
        // represent sixteen unrelated colours - and it is exactly what the
        // gate admits. 166 out of 255 is two thirds of the range.
        XCTAssertEqual(tex.max, 166)

        // Text: the stroke and the ground come back exactly, because BC1's
        // bounding-box endpoints ARE those two colours. The cost falls on the
        // antialiasing pixels between them, whose mid-grey is ~40 off the
        // nearest point on the white-to-black endpoint line.
        XCTAssertEqual(glyph.max, 40)

        // The conclusion, pinned so it cannot quietly stop being true:
        // variance is ANTI-correlated with BC1 damage across these classes.
        // The tile BC1 reproduces exactly scores the highest variance of the
        // three; the tile it damages most scores lower.
        XCTAssertGreaterThan(TilePacker.runVariance(greyRamp),
                             TilePacker.runVariance(noise))
        XCTAssertLessThan(ramp.max, tex.max)
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

    // MARK: - Boundary-tile flattening: is it worth building?

    /// Whether a pixel's centre is inside the round glass, the same predicate
    /// `TileMask` applies per tile.
    private func pixelVisible(_ x: Int, _ y: Int, size: Int = 466) -> Bool {
        let c = Double(size) / 2
        let dx = Double(x) + 0.5 - c, dy = Double(y) + 0.5 - c
        return dx * dx + dy * dy < c * c
    }

    func testBoundaryFlatteningGainIsMeasuredBeforeBeingBuilt() {
        // Section 13.5 left this open: the 719 tiles a keyframe sends still
        // contain 11,244 invisible pixels in the boundary ring, and zeroing
        // them would give RLE long runs to collapse. It is only sound on the
        // RLE candidate - flattening drags BC1's endpoint bounding box and so
        // would damage the VISIBLE pixels of the same tile - which is why it
        // was never just switched on.
        //
        // Before building the plumbing, measure what it could win.
        let g = g466
        let mask = TileMask(geometry: g, round: true)
        var boundary = [Int]()
        for tile in mask.visibleTiles {
            let x0 = g.col(tile) * TileGeometry.tileDim
            let y0 = g.row(tile) * TileGeometry.tileDim
            var hidden = 0
            for y in y0..<(y0 + g.rowHeight(g.row(tile))) {
                for x in x0..<(x0 + g.colWidth(g.col(tile))) {
                    if !pixelVisible(x, y) { hidden += 1 }
                }
            }
            if hidden > 0 { boundary.append(tile) }
        }
        // The ring, and the invisible pixels still being paid for inside it.
        XCTAssertEqual(boundary.count, 106)
        var hiddenPixels = 0
        for tile in boundary {
            let x0 = g.col(tile) * TileGeometry.tileDim
            let y0 = g.row(tile) * TileGeometry.tileDim
            for y in y0..<(y0 + g.rowHeight(g.row(tile))) {
                for x in x0..<(x0 + g.colWidth(g.col(tile))) {
                    if !pixelVisible(x, y) { hiddenPixels += 1 }
                }
            }
        }
        XCTAssertEqual(hiddenPixels, 11_244)

        // Now the gain, on the content class where RLE actually wins and so
        // where flattening could matter: UI-like content, a few flat colours.
        // Photo content sends BC1, which flattening must not touch.
        func uiPixel(_ x: Int, _ y: Int) -> UInt16 {
            // Broad flat bands, the shape of a window's chrome.
            return y % 32 < 16 ? rgb(6, 12, 20) : rgb(28, 56, 28)
        }
        var asIs = 0
        var flattened = 0
        var seed: UInt32 = 99
        for tile in boundary {
            let x0 = g.col(tile) * TileGeometry.tileDim
            let y0 = g.row(tile) * TileGeometry.tileDim
            let w = g.colWidth(g.col(tile)), h = g.rowHeight(g.row(tile))
            var plain = [UInt8](), flat = [UInt8]()
            for y in y0..<(y0 + h) {
                for x in x0..<(x0 + w) {
                    let p = uiPixel(x, y)
                    plain.append(UInt8(p >> 8)); plain.append(UInt8(p & 0xFF))
                    // Outside the glass the sender may write anything. As-is
                    // it carries whatever the capture happened to contain -
                    // modelled as noise, because a desktop corner is not
                    // usually the same colour as the window over it.
                    if pixelVisible(x, y) {
                        flat.append(UInt8(p >> 8)); flat.append(UInt8(p & 0xFF))
                    } else {
                        seed = seed &* 1_664_525 &+ 1_013_904_223
                        let n = UInt16((seed >> 16) & 0xFFFF)
                        plain[plain.count - 2] = UInt8(n >> 8)
                        plain[plain.count - 1] = UInt8(n & 0xFF)
                        // Flattened: repeat the previous pixel so the run
                        // continues instead of breaking.
                        flat.append(flat.count >= 2 ? flat[flat.count - 2] : 0)
                        flat.append(flat.count >= 2 ? flat[flat.count - 1] : 0)
                    }
                }
            }
            asIs += RLE565.encode(plain[...])?.count ?? plain.count
            flattened += RLE565.encode(flat[...])?.count ?? flat.count
        }
        // 5x on the ring, ~20 KB a keyframe. But this is the PESSIMISTIC
        // bound: it models the hidden corner as per-pixel noise, and a real
        // desktop corner is wallpaper or a window - different from the visible
        // content, but not random.
        XCTAssertEqual(asIs, 25_842)
        XCTAssertEqual(flattened, 5_170)

        // The realistic bound: the corner holds a flat colour of its own. RLE
        // already collapses that to EXACTLY what flattening would achieve, so
        // flattening's entire value is recovering the noisy-corner case.
        var flatCornerAsIs = 0
        for tile in boundary {
            let x0 = g.col(tile) * TileGeometry.tileDim
            let y0 = g.row(tile) * TileGeometry.tileDim
            var raster = [UInt8]()
            for y in y0..<(y0 + g.rowHeight(g.row(tile))) {
                for x in x0..<(x0 + g.colWidth(g.col(tile))) {
                    let p = pixelVisible(x, y) ? uiPixel(x, y) : rgb(2, 4, 6)
                    raster.append(UInt8(p >> 8))
                    raster.append(UInt8(p & 0xFF))
                }
            }
            flatCornerAsIs += RLE565.encode(raster[...])?.count ?? raster.count
        }
        XCTAssertEqual(flatCornerAsIs, 5_170)
        // Identical to the flattened figure, which settles it: flattening wins
        // NOTHING when the corner is flat, and 5x when it is busy. The gain is
        // entirely a property of content the sender cannot control, and it only
        // ever helps the RLE candidate. Not built - see section 17.15 and the
        // bezel-diff test below, which fixes the larger problem instead.
        XCTAssertEqual(flatCornerAsIs, flattened)
    }

    func testDiffingIgnoresChangesBehindTheBezel() {
        // The better idea the flattening measurement surfaced. A boundary tile
        // is compared whole, so a change confined to its INVISIBLE pixels
        // marks it dirty and ships a record whose visible content is
        // identical. Flattening would only make that record smaller; not
        // sending it is strictly better, costs nothing in quality, and is
        // codec-independent - where flattening is unsound for BC1.
        let g = g466
        let mask = TileMask(geometry: g, round: true)
        var frame = [UInt8](repeating: 0x11, count: g.frameBytes)
        let previous = frame

        // Pick a boundary tile and change ONLY pixels outside the circle.
        var target = -1
        for tile in mask.visibleTiles {
            let x0 = g.col(tile) * TileGeometry.tileDim
            let y0 = g.row(tile) * TileGeometry.tileDim
            var hidden = [(Int, Int)]()
            for y in y0..<(y0 + g.rowHeight(g.row(tile))) {
                for x in x0..<(x0 + g.colWidth(g.col(tile))) {
                    if !pixelVisible(x, y) { hidden.append((x, y)) }
                }
            }
            if hidden.count >= 4 {
                target = tile
                for (x, y) in hidden {
                    frame[(y * g.width + x) * 2] = 0xFF
                    frame[(y * g.width + x) * 2 + 1] = 0xFF
                }
                break
            }
        }
        XCTAssertGreaterThanOrEqual(target, 0)

        let dirty = TileProtocol.dirtyTiles(
            new: frame, previous: previous, geometry: g, mask: mask)
        // Nothing visible changed, so nothing should be sent.
        XCTAssertEqual(dirty, [], "a change behind the bezel was reported dirty")
    }

    // MARK: - Half-resolution BC1 (codec 3)

    func testHalfDimRoundsUpSoDoublingAlwaysCoversTheRaster() {
        // Mirrors tileproto::halfDim. Rounding UP matters: the panel
        // pixel-doubles, so a half raster that rounded down would leave the
        // last row or column of an odd run unwritten.
        XCTAssertEqual(TileProtocol.halfDim(16), 8)
        XCTAssertEqual(TileProtocol.halfDim(2), 1)    // the 466 grid's edges
        XCTAssertEqual(TileProtocol.halfDim(1), 1)
        XCTAssertEqual(TileProtocol.halfDim(3), 2)
        XCTAssertEqual(TileProtocol.halfDim(466), 233)
        XCTAssertEqual(TileProtocol.halfDim(0), 0)
        XCTAssertEqual(TileProtocol.Codec.halfBc1.rawValue, 3)
    }

    func testDownsampleAveragesEachTwoByTwoBlock() {
        // Four distinct colours in one 2x2 block average to their mean per
        // channel, computed in 5/6/5 space with round-half-up.
        let raw: [UInt8] = [
            0xF8, 0x00, 0x00, 0x00,  // r=31 g=0 b=0, black
            0x00, 0x00, 0x00, 0x00,  // black, black
        ]
        let out = TileProtocol.downsample(raw[...], width: 2, height: 2)
        XCTAssertEqual(out?.count, 2)  // 1x1 px
        // r channel: (31 + 0 + 0 + 0 + 2) / 4 = 8; g and b stay 0.
        let c = (UInt16(out![0]) << 8) | UInt16(out![1])
        XCTAssertEqual(c >> 11, 8)
        XCTAssertEqual((c >> 5) & 0x3F, 0)
        XCTAssertEqual(c & 0x1F, 0)

        // A flat raster survives exactly - averaging equal values cannot
        // drift, which is what keeps flat half-res tiles from shimmering.
        let flat = [UInt8](repeating: 0x5A, count: 16 * 16 * 2)
        let flatOut = TileProtocol.downsample(flat[...], width: 16, height: 16)
        XCTAssertEqual(flatOut?.count, 8 * 8 * 2)
        XCTAssertEqual(flatOut, [UInt8](repeating: 0x5A, count: 8 * 8 * 2))
    }

    func testDownsampleReplicatesEdgesForOddDimensions() {
        // 3x1 -> 2x1: the second output pixel's 2x2 window runs off the right
        // edge, so it replicates the last column instead of averaging in
        // phantom pixels (matching BC1.encode's padding convention).
        let raw: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0xF8, 0x00]
        let out = TileProtocol.downsample(raw[...], width: 3, height: 1)
        XCTAssertEqual(out?.count, 2 * 2)
        // Pixel 1 samples columns 2 and (clamped) 2, both r=31 -> stays 31.
        let second = (UInt16(out![2]) << 8) | UInt16(out![3])
        XCTAssertEqual(second >> 11, 31)

        // Refusals: the raster's byte count must match its claimed size, or
        // the loop would read past the end.
        XCTAssertNil(TileProtocol.downsample(raw[...], width: 4, height: 1))
        XCTAssertNil(TileProtocol.downsample(raw[...], width: 0, height: 1))
        XCTAssertNil(TileProtocol.downsample(raw[...], width: 3, height: 0))
    }

    func testHalfResIsAQuarterOfBc1AndDecodesThroughPixelDoubling() {
        // The size claim section 16 rests on: 32 B a tile against BC1's 128,
        // so a full 719-tile frame is ~17 datagrams instead of 66.
        XCTAssertEqual(BC1.encodedBytes(width: 16, height: 16), 128)
        XCTAssertEqual(BC1.encodedBytes(width: 8, height: 8), 32)
        // Edge cases on the real grid: a 2 px column halves to 1 px, and a
        // full-width row to 233 px.
        XCTAssertEqual(BC1.encodedBytes(width: 1, height: 8), 16)
        XCTAssertEqual(BC1.encodedBytes(width: 233, height: 8), 944)

        // Round trip: downsample, encode, decode, and the decoded raster is
        // half-size - the panel's pixelDouble is what restores the run's true
        // dimensions, so this side must produce exactly the half raster the
        // firmware's length check expects.
        var raw = [UInt8]()
        var seed: UInt32 = 99
        for _ in 0..<(16 * 16) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            raw.append(UInt8((seed >> 24) & 0xFF))
            raw.append(UInt8((seed >> 16) & 0xFF))
        }
        let small = TileProtocol.downsample(raw[...], width: 16, height: 16)
        XCTAssertEqual(small?.count, 8 * 8 * 2)
        let encoded = BC1.encode(small![...], width: 8, height: 8)
        XCTAssertEqual(encoded?.count, 32)
        let decoded = BC1.decode(encoded!, width: 8, height: 8)
        XCTAssertEqual(decoded?.count, 8 * 8 * 2)
    }

    func testHalfResIsOnlyEverChosenWhenTheLadderAsksForIt() {
        // Noise: variance in the thousands, so BC1 wins on every policy that
        // admits lossy. Half-res would win on SIZE against all of them (32 B
        // vs 128), which is exactly why size must not be what selects it.
        var pixels = [UInt8](repeating: 0, count: g466.frameBytes)
        var seed: UInt32 = 4_242
        for y in 0..<16 {
            for x in 0..<16 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                pixels[(y * 466 + x) * 2] = UInt8((seed >> 24) & 0xFF)
                pixels[(y * 466 + x) * 2 + 1] = UInt8((seed >> 16) & 0xFF)
            }
        }
        func codec(_ packets: [Data]) -> Int {
            let bytes = [UInt8](packets[0])
            return (Int(bytes[8]) | (Int(bytes[9]) << 8)) >> 14
        }
        func packets(
            _ policy: TileLossyPolicy, lossy: Bool = false, half: Bool = false
        ) -> [Data] {
            TilePacker.packets(
                frameId: 1, dirtyTiles: [0], pixels: pixels,
                geometry: g466, landscape: false, policy: policy,
                forceLossy: lossy, forceHalfRes: half)
        }
        // Nothing reaches codec 3 without the flag - not even .aggressive,
        // which would otherwise blur every static window on screen.
        XCTAssertEqual(codec(packets(.auto)), 2)
        XCTAssertEqual(codec(packets(.aggressive)), 2)
        XCTAssertEqual(codec(packets(.auto, lossy: true)), 2)
        // With the flag, codec 3 supersedes BC1.
        XCTAssertEqual(codec(packets(.auto, half: true)), 3)
        XCTAssertEqual(codec(packets(.aggressive, half: true)), 3)
        // .losslessOnly forbids it however hard the ladder pushes: the user
        // asked for pixel-perfect, and dropping resolution is the largest
        // violation of that on offer.
        XCTAssertNotEqual(codec(packets(.losslessOnly, half: true)), 3)
        XCTAssertNotEqual(
            codec(packets(.losslessOnly, lossy: true, half: true)), 3)

        // The payload really is a half-res BC1 raster, not merely tagged as
        // one: 32 bytes for this 16x16 tile.
        let bytes = [UInt8](packets(.auto, half: true)[0])
        XCTAssertEqual(Int(bytes[8]) | (Int(bytes[9]) << 8), 32 | (3 << 14))
        XCTAssertEqual(bytes.count, 6 + 4 + 32)
    }

    func testHalfResLosesToASmallerLosslessEncoding() {
        // A flat tile RLEs to a handful of bytes. Half-res is 32 - larger -
        // so the size comparison keeps it at full resolution even with the
        // ladder pushing. This is what stops a mostly-static screen from
        // going soft the moment one busy region trips the budget.
        let pixels = [UInt8](repeating: 0x77, count: g466.frameBytes)
        let out = TilePacker.packets(
            frameId: 1, dirtyTiles: [0], pixels: pixels,
            geometry: g466, landscape: false, policy: .auto,
            forceHalfRes: true)
        let bytes = [UInt8](out[0])
        let lenField = Int(bytes[8]) | (Int(bytes[9]) << 8)
        XCTAssertEqual(lenField >> 14, 1)  // RLE565, not half-res
        XCTAssertLessThan(lenField & 0x3FFF, 32)
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

    // MARK: - Round-glass mask

    func testRoundMaskCountsForThe466Panel() {
        // Verified against real glass before anything relied on it:
        // `espdisp.py tile-test --round-mask` painted these 181 tiles
        // magenta and none of them was visible, with the boundary ring
        // reaching the bezel. The counts are spelled out rather than
        // recomputed so a change to the predicate fails here.
        let mask = TileMask(geometry: g466, round: true)
        XCTAssertTrue(mask.round)
        XCTAssertEqual(mask.visibleTiles.count, 719)
        XCTAssertEqual(mask.hiddenCount, 181)
        XCTAssertEqual(mask.visibleTiles, mask.visibleTiles.sorted())
        // The four corner tiles are the most obviously hidden.
        XCTAssertFalse(mask.isVisible(0))
        XCTAssertFalse(mask.isVisible(29))
        XCTAssertFalse(mask.isVisible(870))
        XCTAssertFalse(mask.isVisible(899))
        // The centre is visible.
        XCTAssertTrue(mask.isVisible(14 * 30 + 14))
        XCTAssertTrue(mask.isVisible(15 * 30 + 15))
        // Out of range is not visible rather than a trap.
        XCTAssertFalse(mask.isVisible(-1))
        XCTAssertFalse(mask.isVisible(900))
    }

    func testRoundMaskRowSpansAreOneContiguousInterval() {
        // A circle's intersection with a tile-row is convex, so every row's
        // visible tiles form ONE run. That is what keeps masking free on the
        // draw side: 30 rows still cost 30 draw calls, never more. The spans
        // are written out by hand from the geometry.
        let expected = [
            (9, 19), (7, 21), (5, 23), (4, 24), (3, 25), (2, 26), (2, 26),
            (1, 27), (1, 27), (0, 28), (0, 28), (0, 28), (0, 29), (0, 29),
            (0, 29), (0, 29), (0, 29), (0, 28), (0, 28), (0, 28), (1, 28),
            (1, 27), (2, 27), (2, 26), (3, 25), (4, 24), (5, 23), (7, 22),
            (9, 20), (12, 16),
        ]
        let mask = TileMask(geometry: g466, round: true)
        for row in 0..<30 {
            let cols = (0..<30).filter { mask.isVisible(row * 30 + $0) }
            XCTAssertEqual(cols.first, expected[row].0, "row \(row) start")
            XCTAssertEqual(cols.last, expected[row].1, "row \(row) end")
            XCTAssertEqual(cols, Array(expected[row].0...expected[row].1),
                           "row \(row) must be one contiguous span")
        }
    }

    func testMaskHidesNothingWhenNotRound() {
        // Rectangular panels need no special case at the call sites.
        let flat = TileMask(geometry: g466, round: false)
        XCTAssertFalse(flat.round)
        XCTAssertEqual(flat.visibleTiles.count, 900)
        XCTAssertEqual(flat.hiddenCount, 0)
        // A round flag on non-square glass is refused: no such panel exists,
        // and the inscribed-circle arithmetic would be wrong for it.
        let oblong = TileMask(
            geometry: TileGeometry(width: 172, height: 320), round: true)
        XCTAssertFalse(oblong.round)
        XCTAssertEqual(oblong.hiddenCount, 0)
    }

    func testDirtyTilesSkipsMaskedTiles() {
        // A change in a corner tile is invisible, so it must not be reported.
        let clean = [UInt8](repeating: 0x11, count: g466.frameBytes)
        var frame = clean
        frame[0] ^= 0xFF                       // tile 0: hidden corner
        frame[(233 * 466 + 233) * 2] ^= 0xFF   // dead centre: visible
        let mask = TileMask(geometry: g466, round: true)
        let masked = TileProtocol.dirtyTiles(
            new: frame, previous: clean, geometry: g466, mask: mask)
        XCTAssertEqual(masked, [14 * 30 + 14])
        // Without the mask both tiles report, which is what the band-era
        // behavior was and still is for rectangular panels.
        let unmasked = TileProtocol.dirtyTiles(
            new: frame, previous: clean, geometry: g466)
        XCTAssertEqual(unmasked, [0, 14 * 30 + 14])
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
        // (deviceproto::CAP_TILE_STREAM, deviceproto::CAP_ROUND_DISPLAY).
        XCTAssertEqual(DeviceProtocol.Capabilities.tileStream.rawValue, 1 << 15)
        XCTAssertEqual(DeviceProtocol.Capabilities.roundDisplay.rawValue, 1 << 16)
        XCTAssertTrue(DeviceProtocol.Capabilities.tileStream
            .isDisjoint(with: [.power, .compressedBands, .roundDisplay]))
    }
}
