import AppKit
import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// The marquee's coordinate conversion.
///
/// A region is points down from its display's top-left; a window frame is points
/// up from the bottom-left of the whole desktop. Pure functions, so the flip is
/// tested rather than eyeballed - a mistake here does not crash or warn, it
/// silently frames the wrong strip of screen.
final class MarqueeConversionTests: XCTestCase {

    /// A display placed to the right of, and above, the desktop origin - as a
    /// second monitor is. A conversion that ignores the screen's own origin
    /// cannot pass by coincidence here.
    private let secondary = CGRect(x: 1728, y: 300, width: 1920, height: 1080)
    private let primary = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    func testRegionAtTheTopReachesTheTopOfTheScreen() {
        let region = RegionSpec(display: "S", x: 0, y: 0, width: 172, height: 320)

        let frame = RegionSelector.globalFrame(
            for: region, onScreenWithFrame: primary)

        XCTAssertEqual(frame.maxY, primary.maxY, accuracy: 0.001)
        XCTAssertEqual(frame.minX, primary.minX, accuracy: 0.001)
    }

    func testRegionAtTheBottomReachesTheBottom() {
        let region = RegionSpec(
            display: "S", x: 0, y: 1117 - 320, width: 172, height: 320)

        let frame = RegionSelector.globalFrame(
            for: region, onScreenWithFrame: primary)

        XCTAssertEqual(frame.minY, primary.minY, accuracy: 0.001)
    }

    /// The region is display-local, so the same numbers land on whichever screen
    /// they are resolved against. This is what makes dragging to a second monitor
    /// work rather than producing an off-screen rectangle.
    func testTheSameRegionResolvesOntoEitherScreen() {
        let region = RegionSpec(display: "S", x: 10, y: 20, width: 172, height: 320)

        let onPrimary = RegionSelector.globalFrame(
            for: region, onScreenWithFrame: primary)
        let onSecondary = RegionSelector.globalFrame(
            for: region, onScreenWithFrame: secondary)

        XCTAssertEqual(onPrimary.minX, 10, accuracy: 0.001)
        XCTAssertEqual(onPrimary.maxY, primary.maxY - 20, accuracy: 0.001)
        XCTAssertEqual(onSecondary.minX, 1738, accuracy: 0.001)
        XCTAssertEqual(onSecondary.maxY, secondary.maxY - 20, accuracy: 0.001)
    }

    /// The two directions must be exact inverses, or dragging would make the
    /// rectangle creep as the value round-tripped.
    func testConversionRoundTripsOnEveryScreen() {
        let cases = [
            RegionSpec(display: "S", x: 0, y: 0, width: 172, height: 320),
            RegionSpec(display: "S", x: 431.5, y: 77.25, width: 516, height: 960),
            RegionSpec(display: "S", x: 100, y: 700, width: 320, height: 172),
        ]

        for screen in [primary, secondary] {
            for region in cases {
                let frame = RegionSelector.globalFrame(
                    for: region, onScreenWithFrame: screen)
                let back = RegionSelector.region(
                    for: frame, display: "S", screenFrame: screen)

                XCTAssertEqual(back.x, region.x, accuracy: 0.001)
                XCTAssertEqual(back.y, region.y, accuracy: 0.001)
                XCTAssertEqual(back.width, region.width, accuracy: 0.001)
                XCTAssertEqual(back.height, region.height, accuracy: 0.001)
            }
        }
    }
}

