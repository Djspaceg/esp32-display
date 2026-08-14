import Foundation

// MARK: - TileGeometry

/// The 16x16 tile grid for square AMOLED panels, mirroring the firmware's
/// `tileproto::TileGeometry` (firmware/display_stream/tile_protocol.h). Both
/// suites assert the grid and wire independently, never through a shared
/// fixture.
///
/// A 466x466 panel derives a 30x30 grid whose last column and row are 2 px
/// (466 = 29*16 + 2). The grid is orientation-independent: tile streaming
/// only ships on square glass (`Capabilities.tileStream`, advertised solely
/// by the CO5300 board), where rotation changes nothing about layout.
public struct TileGeometry: Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Tiles are 16x16 px, except the frame's last column/row.
    public static let tileDim = 16
    /// Ceiling on tiles any geometry may produce: the wire's 10-bit index.
    public static let maxTiles = 1024
    /// Longest run one record can express: 5 bits of (length - 1).
    public static let maxRunTiles = 32
    /// 6-byte packet header, same shape as the band header.
    public static let headerBytes = 6
    /// Whole-datagram budget, header included (Ethernet MTU minus IP+UDP).
    public static let maxPacketBytes = 1472
    /// Per-record header: [tile u16][len u16].
    public static let recordHeaderBytes = 4

    public var tileCols: Int { (width + Self.tileDim - 1) / Self.tileDim }
    public var tileRows: Int { (height + Self.tileDim - 1) / Self.tileDim }
    public var tileCount: Int { tileCols * tileRows }
    public var frameBytes: Int { width * height * 2 }

    public func col(_ tile: Int) -> Int { tile % tileCols }
    public func row(_ tile: Int) -> Int { tile / tileCols }

    /// Pixel width of one tile column: `tileDim` everywhere except a short
    /// last column when width does not divide evenly (466 -> 2 px).
    public func colWidth(_ c: Int) -> Int {
        min(Self.tileDim, width - c * Self.tileDim)
    }

    /// Pixel height of one tile row, same rule as `colWidth`.
    public func rowHeight(_ r: Int) -> Int {
        min(Self.tileDim, height - r * Self.tileDim)
    }

    /// Whether a record's run is expressible on this grid: a nonzero length
    /// that stays inside one tile-row.
    public func runValid(startTile: Int, runLength: Int) -> Bool {
        guard runLength >= 1, runLength <= Self.maxRunTiles else { return false }
        guard startTile >= 0, startTile < tileCount else { return false }
        return col(startTile) + runLength <= tileCols
    }

    /// Pixel width of a run: the sum of its tile column widths.
    public func runPixelWidth(startTile: Int, runLength: Int) -> Int {
        let x0 = col(startTile) * Self.tileDim
        return min((col(startTile) + runLength) * Self.tileDim, width) - x0
    }

    /// Raw (decoded) byte size of a run's raster - computable from geometry
    /// alone, which is what lets the receiver refuse any payload that does
    /// not decode to exactly this size.
    public func runRawBytes(startTile: Int, runLength: Int) -> Int {
        runPixelWidth(startTile: startTile, runLength: runLength)
            * rowHeight(row(startTile)) * 2
    }

    /// Whether the tile protocol can carry this geometry, mirroring the
    /// firmware's `valid()`: nonzero dimensions, the grid fits the 10-bit
    /// index space, a full row of tiles is one expressible run, and the
    /// widest raw run fits a record's 14-bit length field.
    public var isStreamable: Bool {
        guard width > 0, height > 0 else { return false }
        guard tileCols <= Self.maxRunTiles else { return false }
        guard tileCount <= Self.maxTiles else { return false }
        return width * Self.tileDim * 2 <= 0x3FFF
    }
}

// MARK: - TileMask

