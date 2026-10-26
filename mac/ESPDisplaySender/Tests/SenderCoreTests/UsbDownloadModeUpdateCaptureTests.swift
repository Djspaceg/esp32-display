import AppKit
import SwiftUI
import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// Renders the Firmware Update sheet for a board whose firmware does not
/// identify it, to PNGs, when ESPDISP_UX_CAPTURE_DIR is set; otherwise does
/// nothing. The ports are named, never listed, probed or opened, and the window
/// is never ordered on screen.
@MainActor
final class UsbDownloadModeUpdateCaptureTests: XCTestCase {
    func testCaptureTheUpdateSheetForAnUnidentifiedBoardWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["ESPDISP_UX_CAPTURE_DIR"]
        else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let releases = try UsbRescueTests.releaseSet()

        func sheet(chip: String?, family: String?, chosen: String? = nil) throws -> some View {
            let path = "/dev/cu.usbmodem12401"
            var panel = PanelSnapshot(serviceName: "watch", displayName: "watch")
            panel.hardwareID = "7c0c5f4239a4"
            panel.firmwareVersion = "2.1.0"
            panel.chip = chip
            panel.target = family
            panel.usbSerialNumbers = ["7C0C5F4239A4-console"]
            let manager = PanelManager(
                previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])
            manager.usbSerialReader = { $0 == path ? "7C0C5F4239A4-console" : nil }
            manager.updateUSBPorts([path])
            guard case .ready(var target) = manager.firmwareUpdateReadiness("watch")
            else { throw XCTSkip("not ready") }
            target.chosenFamily = chosen
            target.chosenChip = chosen.map { _ in "esp32s3" }
            return FirmwareUpdateSheet(
                manager: manager, target: target, bundledFirmware: .ready(releases),
                capturing: UsbFlashMonitor(flow: .update), isPushing: false)
        }
        try capture(sheet(chip: "esp32s3", family: "s3"),
                    to: output, name: "update-unidentified-board-known-family")
        try capture(sheet(chip: nil, family: nil),
                    to: output, name: "update-unidentified-board-choose-family")
        try capture(sheet(chip: nil, family: nil, chosen: "s3"),
                    to: output, name: "update-unidentified-board-family-chosen")
    }

    private func capture<V: View>(_ view: V, to directory: URL, name: String) throws {
        let size = NSSize(width: 560, height: 620)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
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
