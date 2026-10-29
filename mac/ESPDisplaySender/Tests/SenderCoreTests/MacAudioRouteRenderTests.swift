import AppKit
import SwiftUI
import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// Renders a device's Audio section offscreen with the Play sound on choice:
/// following the Mac (the default) with and without the driver, the copy, and
/// a failed install. Set ESPDISP_RENDER_DIR to keep the PNGs.
@MainActor
final class MacAudioRouteRenderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func render(
        route: MacAudioRoute, plan: MacAudioRoutePlan?, source: String, message: String,
        driver: DisplayAudioDriverAvailability? = nil,
        setup: DisplayAudioDriverSetup = DisplayAudioDriverSetup(
            bundledDriver: true, signingTeam: "YSHQQLS73U")
    ) throws -> Data {
        var panel = PanelSnapshot(serviceName: "desk", displayName: "Desk")
        panel.audioStatus = PanelAudioSnapshot(
            state: .streaming, message: message, sourceName: source,
            uplinkDestination: PanelAudioSession.uplinkDestination,
            descriptor: AudioStreamDescriptor(
                port: 5569, version: 1, sampleRateHz: 16_000,
                playbackChannels: 2, captureChannels: 1),
            tuning: AudioRuntimeTuning(), panelStatus: nil, downlinkQueueDrops: 0,
            captureCallbackDrops: 0, uplinkLostFrames: 0, uplinkLatePackets: 0,
            downlinkCorrectionPPM: 0)
        panel.speakerVolume = 0.6
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])
        manager.setMacAudioRoute(route)
        if let plan { manager.macAudio.showForTesting(plan) }
        manager.macAudio.showForTesting(driver: driver, setup: setup)
        // The bottom of the page, where Audio sits.
        let size = NSSize(width: 640, height: 3_200)
        let host = NSHostingView(
            rootView: PanelDetailView(panel: panel, manager: manager)
                .frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testTheMacSoundChoiceRendersEachRoute() throws {
        let copy = try render(
            route: .copy, plan: nil, source: PanelAudioSession.tappedSourceName,
            message: PanelDownlinkSource.tapStreamingMessage)
        let absent = MacAudioRoutePlan.make(
            chosen: .followMac, driver: .absent, presentDisplayUIDs: [])
        let fallback = try render(
            route: .followMac, plan: absent, source: "Silence (the \"Desk\" output is not ready)",
            message: "The device's speaker gets silence because the \"Desk\" output could "
                + "not be read: the device's output has not appeared in macOS yet.",
            driver: .absent)
        var refused = DisplayAudioDriverSetup(bundledDriver: true, signingTeam: "YSHQQLS73U")
        refused.begin(.install, now: Date())
        refused.finished(
            .install, .failed("The administrator user name or password was incorrect."),
            now: Date())
        let failed = try render(
            route: .copy, plan: nil, source: PanelAudioSession.tappedSourceName,
            message: PanelDownlinkSource.tapStreamingMessage, driver: .absent,
            setup: refused)
        let only = try render(
            route: .followMac,
            plan: MacAudioRoutePlan.make(
                chosen: .followMac, driver: .ready,
                presentDisplayUIDs: [AppIdentity.audioDeviceUIDPrefix + "AAAA"]),
            source: "Mac output \"Desk\"",
            message: "Plays what this Mac sends to the \"Desk\" output while it is "
                + "chosen in Sound settings; quiet otherwise.",
            driver: .ready)
        XCTAssertGreaterThan(copy.count, 10_000, "the render came out empty")
        XCTAssertNotEqual(copy, fallback, "the fallback note is drawn")
        XCTAssertNotEqual(fallback, only)
        XCTAssertNotEqual(copy, failed, "the install error is drawn")

        if let dir = ProcessInfo.processInfo.environment["ESPDISP_RENDER_DIR"] {
            let url = URL(fileURLWithPath: dir)
            try copy.write(to: url.appendingPathComponent("mac-sound-copy.png"))
            try fallback.write(to: url.appendingPathComponent("mac-sound-driver-missing.png"))
            try only.write(to: url.appendingPathComponent("mac-sound-follow-mac.png"))
            try failed.write(to: url.appendingPathComponent("mac-sound-install-failed.png"))
        }
    }
}
