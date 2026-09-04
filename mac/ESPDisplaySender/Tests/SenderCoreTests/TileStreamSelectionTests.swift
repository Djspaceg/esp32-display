import XCTest
import SenderProtocol
@testable import SenderCore

/// The sender-side gate on the tile-stream path.
///
/// The wire rule these protect: tile packets and packed band packets are
/// byte-ambiguous past their shared bit-15 flag, so the sender may only
/// speak tiles to a panel that advertised `tileStream` - and every other
/// panel's bytes must be exactly what they were before tiles existed. The
/// capability flag itself starts false and is only ever set from an EINF
/// carrying the bit, so a band-only panel can never reach the tile branch;
/// what carries actual logic is the geometry gate below.
final class TileStreamSelectionTests: XCTestCase {
    func testTileGeometryDerivesForRealPanels() {
        // The 466x466 AMOLED - the one panel that advertises the bit today.
        let tiles = FrameSender.tileGeometry(
            for: PanelGeometry(width: 466, height: 466))
        XCTAssertEqual(tiles?.tileCount, 900)
        XCTAssertEqual(tiles?.tileCols, 30)
        // The C6 geometry is tile-expressible too; harmless, because that
        // firmware never advertises the capability.
        XCTAssertNotNil(FrameSender.tileGeometry(for: .panel172x320))
    }

    func testLargeTileTransportRequiresCapabilityAndGeometry() {
        let large = PanelGeometry(width: 720, height: 720)
        XCTAssertEqual(
            FrameSender.frameTransport(for: large, capabilities: []),
            .unavailable,
            "720x720 must wait for EINF rather than emit oversized bands")
        XCTAssertEqual(
            FrameSender.frameTransport(for: large, capabilities: .tileStream),
            .unavailable,
            "tile-v1 cannot carry the 2025-tile grid")
        XCTAssertEqual(
            FrameSender.frameTransport(for: large, capabilities: .largeTileStream),
            .largeTiles)

        let pixels = [UInt8](repeating: 0, count: large.frameBytes)
        XCTAssertTrue(FrameSender.firstFramePackets(
            frameId: 1, pixels: pixels, geometry: large).isEmpty)
        let packets = FrameSender.firstFramePackets(
            frameId: 1, pixels: pixels, geometry: large,
            capabilities: .largeTileStream)
        XCTAssertFalse(packets.isEmpty)
        XCTAssertTrue(packets.allSatisfy { $0.prefix(4) == Data("ETL1".utf8) })
    }

    func testLegacyBandAndTilePacketsStayOnTheirExistingPackers() {
        let bandGeometry = PanelGeometry.panel172x320
        let bandPixels = [UInt8](repeating: 0x5A, count: bandGeometry.frameBytes)
        let classic = FrameSender.firstFramePackets(
            frameId: 0x1234, pixels: bandPixels, geometry: bandGeometry)
        var expectedFirst = BandProtocol.packetHeader(
            frameId: 0x1234, band: 0,
            dirtyCount: bandGeometry.bandCount(landscape: false),
            landscape: false)
        expectedFirst.append(contentsOf: bandPixels[0..<bandGeometry.bandPayloadBytes(
            index: 0, landscape: false)])
        XCTAssertEqual(classic.first, expectedFirst)

        let tileGeometry = PanelGeometry(width: 466, height: 466)
        let tilePixels = [UInt8](repeating: 0, count: tileGeometry.frameBytes)
        let selected = FrameSender.firstFramePackets(
            frameId: 7, pixels: tilePixels, geometry: tileGeometry,
            capabilities: .tileStream)
        let grid = TileGeometry(width: 466, height: 466)
        let existing = TilePacker.packets(
            frameId: 7, dirtyTiles: Array(0..<grid.tileCount),
            pixels: tilePixels, geometry: grid, landscape: false,
            policy: .losslessOnly)
        XCTAssertEqual(selected, existing)
        XCTAssertFalse(selected.contains { $0.prefix(4) == Data("ETL1".utf8) })
    }

    func testTransportNegotiationChangeForcesAKeyframe() {
        XCTAssertTrue(FrameSender.transportChangeRequiresKeyframe(
            from: .unavailable, to: .largeTiles))
        XCTAssertTrue(FrameSender.transportChangeRequiresKeyframe(
            from: .classicBands, to: .tileV1))
        XCTAssertFalse(FrameSender.transportChangeRequiresKeyframe(
            from: .tileV1, to: .tileV1))
    }

    func testHostileGeometryDisablesTheTilePath() {
        // A geometry the tile grid cannot carry (33+ tile columns) yields
        // nil, which keeps a panel advertising the bit against a bogus mDNS
        // resolution on the band path instead of feeding bad numbers into
        // grid arithmetic.
        XCTAssertNil(FrameSender.tileGeometry(
            for: PanelGeometry(width: 640, height: 480)))
        XCTAssertNil(FrameSender.tileGeometry(
            for: PanelGeometry(width: 0, height: 0)))
    }
}
