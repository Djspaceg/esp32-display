import Foundation

/// ETL1 geometry: 16×16 tiles, 16-bit indices, and runs up to 255 tiles.
public struct LargeTileGeometry: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
    public static let tileDim = 16
    public static let maxTiles = 4096
    public static let maxRunTiles = 255
    public var tileCols: Int { (width + 15) / 16 }
    public var tileRows: Int { (height + 15) / 16 }
    public var tileCount: Int { tileCols * tileRows }
    public var frameBytes: Int { width * height * 2 }
    public var isStreamable: Bool {
        width > 0 && height > 0 && tileCols <= Self.maxRunTiles
            && tileCount <= Self.maxTiles
    }
    public func col(_ tile: Int) -> Int { tile % tileCols }
    public func row(_ tile: Int) -> Int { tile / tileCols }
    public func colWidth(_ col: Int) -> Int { min(16, width - col * 16) }
    public func rowHeight(_ row: Int) -> Int { min(16, height - row * 16) }
    public func runPixelWidth(start: Int, length: Int) -> Int {
        min((col(start) + length) * 16, width) - col(start) * 16
    }
}

/// Pure magic-prefixed large-tile wire format.
public enum LargeTileProtocol {
    public static let magic = Data("ETL1".utf8)
    public static let headerBytes = 10
    public static let recordHeaderBytes = 6
    public static let maxPacketBytes = 1472
    public static let flagLandscape: UInt8 = 0x01
    public static let codecVisibleSpans: UInt8 = 0x04

    public enum Codec: UInt8, Sendable {
        case raw = 0
        case rle565 = 1
        case bc1 = 2
        case halfBc1 = 3
    }

    public static func header(
        frameId: UInt16, dirtyCount: Int, landscape: Bool
    ) -> Data {
        var data = magic
        appendLE(frameId, to: &data)
        appendLE(UInt16(dirtyCount), to: &data)
        data.append(landscape ? flagLandscape : 0)
        data.append(0)
        return data
    }

    public static func record(
        startTile: Int, runLength: Int, codec: Codec,
        visibleSpans: Bool = false, payload: [UInt8]
    ) -> Data {
        precondition((0...Int(UInt16.max)).contains(startTile))
        precondition((1...255).contains(runLength))
        precondition((1...Int(UInt16.max)).contains(payload.count))
        var data = Data(capacity: recordHeaderBytes + payload.count)
        appendLE(UInt16(startTile), to: &data)
        data.append(UInt8(runLength))
        data.append(codec.rawValue | (visibleSpans ? codecVisibleSpans : 0))
        appendLE(UInt16(payload.count), to: &data)
        data.append(contentsOf: payload)
        return data
    }

    public static func dirtyTiles(
        new: [UInt8], previous: [UInt8], geometry: LargeTileGeometry
    ) -> [Int] {
        precondition(new.count == geometry.frameBytes)
        precondition(previous.count == geometry.frameBytes)
        var dirty = [Int]()
        new.withUnsafeBytes { fresh in
            previous.withUnsafeBytes { old in
                for tile in 0..<geometry.tileCount {
                    let x = geometry.col(tile) * 16
                    let y = geometry.row(tile) * 16
                    let width = geometry.colWidth(geometry.col(tile)) * 2
                    let height = geometry.rowHeight(geometry.row(tile))
                    for row in 0..<height {
                        let offset = ((y + row) * geometry.width + x) * 2
                        if memcmp(fresh.baseAddress! + offset,
                                  old.baseAddress! + offset, width) != 0 {
                            dirty.append(tile)
                            break
                        }
                    }
                }
            }
        }
        return dirty
    }

    public static func mergeRuns(
        _ dirty: [Int], geometry: LargeTileGeometry
    ) -> [(start: Int, length: Int)] {
        var runs = [(start: Int, length: Int)]()
        var index = 0
        while index < dirty.count {
            let start = dirty[index]
            let row = geometry.row(start)
            var length = 1
            while index + 1 < dirty.count,
                  dirty[index + 1] == start + length,
                  geometry.row(dirty[index + 1]) == row,
                  length < LargeTileGeometry.maxRunTiles {
                index += 1
                length += 1
            }
            runs.append((start, length))
            index += 1
        }
        return runs
    }

