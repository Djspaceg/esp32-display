import AppKit
import SwiftUI
import XCTest

@testable import SenderCore

/// Renders the two read-only WiFi rows offscreen, in the states the board can
/// report, so the wording can be looked at without a window or a board. Set
/// ESPDISP_RENDER_DIR to keep the PNG.
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
    private let preset = "Studio WiFi (slot 2 of 10, at the last USB copy)"

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

    private var sheet: some View {
        Form {
            ForEach(Array(cases.enumerated()), id: \.offset) { _, item in
                Section(item.title) {
                    WifiNetworkRows(
                        connectedDescription: item.panel.boardNetworkDescription(asOf: self.now),
                        presetDescription: self.preset)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 1000)
    }

    func testTheRowsRenderForEveryReportedState() throws {
        let host = NSHostingView(rootView: sheet)
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 1000)
        host.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000, "the render came out empty")

        // What each state reads as, so the picture and the words cannot drift.
        XCTAssertEqual(
            cases.map { $0.panel.boardNetworkDescription(asOf: now) },
            ["Studio WiFi", "Not answering (set to \"Studio WiFi\")",
             "Neighbours WiFi", "Connected (name not reported)",
             "Unknown (not reported yet)", "None configured"])

        if let dir = ProcessInfo.processInfo.environment["ESPDISP_RENDER_DIR"] {
            try png.write(to: URL(fileURLWithPath: dir)
                .appendingPathComponent("wifi-rows.png"))
        }
    }

    /// The row draws the words it is given: changing only the board's report
    /// changes the pixels. Without this the test above would still pass if the
    /// view stopped showing `connectedDescription`.
    func testTheConnectedRowDrawsTheBoardsReport() throws {
        func render(_ words: String) throws -> Data {
            let view = Form {
                WifiNetworkRows(
                    connectedDescription: words, presetDescription: preset)
            }
            .formStyle(.grouped)
            .frame(width: 560, height: 160)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 160)
            host.appearance = NSAppearance(named: .aqua)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return try XCTUnwrap(rep.tiffRepresentation)
        }
        let a = try render("Studio WiFi")
        XCTAssertEqual(a, try render("Studio WiFi"), "rendering is not repeatable")
        XCTAssertNotEqual(a, try render("Unknown (not reported yet)"))
    }
}