/// The marquee window's configuration.
///
/// These properties are load-bearing but invisible, so nothing looks obviously
/// wrong if one is lost:
///
///  - `sharingType = .none` keeps the marquee out of the capture it is framing.
///  - the window must be exactly the rectangle. A window covering the screen was
///    a previous design and swallowed every click on the rest of the desktop,
///    leaving no way to press Done.
///  - AppKit must not move it. Its drag handling cannot reach the top of the
///    screen, which is the bug this class exists to avoid.
///  - it must accept key events, or Return and Escape do nothing.
@MainActor
final class MarqueeWindowTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func currentScreen() throws -> (name: String, screen: NSScreen) {
        guard let preferred = DisplayCapture.preferredScreen(),
            let screen = DisplayCapture.screen(named: preferred.name)
        else {
            throw XCTSkip("no named screen available in this environment")
        }
        return (preferred.name, screen)
    }

    func testWindowIsOnlyTheRectangleAndIsNotCapturable() throws {
        let (name, screen) = try currentScreen()
        let selector = RegionSelector()
        let region = RegionSpec.centered(
            on: name, geometry: nil, scale: 2, landscape: false, in: screen.frame.size)

        selector.show(region)
        defer { selector.hide() }
        guard let window = selector.window else {
            throw XCTSkip("the marquee window could not be observed here")
        }

        XCTAssertEqual(
            window.sharingType, .none,
            "the marquee must not be capturable, or it appears on the panel")
        XCTAssertEqual(window.level, .floating)
        XCTAssertFalse(window.isOpaque)
        XCTAssertFalse(window.isMovable, "AppKit must not move it; this class does")
        XCTAssertFalse(window.isMovableByWindowBackground)
        XCTAssertTrue(
            window.canBecomeKey, "Return and Escape have to reach the marquee")
        // Exactly the rectangle, so everything else on screen stays clickable.
        XCTAssertEqual(window.frame.width, region.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, region.height, accuracy: 1)
        XCTAssertLessThan(window.frame.width, screen.frame.width)
    }

    /// The bug this design exists for: a region flush to the top of the display
    /// must be placed there, not pushed down by the menu bar.
    func testRectangleReachesTheTopOfTheScreen() throws {
        let (name, screen) = try currentScreen()
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        XCTAssertGreaterThan(menuBar, 0, "expected a menu bar to be in the way")

        let selector = RegionSelector()
        selector.show(
            RegionSpec(display: name, x: 0, y: 0, width: 172, height: 320))
        defer { selector.hide() }

        let framed = try XCTUnwrap(selector.region)
        XCTAssertEqual(framed.y, 0, accuracy: 0.001)
        guard let window = selector.window else { return }
        XCTAssertEqual(window.frame.maxY, screen.frame.maxY, accuracy: 1)
    }

    func testRepeatedApplyIsStable() throws {
        let (name, screen) = try currentScreen()
        let selector = RegionSelector()
        let region = RegionSpec(display: name, x: 0, y: 0, width: 172, height: 320)

        selector.show(region)
        defer { selector.hide() }
        selector.apply(region)
        selector.apply(region)

        let framed = try XCTUnwrap(selector.region)
        XCTAssertEqual(framed.y, 0, accuracy: 0.001)
        XCTAssertEqual(framed.x, 0, accuracy: 0.001)
        let window = try XCTUnwrap(selector.window)
        XCTAssertEqual(window.frame.maxY, screen.frame.maxY, accuracy: 1)
    }

    func testRotatingSwapsTheFramedShape() throws {
        let (name, screen) = try currentScreen()
        let selector = RegionSelector()
        let portrait = RegionSpec.centered(
            on: name, geometry: nil, scale: 1, landscape: false, in: screen.frame.size)

        selector.show(portrait)
        defer { selector.hide() }
        selector.apply(portrait.rotated(in: screen.frame.size))

        XCTAssertEqual(selector.region?.isLandscape, true)
        XCTAssertGreaterThan(
            selector.window?.frame.width ?? 0, selector.window?.frame.height ?? 0)
    }
}

/// The Done and Cancel buttons drawn inside the rectangle.
///
/// Drawing and hit testing both come from `actionZones`, so a button that is
/// visible in one place and clickable in another is impossible by construction -
/// which is exactly how they went wrong the first time, when the labels were
/// drawn but never hit-tested at all.
final class MarqueeActionZoneTests: XCTestCase {

