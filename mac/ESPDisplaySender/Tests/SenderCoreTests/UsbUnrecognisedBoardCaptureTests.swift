import AppKit
import SwiftUI
import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// Renders the Add Device sheet's footer after a flash to PNGs when
/// ESPDISP_UX_CAPTURE_DIR is set; otherwise does nothing. The run is the real
/// wait on a virtual clock, fed into the sheet's own monitor, so what is drawn
/// is what the sheet draws. Only the footer is rendered: the sheet itself
/// probes real ports when it appears. The window is never ordered on screen.
@MainActor
final class UsbUnrecognisedBoardCaptureTests: XCTestCase {
    private let flashed = "/dev/cu.usbmodem12401"

    func testCaptureTheFooterAfterAFlashWhenRequested() async throws {
        guard let directory = ProcessInfo.processInfo.environment["ESPDISP_UX_CAPTURE_DIR"]
        else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let unrecognised = UsbSettleTests.Bench()
        unrecognised.ports = { [flashed] _ in [flashed] }
        unrecognised.received = { _, _ in [UsbUnrecognisedBoardTests.unresolvedReply] }
        try await capture(unrecognised, name: "add-device-board-not-recognised", to: output)

        let quiet = UsbSettleTests.Bench()
        quiet.ports = { [flashed] _ in [flashed] }
        quiet.answer = { _, _ in .init(existing: .silent, lastLine: "motion: raw=1,2,3") }
        try await capture(quiet, name: "add-device-board-did-not-answer", to: output)
    }

    private func capture(
        _ bench: UsbSettleTests.Bench, name: String, to directory: URL
    ) async throws {
        let monitor = UsbFlashMonitor(flow: .onboarding)
        monitor.record(.phase(.restarting))
        let result = await UsbOnboarder.sendConfiguration(
            steps: UsbOnboarding.configurationSteps(
                name: "watch", ssid: "Stephens Manor", password: .set("hunter2hunter2")),
            flashedPort: flashed, expectedHardwareID: "1cdbd47b5b94", io: bench.io,
            onProgress: { monitor.record($0) })
        guard case .failure(let failure) = result else { return XCTFail("\(result)") }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        monitor.fail(.failure(failure))

        let size = NSSize(width: 520, height: 230)
        let view = FlashStatusFooterView(status: .usb(monitor.session))
            .padding(14)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        host.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        window.close()
    }
}