/// Which tiles of a grid can ever be seen.
///
/// On the round 466x466 AMOLED, 181 of the 900 tiles lie entirely outside the
/// glass's inscribed circle. They are invisible forever, so sending them is
/// pure waste — a fifth of the wire cost of a full frame AND a fifth of the
/// panel's paint time, which is the one lever that moves the measured ~38 fps
/// QSPI full-frame ceiling (docs/tile-stream-plan.md section 11).
///
/// A pixel counts as visible when its CENTRE lies inside the circle of radius
/// width/2 centred on the frame. A tile is skippable only when its NEAREST
/// pixel to the centre is still outside: a tile straddling the boundary has
/// visible pixels and must be sent whole.
///
/// The asymmetry in the conservatism is deliberate and load-bearing. Sending
/// a tile that turns out to be invisible costs bandwidth. SKIPPING a tile
/// that turns out to be visible leaves it permanently stale — no keyframe
/// heals it, because keyframes skip it too. So the predicate errs toward
/// sending, and the mask was verified against real glass before anything
/// relied on it (`espdisp.py tile-test --round-mask` paints the skippable
/// tiles magenta; none of it was visible, and the boundary ring reached the
/// bezel).
public struct TileMask: Hashable, Sendable {
    public let geometry: TileGeometry
    /// Whether the mask is actually masking anything.
    public let round: Bool
    /// Every tile that can contain a visible pixel, ascending — the tile set
    /// a keyframe covers.
    public let visibleTiles: [Int]
    private let visible: [Bool]

    /// The mask for a panel. `round: false` (or a non-square geometry, which
    /// no round panel can have) yields a mask that hides nothing, so callers
    /// need no special case for rectangular panels.
    public init(geometry: TileGeometry, round: Bool) {
        self.geometry = geometry
        let masking = round && geometry.width == geometry.height
            && geometry.width > 0
        self.round = masking
        guard masking else {
            self.visible = [Bool](repeating: true, count: max(geometry.tileCount, 0))
            self.visibleTiles = Array(0..<max(geometry.tileCount, 0))
            return
        }
        let cx = Double(geometry.width) / 2
        let cy = Double(geometry.height) / 2
        let r2 = cx * cx
        var flags = [Bool]()
        var tiles = [Int]()
        flags.reserveCapacity(geometry.tileCount)
        for tile in 0..<geometry.tileCount {
            let x0 = Double(geometry.col(tile) * TileGeometry.tileDim)
            let y0 = Double(geometry.row(tile) * TileGeometry.tileDim)
            let x1 = x0 + Double(geometry.colWidth(geometry.col(tile)))
            let y1 = y0 + Double(geometry.rowHeight(geometry.row(tile)))
            // Nearest pixel centre within the tile, per axis.
            let nx = min(max(cx, x0 + 0.5), x1 - 0.5)
            let ny = min(max(cy, y0 + 0.5), y1 - 0.5)
            let isVisible = (nx - cx) * (nx - cx) + (ny - cy) * (ny - cy) < r2
            flags.append(isVisible)
            if isVisible { tiles.append(tile) }
        }
        self.visible = flags
        self.visibleTiles = tiles
    }

    /// Whether a tile can contain a visible pixel. Out-of-range indices are
    /// not visible rather than a trap: this is called from the diff loop.
    public func isVisible(_ tile: Int) -> Bool {
        tile >= 0 && tile < visible.count ? visible[tile] : false
    }

    /// Tiles hidden behind the glass — what the mask saves.
    public var hiddenCount: Int { visible.count - visibleTiles.count }
}

// MARK: - TileProtocol

/// Pure protocol logic for the tile stream - no networking, no capture. The
/// wire format (mirrors firmware/display_stream/tile_protocol.h):
///
///   [frame_id u16 LE][first_tile u16 LE][dirty_count u16 LE]
/// first_tile bit 15 always set, bits 14..10 reserved-zero, bits 9..0 the
/// first record's starting tile. dirty_count bit 15 = landscape, bits 14..0
/// the number of dirty TILES in this frame. Then records:
///   [tile u16 LE: bits 9..0 start, bits 14..10 run length - 1, bit 15 = 0]
///   [len u16 LE: bits 13..0 payload bytes, bits 15..14 codec]
///   [payload]
public enum TileProtocol {
    /// first_tile bit 15: this datagram is a tile-stream packet.
    public static let firstTileStreamFlag: UInt16 = 0x8000
    /// Record len field bits 13..0.
    public static let recordLengthMask: UInt16 = 0x3FFF
    /// Record len field bits 15..14.
    public static let recordCodecShift = 14
    /// Record tile field bits 14..10.
    public static let recordRunShift = 10