    func testButtonsSitInsideTheRectangleAndDoNotOverlap() throws {
        let bounds = CGRect(x: 0, y: 0, width: 344, height: 640)

        let zones = try XCTUnwrap(RegionSelector.actionZones(in: bounds))

        XCTAssertTrue(bounds.contains(zones.done), "Done escaped the rectangle")
        XCTAssertTrue(bounds.contains(zones.cancel), "Cancel escaped the rectangle")
        XCTAssertFalse(
            zones.done.intersects(zones.cancel),
            "overlapping buttons would make one unclickable")
    }

    func testButtonsAreCentredTogether() throws {
        let bounds = CGRect(x: 0, y: 0, width: 344, height: 640)

        let zones = try XCTUnwrap(RegionSelector.actionZones(in: bounds))

        let combined = zones.done.union(zones.cancel)
        XCTAssertEqual(combined.midX, bounds.midX, accuracy: 0.001)
    }

    /// A 1x region is 172x320, which is narrow. Buttons that do not fit must be
    /// omitted rather than drawn hanging over the edges - the keyboard and the
    /// window's own Done button still work.
    func testButtonsAreOmittedWhenTheyCannotFit() {
        XCTAssertNil(
            RegionSelector.actionZones(in: CGRect(x: 0, y: 0, width: 120, height: 400)),
            "too narrow")
        XCTAssertNil(
            RegionSelector.actionZones(in: CGRect(x: 0, y: 0, width: 400, height: 40)),
            "too short")
    }

    /// The zones are relative to the rectangle, so they follow it around the
    /// screen rather than being pinned to an origin.
    func testZonesFollowTheRectangle() throws {
        let moved = CGRect(x: 900, y: 400, width: 344, height: 640)

        let zones = try XCTUnwrap(RegionSelector.actionZones(in: moved))

        XCTAssertTrue(moved.contains(zones.done))
        XCTAssertTrue(moved.contains(zones.cancel))
    }
}

/// Which part of the marquee the pointer is over.
///
/// Three things read this classifier: what a click does, which cursor is shown,
/// and where the corner brackets are drawn. They are tested together because the
/// failure mode is not a crash - it is a pointer that promises a resize over a
/// spot that actually moves the rectangle.
final class MarqueeZoneTests: XCTestCase {

    /// A 2x region: wide enough for the buttons to be present.
    private let bounds = CGRect(x: 0, y: 0, width: 344, height: 640)

    func testCornersWinOverTheSidesTheyMeet() {
        XCTAssertEqual(
            RegionSelector.zone(at: CGPoint(x: 5, y: 5), in: bounds),
            .handle(.corner(.bottomLeft)))
        XCTAssertEqual(
            RegionSelector.zone(at: CGPoint(x: 339, y: 635), in: bounds),
            .handle(.corner(.topRight)))

        // Not merely a priority ordering: the side bands are trimmed so they do
        // not reach into the corners at all.
        let left = RegionSelector.zoneRects(in: bounds)
            .first { $0.zone == .handle(.edge(.left)) }
        XCTAssertFalse(
            left?.rect.contains(CGPoint(x: 5, y: 5)) ?? true,
            "the left band reached into the bottom-left corner")
    }

    func testSidesResizeAndTheMiddleMoves() {
        XCTAssertEqual(
            RegionSelector.zone(at: CGPoint(x: 2, y: 320), in: bounds),
            .handle(.edge(.left)))
        XCTAssertEqual(
            RegionSelector.zone(at: CGPoint(x: 342, y: 320), in: bounds),
            .handle(.edge(.right)))
        XCTAssertEqual(
            RegionSelector.zone(at: CGPoint(x: 172, y: 3), in: bounds),
            .handle(.edge(.bottom)))
        XCTAssertEqual(
            RegionSelector.zone(at: CGPoint(x: 172, y: 637), in: bounds),
            .handle(.edge(.top)))
        XCTAssertEqual(
            RegionSelector.zone(at: CGPoint(x: 172, y: 320), in: bounds),
            .interior,
            "the centre must still move the rectangle")
    }

