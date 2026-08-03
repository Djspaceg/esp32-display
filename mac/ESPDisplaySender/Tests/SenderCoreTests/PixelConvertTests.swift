import CoreVideo
import XCTest

@testable import SenderCore

/// BGRA8888 -> RGB565 big-endian is the one conversion that decides whether
/// every pixel the panel shows is correct, and it was previously verified only
/// by looking at the screen. These are byte-exact vectors.
final class PixelConvertTests: XCTestCase {

    // MARK: helpers

    /// Build a 32BGRA pixel buffer. `pixel` returns channels for (x, y) in
    /// memory order, so the closure states B, G, R explicitly and a mistake in
    /// channel order in the conversion cannot be mirrored by a mistake here.
    private func makeBuffer(
        width: Int, height: Int,
        pixel: (Int, Int) -> (b: UInt8, g: UInt8, r: UInt8)
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let unwrapped = try XCTUnwrap(buffer, "CVPixelBufferCreate failed (\(status))")
        XCTAssertEqual(status, kCVReturnSuccess)

        CVPixelBufferLockBaseAddress(unwrapped, [])
        defer { CVPixelBufferUnlockBaseAddress(unwrapped, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(unwrapped))
        let stride = CVPixelBufferGetBytesPerRow(unwrapped)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let channels = pixel(x, y)
                row[x * 4 + 0] = channels.b
                row[x * 4 + 1] = channels.g
                row[x * 4 + 2] = channels.r
                row[x * 4 + 3] = 255
            }
        }
        return unwrapped
    }

    /// Convert and return the output buffer, failing the test if the
    /// conversion refused the input.
    private func convert(
        _ buffer: CVPixelBuffer, width: Int, height: Int
    ) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 2)
        let ok = PixelConvert.bgraToRGB565BE(
            buffer, width: width, height: height, into: &out)
        XCTAssertTrue(ok, "conversion rejected a valid BGRA buffer")
        return out
    }

    /// The 16-bit value the panel receives for a pixel, reassembled from the
    /// two output bytes in the order they were written.
    private func word(_ out: [UInt8], x: Int, y: Int, width: Int) -> UInt16 {
        let index = (y * width + x) * 2
        return (UInt16(out[index]) << 8) | UInt16(out[index + 1])
    }

    // MARK: colour vectors

    func testPrimaryColoursMatchRGB565Vectors() throws {
        // Each expected value is the RGB565 bit layout rrrrrggggggbbbbb.
        let cases: [(name: String, b: UInt8, g: UInt8, r: UInt8, expected: UInt16)] = [
            ("black", 0, 0, 0, 0x0000),
            ("white", 255, 255, 255, 0xFFFF),
            ("red", 0, 0, 255, 0xF800),
            ("green", 0, 255, 0, 0x07E0),
            ("blue", 255, 0, 0, 0x001F),
        ]
        for testCase in cases {
            let buffer = try makeBuffer(width: 2, height: 2) { _, _ in
                (b: testCase.b, g: testCase.g, r: testCase.r)
            }
            let out = try convert(buffer, width: 2, height: 2)
            for y in 0..<2 {
                for x in 0..<2 {
                    XCTAssertEqual(
                        word(out, x: x, y: y, width: 2), testCase.expected,
                        "\(testCase.name) at (\(x),\(y))")
                }
            }
        }
    }

    /// A pixel whose three channels are all different catches a swapped
    /// channel order, which the symmetric primaries above cannot.
    func testChannelOrderIsBlueGreenRedInMemory() throws {
        // B=0x10 -> 2, G=0x20 -> 8, R=0x30 -> 6
        // (6 << 11) | (8 << 5) | 2 == 0x3102
        let buffer = try makeBuffer(width: 1, height: 1) { _, _ in
            (b: 0x10, g: 0x20, r: 0x30)
        }
        let out = try convert(buffer, width: 1, height: 1)
        XCTAssertEqual(out, [0x31, 0x02])
    }

    func testHighByteIsWrittenFirst() throws {
        // 0xF800 is pure red: big-endian must put 0xF8 at the lower index.
        let buffer = try makeBuffer(width: 1, height: 1) { _, _ in
            (b: 0, g: 0, r: 255)
        }
        let out = try convert(buffer, width: 1, height: 1)
        XCTAssertEqual(out[0], 0xF8, "high byte must come first")
        XCTAssertEqual(out[1], 0x00)
    }

    /// RGB565 discards low bits rather than rounding, so values inside the
    /// same bucket must produce identical output. Rounding would brighten
    /// near-white content and shift the whole gradient.
    func testLowBitsAreTruncatedNotRounded() throws {
        let bucket = try makeBuffer(width: 2, height: 1) { x, _ in
            x == 0 ? (b: 0xFF, g: 0xFF, r: 0xFF) : (b: 0xF8, g: 0xFC, r: 0xF8)
        }
        let out = try convert(bucket, width: 2, height: 1)
        XCTAssertEqual(word(out, x: 0, y: 0, width: 2), 0xFFFF)
        XCTAssertEqual(
            word(out, x: 1, y: 0, width: 2), 0xFFFF,
            "0xF8/0xFC share a bucket with 0xFF under truncation")

        // One step below the bucket boundary must drop to the next value down.
        let below = try makeBuffer(width: 1, height: 1) { _, _ in
            (b: 0xF7, g: 0xFB, r: 0xF7)
        }
        let belowOut = try convert(below, width: 1, height: 1)
        XCTAssertEqual(word(belowOut, x: 0, y: 0, width: 1), 0xF7DE)
    }

    // MARK: geometry

    /// Rows must advance by the buffer's bytesPerRow, not width * 4.
    /// CoreVideo pads rows, so a buffer wider than the requested region proves
    /// the stride is honoured: with width * 4 the second row would read from
    /// the middle of the first.
    func testPaddedRowsAreReadByStride() throws {
        let bufferWidth = 8
        let requestedWidth = 4
        let height = 3
        let buffer = try makeBuffer(width: bufferWidth, height: height) { x, y in
            // Encode the row in green and the column in red so a stride
            // mistake shows up as the wrong row, not just wrong pixels.
            (b: 0, g: UInt8((y + 1) << 2), r: UInt8((x + 1) << 3))
        }
        XCTAssertGreaterThan(
            CVPixelBufferGetBytesPerRow(buffer), requestedWidth * 4,
            "test needs a buffer whose stride exceeds the requested row width")

        let out = try convert(buffer, width: requestedWidth, height: height)
        for y in 0..<height {
            for x in 0..<requestedWidth {
                let expected =
                    (UInt16(UInt8((x + 1) << 3) >> 3) << 11)
                    | (UInt16(UInt8((y + 1) << 2) >> 2) << 5)
                XCTAssertEqual(
                    word(out, x: x, y: y, width: requestedWidth), expected,
                    "padded read at (\(x),\(y))")
            }
        }
    }

    /// Only the requested region is consumed; pixels beyond it are ignored
    /// rather than bleeding into the next output row.
    func testRegionNarrowerThanBufferIgnoresTrailingPixels() throws {
        let buffer = try makeBuffer(width: 4, height: 1) { x, _ in
            x < 2 ? (b: 0, g: 0, r: 255) : (b: 255, g: 0, r: 0)
        }
        let out = try convert(buffer, width: 2, height: 1)
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(word(out, x: 0, y: 0, width: 2), 0xF800)
        XCTAssertEqual(word(out, x: 1, y: 0, width: 2), 0xF800)
    }

    func testFullPanelFrameFillsExactByteCount() throws {
        let width = PixelConvert.width
        let height = PixelConvert.height
        let buffer = try makeBuffer(width: width, height: height) { x, _ in
            x == 0 ? (b: 0, g: 0, r: 255) : (b: 0, g: 255, r: 0)
        }
        let out = try convert(buffer, width: width, height: height)
        XCTAssertEqual(out.count, 110_080, "172 x 320 x 2 bytes")
        XCTAssertEqual(word(out, x: 0, y: 0, width: width), 0xF800)
        XCTAssertEqual(word(out, x: 1, y: 0, width: width), 0x07E0)
        XCTAssertEqual(word(out, x: 0, y: height - 1, width: width), 0xF800)
        XCTAssertEqual(word(out, x: width - 1, y: height - 1, width: width), 0x07E0)
    }

    /// Landscape uses the same byte count with the axes swapped.
    func testLandscapeGeometryConvertsSameByteCount() throws {
        let buffer = try makeBuffer(width: 320, height: 172) { _, _ in
            (b: 255, g: 255, r: 255)
        }
        let out = try convert(buffer, width: 320, height: 172)
        XCTAssertEqual(out.count, 110_080)
        XCTAssertEqual(word(out, x: 319, y: 171, width: 320), 0xFFFF)
    }

    // MARK: rejection

    func testRejectsNonBGRAPixelFormat() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault, 8, 8,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer),
            kCVReturnSuccess)
        let unwrapped = try XCTUnwrap(buffer)
        var out = [UInt8](repeating: 0, count: 8 * 8 * 2)
        XCTAssertFalse(
            PixelConvert.bgraToRGB565BE(unwrapped, width: 8, height: 8, into: &out),
            "a non-BGRA buffer must be refused, not reinterpreted")
    }

    func testRejectsBufferSmallerThanRequestedRegion() throws {
        let buffer = try makeBuffer(width: 4, height: 4) { _, _ in (b: 0, g: 0, r: 0) }
        var out = [UInt8](repeating: 0, count: 8 * 8 * 2)
        XCTAssertFalse(
            PixelConvert.bgraToRGB565BE(buffer, width: 8, height: 4, into: &out),
            "too narrow")
        XCTAssertFalse(
            PixelConvert.bgraToRGB565BE(buffer, width: 4, height: 8, into: &out),
            "too short")
    }

    func testOutputIsUntouchedWhenConversionIsRefused() throws {
        let buffer = try makeBuffer(width: 2, height: 2) { _, _ in (b: 9, g: 9, r: 9) }
        var out = [UInt8](repeating: 0xAB, count: 4 * 4 * 2)
        XCTAssertFalse(
            PixelConvert.bgraToRGB565BE(buffer, width: 4, height: 4, into: &out))
        XCTAssertTrue(
            out.allSatisfy { $0 == 0xAB },
            "a refused conversion must not partially overwrite the frame")
    }
}