    /// Codec values for a record's len field bits 15..14. All four values are
    /// defined, so the field is full.
    public enum Codec: UInt8, Sendable {
        case raw = 0
        case rle565 = 1
        case bc1 = 2
        /// Half-resolution BC1 (docs/tile-stream-plan.md section 16): BC1 of a
        /// `halfDim` x `halfDim` raster, which the panel pixel-doubles back to
        /// the run's true size. ~16:1 overall, and the only codec here that
        /// costs RESOLUTION rather than just colour precision - so it is never
        /// chosen for being smallest, only when the degradation ladder asks
        /// for it (see `TilePacker.prepare`). Requires the panel to advertise
        /// `Capabilities.tileHalfRes`; older tile firmware rejects the record
        /// and drops the datagram carrying it.
        case halfBc1 = 3
    }

    /// Half-resolution size of one raster axis: `ceil(d / 2)`, mirroring
    /// `tileproto::halfDim`. Stated once because the encoder, the panel's
    /// decoder, and three test suites all have to round a 2 px edge tile the
    /// same way (2 -> 1) or the record's length check fails.
    public static func halfDim(_ d: Int) -> Int { (d + 1) / 2 }

    /// Downsample a big-endian RGB565 raster to `halfDim` x `halfDim` by
    /// averaging each 2x2 source block - the sender's half of `.halfBc1`.
    ///
    /// The filter is deliberately NOT part of the wire contract: the panel
    /// only promises to pixel-double whatever arrives, so this can be
    /// improved later without touching the protocol or the firmware. Box
    /// averaging rather than dropping 3 of every 4 pixels because decimation
    /// aliases hard on exactly the content that triggers half-res - video and
    /// scrolling text - and the cost is trivial next to BC1's own encode.
    ///
    /// Averaging happens in the native 5/6/5 channel space with round-half-up,
    /// so the result needs no requantization. Out-of-raster samples replicate
    /// the edge pixel, matching `BC1.encode`'s padding convention, which keeps
    /// odd dimensions and the 2 px edge tiles from averaging in phantom
    /// pixels.
    public static func downsample(
        _ raw: ArraySlice<UInt8>, width: Int, height: Int
    ) -> [UInt8]? {
        guard width > 0, height > 0, raw.count == width * height * 2 else {
            return nil
        }
        let halfW = halfDim(width), halfH = halfDim(height)
        var out = [UInt8](repeating: 0, count: halfW * halfH * 2)
        raw.withUnsafeBytes { src in
            let base = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<halfH {
                for x in 0..<halfW {
                    var r = 0, g = 0, b = 0
                    for dy in 0..<2 {
                        let sy = min(y * 2 + dy, height - 1)
                        for dx in 0..<2 {
                            let sx = min(x * 2 + dx, width - 1)
                            let p = base + (sy * width + sx) * 2
                            let c = (UInt16(p[0]) << 8) | UInt16(p[1])
                            r += Int(c >> 11)
                            g += Int((c >> 5) & 0x3F)
                            b += Int(c & 0x1F)
                        }
                    }
                    let c = (UInt16((r + 2) / 4) << 11)
                        | (UInt16((g + 2) / 4) << 5)
                        | UInt16((b + 2) / 4)
                    out[(y * halfW + x) * 2] = UInt8(c >> 8)
                    out[(y * halfW + x) * 2 + 1] = UInt8(c & 0xFF)
                }
            }
        }
        return out
    }