    func testButtonsWinOverEverything() throws {
        let zones = try XCTUnwrap(RegionSelector.actionZones(in: bounds))

        XCTAssertEqual(
            RegionSelector.zone(
                at: CGPoint(x: zones.done.midX, y: zones.done.midY), in: bounds),
            .done)
        XCTAssertEqual(
            RegionSelector.zone(
                at: CGPoint(x: zones.cancel.midX, y: zones.cancel.midY), in: bounds),
            .cancel)
    }

    /// Overlapping zones would make one of them unreachable.
    func testZonesNeverOverlap() {
        let rects = RegionSelector.zoneRects(in: bounds)
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] {
                XCTAssertFalse(
                    a.rect.intersects(b.rect),
                    "\(a.zone) overlaps \(b.zone)")
            }
        }
    }

    /// The tie between the cursor and the click: a cursor rectangle is added for
    /// every entry here, so every entry must classify as itself.
    func testEveryZoneRectClassifiesAsItself() {
        for entry in RegionSelector.zoneRects(in: bounds) {
            let centre = CGPoint(x: entry.rect.midX, y: entry.rect.midY)
            XCTAssertEqual(
                RegionSelector.zone(at: centre, in: bounds), entry.zone,
                "cursor would disagree with the click at \(entry.zone)")
        }
    }

    /// At 1x the rectangle is only 172pt wide, so the zones have to shrink to fit
    /// rather than swallow the whole thing.
    func testAllEightHandlesSurviveAtOneTimesScale() {
        let small = CGRect(x: 0, y: 0, width: 172, height: 320)

        let rects = RegionSelector.zoneRects(in: small)

        XCTAssertEqual(rects.count, 8, "a handle was dropped at 1x")
        XCTAssertEqual(
            RegionSelector.zone(at: CGPoint(x: 86, y: 160), in: small), .interior)
        for entry in rects {
            XCTAssertTrue(small.contains(entry.rect), "\(entry.zone) escaped")
        }
    }
}

/// Resizing, which is aspect-locked because the panel's shape is fixed.
///
/// The lock is what makes an edge drag interesting: it cannot just move the side
/// you grabbed, so the opposite side anchors and the rectangle grows about the
/// perpendicular centre line.
final class MarqueeResizeTests: XCTestCase {

    private let start = CGRect(x: 100, y: 100, width: 172, height: 320)
    private let aspect = CGSize(width: 172, height: 320)
    private var ratio: CGFloat { 320.0 / 172.0 }

    private func assertAspectHeld(_ rect: CGRect, _ message: String = "") {
        XCTAssertEqual(
            rect.height / rect.width, ratio, accuracy: 0.0001,
            "aspect ratio drifted \(message)")
    }

    func testDraggingTheLeftEdgePinsTheRightEdgeAndTheVerticalCentre() {
        let result = RegionSelector.resized(
            start, handle: .edge(.left), towards: CGPoint(x: 14, y: 260),
            aspect: aspect)

        XCTAssertEqual(result.maxX, start.maxX, accuracy: 0.0001, "right edge moved")
        XCTAssertEqual(result.midY, start.midY, accuracy: 0.0001, "drifted vertically")
        XCTAssertEqual(result.minX, 14, accuracy: 0.0001)
        assertAspectHeld(result)
    }

    func testDraggingTheRightEdgePinsTheLeftEdge() {
        let result = RegionSelector.resized(
            start, handle: .edge(.right), towards: CGPoint(x: 500, y: 260),
            aspect: aspect)

        XCTAssertEqual(result.minX, start.minX, accuracy: 0.0001, "left edge moved")
        XCTAssertEqual(result.midY, start.midY, accuracy: 0.0001)
        XCTAssertEqual(result.maxX, 500, accuracy: 0.0001)
        assertAspectHeld(result)
    }

