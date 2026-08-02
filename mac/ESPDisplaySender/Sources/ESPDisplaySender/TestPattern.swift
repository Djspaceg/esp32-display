import Foundation

/// Animated RGB565BE test pattern: scrolling hue gradient with a moving
/// white bar, so dropped/duplicated frames are visible on the panel.
enum TestPattern {
    static func frame(tick: Int, into out: inout [UInt8]) {
        let w = PixelConvert.width
        let h = PixelConvert.height
        let barY = tick % h
        out.withUnsafeMutableBytes { raw in
            let dst = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var di = 0
            for y in 0..<h {
                let inBar = abs(y - barY) < 6
                for x in 0..<w {
                    let pixel: UInt16
                    if inBar {
                        pixel = 0xFFFF
                    } else {
                        let r = UInt16((x * 31) / (w - 1))
                        let g = UInt16(((y + tick) % h) * 63 / (h - 1))
                        let b = UInt16(31 - (x * 31) / (w - 1))
                        pixel = (r << 11) | (g << 5) | b
                    }
                    dst[di] = UInt8(pixel >> 8)
                    dst[di + 1] = UInt8(pixel & 0xFF)
                    di += 2
                }
            }
        }
    }
}
