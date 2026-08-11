import Foundation
import SenderProtocol

/// Animated RGB565BE test pattern: scrolling hue gradient with a moving
/// white bar, so dropped/duplicated frames are visible on the panel.
/// In landscape the frame's axes swap and the bar moves along the short one.
enum TestPattern {
    /// Render one animation frame for `tick` into `out` (RGB565BE,
    /// preallocated to `geometry.frameBytes`). Orientation picks the portrait or
    /// landscape layout of whatever panel this is.
    ///
    /// `geometry` defaults to the original panel, so a caller that has no better
    /// answer gets the historical 172x320 pattern. Callers that do - test mode
    /// takes it from the sender - must pass it, because `out` is sized from the
    /// same geometry and the two disagreeing would write past the end.
    static func frame(
        tick: Int, landscape: Bool = false,
        geometry: PanelGeometry = .panel172x320,
        into out: inout [UInt8]
    ) {
        let w = geometry.frameWidth(landscape: landscape)
        let h = geometry.frameHeight(landscape: landscape)
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