    func testDraggingTheTopEdgePinsTheBottomEdgeAndTheHorizontalCentre() {
        let result = RegionSelector.resized(
            start, handle: .edge(.top), towards: CGPoint(x: 186, y: 580),
            aspect: aspect)

        XCTAssertEqual(result.minY, start.minY, accuracy: 0.0001, "bottom edge moved")
        XCTAssertEqual(result.midX, start.midX, accuracy: 0.0001, "drifted sideways")
        XCTAssertEqual(result.maxY, 580, accuracy: 0.0001)
        assertAspectHeld(result)
    }

    func testDraggingTheBottomEdgePinsTheTopEdge() {
        let result = RegionSelector.resized(
            start, handle: .edge(.bottom), towards: CGPoint(x: 186, y: -60),
            aspect: aspect)

        XCTAssertEqual(result.maxY, start.maxY, accuracy: 0.0001, "top edge moved")
        XCTAssertEqual(result.midX, start.midX, accuracy: 0.0001)
        assertAspectHeld(result)
    }

    /// A corner keeps anchoring the opposite corner - unchanged behaviour, kept
    /// under test because the corner and edge paths now share one function.
    func testDraggingACornerPinsTheOppositeCorner() {
        let result = RegionSelector.resized(
            start, handle: .corner(.bottomLeft), towards: CGPoint(x: 14, y: 20),
            aspect: aspect)

        XCTAssertEqual(result.maxX, start.maxX, accuracy: 0.0001)
        XCTAssertEqual(result.maxY, start.maxY, accuracy: 0.0001)
        assertAspectHeld(result)
    }

    /// One panel-worth is the floor. Dragging an edge past its own anchor must not
    /// invert the rectangle or collapse it to nothing.
    func testResizingCannotGoBelowOneTimesScale() {
        let floor = CGFloat(min(PixelConvert.width, PixelConvert.height))

        for handle: RegionSelector.Handle in [
            .edge(.left), .edge(.right), .edge(.top), .edge(.bottom),
            .corner(.topRight),
        ] {
            let result = RegionSelector.resized(
                start, handle: handle,
                towards: CGPoint(x: start.midX, y: start.midY), aspect: aspect)

            XCTAssertGreaterThanOrEqual(
                result.width, floor, "\(handle) collapsed below 1x")
            XCTAssertGreaterThan(result.height, 0, "\(handle) inverted")
            assertAspectHeld(result, "for \(handle)")
        }
    }
}

/// The cursor shown for each handle.
///
/// `NSCursor.FrameResizePosition` is a bitmask - a corner is literally its two
/// edges OR'd together - so these assert that relationship rather than restating
/// the mapping. A swapped corner, which is the realistic mistake and one the
/// compiler cannot catch, fails here.
final class MarqueeCursorTests: XCTestCase {

    private let all: [RegionSelector.Handle] = [
        .corner(.topLeft), .corner(.topRight),
        .corner(.bottomLeft), .corner(.bottomRight),
        .edge(.left), .edge(.right), .edge(.top), .edge(.bottom),
    ]

    private func raw(_ position: NSCursor.FrameResizePosition) -> UInt {
        position.rawValue
    }

    func testEveryHandleGetsItsOwnCursor() {
        let positions = all.map { RegionSelector.cursorPosition(for: $0).rawValue }

        XCTAssertEqual(
            Set(positions).count, all.count,
            "two handles share a cursor, so one of them points the wrong way")
    }

    func testCornersCombineTheTwoEdgesThatMeetThere() {
        let top = raw(.top), bottom = raw(.bottom)
        let left = raw(.left), right = raw(.right)

        let expected: [(RegionSelector.Handle, UInt)] = [
            (.corner(.topLeft), top | left),
            (.corner(.topRight), top | right),
            (.corner(.bottomLeft), bottom | left),
            (.corner(.bottomRight), bottom | right),
        ]
        for (handle, bits) in expected {
            XCTAssertEqual(
                raw(RegionSelector.cursorPosition(for: handle)), bits,
                "\(handle) points at the wrong diagonal")
        }
    }

