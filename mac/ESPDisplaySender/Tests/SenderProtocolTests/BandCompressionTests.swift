import XCTest
@testable import SenderProtocol

/// Byte-exact tests for the RLE band codec and the packed-packet builder.
///
/// Every wire vector here is written out by hand from the format comments in
/// BandCompression.swift, independently of the firmware suite's vectors
/// (firmware/test/test_band_protocol.cpp asserts the same wire from the other
/// side) - deliberately never a shared fixture, so a codec change that breaks
/// interoperability fails a test on at least one side instead of silently
/// updating both.
final class BandCompressionTests: XCTestCase {
    // MARK: - RLE565 codec

    func testRepeatRunEncodesToThreeBytes() {
        // 4x the pixel 0x2104 big-endian. control = 0x80 + (4 - 2) = 0x82.
        let raw: [UInt8] = [0x21, 0x04, 0x21, 0x04, 0x21, 0x04, 0x21, 0x04]
        let encoded = RLE565.encode(raw[...])
        XCTAssertEqual(encoded, [0x82, 0x21, 0x04])
        XCTAssertEqual(RLE565.decode(encoded!, expectedBytes: 8), raw)
    }

    func testLiteralRunEncodesVerbatim() {
        // Three distinct pixels. control = count - 1 = 0x02.
        let raw: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        let encoded = RLE565.encode(raw[...])
        XCTAssertEqual(encoded, [0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        XCTAssertEqual(RLE565.decode(encoded!, expectedBytes: 6), raw)
    }

    func testMixedLiteralsAndRuns() {
        // literal [1122 3344], run 3x[5566], literal [7788].
        let raw: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x55, 0x66,
                            0x55, 0x66, 0x77, 0x88]
        let expected: [UInt8] = [0x01, 0x11, 0x22, 0x33, 0x44,
                                 0x81, 0x55, 0x66,
                                 0x00, 0x77, 0x88]
        let encoded = RLE565.encode(raw[...])
        XCTAssertEqual(encoded, expected)
        XCTAssertEqual(RLE565.decode(expected, expectedBytes: 12), raw)
    }

    func testRunAndLiteralLengthLimits() {
        // 129 identical pixels are one chunk (control 0xFF); 130 need two.
        let pixel: [UInt8] = [0x12, 0x34]
        var raw = [UInt8]()
        for _ in 0..<129 { raw.append(contentsOf: pixel) }
        XCTAssertEqual(RLE565.encode(raw[...]), [0xFF, 0x12, 0x34])
        raw.append(contentsOf: pixel)
        let two = RLE565.encode(raw[...])
        XCTAssertEqual(two, [0xFF, 0x12, 0x34, 0x00, 0x12, 0x34])
        XCTAssertEqual(RLE565.decode(two!, expectedBytes: 260), raw)

        // 128 distinct pixels are one literal (control 0x7F); 129 need two.
        var distinct = [UInt8]()
        for i in 0..<129 {
            distinct.append(UInt8(i >> 8))
            distinct.append(UInt8(truncatingIfNeeded: 3 + i * 2))
        }
        let literal = RLE565.encode(distinct[0..<256])
        XCTAssertEqual(literal?.count, 257)
        XCTAssertEqual(literal?.first, 0x7F)
        let split = RLE565.encode(distinct[...])
        XCTAssertEqual(split?.count, 260)  // 1+256 then 1+2
        XCTAssertEqual(split?[257], 0x00)
        XCTAssertEqual(RLE565.decode(split!, expectedBytes: 258), distinct)
    }

    func testWorstCaseStaysWithinBound() {
        // No two adjacent pixels equal: all-literal, one control byte per
        // 128 pixels. 466 pixels is the S3's row.
        for pixels in [172, 466, 697] {
            var raw = [UInt8]()
            for i in 0..<pixels {
                raw.append(UInt8(i >> 8))
                raw.append(UInt8(i & 0xFF))
            }
            let encoded = RLE565.encode(raw[...])!
            XCTAssertLessThanOrEqual(
                encoded.count, RLE565.maxEncodedBytes(rawBytes: raw.count))
            XCTAssertEqual(encoded.count, raw.count + (pixels + 127) / 128)
            XCTAssertEqual(RLE565.decode(encoded, expectedBytes: raw.count), raw)
        }
    }

    func testFlatBandCollapses() {
        // A uniform 466px row (letterbox bar) is ceil(466/129) = 4 runs.
        let raw = [UInt8](repeating: 0x00, count: 466 * 2)
        XCTAssertEqual(RLE565.encode(raw[...])?.count, 12)
    }

    func testRandomRoundTrips() {
        var seed: UInt32 = 0x0BADCAFE
        func next() -> UInt32 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return seed
        }
        for _ in 0..<50 {
            let pixels = 1 + Int(next() % 700)
            var raw = [UInt8]()
            for _ in 0..<pixels {
                let px = UInt16((next() >> 16) % 5) &* 0x1111  // small palette
                raw.append(UInt8(px >> 8))
                raw.append(UInt8(px & 0xFF))
            }
            let encoded = RLE565.encode(raw[...])
            XCTAssertNotNil(encoded)
            XCTAssertLessThanOrEqual(
                encoded!.count, RLE565.maxEncodedBytes(rawBytes: raw.count))
            XCTAssertEqual(RLE565.decode(encoded!, expectedBytes: raw.count), raw)
        }
    }

