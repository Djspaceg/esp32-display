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

/// The degradation ladder's three thresholds, which decide when the tile
/// stream sheds colour precision (rung a), then resolution (rung b), then
/// whole frames (rung c).
///
/// None of these had a test before: the ladder shipped in phase 5, gained
/// rung (b) in phase 11, and both times its behaviour was only ever observed
/// indirectly through hardware frame rates. The engagement POINT is pure
/// arithmetic and belongs here; whether the resulting picture is acceptable
/// to look at is the part that still needs eyes on the panel.
final class FrameSenderLadderTests: XCTestCase {
    /// Tiles that exactly fill the per-frame budget at a given pacing, for a
    /// given per-tile estimate. Computed independently of the ladder so an
    /// arithmetic mutation in either fails.
    private func tilesAtBudget(spacing: UInt32, bytesPerTile: Int) -> Int {
        let bytesPerSecond = 1_472.0 * 1_000_000.0 / Double(spacing)
        let budget = Int(bytesPerSecond / FrameSender.degradeTargetFps)
        return budget / bytesPerTile
    }

    func testNothingEngagesWhileTheFrameFitsItsBudget() {
        // Light content is the common case and must pay nothing: at 200us
        // pacing the budget is ~245 KB a frame, so a handful of dirty tiles
        // is nowhere near any rung. This is the state the panel was measured
        // in at 57 fps.
        let rungs = FrameSender.degradationRungs(
            dirtyTiles: 20, spacingMicros: 200, policy: .auto,
            halfResAvailable: true)
        XCTAssertFalse(rungs.forceLossy)
        XCTAssertFalse(rungs.forceHalfRes)
        XCTAssertFalse(rungs.skipNextFrame)
    }

    func testRungsEngageInOrderAsDirtyAreaGrows() {
        let spacing: UInt32 = 200
        let rawLimit = tilesAtBudget(
            spacing: spacing, bytesPerTile: FrameSender.rawBytesPerTile)
        let bc1Limit = tilesAtBudget(
            spacing: spacing, bytesPerTile: FrameSender.bc1BytesPerTile)
        let halfLimit = tilesAtBudget(
            spacing: spacing, bytesPerTile: FrameSender.halfResBytesPerTile)
        // Each rung's threshold is ~4x the previous, because each codec is a
        // quarter of the one above it. Not EXACTLY 4x: the budget is not a
        // multiple of every per-tile size, so integer division leaves a couple
        // of tiles of slack (7666 against 7664 here).
        XCTAssertEqual(bc1Limit / rawLimit, 4)
        XCTAssertEqual(halfLimit / rawLimit, 16)
        XCTAssertLessThan(bc1Limit - rawLimit * 4, 8)

        // "lossy/half/skip" as three flags, so a failure names which rung
        // moved rather than just that something did.
        func rungs(_ tiles: Int) -> String {
            let r = FrameSender.degradationRungs(
                dirtyTiles: tiles, spacingMicros: spacing, policy: .auto,
                halfResAvailable: true)
            return "\(r.forceLossy ? "L" : "-")\(r.forceHalfRes ? "H" : "-")"
                + "\(r.skipNextFrame ? "S" : "-")"
        }
        // Just inside the lossless budget: nothing engages.
        XCTAssertEqual(rungs(rawLimit), "---")
        // Past it: BC1 is forced, and BC1 alone still fits.
        XCTAssertEqual(rungs(rawLimit + 1), "L--")
        // Past what all-BC1 can carry: resolution goes too, and half-res fits.
        XCTAssertEqual(rungs(bc1Limit + 1), "LH-")
        // Past what even half-res can carry: frames start being skipped.
        XCTAssertEqual(rungs(halfLimit + 1), "LHS")
    }

    func testRungBNeedsThePanelToHaveAdvertisedHalfRes() {
        // Codec 3 sent to tile firmware that predates it loses whole
        // datagrams, so an unadvertised panel must fall through rung (b) to
        // frame skipping instead - a worse picture, but not a worse outage.
        let tiles = tilesAtBudget(
            spacing: 200, bytesPerTile: FrameSender.bc1BytesPerTile) + 1
        let withHalf = FrameSender.degradationRungs(
            dirtyTiles: tiles, spacingMicros: 200, policy: .auto,
            halfResAvailable: true)
        XCTAssertTrue(withHalf.forceHalfRes)
        XCTAssertFalse(withHalf.skipNextFrame)

        let without = FrameSender.degradationRungs(
            dirtyTiles: tiles, spacingMicros: 200, policy: .auto,
            halfResAvailable: false)
        XCTAssertFalse(without.forceHalfRes)
        XCTAssertTrue(without.skipNextFrame)
    }