    /// The 6-byte packet header.
    public static func packetHeader(
        frameId: UInt16, firstTile: Int, dirtyCount: Int, landscape: Bool
    ) -> Data {
        let tileField = UInt16(firstTile) | firstTileStreamFlag
        let countField = UInt16(dirtyCount) | (landscape ? 0x8000 : 0)
        var header = Data(capacity: TileGeometry.headerBytes)
        header.append(UInt8(frameId & 0xFF))
        header.append(UInt8(frameId >> 8))
        header.append(UInt8(tileField & 0xFF))
        header.append(UInt8(tileField >> 8))
        header.append(UInt8(countField & 0xFF))
        header.append(UInt8(countField >> 8))
        return header
    }

    /// Indices of tiles whose bytes differ between two frames, sorted
    /// ascending - the tile protocol's `dirtyBands`. One strided memcmp per
    /// tile scanline (up to 16 rows of at most 32 bytes), short-circuiting
    /// on the first differing row; ~14,400 tiny compares for a fully clean
    /// 466x466 frame, well under a millisecond on Apple Silicon.
    /// `mask`, when given, excludes tiles that can never be seen (round
    /// glass): they are not compared and never reported dirty, which is both
    /// the bandwidth saving and a slightly cheaper diff.
    public static func dirtyTiles(
        new: [UInt8], previous: [UInt8], geometry: TileGeometry,
        mask: TileMask? = nil
    ) -> [Int] {
        precondition(new.count == geometry.frameBytes)
        precondition(previous.count == geometry.frameBytes)
        var dirty = [Int]()
        let rowStride = geometry.width * 2
        new.withUnsafeBytes { newRaw in
            previous.withUnsafeBytes { oldRaw in
                let newBase = newRaw.baseAddress!
                let oldBase = oldRaw.baseAddress!
                for tile in 0..<geometry.tileCount {
                    if let mask, !mask.isVisible(tile) { continue }
                    let x0 = geometry.col(tile) * TileGeometry.tileDim
                    let y0 = geometry.row(tile) * TileGeometry.tileDim
                    let w = geometry.colWidth(geometry.col(tile)) * 2
                    let h = geometry.rowHeight(geometry.row(tile))
                    for r in 0..<h {
                        let off = (y0 + r) * rowStride + x0 * 2
                        if memcmp(newBase + off, oldBase + off, w) != 0 {
                            dirty.append(tile)
                            break
                        }
                    }
                }
            }
        }
        return dirty
    }

    /// Merge sorted dirty tile indices into runs of horizontally adjacent
    /// tiles, never crossing a tile-row boundary. Run merging is what makes
    /// the panel's ~150 us fixed draw-call cost affordable - phase 0
    /// measured 900 per-tile draws at 7 fps (docs/tile-stream-plan.md
    /// section 11).
    public static func mergeRuns(
        dirtyTiles: [Int], geometry: TileGeometry
    ) -> [(start: Int, length: Int)] {
        var runs = [(start: Int, length: Int)]()
        var at = 0
        while at < dirtyTiles.count {
            let start = dirtyTiles[at]
            let row = geometry.row(start)
            var length = 1
            while at + 1 < dirtyTiles.count,
                  dirtyTiles[at + 1] == start + length,
                  geometry.row(dirtyTiles[at + 1]) == row,
                  length < TileGeometry.maxRunTiles {
                length += 1
                at += 1
            }
            runs.append((start: start, length: length))
            at += 1
        }
        return runs
    }

    /// Extract a run's rectangle from a row-major frame as a contiguous
    /// row-major raster - the byte layout every codec operates on.
    public static func extractRun(
        pixels: [UInt8], geometry: TileGeometry, startTile: Int,
        runLength: Int
    ) -> [UInt8] {
        let x0 = geometry.col(startTile) * TileGeometry.tileDim
        let y0 = geometry.row(startTile) * TileGeometry.tileDim
        let w = geometry.runPixelWidth(startTile: startTile, runLength: runLength)
        let h = geometry.rowHeight(geometry.row(startTile))
        var out = [UInt8]()
        out.reserveCapacity(w * h * 2)
        for r in 0..<h {
            let off = ((y0 + r) * geometry.width + x0) * 2
            out.append(contentsOf: pixels[off..<(off + w * 2)])
        }
        return out
    }
}