    func testEncoderRefusesUnrepresentableInput() {
        XCTAssertNil(RLE565.encode([][...]))
        XCTAssertNil(RLE565.encode([0x11, 0x22, 0x33][...]))  // odd length
    }

    func testDecoderRefusesMalformedInput() {
        // Truncated literal: control claims 2 pixels, one follows.
        XCTAssertNil(RLE565.decode([0x01, 0x11, 0x22], expectedBytes: 8))
        // Its exact-fill sibling: all 4 payload bytes present succeeds. This
        // pins the truncation guard to "fewer bytes than the chunk claims",
        // not to some looser multiple of it.
        XCTAssertEqual(
            RLE565.decode([0x01, 0x11, 0x22, 0x33, 0x44], expectedBytes: 4),
            [0x11, 0x22, 0x33, 0x44])
        // Truncated repeat: control with no pixel / half a pixel.
        XCTAssertNil(RLE565.decode([0x82], expectedBytes: 8))
        XCTAssertNil(RLE565.decode([0x82, 0x11], expectedBytes: 8))

        // Overrun, pinned at the exact boundary rather than some looser gap:
        // this chunk is a run of 4 pixels (8 bytes), full stop. A canary
        // window wider than the true boundary - e.g. testing only against a
        // dstLen two bytes short - would still pass if the guard's `<=` were
        // mutated to allow a one-byte overrun; testing exactly one byte
        // short does not.
        let runOverrun: [UInt8] = [0x82, 0x11, 0x22]
        XCTAssertNil(RLE565.decode(runOverrun, expectedBytes: 7))  // 1 byte short of fitting
        XCTAssertEqual(
            RLE565.decode(runOverrun, expectedBytes: 8),  // exact fit succeeds
            [0x11, 0x22, 0x11, 0x22, 0x11, 0x22, 0x11, 0x22])

        // Same boundary pin for a literal chunk: 4 pixels, 8 bytes exactly.
        let literalOverrun: [UInt8] = [0x03, 1, 2, 3, 4, 5, 6, 7, 8]
        XCTAssertNil(RLE565.decode(literalOverrun, expectedBytes: 7))
        XCTAssertEqual(
            RLE565.decode(literalOverrun, expectedBytes: 8),
            [1, 2, 3, 4, 5, 6, 7, 8])

        // Short: decodes cleanly but to fewer bytes than the band needs.
        XCTAssertNil(RLE565.decode([0x81, 0x11, 0x22], expectedBytes: 8))
        XCTAssertNil(RLE565.decode([0x81, 0x11, 0x22], expectedBytes: 7))
        // Empty input never fills a band, except the degenerate zero-size one.
        XCTAssertNil(RLE565.decode([], expectedBytes: 8))
        XCTAssertEqual(RLE565.decode([], expectedBytes: 0), [])
        // And the exact-fill sibling of the "short" case succeeds.
        XCTAssertEqual(RLE565.decode([0x81, 0x11, 0x22], expectedBytes: 6),
                       [0x11, 0x22, 0x11, 0x22, 0x11, 0x22])
    }

