import CoreGraphics
import CoreVideo
import Foundation

/// Converts captured BGRA8888 pixel buffers to big-endian RGB565 (the ST7789
/// panel byte order, so the ESP32 can bulk-DMA the payload untouched).
enum PixelConvert {
    /// Default panel dimensions (172x320 T-Display S3). Sessions driving
    /// panels of different resolutions pass explicit width/height to the
    /// conversion functions below; these statics are the fallback.
    static let width = 172
    static let height = 320

    /// Convert a BGRA CVPixelBuffer into RGB565BE. `width`/`height` are the
    /// expected capture dimensions (172x320 portrait or 320x172 landscape);
    /// the byte count is identical either way. Rows are read via bytesPerRow
    /// so padded buffers are handled.
    static func bgraToRGB565BE(
        _ pixelBuffer: CVPixelBuffer, width: Int, height: Int, into out: inout [UInt8]
    ) -> Bool {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return false
        }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w >= width, h >= height else { return false }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)

        out.withUnsafeMutableBytes { rawOut in
            let dst = rawOut.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var di = 0
            for row in 0..<height {
                let src = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
                var si = 0
                for _ in 0..<width {
                    let b = UInt16(src[si])
                    let g = UInt16(src[si + 1])
                    let r = UInt16(src[si + 2])
                    let rgb565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
                    dst[di] = UInt8(rgb565 >> 8)      // high byte first: big-endian
                    dst[di + 1] = UInt8(rgb565 & 0xFF)
                    si += 4
                    di += 2
                }
            }
        }
        return true
    }

    /// Expand a 5- or 6-bit channel to 8 bits by replicating its high bits,
    /// so full-scale input maps to full-scale output (0x1F -> 0xFF, not 0xF8).
    private static func expand5(_ v: UInt16) -> UInt8 {
        UInt8((v << 3) | (v >> 2))
    }

    private static func expand6(_ v: UInt16) -> UInt8 {
        UInt8((v << 2) | (v >> 4))
    }

    /// Build an image from the same RGB565BE bytes that go to the panel, for
    /// the app's own preview of what it is sending.
    ///
    /// CoreGraphics has no 5-6-5 pixel format, so the channels are expanded to
    /// 8 bits here rather than handed over as-is. At panel size (172x320, 55k
    /// pixels) that is ~220 KB per image, which is why the caller throttles
    /// this well below the capture rate.
    static func imageFromRGB565BE(
        _ pixels: [UInt8], width: Int, height: Int
    ) -> CGImage? {
        guard width > 0, height > 0, pixels.count >= width * height * 2 else {
            return nil
        }
        var rgba = [UInt8](repeating: 0xFF, count: width * height * 4)
        pixels.withUnsafeBufferPointer { src in
            rgba.withUnsafeMutableBufferPointer { dst in
                var si = 0
                var di = 0
                for _ in 0..<(width * height) {
                    let value = (UInt16(src[si]) << 8) | UInt16(src[si + 1])
                    dst[di] = expand5((value >> 11) & 0x1F)
                    dst[di + 1] = expand6((value >> 5) & 0x3F)
                    dst[di + 2] = expand5(value & 0x1F)
                    dst[di + 3] = 0xFF
                    si += 2
                    di += 4
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent)
    }
}
