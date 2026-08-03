import CoreVideo
import Foundation

/// Converts captured BGRA8888 pixel buffers to big-endian RGB565 (the ST7789
/// panel byte order, so the ESP32 can bulk-DMA the payload untouched).
enum PixelConvert {
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
}
