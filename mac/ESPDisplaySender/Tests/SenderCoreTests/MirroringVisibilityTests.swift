import CoreGraphics
import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// A capture failure has to survive contact with the device heartbeats.
///
/// This is the regression that made a dropped mirror impossible to diagnose:
/// every status tick and every heartbeat set `lastError = nil`, so the only
/// channel a capture problem could have used was wiped within five seconds -
/// and the panel kept answering perfectly well while receiving nothing, so
/// every other indicator in the window said "Online".
@MainActor
final class CaptureStatusReportingTests: XCTestCase {

    private func manager() -> PanelManager {
        PanelManager(previewPanels: [], savedNetworkNames: [], usbSerialPorts: [])
    }

    private func status(
        capture: CaptureStatus,
        parked: Bool = false,
        paused: Bool = false,
        lastFrameAt: Date? = Date(),
        serviceName: String = "studio-display"
    ) -> DeviceSession.Status {
        DeviceSession.Status(
            serviceName: serviceName,
            displayFPS: 39.5,
            framesSent: 1_000,
            sendErrors: 0,
            diffPercent: 12,
            heartbeatAge: 0.5,
            stats: BandProtocol.DeviceStats(shown: 990, heap: 180_000),
            info: nil,
            resolvedAddress: "192.168.1.42",
            spacingMicros: 200,
            paused: paused,
            parked: parked,
            sourceDescription: "A window (900x600)",
            landscape: false,
            captureStatus: capture,
            lastFrameAt: lastFrameAt,
            updatedAt: Date())
    }

    func testCaptureFailureReachesThePanel() {
        let manager = manager()

        manager.update(status(capture: .failed("The window has closed.")))

        XCTAssertEqual(
            manager.panels.first?.captureStatus, .failed("The window has closed."))
    }

    /// The heartbeat path clears `lastError` by design - the device is plainly
    /// reachable. It must not take the capture state with it.
    func testHeartbeatDoesNotClearACaptureFailure() {
        let manager = manager()
        manager.update(status(capture: .failed("The window has closed.")))

        manager.update(
            .heartbeat(BandProtocol.DeviceStats(shown: 1_000, heap: 180_000)),
            for: "studio-display")

        XCTAssertEqual(
            manager.panels.first?.captureStatus, .failed("The window has closed."))
    }

    /// A status tick with no capture problem is what clears it, because that
    /// tick is the sender saying frames are flowing again.
    func testRecoveryClearsTheFailure() {
        let manager = manager()
        manager.update(status(capture: .failed("The window has closed.")))

        manager.update(status(capture: .streaming))

        XCTAssertEqual(manager.panels.first?.captureStatus, .streaming)
    }

    func testRetiredSessionReportsThatNothingIsBeingSent() {
        let manager = manager()
        manager.update(status(capture: .streaming))

        manager.retire("studio-display")

        XCTAssertTrue(
            manager.panels.first?.captureStatus.needsAttention ?? false,
            "a display with no session is not mirroring anything")
    }

    /// Only a genuine dead end earns the warning triangle. Streams are
    /// restarted routinely, and flagging every restart would teach the user to
    /// ignore the indicator.
    func testOnlyFailuresAskForAttention() {
        XCTAssertTrue(CaptureStatus.failed("gone").needsAttention)
        XCTAssertFalse(CaptureStatus.streaming.needsAttention)
        XCTAssertFalse(CaptureStatus.recovering("reconnecting").needsAttention)
        XCTAssertFalse(CaptureStatus.waiting("looking").needsAttention)
        XCTAssertFalse(CaptureStatus.suspended("paused").needsAttention)
    }

    func testOnlyStreamingCountsAsStreaming() {
        XCTAssertTrue(CaptureStatus.streaming.isStreaming)
        XCTAssertFalse(CaptureStatus.recovering("reconnecting").isStreaming)
        XCTAssertFalse(CaptureStatus.failed("gone").isStreaming)
    }
}