    public static func extract(
        pixels: [UInt8], geometry: LargeTileGeometry,
        start: Int, length: Int
    ) -> [UInt8] {
        let x = geometry.col(start) * 16
        let y = geometry.row(start) * 16
        let width = geometry.runPixelWidth(start: start, length: length)
        let height = geometry.rowHeight(geometry.row(start))
        var out = [UInt8]()
        out.reserveCapacity(width * height * 2)
        for row in 0..<height {
            let offset = ((y + row) * geometry.width + x) * 2
            out.append(contentsOf: pixels[offset..<(offset + width * 2)])
        }
        return out
    }

    private static func appendLE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8(value >> 8))
    }
}

public enum LargeTilePacker {
    private struct Prepared {
        let start: Int
        let length: Int
        let codec: LargeTileProtocol.Codec
        let payload: [UInt8]
    }

    public static func packets(
        frameId: UInt16, dirtyTiles: [Int], pixels: [UInt8],
        geometry: LargeTileGeometry, landscape: Bool,
        policy: TileLossyPolicy, forceLossy: Bool = false,
        forceHalfRes: Bool = false
    ) -> [Data] {
        precondition(geometry.isStreamable)
        precondition(pixels.count == geometry.frameBytes)
        var records = [Prepared]()
        for run in LargeTileProtocol.mergeRuns(dirtyTiles, geometry: geometry) {
            prepare(run.start, run.length, into: &records, pixels: pixels,
                    geometry: geometry, policy: policy,
                    forceLossy: forceLossy, forceHalfRes: forceHalfRes)
        }
        var packets = [Data]()
        var current = [Prepared]()
        var size = LargeTileProtocol.headerBytes
        func flush() {
            guard !current.isEmpty else { return }
            var packet = LargeTileProtocol.header(
                frameId: frameId, dirtyCount: dirtyTiles.count,
                landscape: landscape)
            for item in current {
                packet.append(LargeTileProtocol.record(
                    startTile: item.start, runLength: item.length,
                    codec: item.codec, payload: item.payload))
            }
            packets.append(packet)
            current.removeAll(keepingCapacity: true)
            size = LargeTileProtocol.headerBytes
        }
        for item in records {
            let bytes = LargeTileProtocol.recordHeaderBytes + item.payload.count
            if size + bytes > LargeTileProtocol.maxPacketBytes { flush() }
            current.append(item)
            size += bytes
        }
        flush()
        return packets
    }

    private static func prepare(
        _ start: Int, _ length: Int, into out: inout [Prepared],
        pixels: [UInt8], geometry: LargeTileGeometry,
        policy: TileLossyPolicy, forceLossy: Bool, forceHalfRes: Bool
    ) {
        let raw = LargeTileProtocol.extract(
            pixels: pixels, geometry: geometry, start: start, length: length)
        var best = Prepared(start: start, length: length,
                            codec: .raw, payload: raw)
        if let rle = RLE565.encode(raw[...]), rle.count < best.payload.count {
            best = Prepared(start: start, length: length,
                            codec: .rle565, payload: rle)
        }
        let width = geometry.runPixelWidth(start: start, length: length)
        let height = geometry.rowHeight(geometry.row(start))
        let allowBc1 = policy == .aggressive ||
            (policy == .auto && (forceLossy ||
             TilePacker.runVariance(raw) >= TilePacker.autoVarianceThreshold))
        if allowBc1,
           BC1.encodedBytes(width: width, height: height) < best.payload.count,
           let bc1 = BC1.encode(raw[...], width: width, height: height) {
            best = Prepared(start: start, length: length,
                            codec: .bc1, payload: bc1)
        }
        if forceHalfRes, policy != .losslessOnly,
           let small = TileProtocol.downsample(raw[...], width: width, height: height),
           let half = BC1.encode(
               small[...], width: TileProtocol.halfDim(width),
               height: TileProtocol.halfDim(height)),
           half.count < best.payload.count {
            best = Prepared(start: start, length: length,
                            codec: .halfBc1, payload: half)
        }
        let budget = LargeTileProtocol.maxPacketBytes
            - LargeTileProtocol.headerBytes - LargeTileProtocol.recordHeaderBytes
        if best.payload.count <= budget {
            out.append(best)
            return
        }
        precondition(length > 1)
        let left = length / 2
        prepare(start, left, into: &out, pixels: pixels, geometry: geometry,
                policy: policy, forceLossy: forceLossy,
                forceHalfRes: forceHalfRes)
        prepare(start + left, length - left, into: &out, pixels: pixels,
                geometry: geometry, policy: policy, forceLossy: forceLossy,
                forceHalfRes: forceHalfRes)
    }
}
