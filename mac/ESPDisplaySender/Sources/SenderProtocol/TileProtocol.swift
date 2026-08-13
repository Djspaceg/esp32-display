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

    /// Codec values for a record's len field bits 15..14. Value 3 is
    /// reserved (a future half-res motion mode); never emitted.
    public enum Codec: UInt8, Sendable {
        case raw = 0
        case rle565 = 1
        case bc1 = 2
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
    public static func dirtyTiles(
        new: [UInt8], previous: [UInt8], geometry: TileGeometry
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

// MARK: - TilePacker

/// Builds tile-stream datagrams: per merged run, every applicable codec is
/// tried and the smallest wins; runs whose record would not fit a datagram
/// are split so a record never spans datagrams. Mirrors `BandPacker`'s
/// greedy packing but with runs and a codec field instead of bands and a
/// compressed flag.
public enum TilePacker {
    /// One run ready for packing: its placement and cheapest encoding.
    struct PreparedRecord {
        let startTile: Int
        let runLength: Int
        let codec: TileProtocol.Codec
        let payload: [UInt8]
    }

    /// Build the datagrams that carry `dirtyTiles` (sorted indices) of
    /// `pixels`. `allowLossy` gates BC1: false means lossless-only (raw or
    /// RLE565), true lets BC1 win when it is strictly smallest. The
    /// variance-based per-run policy arrives with the degradation work; the
    /// packer only knows sizes.
    public static func packets(
        frameId: UInt16, dirtyTiles: [Int], pixels: [UInt8],
        geometry: TileGeometry, landscape: Bool, allowLossy: Bool
    ) -> [Data] {
        precondition(pixels.count == geometry.frameBytes)
        let runs = TileProtocol.mergeRuns(dirtyTiles: dirtyTiles, geometry: geometry)
        var prepared = [PreparedRecord]()
        for run in runs {
            prepare(run.start, run.length, into: &prepared,
                    pixels: pixels, geometry: geometry, allowLossy: allowLossy)
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

    /// Encode one run with the cheapest applicable codec; when even the
    /// cheapest record would not fit an empty datagram, split the run in
    /// half by tiles and recurse - a record never spans datagrams.
    private static func prepare(
        _ startTile: Int, _ runLength: Int,
        into prepared: inout [PreparedRecord],
        pixels: [UInt8], geometry: TileGeometry, allowLossy: Bool
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
        if allowLossy {
            let w = geometry.runPixelWidth(startTile: startTile, runLength: runLength)
            let h = geometry.rowHeight(geometry.row(startTile))
            if let bc1 = BC1.encode(raw[...], width: w, height: h),
               bc1.count < best.payload.count {
                best = PreparedRecord(
                    startTile: startTile, runLength: runLength,
                    codec: .bc1, payload: bc1)
            }
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
                pixels: pixels, geometry: geometry, allowLossy: allowLossy)
        prepare(startTile + left, runLength - left, into: &prepared,
                pixels: pixels, geometry: geometry, allowLossy: allowLossy)
    }
}
