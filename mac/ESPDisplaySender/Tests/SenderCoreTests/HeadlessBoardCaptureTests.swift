import AppKit
import SwiftUI
import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// Renders a board with no screen's detail pane to a PNG when
/// ESPDISP_UX_CAPTURE_DIR is set; otherwise does nothing. The panel is the bare
/// XIAO as its firmware reports itself. The window is never ordered on screen.
@MainActor
final class HeadlessBoardCaptureTests: XCTestCase {
    func testCaptureTheNoScreenPaneWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["ESPDISP_UX_CAPTURE_DIR"]
        else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var panel = PanelSnapshot(
            serviceName: "espdisplay-8af8",
            displayName: "espdisplay-8af8",
            lastSeen: Date(),
            lastHeartbeatAt: Date(),
            controlProtocolVersion: Int(DeviceProtocol.controlProtocolVersion),
            capabilitiesRaw: DeviceProtocol.Capabilities([.restart, .telemetry]).rawValue)
        panel.profile = "xiao-s3-bare"
        panel.target = "s3"
        panel.chip = "esp32s3"
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])

        let size = NSSize(width: 640, height: 900)
        let view = PanelDetailView(panel: panel, manager: manager)
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
        try png.write(to: output.appendingPathComponent("no-screen-device-pane.png"))
        window.close()
    }
}
