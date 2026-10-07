import AppKit
import SwiftUI
import XCTest
@testable import SenderCore

/// Renders the Settings sheet's WiFi Networks section and a display's Network
/// Connection rows to PNGs when ESPDISP_UX_CAPTURE_DIR is set; otherwise does
/// nothing. As in `LayoutCaptureTests`, windows are never ordered on screen,
/// serial I/O is off, and the networks are in memory, never the Keychain.
@MainActor
final class WifiSettingsCaptureTests: XCTestCase {
    func testCaptureWifiSettingsWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["ESPDISP_UX_CAPTURE_DIR"]
        else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let names = [
            "Studio WiFi", "Home", "Office 5G", "Guest", "Phone Hotspot", "Cafe",
            "Workshop", "Lab", "Garage", "Cabin", "Hotel Lobby", "Airport Free",
        ]
        let store = InMemoryWifiCredentials(names.map {
            $0 == "Guest" || $0 == "Airport Free"
                ? SavedWiFiCredential(ssid: $0, password: "", isOpenNetwork: true)
                : SavedWiFiCredential(ssid: $0, password: "pw")
        })
        var panel = PanelSnapshot(serviceName: "desk-panel", displayName: "Desk Panel")
        panel.address = "192.168.1.42"
        panel.discovered = true
        panel.lastSeen = Date()
        panel.rssi = -52
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [],
            settings: SenderSettings(wifiPresetOrder: names))
        manager.serialIODisabled = true
        manager.useWifiCredentials(store)
        manager.applySavedNetworkNames(store.names)
        manager.report(
            .wifiPresetSync, source: "020000123456",
            detail: "Desk Panel: WiFi preset sync stopped. Command 3 of 9 "
                + "(CFGWIFISET slot 3) failed: no response from the device.")

        try capture(
            Form {
                WifiNetworksSection(manager: manager, isEditing: .constant(false))
            }
            .formStyle(.grouped)
            .textSelection(.enabled)
            .labeledContentStyle(.labelColumn),
            size: .init(width: 560, height: 820), to: output,
            name: "wifi-1-settings-networks-section")
        try capture(
            Form {
                Section("Network Connection") {
                    WifiNetworkRows(
                        connectedDescription: "Studio WiFi",
                        savedNetworkNames: manager.savedNetworkNames,
                        selection: .constant("Studio WiFi"),
                        canApply: true, canEdit: true)
                }
            }
            .formStyle(.grouped)
            .labeledContentStyle(.labelColumn),
            size: .init(width: 620, height: 200), to: output,
            name: "wifi-2-board-network-rows")
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
}
