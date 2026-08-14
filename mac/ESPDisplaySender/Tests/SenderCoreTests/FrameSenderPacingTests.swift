import XCTest
import SenderProtocol
@testable import SenderCore

/// The pacing controller's bounds, per panel geometry.
///
/// The bug these exist to prevent: the controller's spacing ceiling used to be
/// a fixed 2500us regardless of how many packets a frame takes, which is a
/// 5 fps floor on the 80-band 172x320 but a 0.86 fps floor on the 466-band
/// 466x466 - so the hill-climb could (and did) park the square panel at ~1 fps.
/// The invariant is packets per second: the ceiling must scale with
/// geometry.bandCount so no panel can be held below `minWorstCaseFps` of
/// worst-case (uncompressed keyframe) frames.
///
/// Expected values are written as independently computed constants, not by
/// restating the formula, so an arithmetic mutation fails here.
final class FrameSenderPacingTests: XCTestCase {
    func testBoundsForThe172x320() {
        // Worst orientation is landscape: 86 bands. 5 fps x 86 = 430 pkt/s,
        // one packet every 2325us (integer floor of 2325.58).
        let bounds = FrameSender.spacingBounds(for: .panel172x320)
        XCTAssertEqual(bounds.lowerBound, 120)
        XCTAssertEqual(bounds.upperBound, 2325)
    }

    func testBoundsForThe466x466() {
        // 466 one-row bands either way up. 5 fps x 466 = 2330 pkt/s, one
        // packet every 429us (integer floor of 429.18). Against the measured
        // ~1826 pkt/s ingest ceiling the climb saturates the panel instead of
        // idling at a gap sized for a panel a sixth the resolution.
        let bounds = FrameSender.spacingBounds(
            for: PanelGeometry(width: 466, height: 466))
        XCTAssertEqual(bounds.lowerBound, 120)
        XCTAssertEqual(bounds.upperBound, 429)
    }

    func testControllerCeilingCannotSitBelowTheFpsFloor() {
        // The property itself, across every geometry the protocol accepts:
        // at the ceiling gap, a full keyframe still repeats at minWorstCaseFps
        // or better in the worst orientation.
        for geometry in [PanelGeometry.panel172x320,
                         PanelGeometry(width: 412, height: 412),
                         PanelGeometry(width: 466, height: 466),
                         PanelGeometry(width: 480, height: 480),
                         PanelGeometry(width: 697, height: 100)] {
            let bounds = FrameSender.spacingBounds(for: geometry)
            let worstBands = max(geometry.bandCount(landscape: false),
                                 geometry.bandCount(landscape: true))
            let fpsAtCeiling = 1_000_000.0
                / (Double(bounds.upperBound) * Double(worstBands))
            XCTAssertGreaterThanOrEqual(
                fpsAtCeiling, Double(FrameSender.minWorstCaseFps),
                "\(geometry.width)x\(geometry.height)")
            XCTAssertLessThanOrEqual(bounds.lowerBound, bounds.upperBound)
        }
    }

    func testTileCeilingReachesTheRateATilePanelCanAbsorb() {
        // The band-derived ceiling is aimed at a different protocol, and on
        // this panel it makes the collapse region inescapable. 466 bands at
        // 5 fps is 2330 pkt/s, one every 429us - and a tile panel absorbs
        // ~300/s while still painting (docs section 17.3). So the controller
        // could not offer less than ~8x what the panel can use, and was
        // observed parked exactly at 429us in the app log.
        let bandCeiling = FrameSender.spacingBounds(
            for: PanelGeometry(width: 466, height: 466)).upperBound
        XCTAssertEqual(bandCeiling, 429)
        let offeredAtBandCeiling = 1_000_000 / bandCeiling
        XCTAssertEqual(offeredAtBandCeiling, 2331)
        XCTAssertGreaterThan(
            offeredAtBandCeiling,
            FrameSender.tileAbsorbablePacketsPerSecond * 7,
            "the band bound must be shown to be the problem, not a near miss")

        // The tile ceiling expresses the measured rate: 300/s is 3333us.
        XCTAssertEqual(FrameSender.tileSpacingCeiling, 3333)
        XCTAssertEqual(
            1_000_000 / FrameSender.tileSpacingCeiling,
            FrameSender.tileAbsorbablePacketsPerSecond)
        XCTAssertGreaterThan(FrameSender.tileSpacingCeiling, bandCeiling)
    }

    func testTileCeilingIsExpressibleAndNeverTightensABandPanel() {
        // The manual range has to be able to express it, or the settings
        // slider and setSpacingMicros would clamp the controller's own
        // ceiling away.
        XCTAssertLessThanOrEqual(
            FrameSender.tileSpacingCeiling, FrameSender.spacingRange.upperBound)
        XCTAssertGreaterThanOrEqual(
            FrameSender.tileSpacingCeiling, FrameSender.spacingRange.lowerBound)

        // Band panels are untouched: the tile ceiling only ever widens, and
        // only where the tile protocol is actually in use. The 172x320's
        // band-derived ceiling is unchanged by any of this.
        XCTAssertEqual(
            FrameSender.spacingBounds(for: .panel172x320).upperBound, 2325)
    }

    func testControllerBoundsSitInsideTheManualRange() {
        // The settings slider offers spacingRange; the controller must not be
        // able to escape it, only to stop short of its slow end.
        for geometry in [PanelGeometry.panel172x320,
                         PanelGeometry(width: 466, height: 466)] {
            let bounds = FrameSender.spacingBounds(for: geometry)
            XCTAssertGreaterThanOrEqual(
                bounds.lowerBound, FrameSender.spacingRange.lowerBound)
            XCTAssertLessThanOrEqual(
                bounds.upperBound, FrameSender.spacingRange.upperBound)
        }
    }

    func testOfferedRateCap() {
        // 120us floor = ~8333 packets/s offered, the cap the fixed floor
        // always meant.
        XCTAssertEqual(FrameSender.maxOfferedPacketsPerSecond, 8333)
    }
}