    // MARK: - BandPacker

    /// A synthetic 4x8 geometry: 2 rows per band (8-byte bands would need a
    /// tiny budget), here rowBytes = 8, rowsPerBand = 174 -> one band. Too
    /// coarse; use the real geometries instead.
    private let g466 = PanelGeometry(width: 466, height: 466)

    func testPackedPacketWireLayout() {
        // Two dirty bands of a 466x466 frame, both flat so they compress to a
        // known 12-byte RLE payload each. Assert the whole datagram byte for
        // byte: header [frame 7][band 5 | 0x8000][dirty 2], then two records.
        var pixels = [UInt8](repeating: 0x00, count: g466.frameBytes)
        // Band 9 gets a different flat color so the two payloads differ.
        let off9 = g466.bandOffset(index: 9, landscape: false)
        for i in stride(from: off9, to: off9 + 932, by: 2) {
            pixels[i] = 0x21
            pixels[i + 1] = 0x04
        }
        let packets = BandPacker.packets(
            frameId: 7, dirty: [5, 9], pixels: pixels,
            geometry: g466, landscape: false)
        XCTAssertEqual(packets.count, 1)
        var expected: [UInt8] = [
            0x07, 0x00,             // frame_id 7
            0x05, 0x80,             // first band 5 | packed flag
            0x02, 0x00,             // dirty_count 2, portrait
            0x05, 0x00, 0x0C, 0x80, // record: band 5, len 12, compressed
        ]
        // Band 5: 466 black pixels = runs of 129,129,129,79.
        expected += [0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00,
                     0xCD, 0x00, 0x00]
        expected += [0x09, 0x00, 0x0C, 0x80]  // record: band 9, len 12, compressed
        expected += [0xFF, 0x21, 0x04, 0xFF, 0x21, 0x04, 0xFF, 0x21, 0x04,
                     0xCD, 0x21, 0x04]
        XCTAssertEqual([UInt8](packets[0]), expected)
    }

    func testIncompressibleBandGoesRaw() {
        // A noise band (no two adjacent pixels equal) must be sent raw with
        // the compressed flag clear, costing its raw size plus the record
        // header - the worst case is bounded, not amplified.
        var pixels = [UInt8](repeating: 0x00, count: g466.frameBytes)
        let off = g466.bandOffset(index: 3, landscape: false)
        for i in 0..<466 {
            pixels[off + i * 2] = UInt8(i >> 8)
            pixels[off + i * 2 + 1] = UInt8(i & 0xFF)
        }
        let packets = BandPacker.packets(
            frameId: 1, dirty: [3], pixels: pixels,
            geometry: g466, landscape: false)
        XCTAssertEqual(packets.count, 1)
        let bytes = [UInt8](packets[0])
        XCTAssertEqual(bytes.count, 6 + 4 + 932)
        XCTAssertEqual(bytes[2], 0x03)  // first band 3
        XCTAssertEqual(bytes[3], 0x80)  // packed flag
        XCTAssertEqual(bytes[6], 0x03)  // record band 3
        XCTAssertEqual(bytes[7], 0x00)
        XCTAssertEqual(bytes[8], 0xA4)  // len 932 = 0x03A4, flag clear
        XCTAssertEqual(bytes[9], 0x03)
        XCTAssertEqual(Array(bytes[10..<14]), Array(pixels[off..<(off + 4)]))
    }

