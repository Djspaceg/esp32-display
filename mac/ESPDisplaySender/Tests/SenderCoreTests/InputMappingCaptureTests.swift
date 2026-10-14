import AppKit
import SenderProtocol
import SwiftUI
import XCTest

@testable import SenderCore

/// Renders the display page's Buttons and Gestures section, offscreen, when
/// ESPDISP_UX_CAPTURE_DIR is set: a 1.75-inch round on the default preset, the
/// same board with assignments changed by hand, a board whose firmware
/// predates maps, and the key-capture sheet. Nothing here opens a port or
/// posts a key.
@MainActor
final class InputMappingCaptureTests: XCTestCase {
    func testCaptureButtonsAndGesturesWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["ESPDISP_UX_CAPTURE_DIR"]
        else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let defaults: [UInt8] = [1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 3, 4, 5, 6, 0, 0]
        var round = PanelSnapshot(serviceName: "silver-round", displayName: "silver-round")
        round.profile = "co5300"
        round.capabilitiesRaw = DeviceProtocol.Capabilities(
            [.touch, .touchLongPress, .inputMap, .battery, .roundDisplay]).rawValue
        round.inputReport = DeviceProtocol.InputReport(
            inputs: [.tap, .swipeLeft, .swipeRight, .swipeUp, .swipeDown, .longPress,
                     .bootSinglePress, .bootDoublePress, .bootTriplePress, .bootLongPress,
                     .bootExtraLongPress, .powerKeyPress, .powerKeyLongPress],
            functions: Set(DeviceProtocol.BoardFunctionCode.allCases),
            current: defaults, defaults: defaults)
        try capture(page(round), to: output, name: "buttons-and-gestures-default")

        var edited = round
        edited.inputAssignments = [
            .powerKeyPress: .board(.displayPower),
            .powerKeyLongPress: .mac(.keyPress(KeyCombo(
                keyCode: 12, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue,
                label: "\u{21E7}\u{2318}Q"))),
            .bootSinglePress: .mac(.mediaPlayPause),
            .longPress: .board(.statusScreen),
        ]
        try capture(page(edited), to: output, name: "buttons-and-gestures-custom")

        var older = PanelSnapshot(serviceName: "older", displayName: "older-panel")
        older.capabilitiesRaw = DeviceProtocol.Capabilities([.touch, .touchLongPress]).rawValue
        try capture(page(older), to: output, name: "buttons-and-gestures-older-firmware")

        let request = KeyCaptureRequest(input: .powerKeyLongPress, inputLabel: "Hold the power button")
        try capture(
            KeyCaptureSheet(request: request, onSave: { _ in }, onCancel: {}),
            to: output, name: "key-capture-sheet", size: NSSize(width: 380, height: 300))
    }

    private func page(_ panel: PanelSnapshot) -> some View {
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])
        manager.serialIODisabled = true
        manager.mediaKeysAuthorized = { true }
        manager.selectedServiceName = panel.serviceName
        return PanelDetailView(panel: panel, manager: manager)
    }

    private func capture<V: View>(
        _ view: V, to directory: URL, name: String,
        size: NSSize = NSSize(width: 640, height: 3200)
    ) throws {
        let host = NSHostingView(rootView: view
            .environment(\.glassRendersOpaque, true)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
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
