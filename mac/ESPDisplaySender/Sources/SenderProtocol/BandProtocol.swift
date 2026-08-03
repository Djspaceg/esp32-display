import Foundation

/// Pure protocol logic for the band stream - no networking, no capture -
/// so it's unit testable, and its test vectors mirror the firmware's
/// (firmware/test/test_band_protocol.cpp) to keep both ends agreeing on the
/// wire format.
public enum BandProtocol {
    public static let frameBytes = 172 * 320 * 2  // 110_080

    /// Band geometry is orientation-native so bands align to whole rows:
    /// portrait 172px rows: 4 rows x 344B; landscape 320px rows: 2 rows x
    /// 640B. Both tile the frame exactly and stay under a 1400B safe MTU.
    public static func bandGeometry(landscape: Bool) -> (bands: Int, bandBytes: Int) {
        landscape ? (86, 1280) : (80, 1376)
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

    /// Indices of bands whose bytes differ between two frames.
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
