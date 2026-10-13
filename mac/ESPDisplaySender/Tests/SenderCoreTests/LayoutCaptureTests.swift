import AppKit
import SwiftUI
import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// Renders the reworked manager window and firmware sheet to PNGs when
/// ESPDISP_UX_CAPTURE_DIR is set; otherwise does nothing. Windows are never
/// ordered on screen, and serial I/O is switched off on the manager, so no
/// capture lists, probes or opens a serial port.
@MainActor
final class LayoutCaptureTests: XCTestCase {
    /// The commit the committed bundles were built from, read from one of
    /// them so a regeneration does not have to edit this test.
    private static let commit: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("firmware-releases/c6/espdisp-c6-1.5.0.espdispfw")
        return (try? FirmwareBundle.read(Data(contentsOf: url)))?.sourceCommit ?? ""
    }()

    func testCaptureReworkedLayoutWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["ESPDISP_UX_CAPTURE_DIR"]
        else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let releases = try Self.releaseSet()

        let now = Date()
        var panel = PanelSnapshot(serviceName: "desk-panel", displayName: "Desk Panel")
        panel.hardwareID = "020000123456"
        panel.address = "192.168.1.42"
        panel.discovered = true
        panel.lastSeen = now
        panel.lastHeartbeatAt = now
        panel.rssi = -52
        panel.displayFPS = 29.8
        panel.firmwareVersion = "1.5.0"
        panel.noteFirmwareSource(
            FirmwareSourceIdentity(reported: Self.commit), reportedWith: "1.5.0")
        panel.chip = "esp32s3"
        panel.target = "s3"
        panel.profile = "co5300"
        panel.partition = "universal-8m-doom-saves-ota"
        panel.geometry = PanelGeometry(width: 466, height: 466)
        panel.frameProtocolVersion = 2
        panel.controlProtocolVersion = Int(DeviceProtocol.controlProtocolVersion)
        panel.capabilitiesRaw = DeviceProtocol.Capabilities.brightness
            .union(.brightnessLevel).union(.rotate).union(.flip).union(.identify)
            .union(.restart).union(.power).union(.touch).union(.idleText)
            .union(.battery).rawValue
        panel.uptimeSeconds = 93_840
        panel.brightness = 180
        panel.source = .display("Studio Display")
        panel.sourceDescription = "Studio Display"
        panel.captureStatus = .streaming
        panel.lastFrameAt = now

        func manager(_ panels: [PanelSnapshot]) -> PanelManager {
            let manager = PanelManager(
                previewPanels: panels, savedNetworkNames: ["Studio WiFi"],
                usbSerialPorts: ["/dev/cu.usbmodem1101"])
            manager.serialIODisabled = true
            manager.bundledFirmwareCache = .ready(releases)
            let caps = String(format: "%08x", panel.capabilitiesRaw)
            manager.noteUSBIdentity(
                path: "/dev/cu.usbmodem1101",
                identity: WifiConfigUI.usbIdentity(from:
                    "CFGINFO ssid64=U3R1ZGlvIFdpRmk= name64=RGVzayBQYW5lbA== "
                        + "id=020000123456 connected=1 ip=192.168.1.42 rssi=-52 flip=0 "
                        + "rot=0 pwr=on board=co5300 profile=co5300 target=s3 "
                        + "chip=esp32s3 partition=universal-8m-doom-saves-ota bat=87 ota=on "
                        + "ssid=Studio WiFi caps=\(caps) bllevel=180 fw=1.5.0 "
                        + "src=\(Self.commit)"),
                generation: manager.usbPathGeneration("/dev/cu.usbmodem1101"))
            return manager
        }

        let live = manager([panel])
        try capture(Self.detail(live), size: .init(width: 780, height: 760),
                    to: output, name: "1-detail-top")
        try capture(Self.detail(live), size: .init(width: 780, height: 2300),
                    to: output, name: "2-detail-full")

        var off = panel
        off.manuallyOff = true
        off.lastError = "Gave up trying to reach this display. It is retried "
            + "automatically once it reappears on the network."
        let offManager = manager([off])
        // A build this app does not carry, as the board would report it.
        offManager.panels[0].noteFirmwareSource(
            FirmwareSourceIdentity(
                commit: "0123456789abcdef0123456789abcdef01234567", dirty: false),
            reportedWith: "1.5.0")
        offManager.panels[0].manuallyOff = true
        try capture(Self.detail(offManager),
                    size: .init(width: 780, height: 760),
                    to: output, name: "3-detail-screen-off-other-build")

        let sheetManager = manager([panel])
        guard case .ready(let target) = sheetManager.firmwareUpdateReadiness("desk-panel")
        else { return XCTFail("capture target should be ready") }
        let writing = UsbFlashMonitor(flow: .update)
        writing.record(.phase(.findingBoard))
        writing.record(.log(.esptool,
            "Writing at 0x001280ef [========================>   ] 63.3% 737280/1165283 bytes..."))
        writing.record(.phase(.writing(FlashPartProgress(
            index: 4, count: 5, role: "app", address: 0x10000, percent: 63,
            bytesBefore: 31_232, bytes: 1_481_286, totalBytes: 5_708_538))))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        try capture(
            FirmwareUpdateSheet(
                manager: sheetManager, target: target,
                bundledFirmware: .ready(releases), capturing: writing, isPushing: true),
            size: .init(width: 560, height: 620), to: output, name: "4-update-writing")

        let failed = UsbFlashMonitor(flow: .update)
        failed.record(.phase(.enteringDownloadMode))
        failed.record(.log(.esptool, "Connecting......................................"))
        failed.record(.log(.esptool,
            "A fatal error occurred: Failed to connect to ESP32-S3: No serial data received."))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let outcome = OperationOutcome.failure(
            "Flashing failed",
            "esptool could not connect to /dev/cu.usbmodem1101: No serial data received.")
        failed.fail(outcome)
        try capture(
            FirmwareUpdateSheet(
                manager: sheetManager, target: target,
                bundledFirmware: .ready(releases), capturing: failed, isPushing: false,
                failure: outcome),
            size: .init(width: 560, height: 620), to: output, name: "5-update-failed")
        try capture(
            FirmwareUpdateSheet(
                manager: sheetManager, target: target,
                bundledFirmware: .ready(releases),
                capturing: UsbFlashMonitor(flow: .update), isPushing: false),
            size: .init(width: 560, height: 620), to: output, name: "6-update-ready")
    }

    private func capture<V: View>(
        _ view: V, size: CGSize, to directory: URL, name: String
    ) throws {
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

    /// The detail pane on its own: NavigationSplitView is an AppKit split view
    /// and draws nothing into an offscreen bitmap, so the sidebar is left out.
    private static func detail(_ manager: PanelManager) -> some View {
        PanelDetailView(panel: manager.panels[0], manager: manager)
    }

    private static func releaseSet() throws -> BundledFirmware.ReleaseSet {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("firmware-releases")
        let catalog = try FirmwareReleaseCatalog.read(
            contentsOf: root.appendingPathComponent(FirmwareReleaseCatalog.fileName))
        var options = [String: [BundledFirmware.RevisionOption]]()
        for entry in catalog.families.values {
            options[entry.family] = try entry.revisions.map { revision in
                let url = root.appendingPathComponent(revision.artifact)
                let bundle = try catalog.bundle(
                    for: revision, in: entry, data: Data(contentsOf: url))
                return .init(
                    revision: revision,
                    selection: .init(
                        catalogEntry: entry, revision: revision, bundle: bundle, url: url),
                    unavailableReason: nil)
            }
        }
        return .init(catalog: catalog, revisionOptions: options)
    }
}
