import AppKit
import SwiftUI
import XCTest
@testable import SenderCore

/// Renders the Settings window's panes and a display's Network Connection
/// rows to PNGs when ESPDISP_UX_CAPTURE_DIR is set; otherwise does nothing.
/// As in `LayoutCaptureTests`, windows are never ordered on screen, serial
/// I/O is off, and the networks are in memory, never the Keychain.
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

        for (index, pane) in SettingsPane.allCases.enumerated() {
            let navigation = SettingsNavigation()
            navigation.show(pane)
            try capture(
                SettingsView(manager: manager, navigation: navigation),
                size: .init(width: 720, height: pane == .wifiNetworks ? 1000 : 720),
                to: output, name: "settings-\(index + 1)-\(pane.rawValue)")
        }
        // The sidebar on its own as well: inside the split view its material
        // has nothing behind it to sample offscreen, and draws as a blank.
        try capture(
            SettingsSidebar(navigation: SettingsNavigation())
                .background(Color(nsColor: .windowBackgroundColor)),
            size: .init(width: 230, height: 360), to: output,
            name: "settings-0-sidebar")
        try capture(
            Form {
                Section("Network Connection") {
                    WifiNetworkRows(
                        connectedDescription: "Studio WiFi",
                        presetDescription: "Studio WiFi (slot 1 of 10, at the last USB copy)")
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