/// The frame-age line, which is what separates "mirroring stopped" from "the
/// window is simply not changing".
final class FrameAgeDescriptionTests: XCTestCase {

    private func panel(lastFrameAt: Date?) -> PanelSnapshot {
        var panel = PanelSnapshot(serviceName: "p", displayName: "p")
        panel.lastFrameAt = lastFrameAt
        return panel
    }

    func testNoFrameYet() {
        XCTAssertEqual(panel(lastFrameAt: nil).frameAgeDescription, "No frames yet")
        XCTAssertNil(panel(lastFrameAt: nil).frameAge)
    }

    func testFreshFrameReadsAsLive() {
        XCTAssertEqual(panel(lastFrameAt: Date()).frameAgeDescription, "Live")
    }

    func testSecondsAndMinutes() {
        XCTAssertEqual(
            panel(lastFrameAt: Date(timeIntervalSinceNow: -12)).frameAgeDescription,
            "Last frame 12s ago")
        XCTAssertEqual(
            panel(lastFrameAt: Date(timeIntervalSinceNow: -185)).frameAgeDescription,
            "Last frame 3m ago")
    }
}

/// The preview must never show one panel's screen against another's details,
/// and a callback already in flight when the selection changes must not sneak
/// one through.
@MainActor
final class FramePreviewTests: XCTestCase {

    private func image() -> CGImage {
        let pixels = [UInt8](repeating: 0, count: 4 * 2)
        return PixelConvert.imageFromRGB565BE(pixels, width: 2, height: 2)!
    }

    func testFrameFromTheFocusedPanelIsKept() {
        let preview = FramePreview()
        preview.focus(on: "studio-display")

        preview.accept(image: image(), landscape: false, from: "studio-display")

        XCTAssertNotNil(preview.frame)
    }

    func testFrameFromAnotherPanelIsDropped() {
        let preview = FramePreview()
        preview.focus(on: "studio-display")

        preview.accept(image: image(), landscape: false, from: "travel-display")

        XCTAssertNil(preview.frame)
    }

    func testChangingFocusDiscardsTheOldImage() {
        let preview = FramePreview()
        preview.focus(on: "studio-display")
        preview.accept(image: image(), landscape: false, from: "studio-display")

        preview.focus(on: "travel-display")

        XCTAssertNil(preview.frame)
        XCTAssertEqual(preview.serviceName, "travel-display")
    }

    func testUnfocusedPreviewKeepsNothing() {
        let preview = FramePreview()

        preview.accept(image: image(), landscape: false, from: "studio-display")

        XCTAssertNil(preview.frame)
    }

    /// Frames are compared by sequence number, not by pixels: the question is
    /// "is this a new frame", and comparing two 55k-pixel images to answer it
    /// would cost more than drawing them.
    func testSuccessiveFramesAreDistinctEvenWhenIdentical() {
        let preview = FramePreview()
        preview.focus(on: "p")
        let same = image()

        preview.accept(image: same, landscape: false, from: "p")
        let first = preview.frame
        preview.accept(image: same, landscape: false, from: "p")

        XCTAssertNotEqual(first, preview.frame)
    }
}

/// The RGB565 to image expansion behind the preview.
final class PreviewImageTests: XCTestCase {

    /// Two bytes per pixel, big-endian, as the panel receives them.
    private func rgb565(_ value: UInt16, count: Int) -> [UInt8] {
        var out: [UInt8] = []
        for _ in 0..<count {
            out.append(UInt8(value >> 8))
            out.append(UInt8(value & 0xFF))
        }
        return out
    }

    func testImageHasTheRequestedGeometry() {
        let image = PixelConvert.imageFromRGB565BE(
            rgb565(0, count: 172 * 320), width: 172, height: 320)

        XCTAssertEqual(image?.width, 172)
        XCTAssertEqual(image?.height, 320)
    }