    func testEachSideGetsItsOwnSingleDirection() {
        let expected: [(RegionSelector.Handle, NSCursor.FrameResizePosition)] = [
            (.edge(.left), .left), (.edge(.right), .right),
            (.edge(.top), .top), (.edge(.bottom), .bottom),
        ]
        for (handle, position) in expected {
            let mapped = RegionSelector.cursorPosition(for: handle)
            XCTAssertEqual(raw(mapped), raw(position), "\(handle) mismatched")
            // A single bit: a side is never a corner.
            XCTAssertEqual(
                raw(mapped).nonzeroBitCount, 1,
                "\(handle) resolved to a corner cursor")
        }
    }
}

/// The pointer style at a point, which is what the tracking area installs.
///
/// A value rather than an `NSCursor` precisely so it can be asserted: the view
/// only turns these into cursors, it does not decide them.
final class MarqueePointerStyleTests: XCTestCase {

    private let bounds = CGRect(x: 0, y: 0, width: 344, height: 640)

    func testTheInteriorAdvertisesThatItMoves() {
        XCTAssertEqual(
            RegionSelector.pointerStyle(at: CGPoint(x: 172, y: 320), in: bounds),
            .move)
    }

    /// A resize cursor over a button would promise something the click does not do.
    func testButtonsKeepThePlainArrow() throws {
        let zones = try XCTUnwrap(RegionSelector.actionZones(in: bounds))

        XCTAssertEqual(
            RegionSelector.pointerStyle(
                at: CGPoint(x: zones.done.midX, y: zones.done.midY), in: bounds),
            .arrow)
        XCTAssertEqual(
            RegionSelector.pointerStyle(
                at: CGPoint(x: zones.cancel.midX, y: zones.cancel.midY), in: bounds),
            .arrow)
    }

    func testHandlesGetTheMatchingResizeCursor() {
        XCTAssertEqual(
            RegionSelector.pointerStyle(at: CGPoint(x: 5, y: 5), in: bounds),
            .resize(.bottomLeft))
        XCTAssertEqual(
            RegionSelector.pointerStyle(at: CGPoint(x: 339, y: 635), in: bounds),
            .resize(.topRight))
        XCTAssertEqual(
            RegionSelector.pointerStyle(at: CGPoint(x: 2, y: 320), in: bounds),
            .resize(.left))
        XCTAssertEqual(
            RegionSelector.pointerStyle(at: CGPoint(x: 172, y: 637), in: bounds),
            .resize(.top))
    }

    /// Every point in the rectangle resolves to something, so there is no dead
    /// area where the cursor is left over from wherever it was last.
    func testEveryPointResolves() {
        for x in stride(from: 1.0, to: 344.0, by: 17.0) {
            for y in stride(from: 1.0, to: 640.0, by: 17.0) {
                let style = RegionSelector.pointerStyle(
                    at: CGPoint(x: x, y: y), in: bounds)
                // A resize style must correspond to a real handle at that point.
                if case .resize = style {
                    guard case .handle = RegionSelector.zone(
                        at: CGPoint(x: x, y: y), in: bounds) else {
                        XCTFail("resize cursor at (\(x), \(y)) with no handle there")
                        continue
                    }
                }
            }
        }
    }
}

/// The overlay's scale-preset and rotate zones. These controls exist ONLY on
/// the marquee - the manager window deliberately has no copy, because
/// adjusting a rectangle that is not on screen is meaningless - so the overlay
/// geometry is the one place they can be clickable, and it is pure.
final class MarqueePresetZoneTests: XCTestCase {

    private let roomy = CGRect(x: 0, y: 0, width: 466, height: 466)

