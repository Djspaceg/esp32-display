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
