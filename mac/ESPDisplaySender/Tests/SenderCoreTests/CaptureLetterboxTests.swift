import CoreGraphics
import ScreenCaptureKit
import SenderProtocol
import XCTest

@testable import SenderCore

/// Where a source whose shape is not the frame's lands in the frame.
///
/// ScreenCaptureKit fits the source into `destinationRect`, or into the whole
/// surface when that is unset, keeping its aspect and pinning it to that
/// rectangle's top-left corner. Left unset, a wide window on the square
/// 466x466 panel filled the top of the frame with all the black below it.
final class CaptureLetterboxTests: XCTestCase {

    private let square = PanelGeometry(width: 466, height: 466)
    private let rectangular = PanelGeometry(width: 172, height: 320)

    /// Where ScreenCaptureKit puts `content` under `config`: fitted into the
    /// destination rectangle (the whole surface when unset), top-left aligned.
    private func placement(of content: CGSize, under config: SCStreamConfigurationShape)
        -> CGRect
    {
        let target = config.destination.isEmpty
            ? CGRect(x: 0, y: 0, width: config.width, height: config.height)
            : config.destination
        let fit = min(target.width / content.width, target.height / content.height)
        return CGRect(
            x: target.minX, y: target.minY,
            width: content.width * fit, height: content.height * fit)
    }

    private struct SCStreamConfigurationShape {
        let width: Int
        let height: Int
        let destination: CGRect
    }

    private func shape(
        geometry: PanelGeometry, landscape: Bool, content: CGSize, sourceRect: CGRect? = nil
    ) -> SCStreamConfigurationShape {
        let config = DisplayCapture.configuration(
            width: geometry.frameWidth(landscape: landscape),
            height: geometry.frameHeight(landscape: landscape),
            fps: 30, sourceRect: sourceRect, contentSize: content)
        return SCStreamConfigurationShape(
            width: config.width, height: config.height, destination: config.destinationRect)
    }

    private func assertCentred(
        _ content: CGSize, geometry: PanelGeometry, landscape: Bool = false,
        sourceRect: CGRect? = nil, file: StaticString = #filePath, line: UInt = #line
    ) {
        let config = shape(
            geometry: geometry, landscape: landscape, content: content, sourceRect: sourceRect)
        let placed = placement(of: content, under: config)
        let left = placed.minX
        let right = Double(config.width) - placed.maxX
        let top = placed.minY
        let bottom = Double(config.height) - placed.maxY
        XCTAssertEqual(left, right, accuracy: 1, "left/right bars differ", file: file, line: line)
        XCTAssertEqual(top, bottom, accuracy: 1, "top/bottom bars differ", file: file, line: line)
        XCTAssertGreaterThan(placed.width, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(placed.maxX, Double(config.width) + 0.5, file: file, line: line)
        XCTAssertLessThanOrEqual(placed.maxY, Double(config.height) + 0.5, file: file, line: line)
    }

    /// The reported case: a wide window on the square round panel.
    func testAWideWindowIsCentredWithEqualBarsAboveAndBelow() {
        assertCentred(CGSize(width: 1600, height: 900), geometry: square)
    }

    func testATallWindowIsCentredWithEqualBarsLeftAndRight() {
        assertCentred(CGSize(width: 700, height: 1200), geometry: square)
    }

    /// A whole display has its own shape too, and on the portrait 172x320
    /// panel even a 16:10 screen leaves bars.
    func testAWholeDisplayIsCentredOnEitherPanelShape() {
        let display = CGSize(width: 1512, height: 982)
        assertCentred(display, geometry: square)
        assertCentred(display, geometry: rectangular, landscape: false)
        assertCentred(display, geometry: rectangular, landscape: true)
    }

    /// A region dragged off the panel's shape is centred the same way, in
    /// whichever frame shape the rotation picked.
    func testAnOffShapeRegionIsCentred() {
        let rect = CGRect(x: 10, y: 20, width: 500, height: 200)
        assertCentred(rect.size, geometry: rectangular, landscape: false, sourceRect: rect)
        assertCentred(rect.size, geometry: rectangular, landscape: true, sourceRect: rect)
    }

    /// A source already the frame's shape fills it exactly.
    func testAPanelShapedSourceFillsTheFrame() {
        let config = shape(
            geometry: rectangular, landscape: true, content: CGSize(width: 640, height: 344))
        let placed = placement(of: CGSize(width: 640, height: 344), under: config)
        XCTAssertEqual(placed.minX, 0, accuracy: 0.5)
        XCTAssertEqual(placed.minY, 0, accuracy: 0.5)
        XCTAssertEqual(placed.width, 320, accuracy: 0.5)
        XCTAssertEqual(placed.height, 172, accuracy: 0.5)
    }

    /// A window resized while it streams is re-centred in place, and an
    /// unchanged size (a window only moved) sends nothing.
    func testAResizedWindowIsReCentredAndAnUnchangedOneIsLeftAlone() async {
        let capture = DisplayCapture(geometry: square, landscape: false, onFrame: { _, _ in })
        let calls = LockedBox(0)
        capture.configureForTesting = { _, _, _ in calls.update { $0 += 1 } }
        let resized = await capture.updateContentSize(CGSize(width: 1600, height: 900))
        XCTAssertTrue(resized)
        XCTAssertEqual(calls.get(), 1)
        _ = await capture.updateContentSize(CGSize(width: 1600, height: 900))
        XCTAssertEqual(calls.get(), 1, "an unchanged size reconfigured the stream")
    }

    /// A rotation that changes the frame shape keeps the content, and places
    /// it centred in the new shape.
    func testAReshapeReCentresTheContentInTheNewFrameShape() async {
        let capture = DisplayCapture(geometry: rectangular, landscape: false, onFrame: { _, _ in })
        capture.configureForTesting = { _, _, _ in }
        let content = CGSize(width: 1600, height: 900)
        _ = await capture.updateContentSize(content)
        _ = await capture.reshape(landscape: true)
        XCTAssertEqual(
            capture.destinationForTesting,
            DisplayCapture.letterbox(content: content, width: 320, height: 172))
    }

    /// A re-centre ScreenCaptureKit refuses keeps the old placement without
    /// rebuilding the stream, and the next look at the window asks again.
    func testARefusedReCentreIsAskedForAgain() async {
        struct Refused: Error {}
        let capture = DisplayCapture(geometry: square, landscape: false, onFrame: { _, _ in })
        let calls = LockedBox(0)
        capture.configureForTesting = { _, _, _ in calls.update { $0 += 1 } }
        let wide = CGSize(width: 1600, height: 900)
        _ = await capture.updateContentSize(wide)
        capture.configureForTesting = { _, _, _ in
            calls.update { $0 += 1 }
            throw Refused()
        }
        let tall = CGSize(width: 700, height: 1200)
        let applied = await capture.updateContentSize(tall)
        XCTAssertFalse(applied)
        XCTAssertEqual(
            capture.destinationForTesting,
            DisplayCapture.letterbox(content: wide, width: 466, height: 466))
        XCTAssertFalse(capture.stopped, "a content-only refusal rebuilt the stream")
        _ = await capture.updateContentSize(tall)
        XCTAssertEqual(calls.get(), 3, "the refused size was not asked for again")
    }
}

/// Live re-centring for a picker selection, which the session must not
/// restart: a stream started from a picked filter cannot reliably be recreated.
final class PickedDisplayFollowTests: XCTestCase {

