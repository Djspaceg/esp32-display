import XCTest
@testable import SenderCore

/// The one-third / two-thirds row split.
///
/// Pure arithmetic, and the only part of the layout that can be checked without
/// looking at it. It matters that the two halves plus the gap add back up to the
/// row: a measuring pass and a placing pass that disagree by the spacing is
/// exactly how a column drifts out of alignment down a long form.
final class LabelColumnLayoutTests: XCTestCase {

    func testLabelTakesOneThirdOfWhatIsLeftAfterTheGap() {
        let layout = LabelColumnLayout(labelFraction: 1.0 / 3.0, spacing: 12)

        let widths = layout.widths(for: 312)

        // 312 - 12 of spacing = 300 usable, split 100 / 200.
        XCTAssertEqual(widths.label, 100, accuracy: 0.001)
        XCTAssertEqual(widths.content, 200, accuracy: 0.001)
    }

    func testHalvesAndGapReconstructTheRow() {
        let layout = LabelColumnLayout()

        for total in [200.0, 320.0, 640.0, 741.5, 1200.0] as [CGFloat] {
            let widths = layout.widths(for: total)
            XCTAssertEqual(
                widths.label + widths.content + layout.spacing, total, accuracy: 0.001,
                "row of \(total) did not add back up")
        }
    }

    func testFractionIsHonoured() {
        let layout = LabelColumnLayout(labelFraction: 0.25, spacing: 0)

        let widths = layout.widths(for: 400)

        XCTAssertEqual(widths.label, 100, accuracy: 0.001)
        XCTAssertEqual(widths.content, 300, accuracy: 0.001)
    }

    /// A row narrower than its own spacing happens transiently while a window is
    /// being sized. Negative widths would trap in `place`.
    func testDegenerateWidthsStayNonNegative() {
        let layout = LabelColumnLayout(labelFraction: 1.0 / 3.0, spacing: 12)

        for total in [0.0, 4.0, 12.0] as [CGFloat] {
            let widths = layout.widths(for: total)
            XCTAssertGreaterThanOrEqual(widths.label, 0, "label at \(total)")
            XCTAssertGreaterThanOrEqual(widths.content, 0, "content at \(total)")
        }
    }
}
