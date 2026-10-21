import AppKit
import SenderProtocol
import SwiftUI
import XCTest

@testable import SenderCore

/// Renders the Network Connection section's WiFi row offscreen, in the states
/// the board can report, so it can be looked at without a window or a board.
/// Set ESPDISP_RENDER_DIR to keep the PNGs.
@MainActor
final class WifiNetworkRowsRenderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private struct Case {
        let title: String
        let panel: PanelSnapshot
    }

    private let now = Date()
    private let saved = ["Studio WiFi", "Guest", "Office"]

    private func panel(
        ssid: String?, announced: String? = nil, connected: Bool?,
        heartbeatSecondsAgo: Double?
    ) -> PanelSnapshot {
        var panel = PanelSnapshot(serviceName: "p", displayName: "p")
        panel.currentSSID = ssid
        panel.announcedSSID = announced
        panel.networkConnected = connected
        panel.networkReportedAt = connected == nil ? nil : now.addingTimeInterval(-600)
        panel.lastReplyAt = heartbeatSecondsAgo.map { now.addingTimeInterval(-$0) }
        return panel
    }

    private var cases: [Case] {
        [
            Case(title: "On WiFi, named by its announcement",
                 panel: panel(
                     ssid: nil, announced: "Studio WiFi", connected: nil,
                     heartbeatSecondsAgo: 1)),
            Case(title: "Went quiet over WiFi",
                 panel: panel(ssid: "Studio WiFi", connected: true, heartbeatSecondsAgo: 120)),
            Case(title: "On a network this Mac has not saved",
                 panel: panel(
                     ssid: nil, announced: "Neighbours WiFi", connected: nil,
                     heartbeatSecondsAgo: 1)),
            Case(title: "Older firmware over WiFi only",
                 panel: panel(ssid: nil, connected: nil, heartbeatSecondsAgo: 1)),
            Case(title: "Nothing reported yet",
                 panel: panel(ssid: nil, connected: nil, heartbeatSecondsAgo: nil)),
            Case(title: "USB says no network is set",
                 panel: panel(ssid: "", connected: false, heartbeatSecondsAgo: nil)),
        ]
    }

    private func model(
        _ panel: PanelSnapshot, switchState: WifiSwitchState? = nil,
        report: WifiPresetSyncReport? = nil, unavailable: String? = nil
    ) -> WifiNetworkRows.Model {
        WifiNetworkRows.model(
            current: panel.boardSSID(asOf: now),
            currentDescription: panel.boardNetworkDescription(asOf: now),
            savedNetworks: saved, report: report, switchState: switchState,
            unavailableReason: unavailable)
    }

    /// The section as the display page lays it out.
    private func section(_ model: WifiNetworkRows.Model, title: String) -> some View {
        Section(title) {
            WifiNetworkRows(model: model)
            LabeledContent("Address", value: "192.168.1.159")
            LabeledContent("Signal strength", value: "Excellent (-43 dBm)")
        }
    }

    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat) throws
        -> NSBitmapImageRep
    {
        let host = NSHostingView(rootView: view
            .formStyle(.grouped)
            .labeledContentStyle(.labelColumn)
            .frame(width: width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    func testTheRowRendersForEveryReportedState() throws {
        let onStudio = panel(
            ssid: nil, announced: "Studio WiFi", connected: nil, heartbeatSecondsAgo: 1)
        let unreadable = WifiPresetSyncReport(
            snapshot: WifiPresetSnapshot(
                roster: ConfigCommands.WiFiPresetRoster(
                    capacity: 10, validSlots: [1], activeSlot: 1,
                    localSelectorAvailable: true),
                slots: [1: ConfigCommands.WiFiPresetSlot(
                    slot: 1, ssid: "Studio WiFi", hasPassword: true, active: true)]),
            omitted: [], unusable: ["Office"], commandCount: 0)
        let states: [(String, WifiNetworkRows.Model)] = [
            ("On a saved network, over USB", model(onStudio)),
            ("Over WiFi only", model(onStudio, unavailable: "Connect by USB")),
            ("Switching", model(onStudio, switchState: .switching("Guest", since: now))),
            ("A password that could not be read", model(onStudio, report: unreadable)),
        ] + cases.map { ($0.title, model($0.panel)) }
        let view = Form {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                self.section(state.1, title: state.0)
            }
        }
        let rep = try render(view, width: 640, height: 1500)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000, "the render came out empty")

        // What each reported state reads as, so the picture and the words
        // cannot drift.
        XCTAssertEqual(
            cases.map { $0.panel.boardNetworkDescription(asOf: now) },
            ["Studio WiFi", "Not answering (set to \"Studio WiFi\")",
             "Neighbours WiFi", "Connected (name not reported)",
             "Unknown (not reported yet)", "None configured"])
        XCTAssertEqual(
            cases.map { $0.panel.boardSSID(asOf: now) },
            ["Studio WiFi", "Studio WiFi", "Neighbours WiFi", nil, nil, nil])

        if let dir = ProcessInfo.processInfo.environment["ESPDISP_RENDER_DIR"] {
            try png.write(to: URL(fileURLWithPath: dir)
                .appendingPathComponent("wifi-row-states.png"))
        }
    }

    /// The row draws what it is given: changing only the board's network or
    /// the error changes the pixels.
    func testTheRowDrawsTheSelectionAndTheError() throws {
        func render(_ model: WifiNetworkRows.Model) throws -> Data {
            try XCTUnwrap(self.render(
                Form { WifiNetworkRows(model: model) }, width: 600, height: 140)
                .tiffRepresentation)
        }
        let base = WifiNetworkRows.Model(
            savedNetworks: saved, current: "Studio WiFi",
            currentDescription: "Studio WiFi")
        let a = try render(base)
        XCTAssertEqual(a, try render(base), "rendering is not repeatable")
        var other = base
        other.current = "Guest"
        XCTAssertNotEqual(a, try render(other))
        var failed = base
        failed.problem = "The device refused it."
        XCTAssertNotEqual(a, try render(failed))
        // The item for a selection the saved list lacks is drawn too, rather
        // than the pop-up coming out blank.
        let unknown = WifiNetworkRows.Model(
            savedNetworks: saved, current: nil,
            currentDescription: "Unknown (not reported yet)")
        var other2 = unknown
        other2.currentDescription = "None configured"
        XCTAssertNotEqual(try render(unknown), try render(other2))
    }
}
