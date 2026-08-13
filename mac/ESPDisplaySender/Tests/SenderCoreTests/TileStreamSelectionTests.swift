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