    private let square = PanelGeometry(width: 466, height: 466)

    /// A picked display (or an application share, which is shown on its
    /// display) whose resolution changes shape is re-centred in place.
    func testAPickedDisplayThatChangesResolutionIsReCentred() async {
        let capture = DisplayCapture(geometry: square, landscape: false, onFrame: { _, _ in })
        capture.configureForTesting = { _, _, _ in }
        _ = await capture.updateContentSize(CGSize(width: 1512, height: 982))
        let looked = LockedBox<[CGDirectDisplayID]>([])
        await DeviceSession.followPickedDisplay(capture, displayID: 7) { id in
            looked.update { $0.append(id) }
            return CGSize(width: 1024, height: 768)
        }
        XCTAssertEqual(looked.get(), [7])
        XCTAssertEqual(
            capture.destinationForTesting,
            DisplayCapture.letterbox(
                content: CGSize(width: 1024, height: 768), width: 466, height: 466))
    }

    /// Which picks the watchdog follows by display: a picked display or
    /// application share, never a picked window (that follows the window), and
    /// nothing without a selection or a display to look up.
    func testOnlyAPickedDisplayOrApplicationShareIsFollowedByItsDisplay() {
        XCTAssertEqual(
            DeviceSession.pickedDisplayToFollow(
                pickerSelected: true, windowTracked: false, displayID: 7), 7)
        XCTAssertNil(
            DeviceSession.pickedDisplayToFollow(
                pickerSelected: true, windowTracked: true, displayID: 7))
        XCTAssertNil(
            DeviceSession.pickedDisplayToFollow(
                pickerSelected: false, windowTracked: false, displayID: 7))
        XCTAssertNil(
            DeviceSession.pickedDisplayToFollow(
                pickerSelected: true, windowTracked: false, displayID: nil))
    }

    /// The live display lookup answers a real display's size in points and
    /// nil for an ID that is not attached.
    func testTheDisplaySizeLookupAnswersOnlyForAnAttachedDisplay() {
        XCTAssertNil(DeviceSession.displayPointSize(0xDEAD_BEEF))
        let main = CGMainDisplayID()
        if let size = DeviceSession.displayPointSize(main) {
            XCTAssertEqual(size, CGDisplayBounds(main).size)
        }
    }

    /// A display that keeps its shape, or a lookup that fails, sends nothing.
    func testAnUnchangedOrUnknownDisplayLeavesTheStreamAlone() async {
        let capture = DisplayCapture(geometry: square, landscape: false, onFrame: { _, _ in })
        let calls = LockedBox(0)
        capture.configureForTesting = { _, _, _ in calls.update { $0 += 1 } }
        _ = await capture.updateContentSize(CGSize(width: 1512, height: 982))
        await DeviceSession.followPickedDisplay(capture, displayID: 7) { _ in
            CGSize(width: 1512, height: 982)
        }
        await DeviceSession.followPickedDisplay(capture, displayID: 7) { _ in nil }
        XCTAssertEqual(calls.get(), 1)
    }
}

/// The stream reference is touched by the supervisor, the preview's window
/// poll and region drags from different tasks at once. Run under
/// ThreadSanitizer (`swift test --sanitize=thread`) to check it; without it
/// this only exercises the same paths.
final class CaptureStreamRaceTests: XCTestCase {

    func testStoppingWhileReconfiguringIsNotADataRace() async {
        let capture = DisplayCapture(
            geometry: PanelGeometry(width: 466, height: 466), landscape: false,
            onFrame: { _, _ in })
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    if i % 2 == 0 {
                        await capture.stop()
                    } else {
                        _ = await capture.updateContentSize(
                            CGSize(width: 1000 + i, height: 700))
                        _ = await capture.retarget(
                            to: SCContentFilter())
                    }
                }
            }
        }
        // The assertion here is ThreadSanitizer's: there is no stream, so the
        // calls themselves have nothing to apply.
    }
}