    func testPacketsRespectTheBudget() {
        // A full keyframe of moderately compressible content: every packet
        // stays within the packed budget and every band appears exactly once,
        // in order, across the sequence.
        var pixels = [UInt8](repeating: 0x00, count: g466.frameBytes)
        var seed: UInt32 = 42
        var px: UInt16 = 0
        for i in stride(from: 0, to: pixels.count, by: 2) {
            // Flat 16-pixel blocks in a random palette: desktop-like content
            // (regions of solid color) rather than noise, so packing has
            // something to pack.
            if (i / 2) % 16 == 0 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                px = UInt16((seed >> 16) % 7) &* 0x0842
            }
            pixels[i] = UInt8(px >> 8)
            pixels[i + 1] = UInt8(px & 0xFF)
        }
        let dirty = Array(0..<g466.bandCount(landscape: false))
        let packets = BandPacker.packets(
            frameId: 2, dirty: dirty, pixels: pixels,
            geometry: g466, landscape: false)
        XCTAssertGreaterThan(packets.count, 0)
        XCTAssertLessThan(packets.count, dirty.count)  // packing must help
        var bandsSeen = [Int]()
        for packet in packets {
            XCTAssertLessThanOrEqual(packet.count, BandPacker.maxPacketBytes)
            let bytes = [UInt8](packet)
            XCTAssertEqual(bytes[3] & 0x80, 0x80)
            // Walk the records, decode each, and compare against the frame.
            var at = 6
            var firstBand: Int?
            while at < bytes.count {
                let band = Int(bytes[at]) | (Int(bytes[at + 1]) << 8)
                let lenField = Int(bytes[at + 2]) | (Int(bytes[at + 3]) << 8)
                let compressed = lenField & 0x8000 != 0
                let len = lenField & 0x7FFF
                at += 4
                if firstBand == nil {
                    firstBand = band
                    // Header cross-check: first_band matches record one.
                    XCTAssertEqual(
                        Int(bytes[2]) | (Int(bytes[3] & 0x7F) << 8), band)
                }
                let payload = Array(bytes[at..<(at + len)])
                at += len
                let rawLen = g466.bandPayloadBytes(index: band, landscape: false)
                let raw = compressed
                    ? RLE565.decode(payload, expectedBytes: rawLen)
                    : payload
                let off = g466.bandOffset(index: band, landscape: false)
                XCTAssertEqual(raw, Array(pixels[off..<(off + rawLen)]))
                bandsSeen.append(band)
            }
            XCTAssertEqual(at, bytes.count)
        }
        XCTAssertEqual(bandsSeen, dirty)
    }

    func testScatteredBandsShareAPacket() {
        // Non-consecutive dirty bands - the common diff shape - pack together
        // because records carry their own indices.
        let pixels = [UInt8](repeating: 0x1F, count: g466.frameBytes)
        let packets = BandPacker.packets(
            frameId: 3, dirty: [0, 100, 465], pixels: pixels,
            geometry: g466, landscape: false)
        XCTAssertEqual(packets.count, 1)
    }

    func testWorstCaseRecordAlwaysFitsOnePacket() {
        // The largest raw band any streamable geometry can produce still fits
        // one packed datagram, so the packer can never need to split a record.
        XCTAssertLessThanOrEqual(
            PanelGeometry.headerBytes + BandPacker.recordHeaderBytes
                + (PanelGeometry.maxPacketBytes - PanelGeometry.headerBytes),
            BandPacker.maxPacketBytes)
    }

    func testWireConstantsMatchTheFirmware() {
        XCTAssertEqual(BandPacker.maxPacketBytes, 1472)
        XCTAssertEqual(BandPacker.recordHeaderBytes, 4)
        XCTAssertEqual(BandPacker.bandIndexPackedFlag, 0x8000)
        XCTAssertEqual(BandPacker.recordCompressedFlag, 0x8000)
    }
}