    func testLosslessOnlyRefusesBothCodecRungs() {
        // The user asked for pixel-perfect. Neither colour precision nor
        // resolution may be traded away, so an over-budget frame can only be
        // answered by sending fewer frames.
        let tiles = tilesAtBudget(
            spacing: 200, bytesPerTile: FrameSender.halfResBytesPerTile) + 1
        let rungs = FrameSender.degradationRungs(
            dirtyTiles: tiles, spacingMicros: 200, policy: .losslessOnly,
            halfResAvailable: true)
        XCTAssertFalse(rungs.forceLossy)
        XCTAssertFalse(rungs.forceHalfRes)
        XCTAssertTrue(rungs.skipNextFrame)
    }

    func testAggressiveNeedsNoPushIntoBc1ButStillTakesHalfRes() {
        // .aggressive already lets BC1 win on size alone, so rung (a) is
        // meaningless for it - but rung (b) is a frame-level decision the
        // per-run codec choice cannot make, so it still applies.
        let tiles = tilesAtBudget(
            spacing: 200, bytesPerTile: FrameSender.bc1BytesPerTile) + 1
        let rungs = FrameSender.degradationRungs(
            dirtyTiles: tiles, spacingMicros: 200, policy: .aggressive,
            halfResAvailable: true)
        XCTAssertFalse(rungs.forceLossy)
        XCTAssertTrue(rungs.forceHalfRes)
    }

    func testLooserPacingShrinksTheBudgetAndEngagesRungsSooner() {
        // The ladder's budget is derived FROM pacing, so the wider tile
        // ceiling (section 17.12) makes it stricter, not laxer: at 3333us the
        // budget is ~16x smaller than at 200us, and a frame that fit before
        // now needs help. Worth pinning because it is counterintuitive - the
        // sender slowing down makes the ladder work harder.
        let tiles = 200
        let tight = FrameSender.degradationRungs(
            dirtyTiles: tiles, spacingMicros: 200, policy: .auto,
            halfResAvailable: true)
        XCTAssertFalse(tight.forceLossy)
        let loose = FrameSender.degradationRungs(
            dirtyTiles: tiles, spacingMicros: FrameSender.tileSpacingCeiling,
            policy: .auto, halfResAvailable: true)
        XCTAssertTrue(loose.forceLossy)
        XCTAssertTrue(loose.forceHalfRes)
    }

    func testAFullFrameOfMotionAtTightPacingNeedsOnlyBc1() {
        // Every visible tile of the round mask dirty at once, at the tight
        // pacing the sender uses on light content. The budget is ~123 KB a
        // frame there, and 719 BC1 tiles are 92 KB - so full resolution still
        // fits and rung (b) correctly stays out. Pinned because it is the
        // case one would GUESS engages half-res, and it does not: dirty area
        // alone never decides, only dirty area against the current pacing.
        let rungs = FrameSender.degradationRungs(
            dirtyTiles: 719, spacingMicros: 400, policy: .auto,
            halfResAvailable: true)
        XCTAssertTrue(rungs.forceLossy)
        XCTAssertFalse(rungs.forceHalfRes)
        XCTAssertFalse(rungs.skipNextFrame)
    }

    func testAFullFrameAtTheAbsorbableRateEngagesEveryRung() {
        // The same frame once the climb has backed off to what the panel can
        // actually absorb (section 17.12): the budget is ~14.7 KB, so 92 KB of
        // BC1 is hopeless and even 23 KB of half-res does not fit 30 fps.
        // Every rung engages, including frame skipping.
        let rungs = FrameSender.degradationRungs(
            dirtyTiles: 719, spacingMicros: FrameSender.tileSpacingCeiling,
            policy: .auto, halfResAvailable: true)
        XCTAssertTrue(rungs.forceLossy)
        XCTAssertTrue(rungs.forceHalfRes)
        XCTAssertTrue(rungs.skipNextFrame)

        // And that lands where the hardware landed, which is the useful part.
        // Skipping every other frame halves the ladder's 30 fps target to 15;
        // section 17.7 measured the peak at 14.2 displayed. The ladder's
        // arithmetic and the panel's behaviour agree without having been
        // fitted to each other.
        XCTAssertEqual(FrameSender.degradeTargetFps / 2, 15.0)
    }
}
