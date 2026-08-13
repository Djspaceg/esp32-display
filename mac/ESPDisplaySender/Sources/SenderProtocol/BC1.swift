import Foundation

/// BC1 (DXT1) block codec for tile-stream run payloads: fixed 4:1 lossy
/// compression of RGB565 rasters. Mirrors the firmware's `bc1`
/// (firmware/display_stream/bc1.h); both suites assert the wire
/// independently, never through a shared fixture, so a change that breaks
/// interoperability fails a test.
///
/// Encoded stream: ceil(w/4) x ceil(h/4) blocks, row-major, 8 bytes each:
///   [c0 u16 LE][c1 u16 LE][indices u32 LE]
/// c0 and c1 are RGB565 endpoint colors. The index word carries 2 bits per
/// pixel, row-major within the block, consumed from the least significant
/// bits up. Each index picks from a 4-color palette: {c0, c1, (2*c0+c1)/3,
/// (c0+2*c1)/3}, the interpolants computed per RGB565 channel in integer
/// math - see `palette`.
///
/// Deliberately NOT general DXT1: the 3-color+transparent mode (selected
/// there by c0 <= c1) does not exist here. The encoder's bounding-box
/// endpoints give c0 >= c1 by construction, and the decoder applies the
/// 4-color palette unconditionally, so every block decodes to something
/// well-defined.
///
/// Rasters are in the wire's pixel order - big-endian RGB565, hi byte first.
/// Edge rasters (2 px tiles on the 466x466 grid) still occupy whole blocks:
/// the encoder pads by replicating the last row/column, the decoder consumes
/// the padding's indices but clips the writes to the true w x h rect.
public enum BC1 {
    /// Blocks are 4x4 pixels.
    public static let blockDim = 4
    /// Two RGB565 endpoints (u16 LE each) then 16 x 2-bit indices (u32 LE).
    public static let blockBytes = 8
    /// Sanity ceiling on either raster dimension, mirroring the firmware.
    public static let maxDim = 4096

    /// Exact encoded size of a w x h raster: ceil(w/4) x ceil(h/4) blocks of
    /// `blockBytes`. Zero when a dimension is zero or beyond `maxDim` -
    /// callers treat zero as refusal. BC1 is fixed-rate, so unlike
    /// `RLE565.maxEncodedBytes` this is the size, not a ceiling.
    public static func encodedBytes(width: Int, height: Int) -> Int {
        guard width > 0, height > 0, width <= maxDim, height <= maxDim else {
            return 0
        }
        let bw = (width + blockDim - 1) / blockDim
        let bh = (height + blockDim - 1) / blockDim
        return bw * bh * blockBytes
    }

    /// The 4-color palette for a block: the two endpoints then the 1/3 and
    /// 2/3 interpolants, computed per RGB565 channel without unpacking to
    /// 888 - integer division truncates, exactly as the panel's decoder
    /// does. Both `encode`'s index selection and `decode` use this, so the
    /// encoder optimizes against the palette the panel will actually apply.
    public static func palette(_ c0: UInt16, _ c1: UInt16) -> [UInt16] {
        let r0 = Int(c0 >> 11), g0 = Int((c0 >> 5) & 0x3F), b0 = Int(c0 & 0x1F)
        let r1 = Int(c1 >> 11), g1 = Int((c1 >> 5) & 0x3F), b1 = Int(c1 & 0x1F)
        let p2 = UInt16(((2 * r0 + r1) / 3) << 11
            | (((2 * g0 + g1) / 3) & 0x3F) << 5
            | ((2 * b0 + b1) / 3) & 0x1F)
        let p3 = UInt16(((r0 + 2 * r1) / 3) << 11
            | (((g0 + 2 * g1) / 3) & 0x3F) << 5
            | ((b0 + 2 * b1) / 3) & 0x1F)
        return [c0, c1, p2, p3]
    }