// MARK: - TileLossyPolicy

/// The user-facing quality lever for tile streaming, replacing JPEG's
/// percentage (docs/tile-stream-plan.md section 6.3). It only decides when
/// BC1 - the lossy codec - may win a run; raw and RLE565 are lossless and
/// always compete.
public enum TileLossyPolicy: String, Codable, CaseIterable, Sendable {
    /// Never BC1. Pixel-perfect, at the cost of frame rate on content RLE
    /// cannot compress (photos, video).
    case losslessOnly
    /// BC1 only where it is both the smallest encoding AND the run's content
    /// is busy enough (see `TilePacker.runVariance`) that its 4:1 loss hides
    /// in the texture. Over-budget frames drop the variance gate (the sender
    /// passes forceLossy) so motion keeps its frame rate.
    ///
    /// The "smooth gradients stay lossless because BC1 would band them" part
    /// of that intent is NOT what the gate achieves - BC1 returns linear
    /// ramps bit-exact, and they score higher variance than the noise it does
    /// damage. See `autoVarianceThreshold` for the measurements and why the
    /// number is still 400.
    case auto
    /// BC1 whenever it is smallest, variance regardless.
    case aggressive
}

// MARK: - TilePacker

/// Builds tile-stream datagrams: per merged run, every applicable codec is
/// tried and the smallest wins subject to the lossy policy; runs whose
/// record would not fit a datagram are split so a record never spans
/// datagrams. Mirrors `BandPacker`'s greedy packing but with runs and a
/// codec field instead of bands and a compressed flag.
public enum TilePacker {
    /// Content-variance floor for BC1 under `.auto`: the sum over the three
    /// channels of per-channel population variance in 888 space (see
    /// `runVariance`).
    ///
    /// MEASURED, and the rationale this shipped with does not survive it. The
    /// claim was that gradients are where BC1's 4:1 visibly bands, so a low
    /// threshold keeps them lossless while letting texture compress. Neither
    /// half holds (docs/tile-stream-plan.md section 17.14, pinned by
    /// `testVarianceOfRepresentativeContentClasses` and
    /// `testBc1ErrorIsSmallestOnExactlyTheContentTheGateLetsThrough`):
    ///
    /// | 16x16 tile | variance | BC1 worst error /255 |
    /// | --- | --- | --- |
    /// | flat fill | 0 | 0 |
    /// | 4-level gradient | 80 | 0 |
    /// | grey ramp | 17,163 | 0 |
    /// | photo noise | 16,528 | 166 |
    /// | antialiased text | 23,397 | 40 |
    ///
    /// Variance is ANTI-correlated with BC1 damage here. A linear ramp needs
    /// exactly the four levels BC1's endpoint line provides, so BC1 returns it
    /// bit-exact - while scoring higher variance than the noise BC1 mangles.
    /// Gradients were never the problem; the banding the gate was built to
    /// prevent is endpoint quantisation at block BOUNDARIES, which no
    /// per-tile variance can see.
    ///
    /// So this separates FLAT from everything else and nothing more, and on
    /// the one class it acts upon - shallow gradients, where BC1's error is
    /// zero - it spends extra bytes to avoid a loss that does not occur.
    /// Retuning the number cannot fix that; the metric would have to change.
    /// Left at 400 pending a decision on what `.auto` should mean, because
    /// making it agree with the evidence would make `.auto` behave like
    /// `.aggressive`, and that is a product question rather than a technical
    /// one.
    public static let autoVarianceThreshold = 400

