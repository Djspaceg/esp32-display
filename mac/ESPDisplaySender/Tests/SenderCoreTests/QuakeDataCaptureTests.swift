import AppKit
import SenderProtocol
import SwiftUI
import XCTest

@testable import SenderCore

/// Renders the Quake data sheet for an S3 and a P4 display when
/// ESPDISP_UX_CAPTURE_DIR is set. The sheet does no USB I/O until Write is
/// pressed, so nothing here lists, probes or opens a serial port.
@MainActor
final class QuakeDataCaptureTests: XCTestCase {
    func testCaptureQuakeDataSheetWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["ESPDISP_UX_CAPTURE_DIR"]
        else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let manager = PanelManager(previewPanels: [], savedNetworkNames: [], usbSerialPorts: [])
        let pak = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("firmware/quake/id1/pak0.pak")
        let chosen = try FileManager.default.fileExists(atPath: pak.path)
            ? (url: pak, validated: QuakePak.validate(
                Data(contentsOf: pak, options: .mappedIfSafe)))
            : nil

        func target(_ name: String, chip: String, path: String) -> PanelManager.FirmwareUpdateTarget {
            PanelManager.FirmwareUpdateTarget(
                serviceName: name, displayName: name, hardwareID: "7C:0C:5F:42:39:A4",
                address: nil, chip: chip, firmwareVersion: "2.0.0",
                usbDevice: WifiConfigUI.USBDeviceOption(path: path, isConnected: true),
                usbPathGeneration: 1)
        }
        try capture(
            QuakeDataSheet(
                manager: manager,
                target: target("silver-round", chip: "esp32s3",
                               path: "/dev/cu.usbmodem1312101")),
            to: output, name: "quake-data-s3-empty")
        if let chosen {
            try capture(
                QuakeDataSheet(
                    manager: manager,
                    target: target("silver-round", chip: "esp32s3",
                                   path: "/dev/cu.usbmodem1312101"),
                    chosen: chosen),
                to: output, name: "quake-data-s3-chosen")
            try capture(
                QuakeDataSheet(
                    manager: manager,
                    target: target("studio-4b", chip: "esp32p4",
                                   path: "/dev/cu.usbmodem2101"),
                    chosen: chosen),
                to: output, name: "quake-data-p4-chosen")
        }
    }

    private func capture<V: View>(_ view: V, to directory: URL, name: String) throws {
        let host = NSHostingView(rootView: view.frame(width: 520, height: 620))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 620)
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
