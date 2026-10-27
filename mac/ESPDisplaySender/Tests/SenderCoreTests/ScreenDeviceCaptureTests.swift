import AppKit
import SwiftUI
import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// Renders the Mac-screen rows and page to PNGs when ESPDISP_UX_CAPTURE_DIR is
/// set; otherwise does nothing. Windows are never ordered on screen, and the
/// controller's covers and feeds are fakes, so nothing is covered or captured.
@MainActor
final class ScreenDeviceCaptureTests: XCTestCase {
    func testCaptureScreenDevicePagesWhenRequested() async throws {
        guard let directory = ProcessInfo.processInfo.environment["ESPDISP_UX_CAPTURE_DIR"]
        else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let fakes = ScreenDeviceFakes()
        let builtIn = ScreenDeviceTests.builtIn
        let oled = ScreenDeviceTests.oled
        let studio = ScreenDeviceTests.studio
        fakes.screens = [builtIn, oled, studio]
        let controller = fakes.makeController()
        controller.reconcile()
        let key = oled.identity.key

        try capture(page(controller, key), to: output, name: "screen-1-offered")
        controller.use(key)
        await controller.settle()
        try capture(page(controller, key), to: output, name: "screen-2-in-use")
        controller.setRotation(1, for: key)
        await controller.settle()
        try capture(page(controller, key), to: output, name: "screen-3-quarter-turn")
        fakes.screens = [builtIn, studio]
        controller.reconcile()
        await controller.settle()
        try capture(page(controller, key), to: output, name: "screen-4-unplugged")
    }

    private func page(_ controller: ScreenDeviceController, _ key: String) -> some View {
        HStack(spacing: 0) {
            List(selection: .constant(Optional(ScreenDeviceEntry.tag(for: key)))) {
                ScreenDeviceSidebarSection(controller: controller, capturingFrom: [])
            }
            .listStyle(.sidebar)
            .frame(width: 240)
            Divider()
            NavigationStack {
                ScreenDeviceDetailView(controller: controller, key: key, capturingFrom: [])
            }
        }
    }

    private func capture<V: View>(_ view: V, to directory: URL, name: String) throws {
        let size = CGSize(width: 900, height: 640)
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .environment(\.glassRendersOpaque, true))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        host.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        window.close()
    }
}
