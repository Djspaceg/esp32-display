import AppKit
import SwiftUI
import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// Renders the Repair screens to PNGs for review when
/// ESPDISP_UX_CAPTURE_DIR is set; otherwise does nothing. The window is never
/// ordered on screen, so the capture does not take the foreground, and nothing
/// rendered here lists, probes or opens a serial port.
@MainActor
final class UsbRepairCaptureTests: XCTestCase {
    func testCaptureRepairScreensWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["ESPDISP_UX_CAPTURE_DIR"]
        else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let manager = PanelManager(previewPanels: [], savedNetworkNames: [], usbSerialPorts: [])
        let releases = try UsbRescueTests.releaseSet()
        let board = UsbRescueTests.rescuedBoard()
        let port = board.port

        // Only UsbRepairView is rendered: it does no USB I/O on appear. The
        // Add Display and Firmware Update sheets refresh and probe real ports
        // when they appear, so they are never rendered here.
        func repair(_ name: String, _ configure: (UsbRepairModel) -> Void) throws {
            let model = UsbRepairModel(family: .named("s3"))
            configure(model)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            try capture(
                UsbRepairView(manager: manager, model: model, onClose: { _ in }),
                to: output, name: name)
        }
        try repair("2-repair-choose-family") { _ in }
        try repair("3-repair-plug-in-now") { model in
            model.stage = .catching
            model.monitor.record(.phase(.rescue(.startingEsptool)))
            model.monitor.record(.log(.app, "Starting esptool; this takes a few seconds."))
            model.monitor.record(.phase(.rescue(.plugIn)))
        }
        try repair("4-repair-missed-it") { model in
            model.stage = .catching
            model.monitor.record(.phase(.rescue(.plugIn)))
            model.monitor.record(.phase(.rescue(.caught(port: port))))
            model.monitor.record(.phase(.rescue(.missed(esptoolReady: true))))
        }
        try repair("5-repair-rescue-is-on-offer-install") { model in
            model.monitor.record(.phase(.rescue(.rescued(port: port))))
            model.rescued(board, firmware: .ready(releases))
        }
        try repair("6-repair-installing-real-firmware") { model in
            model.rescued(board, firmware: .ready(releases))
            model.stage = .installing(board)
            model.monitor.record(.phase(.writing(FlashPartProgress(
                index: 4, count: 4, role: "app", address: 0x10000, percent: 42,
                bytesBefore: 31_232, bytes: 2_000_000, totalBytes: 2_031_232))))
        }
        try repair("7-repair-stored-override") { model in
            var forced = board
            forced.storedOverride = "st7789-190"
            model.monitor.record(.phase(.rescue(.rescued(port: port))))
            model.rescued(forced, firmware: .ready(releases))
        }
        try repair("8-repair-could-not-connect") { model in
            model.stage = .catching
            model.monitor.record(.phase(.rescue(.couldNotConnect(port: port, family: "s3"))))
        }
    }

    private func capture<V: View>(_ view: V, to directory: URL, name: String) throws {
        let host = NSHostingView(rootView: view.frame(width: 560, height: 620))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 620)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        host.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        window.close()
    }
}
