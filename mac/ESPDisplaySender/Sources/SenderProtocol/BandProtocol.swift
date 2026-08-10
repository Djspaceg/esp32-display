import Foundation

// MARK: - PanelGeometry

/// Resolution-independent geometry for any panel the firmware can drive.
///
/// The firmware advertises its resolution in an mDNS TXT record (`res=WxH`).
/// Band geometry is derived parametrically so the same formula runs on both
/// sides:
///   rowsPerBand = max(1, floor((maxPacketBytes - headerBytes) / rowBytes))
///   bandCount   = ceil(height / rowsPerBand)
///
/// The last band may be shorter than the others when height does not divide
/// evenly (e.g. 466x466: every band is 1 row, all uniform).
public struct PanelGeometry: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var frameBytes: Int { width * height * 2 }

    /// UDP payload budget matching the firmware.
    public static let maxPacketBytes = 1400
    /// 6-byte band header: [frame_id u16 LE][band_index u16 LE][dirty_count u16 LE].
    public static let headerBytes = 6

    public func frameWidth(landscape: Bool) -> Int { landscape ? height : width }
    public func frameHeight(landscape: Bool) -> Int { landscape ? width : height }
    public func rowBytes(landscape: Bool) -> Int { frameWidth(landscape: landscape) * 2 }

    public func rowsPerBand(landscape: Bool) -> Int {
        let fit = (Self.maxPacketBytes - Self.headerBytes) / rowBytes(landscape: landscape)
        return max(1, fit)
    }

    public func bandCount(landscape: Bool) -> Int {
        let rpb = rowsPerBand(landscape: landscape)
        return (frameHeight(landscape: landscape) + rpb - 1) / rpb
    }

    public func bandPayloadBytes(index: Int, landscape: Bool) -> Int {
        let rpb = rowsPerBand(landscape: landscape)
        let bands = bandCount(landscape: landscape)
        let rows = (index + 1 < bands) ? rpb : (frameHeight(landscape: landscape) - (bands - 1) * rpb)
        return rows * rowBytes(landscape: landscape)
    }

    public func bandOffset(index: Int, landscape: Bool) -> Int {
        index * rowsPerBand(landscape: landscape) * rowBytes(landscape: landscape)
    }

    /// The original 172x320 panel (T-Display S3).
    public static let panel172x320 = PanelGeometry(width: 172, height: 320)
}

// MARK: - BandProtocol

/// Pure protocol logic for the band stream - no networking, no capture -
/// so it's unit testable, and its test vectors mirror the firmware's
/// (firmware/test/test_band_protocol.cpp) to keep both ends agreeing on the
/// wire format.
public enum BandProtocol {
    // Legacy constants assuming the 172x320 panel.
    public static let frameBytes = 172 * 320 * 2  // 110_080

    /// Band geometry for the 172x320 panel. Orientation-native so bands align
    /// to whole rows: portrait 172px rows: 4 rows x 344B; landscape 320px rows:
    /// 2 rows x 640B. Both tile the frame exactly and stay under a 1400B safe MTU.
    public static func bandGeometry(landscape: Bool) -> (bands: Int, bandBytes: Int) {
        landscape ? (86, 1280) : (80, 1376)
    }

    /// Geometry for an arbitrary panel resolution.
    ///
    /// For uniform panels (where all bands are the same size), `bandBytes` is
    /// the size of every band. For panels where height is not evenly divisible
    /// by rowsPerBand, `bandBytes` is the size of the first (full) band; the
    /// last band may be shorter. Callers that need per-band sizes should use
    /// `geometry.bandPayloadBytes(index:landscape:)`.
    public static func bandGeometry(for geometry: PanelGeometry, landscape: Bool) -> (bands: Int, bandBytes: Int) {
        (geometry.bandCount(landscape: landscape),
         geometry.bandPayloadBytes(index: 0, landscape: landscape))
    }

    /// The 6-byte packet header: [frame_id u16 LE][band_index u16 LE]
    /// [dirty_count u16 LE] with orientation in bit 15 of dirty_count.
    public static func packetHeader(
        frameId: UInt16, band: Int, dirtyCount: Int, landscape: Bool
    ) -> Data {
        let countField = UInt16(dirtyCount) | (landscape ? 0x8000 : 0)
        var header = Data(capacity: 6)
        header.append(UInt8(frameId & 0xFF))
        header.append(UInt8(frameId >> 8))
        header.append(UInt8(band & 0xFF))
        header.append(UInt8(band >> 8))
        header.append(UInt8(countField & 0xFF))
        header.append(UInt8(countField >> 8))
        return header
    }

    /// Indices of bands whose bytes differ between two frames (172x320 only).
    public static func dirtyBands(new: [UInt8], previous: [UInt8], landscape: Bool) -> [Int] {
        precondition(new.count == frameBytes && previous.count == frameBytes)
        let (bands, bandBytes) = bandGeometry(landscape: landscape)
        var dirty = [Int]()
        new.withUnsafeBytes { newRaw in
            previous.withUnsafeBytes { oldRaw in
                for band in 0..<bands {
                    let off = band * bandBytes
                    if memcmp(newRaw.baseAddress! + off, oldRaw.baseAddress! + off,
                              bandBytes) != 0 {
                        dirty.append(band)
                    }
                }
            }
        }
        return dirty
    }

    /// Geometry-aware dirty-band detection for arbitrary panel resolutions.
    ///
    /// Handles non-uniform last bands correctly (the last band may be shorter
    /// than the rest when height is not evenly divisible by rowsPerBand).
    public static func dirtyBands(new: [UInt8], previous: [UInt8], geometry: PanelGeometry, landscape: Bool) -> [Int] {
        precondition(new.count == geometry.frameBytes && previous.count == geometry.frameBytes)
        let bands = geometry.bandCount(landscape: landscape)
        var dirty = [Int]()
        new.withUnsafeBytes { newRaw in
            previous.withUnsafeBytes { oldRaw in
                for band in 0..<bands {
                    let off = geometry.bandOffset(index: band, landscape: landscape)
                    let len = geometry.bandPayloadBytes(index: band, landscape: landscape)
                    if memcmp(newRaw.baseAddress! + off, oldRaw.baseAddress! + off, len) != 0 {
                        dirty.append(band)
                    }
                }
            }
        }
        return dirty
    }

    public struct DeviceStats: Equatable {
        public var shown: UInt32 = 0
        public var dropped: UInt32 = 0
        public var skipped: UInt32 = 0
        public var packets: UInt32 = 0
        public var heap: UInt32 = 0

        public init(shown: UInt32 = 0, dropped: UInt32 = 0, skipped: UInt32 = 0,
                    packets: UInt32 = 0, heap: UInt32 = 0) {
            self.shown = shown
            self.dropped = dropped
            self.skipped = skipped
            self.packets = packets
            self.heap = heap
        }
    }

    /// Parse a device heartbeat: "EHB1" + 5 x u32 LE. Nil for anything else.
    public static func parseHeartbeat(_ data: Data) -> DeviceStats? {
        guard data.count == 24, data.prefix(4) == Data("EHB1".utf8) else { return nil }
        func u32(_ index: Int) -> UInt32 {
            let b = [UInt8](data[(4 + index * 4)..<(8 + index * 4)])
            return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
        }
        return DeviceStats(
            shown: u32(0), dropped: u32(1), skipped: u32(2), packets: u32(3), heap: u32(4))
    }
}