    /// Squared distance between two RGB565 colors in 888 space (channels
    /// expanded by bit replication, so green's extra bit does not double its
    /// weight relative to a straight 5/6/5 comparison).
    private static func distance2(_ a: UInt16, _ b: UInt16) -> Int {
        func expand(_ c: UInt16) -> (Int, Int, Int) {
            let r = Int(c >> 11), g = Int((c >> 5) & 0x3F), b = Int(c & 0x1F)
            return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))
        }
        let (ar, ag, ab) = expand(a)
        let (br, bg, bb) = expand(b)
        return (ar - br) * (ar - br) + (ag - bg) * (ag - bg)
            + (ab - bb) * (ab - bb)
    }

    /// Encode a w x h big-endian RGB565 raster. Returns nil when the
    /// dimensions are invalid or the raster is not exactly w*h*2 bytes.
    /// The output is always exactly `encodedBytes(width:height:)` long.
    ///
    /// Endpoints are the block's per-channel bounding box: c0 packs the
    /// channel maxima, c1 the minima, which makes c0 >= c1 numerically by
    /// construction, reproduces flat blocks exactly, and reproduces two-tone
    /// blocks exactly when the two colors are channel-wise ordered. Each
    /// pixel takes the palette index nearest in 888 space, first index
    /// winning ties. Pixels past the raster's edge replicate the last
    /// row/column so padding never drags the bounding box outward.
    public static func encode(
        _ raw: ArraySlice<UInt8>, width: Int, height: Int
    ) -> [UInt8]? {
        let need = encodedBytes(width: width, height: height)
        guard need > 0, raw.count == width * height * 2 else { return nil }
        let src = Array(raw)
        let bw = (width + blockDim - 1) / blockDim
        let bh = (height + blockDim - 1) / blockDim
        var out = [UInt8]()
        out.reserveCapacity(need)
        for by in 0..<bh {
            for bx in 0..<bw {
                // Gather the block, replicating the edge row/column.
                var px = [UInt16](repeating: 0, count: 16)
                for py in 0..<4 {
                    let sy = min(by * 4 + py, height - 1)
                    for pxi in 0..<4 {
                        let sx = min(bx * 4 + pxi, width - 1)
                        let at = (sy * width + sx) * 2
                        px[py * 4 + pxi] =
                            (UInt16(src[at]) << 8) | UInt16(src[at + 1])
                    }
                }
                // Bounding-box endpoints per channel.
                var rMin = 0x1F, rMax = 0, gMin = 0x3F, gMax = 0
                var bMin = 0x1F, bMax = 0
                for p in px {
                    let r = Int(p >> 11), g = Int((p >> 5) & 0x3F)
                    let b = Int(p & 0x1F)
                    rMin = min(rMin, r); rMax = max(rMax, r)
                    gMin = min(gMin, g); gMax = max(gMax, g)
                    bMin = min(bMin, b); bMax = max(bMax, b)
                }
                let c0 = UInt16((rMax << 11) | (gMax << 5) | bMax)
                let c1 = UInt16((rMin << 11) | (gMin << 5) | bMin)
                let pal = palette(c0, c1)
                var idx: UInt32 = 0
                for i in 0..<16 {
                    var best = distance2(px[i], pal[0])
                    var sel: UInt32 = 0
                    for p in 1..<4 {
                        let d = distance2(px[i], pal[p])
                        if d < best {  // strict: first index wins ties
                            best = d
                            sel = UInt32(p)
                        }
                    }
                    idx |= sel << (i * 2)
                }
                out.append(UInt8(c0 & 0xFF))
                out.append(UInt8(c0 >> 8))
                out.append(UInt8(c1 & 0xFF))
                out.append(UInt8(c1 >> 8))
                out.append(UInt8(idx & 0xFF))
                out.append(UInt8((idx >> 8) & 0xFF))
                out.append(UInt8((idx >> 16) & 0xFF))
                out.append(UInt8((idx >> 24) & 0xFF))
            }
        }
        return out
    }

    /// Decode into exactly a w x h big-endian RGB565 raster, or nil.
    ///
    /// Nil unless `encoded.count` is PRECISELY `encodedBytes(width:height:)`
    /// - short and long inputs are both refused, not clamped, mirroring the
    /// firmware decoder's posture on the receive path. Edge blocks consume
    /// their full 16 indices but write only the pixels inside the raster.
    public static func decode(
        _ encoded: [UInt8], width: Int, height: Int
    ) -> [UInt8]? {
        let need = encodedBytes(width: width, height: height)
        guard need > 0, encoded.count == need else { return nil }
        var out = [UInt8](repeating: 0, count: width * height * 2)
        let bw = (width + blockDim - 1) / blockDim
        let bh = (height + blockDim - 1) / blockDim
        for by in 0..<bh {
            for bx in 0..<bw {
                let b = (by * bw + bx) * blockBytes
                let c0 = UInt16(encoded[b]) | (UInt16(encoded[b + 1]) << 8)
                let c1 = UInt16(encoded[b + 2]) | (UInt16(encoded[b + 3]) << 8)
                let pal = palette(c0, c1)
                var idx = UInt32(encoded[b + 4])
                    | (UInt32(encoded[b + 5]) << 8)
                    | (UInt32(encoded[b + 6]) << 16)
                    | (UInt32(encoded[b + 7]) << 24)
                let x0 = bx * 4, y0 = by * 4
                for py in 0..<4 {
                    for pxi in 0..<4 {
                        let c = pal[Int(idx & 3)]
                        idx >>= 2
                        if x0 + pxi < width, y0 + py < height {
                            let at = ((y0 + py) * width + (x0 + pxi)) * 2
                            out[at] = UInt8(c >> 8)  // wire: big-endian
                            out[at + 1] = UInt8(c & 0xFF)
                        }
                    }
                }
            }
        }
        return out
    }
}
