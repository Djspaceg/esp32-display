import CoreGraphics
import XCTest
@testable import SenderCore
@testable import SenderProtocol

// The region-to-view coordinate flip now lives with the marquee overlay; see
// MarqueeConversionTests in RegionSelectorTests.swift. The window-frame
// conversion it replaced is gone, along with the window that needed it.

/// Clamping, presets, and orientation.
final class RegionPresetTests: XCTestCase {
    private let displaySize = CGSize(width: 1920, height: 1080)

    func testPresetsArePanelMultiples() {
        XCTAssertEqual(
            RegionSpec.panelSize(scale: 1, landscape: false),
            CGSize(width: 172, height: 320))
        XCTAssertEqual(
            RegionSpec.panelSize(scale: 3, landscape: false),
            CGSize(width: 516, height: 960))
        XCTAssertEqual(
            RegionSpec.panelSize(scale: 2, landscape: true),
            CGSize(width: 640, height: 344))
    }

    func testCenteredRegionIsCentered() {
        let region = RegionSpec.centered(
            on: "S", scale: 1, landscape: false, in: displaySize)

        XCTAssertEqual(region.x + region.width / 2, 960, accuracy: 0.001)
        XCTAssertEqual(region.y + region.height / 2, 540, accuracy: 0.001)
    }

    /// Presets behave like a zoom, not a jump: whatever was framed stays framed.
    func testScalingKeepsTheCentre() {
        let region = RegionSpec(display: "S", x: 400, y: 300, width: 172, height: 320)
        let centreX = region.x + region.width / 2
        let centreY = region.y + region.height / 2

        let scaled = region.scaled(to: 2, in: displaySize)

        XCTAssertEqual(scaled.x + scaled.width / 2, centreX, accuracy: 0.001)
        XCTAssertEqual(scaled.y + scaled.height / 2, centreY, accuracy: 0.001)
        XCTAssertEqual(scaled.width, 344, accuracy: 0.001)
        XCTAssertEqual(scaled.height, 640, accuracy: 0.001)
    }

    func testRotationSwapsTheSides() {
        let region = RegionSpec(display: "S", x: 100, y: 100, width: 172, height: 320)

        let rotated = region.rotated(in: displaySize)

        XCTAssertEqual(rotated.width, 320, accuracy: 0.001)
        XCTAssertEqual(rotated.height, 172, accuracy: 0.001)
        XCTAssertTrue(rotated.isLandscape)
    }

    /// A stored region outlives the display geometry it was drawn on. An
    /// unclamped rectangle hanging off the edge makes ScreenCaptureKit produce
    /// nothing, which looks exactly like the panel having died.
    func testRegionIsPulledBackInsideTheDisplay() {
        let region = RegionSpec(display: "S", x: 1900, y: 1000, width: 344, height: 640)

        let clamped = region.clamped(to: displaySize)

        XCTAssertGreaterThanOrEqual(clamped.x, 0)
        XCTAssertGreaterThanOrEqual(clamped.y, 0)
        XCTAssertLessThanOrEqual(clamped.x + clamped.width, displaySize.width + 0.001)
        XCTAssertLessThanOrEqual(clamped.y + clamped.height, displaySize.height + 0.001)
    }

    /// Shrinking is uniform. Clamping each side independently used to distort the
    /// rectangle - a too-wide region lost width but kept its height - and the
    /// marquee then re-locked its aspect ratio to the distorted shape, so the
    /// outline stopped matching the panel it was supposed to represent.
    func testRegionLargerThanTheDisplayKeepsItsShape() {
        let region = RegionSpec(display: "S", x: 0, y: 0, width: 4000, height: 4000)

        let clamped = region.clamped(to: displaySize)

        XCTAssertEqual(clamped.width / clamped.height, 1, accuracy: 0.001)
        XCTAssertLessThanOrEqual(clamped.width, displaySize.width + 0.001)
        XCTAssertLessThanOrEqual(clamped.height, displaySize.height + 0.001)
    }

    func testClampingNeverChangesTheAspectRatio() {
        let shapes = [
            RegionSpec.panelSize(scale: 1, landscape: false),
            RegionSpec.panelSize(scale: 3, landscape: false),
            RegionSpec.panelSize(scale: 3, landscape: true),
        ]

        for size in shapes {
            // Deliberately hanging off the top-left and the bottom-right.
            for origin in [CGPoint(x: -500, y: -500), CGPoint(x: 1900, y: 1000)] {
                let region = RegionSpec(
                    display: "S", x: origin.x, y: origin.y,
                    width: size.width, height: size.height)

                let clamped = region.clamped(to: displaySize)

                XCTAssertEqual(
                    clamped.width / clamped.height, size.width / size.height,
                    accuracy: 0.001,
                    "\(size) at \(origin) was distorted by clamping")
            }
        }
    }

    func testMatchingScaleIdentifiesThePreset() {
        let oneX = RegionSpec.centered(
            on: "S", scale: 1, landscape: false, in: displaySize)
        let threeX = RegionSpec.centered(
            on: "S", scale: 3, landscape: false, in: displaySize)
        let odd = RegionSpec(display: "S", x: 0, y: 0, width: 200, height: 400)

        XCTAssertEqual(oneX.matchingScale, 1)
        XCTAssertEqual(threeX.matchingScale, 3)
        XCTAssertNil(odd.matchingScale)
    }
}