    /// Busyness of a raster: per-channel population variance in 888 space
    /// (channels expanded by bit replication, matching `BC1`'s distance
    /// space), summed over R, G, B. Integer throughout - truncation is part
    /// of the pinned definition so both suites agree on boundary content.
    public static func runVariance(_ raw: [UInt8]) -> Int {
        let pixels = raw.count / 2
        guard pixels > 0 else { return 0 }
        var sum = (r: 0, g: 0, b: 0)
        var sumSq = (r: 0, g: 0, b: 0)
        for i in 0..<pixels {
            let p = (UInt16(raw[i * 2]) << 8) | UInt16(raw[i * 2 + 1])
            let r5 = Int(p >> 11), g6 = Int((p >> 5) & 0x3F), b5 = Int(p & 0x1F)
            let r = (r5 << 3) | (r5 >> 2)
            let g = (g6 << 2) | (g6 >> 4)
            let b = (b5 << 3) | (b5 >> 2)
            sum.r += r; sum.g += g; sum.b += b
            sumSq.r += r * r; sumSq.g += g * g; sumSq.b += b * b
        }
        func variance(_ s: Int, _ sq: Int) -> Int {
            (sq - s * s / pixels) / pixels
        }
        return variance(sum.r, sumSq.r) + variance(sum.g, sumSq.g)
            + variance(sum.b, sumSq.b)
    }
    /// One run ready for packing: its placement and cheapest encoding.
    struct PreparedRecord {
        let startTile: Int
        let runLength: Int
        let codec: TileProtocol.Codec
        let payload: [UInt8]
    }

    /// Build the datagrams that carry `dirtyTiles` (sorted indices) of
    /// `pixels`. `policy` decides when BC1 may win (see `TileLossyPolicy`);
    /// `forceLossy` is the over-budget override that turns `.auto`'s
    /// variance gate off for this frame - the sender sets it when the
    /// frame's lossless cost would blow the pacing budget, per the
    /// degradation ladder in docs/tile-stream-plan.md section 6.6.
    public static func packets(
        frameId: UInt16, dirtyTiles: [Int], pixels: [UInt8],
        geometry: TileGeometry, landscape: Bool,
        policy: TileLossyPolicy, forceLossy: Bool = false,
        forceHalfRes: Bool = false
    ) -> [Data] {
        precondition(pixels.count == geometry.frameBytes)
        let runs = TileProtocol.mergeRuns(dirtyTiles: dirtyTiles, geometry: geometry)
        var prepared = [PreparedRecord]()
        for run in runs {
            prepare(run.start, run.length, into: &prepared,
                    pixels: pixels, geometry: geometry,
                    policy: policy, forceLossy: forceLossy,
                    forceHalfRes: forceHalfRes)
        }

        let budget = TileGeometry.maxPacketBytes
        let headerBytes = TileGeometry.headerBytes
        var packets = [Data]()
        var current: [PreparedRecord] = []
        var currentBytes = headerBytes

        func flush() {
            guard let first = current.first else { return }
            var packet = TileProtocol.packetHeader(
                frameId: frameId, firstTile: first.startTile,
                dirtyCount: dirtyTiles.count, landscape: landscape)
            for record in current {
                let tileField = UInt16(record.startTile)
                    | (UInt16(record.runLength - 1) << TileProtocol.recordRunShift)
                let lenField = UInt16(record.payload.count)
                    | (UInt16(record.codec.rawValue) << TileProtocol.recordCodecShift)
                packet.append(UInt8(tileField & 0xFF))
                packet.append(UInt8(tileField >> 8))
                packet.append(UInt8(lenField & 0xFF))
                packet.append(UInt8(lenField >> 8))
                packet.append(contentsOf: record.payload)
            }
            packets.append(packet)
            current.removeAll(keepingCapacity: true)
            currentBytes = headerBytes
        }

        for record in prepared {
            let recordBytes = TileGeometry.recordHeaderBytes + record.payload.count
            if currentBytes + recordBytes > budget {
                flush()
            }
            current.append(record)
            currentBytes += recordBytes
        }
        flush()
        return packets
    }