    func testPresetRowSitsAboveDoneAndCancel() throws {
        let presets = try XCTUnwrap(
            RegionSelector.presetZones(in: roomy, includeRotate: true))
        let actions = try XCTUnwrap(RegionSelector.actionZones(in: roomy))
        XCTAssertEqual(presets.count, RegionSpec.scalePresets.count + 1)
        for entry in presets {
            XCTAssertGreaterThan(entry.rect.minY, actions.done.maxY)
            XCTAssertTrue(roomy.contains(entry.rect))
        }
    }

    func testEveryPresetZoneIsClickableWhereItIsDrawn() throws {
        // Same discipline as Done/Cancel: hit-testing reads the identical rects
        // that drawing does, asserted through the public classifier.
        let presets = try XCTUnwrap(
            RegionSelector.presetZones(in: roomy, includeRotate: true))
        for entry in presets {
            let centre = CGPoint(x: entry.rect.midX, y: entry.rect.midY)
            XCTAssertEqual(
                RegionSelector.zone(at: centre, in: roomy, includeRotate: true),
                entry.zone)
            // A button is a button, never a resize handle.
            XCTAssertEqual(
                RegionSelector.pointerStyle(
                    at: centre, in: roomy, includeRotate: true),
                .arrow)
        }
    }

    func testScaleZonesCarryTheirPresets() throws {
        let presets = try XCTUnwrap(
            RegionSelector.presetZones(in: roomy, includeRotate: true))
        let scales = presets.compactMap { entry -> Int? in
            if case .scale(let value) = entry.zone { return value }
            return nil
        }
        XCTAssertEqual(scales, RegionSpec.scalePresets)
        XCTAssertEqual(presets.last?.zone, .rotate)
    }

    func testRotateIsAbsentWhenExcluded() throws {
        // A square region's rotation swaps two equal sides - a visible no-op -
        // so the selector hides the button and the classifier must agree.
        let presets = try XCTUnwrap(
            RegionSelector.presetZones(in: roomy, includeRotate: false))
        XCTAssertFalse(presets.contains { $0.zone == .rotate })
        // The spot where rotate would be is interior again, not a dead zone.
        let withRotate = try XCTUnwrap(
            RegionSelector.presetZones(in: roomy, includeRotate: true))
        let rotateRect = try XCTUnwrap(
            withRotate.first { $0.zone == .rotate }?.rect)
        let centre = CGPoint(x: rotateRect.midX, y: rotateRect.midY)
        XCTAssertEqual(
            RegionSelector.zone(at: centre, in: roomy, includeRotate: false),
            .interior)
    }

    func testTooSmallARectangleShowsNoPresets() {
        // The floor mirrors actionZones' own: a rectangle that cannot hold the
        // row cleanly holds none of it, rather than clipping half a button.
        let tiny = CGRect(x: 0, y: 0, width: 120, height: 80)
        XCTAssertNil(RegionSelector.presetZones(in: tiny, includeRotate: true))
        // And clicks there fall through to the ordinary zones.
        XCTAssertNotEqual(
            RegionSelector.zone(
                at: CGPoint(x: 60, y: 40), in: tiny, includeRotate: true),
            .rotate)
    }

    func testPresetsNeverOverlapDoneCancelOrEachOther() throws {
        for bounds in [roomy, CGRect(x: 0, y: 0, width: 240, height: 300)] {
            guard let presets = RegionSelector.presetZones(
                in: bounds, includeRotate: true) else { continue }
            let actions = try XCTUnwrap(RegionSelector.actionZones(in: bounds))
            var rects = presets.map(\.rect)
            rects.append(actions.done)
            rects.append(actions.cancel)
            for (i, a) in rects.enumerated() {
                for b in rects.dropFirst(i + 1) {
                    XCTAssertFalse(
                        a.intersects(b),
                        "\(a) overlaps \(b) in \(bounds)")
                }
            }
        }
    }
}
