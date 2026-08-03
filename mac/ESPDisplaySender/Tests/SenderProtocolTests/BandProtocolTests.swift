import XCTest

@testable import SenderProtocol

final class BandProtocolTests: XCTestCase {

    // Bands must tile the frame exactly in both orientations, MTU-safe.
    func testGeometryTilesTheFrame() {
        let p = BandProtocol.bandGeometry(landscape: false)
        let l = BandProtocol.bandGeometry(landscape: true)
        XCTAssertEqual(p.bands * p.bandBytes, BandProtocol.frameBytes)
        XCTAssertEqual(l.bands * l.bandBytes, BandProtocol.frameBytes)
        XCTAssertLessThanOrEqual(6 + p.bandBytes, 1400)
        XCTAssertLessThanOrEqual(6 + l.bandBytes, 1400)
        // Portrait bands are whole 172px rows; landscape whole 320px rows.
        XCTAssertEqual(p.bandBytes % (172 * 2), 0)
        XCTAssertEqual(l.bandBytes % (320 * 2), 0)
    }

    // Same test vector as the firmware's parseHeader test - this is the
    // cross-language agreement check.
    func testPacketHeaderMatchesFirmwareVector() {
        let h = BandProtocol.packetHeader(
            frameId: 0x1234, band: 5, dirtyCount: 0x50, landscape: true)
        XCTAssertEqual([UInt8](h), [0x34, 0x12, 0x05, 0x00, 0x50, 0x80])

        let portrait = BandProtocol.packetHeader(
            frameId: 0, band: 0, dirtyCount: 80, landscape: false)
        XCTAssertEqual([UInt8](portrait), [0x00, 0x00, 0x00, 0x00, 0x50, 0x00])
    }

    func testDirtyBandsIdenticalFramesAreClean() {
        let frame = [UInt8](repeating: 0xAB, count: BandProtocol.frameBytes)
        XCTAssertEqual(BandProtocol.dirtyBands(new: frame, previous: frame, landscape: false), [])
        XCTAssertEqual(BandProtocol.dirtyBands(new: frame, previous: frame, landscape: true), [])
    }

    func testDirtyBandsDetectsSingleByteChange() {
        let prev = [UInt8](repeating: 0, count: BandProtocol.frameBytes)
        let (_, bandBytes) = BandProtocol.bandGeometry(landscape: false)

        var new = prev
        new[42 * bandBytes] = 1  // first byte of band 42
        XCTAssertEqual(BandProtocol.dirtyBands(new: new, previous: prev, landscape: false), [42])

        var lastByte = prev
        lastByte[BandProtocol.frameBytes - 1] = 1  // last byte of last band
        XCTAssertEqual(
            BandProtocol.dirtyBands(new: lastByte, previous: prev, landscape: false), [79])
    }

    func testDirtyBandsChangeSpanningBoundaryMarksBothBands() {
        let prev = [UInt8](repeating: 0, count: BandProtocol.frameBytes)
        let (_, bandBytes) = BandProtocol.bandGeometry(landscape: false)
        var new = prev
        new[5 * bandBytes - 1] = 1  // last byte of band 4
        new[5 * bandBytes] = 1      // first byte of band 5
        XCTAssertEqual(BandProtocol.dirtyBands(new: new, previous: prev, landscape: false), [4, 5])
    }

    func testDirtyBandsLandscapeGeometry() {
        let prev = [UInt8](repeating: 0, count: BandProtocol.frameBytes)
        let (bands, bandBytes) = BandProtocol.bandGeometry(landscape: true)
        var new = prev
        new[(bands - 1) * bandBytes] = 1  // first byte of band 85
        XCTAssertEqual(
            BandProtocol.dirtyBands(new: new, previous: prev, landscape: true), [bands - 1])
    }

    func testParseHeartbeat() {
        var packet = Data("EHB1".utf8)
        // shown=0x01020304, dropped=5, skipped=6, packets=0x00010000, heap=81920
        let values: [UInt32] = [0x0102_0304, 5, 6, 0x0001_0000, 81920]
        for v in values {
            packet.append(UInt8(v & 0xFF))
            packet.append(UInt8((v >> 8) & 0xFF))
            packet.append(UInt8((v >> 16) & 0xFF))
            packet.append(UInt8((v >> 24) & 0xFF))
        }
        let stats = BandProtocol.parseHeartbeat(packet)
        XCTAssertEqual(
            stats,
            BandProtocol.DeviceStats(
                shown: 0x0102_0304, dropped: 5, skipped: 6, packets: 0x0001_0000, heap: 81920))
    }

    func testParseHeartbeatRejectsGarbage() {
        XCTAssertNil(BandProtocol.parseHeartbeat(Data("EHB1".utf8)))       // too short
        XCTAssertNil(BandProtocol.parseHeartbeat(Data(repeating: 0, count: 24)))  // bad magic
        var long = Data("EHB1".utf8)
        long.append(Data(repeating: 0, count: 24))
        XCTAssertNil(BandProtocol.parseHeartbeat(long))                    // too long
        XCTAssertNil(BandProtocol.parseHeartbeat(Data("EPNG".utf8)))       // wrong type
    }
}