    /// Encode one run with the cheapest codec the policy admits; when even
    /// the cheapest record would not fit an empty datagram, split the run
    /// in half by tiles and recurse - a record never spans datagrams.
    private static func prepare(
        _ startTile: Int, _ runLength: Int,
        into prepared: inout [PreparedRecord],
        pixels: [UInt8], geometry: TileGeometry,
        policy: TileLossyPolicy, forceLossy: Bool,
        forceHalfRes: Bool = false
    ) {
        let raw = TileProtocol.extractRun(
            pixels: pixels, geometry: geometry,
            startTile: startTile, runLength: runLength)
        var best = PreparedRecord(
            startTile: startTile, runLength: runLength,
            codec: .raw, payload: raw)
        if let rle = RLE565.encode(raw[...]), rle.count < best.payload.count {
            best = PreparedRecord(
                startTile: startTile, runLength: runLength,
                codec: .rle565, payload: rle)
        }
        // BC1 is fixed-rate, so its size is known WITHOUT encoding. When the
        // lossless winner is already at least as small, BC1 cannot win, and
        // neither it nor the variance scan needs to run at all. That is the
        // common case for UI content - a flat tile RLEs to a few bytes
        // against BC1's 128 - and encode was measured at ~30 us/tile, the
        // single largest cost in the send path once pacing was fixed.
        let w = geometry.runPixelWidth(startTile: startTile, runLength: runLength)
        let h = geometry.rowHeight(geometry.row(startTile))
        let bc1Size = BC1.encodedBytes(width: w, height: h)
        // Half-res is the ladder's last codec rung, and it is gated
        // differently from every other codec here on purpose. The others
        // compete on size and win when they are smallest; half-res is ALWAYS
        // smallest (a quarter of BC1), so letting it compete would blur
        // static UI the moment the policy allowed lossy at all - `.aggressive`
        // would never send anything else. So it is only ever chosen when the
        // frame-level ladder explicitly asks (`forceHalfRes`), and even then
        // it must still beat the lossless winner, which is what keeps flat
        // runs - already a handful of RLE bytes - at full resolution.
        let halfSize = BC1.encodedBytes(
            width: TileProtocol.halfDim(w), height: TileProtocol.halfDim(h))
        let tryHalf = forceHalfRes && policy != .losslessOnly
            && halfSize > 0 && halfSize < best.payload.count
        // Skipping BC1 when half-res will supersede it is not just tidiness:
        // BC1 encode was ~30 us/tile, so encoding all 719 tiles only to throw
        // the result away would add ~21 ms to exactly the frames the ladder is
        // trying to make cheaper.
        if !tryHalf, bc1Size > 0, bc1Size < best.payload.count {
            let lossyEligible: Bool
            switch policy {
            case .losslessOnly:
                lossyEligible = false
            case .aggressive:
                lossyEligible = true
            case .auto:
                lossyEligible = forceLossy
                    || runVariance(raw) >= autoVarianceThreshold
            }
            if lossyEligible, let bc1 = BC1.encode(raw[...], width: w, height: h) {
                best = PreparedRecord(
                    startTile: startTile, runLength: runLength,
                    codec: .bc1, payload: bc1)
            }
        }
        if tryHalf,
           let small = TileProtocol.downsample(raw[...], width: w, height: h),
           let half = BC1.encode(
               small[...], width: TileProtocol.halfDim(w),
               height: TileProtocol.halfDim(h)) {
            best = PreparedRecord(
                startTile: startTile, runLength: runLength,
                codec: .halfBc1, payload: half)
        }
        let budget = TileGeometry.maxPacketBytes - TileGeometry.headerBytes
            - TileGeometry.recordHeaderBytes
        if best.payload.count <= budget {
            prepared.append(best)
            return
        }
        // Too big for any datagram: split by tiles. A single tile always
        // fits (512 B raw at most), so the recursion terminates.
        let left = runLength / 2
        prepare(startTile, left, into: &prepared,
                pixels: pixels, geometry: geometry,
                policy: policy, forceLossy: forceLossy,
                forceHalfRes: forceHalfRes)
        prepare(startTile + left, runLength - left, into: &prepared,
                pixels: pixels, geometry: geometry,
                policy: policy, forceLossy: forceLossy,
                forceHalfRes: forceHalfRes)
    }
}
