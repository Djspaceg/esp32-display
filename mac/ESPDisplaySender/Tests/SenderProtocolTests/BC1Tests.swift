import XCTest
@testable import SenderProtocol

/// Byte-exact tests for the BC1 tile codec.
///
/// Every wire vector here is written out by hand from the format comments in
/// BC1.swift, independently of the firmware suite's vectors
/// (firmware/test/test_band_protocol.cpp asserts the same wire from the other
/// side) - deliberately never a shared fixture, so a codec change that breaks
/// interoperability fails a test on at least one side instead of silently
/// updating both.
final class BC1Tests: XCTestCase {
    // MARK: - Sizing

    func testEncodedSizeIsAPureFunctionOfDimensions() {
        // Fixed-rate: ceil(w/4) x ceil(h/4) blocks of 8 bytes, pinned over
        // the 466x466 tile grid's real run shapes including the 2 px edges.
        XCTAssertEqual(BC1.encodedBytes(width: 4, height: 4), 8)
        XCTAssertEqual(BC1.encodedBytes(width: 16, height: 16), 128)
        XCTAssertEqual(BC1.encodedBytes(width: 464, height: 16), 3712)
        XCTAssertEqual(BC1.encodedBytes(width: 2, height: 16), 32)
        XCTAssertEqual(BC1.encodedBytes(width: 16, height: 2), 32)
        XCTAssertEqual(BC1.encodedBytes(width: 2, height: 2), 8)
        XCTAssertEqual(BC1.encodedBytes(width: 466, height: 16), 3744)
        XCTAssertEqual(BC1.encodedBytes(width: 0, height: 16), 0)
        XCTAssertEqual(BC1.encodedBytes(width: 16, height: 0), 0)
        XCTAssertEqual(BC1.encodedBytes(width: 4097, height: 4), 0)
    }

    // MARK: - Palette

    func testPaletteInterpolantsTruncate() {
        // c0 = 0xF800 (max red), c1 = 0x0000: red interpolants 2*31/3 = 20
        // and 31/3 = 10 -> 0xA000 and 0x5000. Integer division truncates;
        // pinned so neither side rounds.
        XCTAssertEqual(BC1.palette(0xF800, 0x0000),
                       [0xF800, 0x0000, 0xA000, 0x5000])
        // White against 0x2104 (r=4, g=8, b=4):
        // 2/3 point r=(62+4)/3=22 g=(126+8)/3=44 b=22 -> 0xB596
        // 1/3 point r=(31+8)/3=13 g=(63+16)/3=26 b=13 -> 0x6B4D
        let pal = BC1.palette(0xFFFF, 0x2104)
        XCTAssertEqual(pal[2], 0xB596)
        XCTAssertEqual(pal[3], 0x6B4D)
    }

    // MARK: - Decode wire vectors

    func testHandBuiltBlockDecodesByteForByte() {
        // Endpoints red/black, index word 0xE4E4E4E4: each byte 0b11100100
        // is one block row of indices 0,1,2,3 LSB-first. Every decoded row
        // must be [c0, c1, 2/3 point, 1/3 point] in big-endian pixel order.
        let block: [UInt8] = [0x00, 0xF8, 0x00, 0x00, 0xE4, 0xE4, 0xE4, 0xE4]
        let out = BC1.decode(block, width: 4, height: 4)
        XCTAssertNotNil(out)
        let row: [UInt8] = [0xF8, 0x00, 0x00, 0x00, 0xA0, 0x00, 0x50, 0x00]
        for r in 0..<4 {
            XCTAssertEqual(Array(out![(r * 8)..<(r * 8 + 8)]), row)
        }
    }

    func testEdgeBlockClipsWritesToTheRaster() {
        // A 2x2 raster is one block; only its top-left 2x2 pixels land.
        // Indices: rows of 0,1,x,x - the written pixels alternate c0/c1.
        let block: [UInt8] = [0x00, 0xF8, 0x1F, 0x00, 0xE4, 0xE4, 0xE4, 0xE4]
        let out = BC1.decode(block, width: 2, height: 2)
        XCTAssertEqual(out, [0xF8, 0x00, 0x00, 0x1F,   // row 0: c0, c1
                             0xF8, 0x00, 0x00, 0x1F])  // row 1: c0, c1
    }

    // MARK: - Round-trips

    func testFlatRastersRoundTripExactly() {
        // Bounding-box endpoints collapse to the one color, at every
        // tile-grid shape including the 2 px edges.
        for (w, h) in [(16, 16), (2, 16), (16, 2), (2, 2), (48, 16)] {
            var raw = [UInt8]()
            for _ in 0..<(w * h) { raw.append(contentsOf: [0x2A, 0xAA] as [UInt8]) }
            let encoded = BC1.encode(raw[...], width: w, height: h)
            XCTAssertEqual(encoded?.count, BC1.encodedBytes(width: w, height: h))
            XCTAssertEqual(BC1.decode(encoded!, width: w, height: h), raw)
        }
    }

    func testOrderedTwoToneRoundTripsExactly() {
        // Two colors that are channel-wise ordered (black-on-white text's
        // shape): the bounding box IS the two colors, so the round-trip is
        // lossless.
        var raw = [UInt8]()
        for i in 0..<(16 * 16) {
            let ink = (i / 3) % 2 == 0
            raw.append(contentsOf: (ink ? [0x00, 0x00] : [0xFF, 0xFF]) as [UInt8])
        }
        let encoded = BC1.encode(raw[...], width: 16, height: 16)
        XCTAssertEqual(BC1.decode(encoded!, width: 16, height: 16), raw)
    }