    func testLandscapeGeometry() {
        let image = PixelConvert.imageFromRGB565BE(
            rgb565(0, count: 320 * 172), width: 320, height: 172)

        XCTAssertEqual(image?.width, 320)
        XCTAssertEqual(image?.height, 172)
    }

    func testTooFewBytesIsRejectedRatherThanReadingPastTheBuffer() {
        XCTAssertNil(
            PixelConvert.imageFromRGB565BE(rgb565(0, count: 4), width: 172, height: 320))
    }

    func testEmptyGeometryIsRejected() {
        XCTAssertNil(PixelConvert.imageFromRGB565BE([], width: 0, height: 0))
    }

    /// Full-scale 5- and 6-bit input has to reach full-scale 8-bit output.
    /// Shifting alone would cap white at 0xF8F8F8, a visibly grey "white".
    func testWhiteStaysWhite() throws {
        let image = try XCTUnwrap(
            PixelConvert.imageFromRGB565BE(rgb565(0xFFFF, count: 1), width: 1, height: 1))
        let pixel = try XCTUnwrap(sampleFirstPixel(of: image))

        XCTAssertEqual(pixel.red, 0xFF)
        XCTAssertEqual(pixel.green, 0xFF)
        XCTAssertEqual(pixel.blue, 0xFF)
    }

    func testBlackStaysBlack() throws {
        let image = try XCTUnwrap(
            PixelConvert.imageFromRGB565BE(rgb565(0x0000, count: 1), width: 1, height: 1))
        let pixel = try XCTUnwrap(sampleFirstPixel(of: image))

        XCTAssertEqual(pixel.red, 0x00)
        XCTAssertEqual(pixel.green, 0x00)
        XCTAssertEqual(pixel.blue, 0x00)
    }

    /// Channel order survives the trip: pure red in RGB565 must not come out
    /// blue, which is the classic way this conversion goes wrong.
    func testRedStaysRed() throws {
        let image = try XCTUnwrap(
            PixelConvert.imageFromRGB565BE(rgb565(0xF800, count: 1), width: 1, height: 1))
        let pixel = try XCTUnwrap(sampleFirstPixel(of: image))

        XCTAssertEqual(pixel.red, 0xFF)
        XCTAssertEqual(pixel.green, 0x00)
        XCTAssertEqual(pixel.blue, 0x00)
    }

    func testBlueStaysBlue() throws {
        let image = try XCTUnwrap(
            PixelConvert.imageFromRGB565BE(rgb565(0x001F, count: 1), width: 1, height: 1))
        let pixel = try XCTUnwrap(sampleFirstPixel(of: image))

        XCTAssertEqual(pixel.red, 0x00)
        XCTAssertEqual(pixel.green, 0x00)
        XCTAssertEqual(pixel.blue, 0xFF)
    }

    private func sampleFirstPixel(
        of image: CGImage
    ) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        guard let data = image.dataProvider?.data as Data?, data.count >= 3 else {
            return nil
        }
        return (red: data[0], green: data[1], blue: data[2])
    }
}

/// The by-ID window lookup the resize fix depends on, exercised against the
/// real window server.
///
/// Re-finding a window by ID rather than by name is the point: `findWindow`
/// returns the *largest* match, so resizing one window of an app that has
/// several used to hand the session to a sibling and restart capture on the
/// wrong content.
final class WindowLookupTests: XCTestCase {

    func testAWindowIsFoundByTheIDItReported() async throws {
        guard let sample = try? await DisplayCapture.listWindows(), let first = sample.first
        else {
            throw XCTSkip("ScreenCaptureKit offered no windows on this machine")
        }

        let found = await DisplayCapture.findWindow(id: first.id)

        XCTAssertEqual(found?.windowID, first.id)
    }

    /// A closed window has to resolve to nothing, which is what tells the
    /// supervisor to look for a replacement instead of retrying a dead filter.
    func testAnUnknownIDResolvesToNothing() async {
        let found = await DisplayCapture.findWindow(id: CGWindowID.max)

        XCTAssertNil(found)
    }
}