    func testLossyOutputStaysWithinEachBlocksColorBounds() {
        // decode(encode(x)) cannot invent colors outside the per-channel
        // bounding box each block derived - the interpolants sit between
        // the endpoints by construction. Deterministic pseudo-random input.
        var seed: UInt32 = 0x1234567
        func next() -> UInt32 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return seed
        }
        for _ in 0..<20 {
            let w = 16, h = 16
            var raw = [UInt8]()
            for _ in 0..<(w * h) {
                let v = next()
                raw.append(UInt8((v >> 24) & 0xFF))
                raw.append(UInt8((v >> 16) & 0xFF))
            }
            let encoded = BC1.encode(raw[...], width: w, height: h)!
            let decoded = BC1.decode(encoded, width: w, height: h)!
            func channels(_ bytes: [UInt8], _ at: Int) -> (Int, Int, Int) {
                let p = (UInt16(bytes[at]) << 8) | UInt16(bytes[at + 1])
                return (Int(p >> 11), Int((p >> 5) & 0x3F), Int(p & 0x1F))
            }
            for by in 0..<(h / 4) {
                for bx in 0..<(w / 4) {
                    var rMin = 0x1F, rMax = 0, gMin = 0x3F, gMax = 0
                    var bMin = 0x1F, bMax = 0
                    for py in 0..<4 {
                        for px in 0..<4 {
                            let at = ((by * 4 + py) * w + bx * 4 + px) * 2
                            let (r, g, b) = channels(raw, at)
                            rMin = min(rMin, r); rMax = max(rMax, r)
                            gMin = min(gMin, g); gMax = max(gMax, g)
                            bMin = min(bMin, b); bMax = max(bMax, b)
                        }
                    }
                    for py in 0..<4 {
                        for px in 0..<4 {
                            let at = ((by * 4 + py) * w + bx * 4 + px) * 2
                            let (r, g, b) = channels(decoded, at)
                            XCTAssertTrue(r >= rMin && r <= rMax)
                            XCTAssertTrue(g >= gMin && g <= gMax)
                            XCTAssertTrue(b >= bMin && b <= bMax)
                        }
                    }
                }
            }
        }
    }

    func testEdgeReplicationRoundTripsFlatEdgeTiles() {
        // 6x6: four blocks, every one clipped. Flat content must survive
        // the padding (replication cannot introduce a second color).
        let raw = [UInt8](repeating: 0x33, count: 6 * 6 * 2)
        let encoded = BC1.encode(raw[...], width: 6, height: 6)
        XCTAssertEqual(encoded?.count, BC1.encodedBytes(width: 6, height: 6))
        XCTAssertEqual(BC1.decode(encoded!, width: 6, height: 6), raw)
    }

    // MARK: - Refusals

    func testEncoderRefusesUnrepresentableInput() {
        let raw = [UInt8](repeating: 0, count: 16 * 16 * 2)
        XCTAssertNil(BC1.encode(raw[...], width: 0, height: 16))
        XCTAssertNil(BC1.encode(raw[...], width: 16, height: 0))
        XCTAssertNil(BC1.encode(raw[...], width: 4097, height: 4))
        // Raster length must match the claimed dimensions exactly.
        XCTAssertNil(BC1.encode(raw[0..<510], width: 16, height: 16))
        XCTAssertNil(BC1.encode(raw[...], width: 8, height: 8))
    }

    func testDecoderRefusesWrongSizedInput() {
        // BC1 is fixed-rate, so the whole input-length question is one exact
        // equality - pinned one byte short AND one byte long, both sides of
        // the boundary, mirroring the firmware's exact-size heap tests.
        XCTAssertNil(BC1.decode([UInt8](repeating: 0, count: 127),
                                width: 16, height: 16))
        XCTAssertNil(BC1.decode([UInt8](repeating: 0, count: 129),
                                width: 16, height: 16))
        XCTAssertNil(BC1.decode([], width: 16, height: 16))
        XCTAssertNil(BC1.decode([UInt8](repeating: 0, count: 7),
                                width: 2, height: 2))
        XCTAssertNil(BC1.decode([UInt8](repeating: 0, count: 9),
                                width: 2, height: 2))
        XCTAssertNil(BC1.decode([UInt8](repeating: 0, count: 8),
                                width: 0, height: 4))
        XCTAssertNil(BC1.decode([UInt8](repeating: 0, count: 32),
                                width: 4097, height: 4))
        // Exact size succeeds - the positive control.
        XCTAssertNotNil(BC1.decode([UInt8](repeating: 0, count: 128),
                                   width: 16, height: 16))
        XCTAssertNotNil(BC1.decode([UInt8](repeating: 0, count: 8),
                                   width: 2, height: 2))
    }

    // MARK: - Constants

    func testWireConstantsMatchTheFirmware() {
        XCTAssertEqual(BC1.blockDim, 4)
        XCTAssertEqual(BC1.blockBytes, 8)
        XCTAssertEqual(BC1.maxDim, 4096)
    }
}
