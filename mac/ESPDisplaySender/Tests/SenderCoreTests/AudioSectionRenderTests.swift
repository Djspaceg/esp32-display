import AppKit
import SwiftUI
import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// Renders a display's settings offscreen with its Audio section: the volume
/// slider, what the display speaker is sent, and where the display microphone
/// goes, both while the Mac's sound streams and after the permission is
/// refused. Set ESPDISP_RENDER_DIR to keep the PNGs.
@MainActor
final class AudioSectionRenderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func audio(source: String, message: String) -> PanelAudioSnapshot {
        PanelAudioSnapshot(
            state: .streaming,
            message: message,
            sourceName: source,
            uplinkDestination: PanelAudioSession.uplinkDestination,
            descriptor: AudioStreamDescriptor(
                port: 5569, version: 1, sampleRateHz: 16_000,
                playbackChannels: 2, captureChannels: 1),
            tuning: AudioRuntimeTuning(),
            panelStatus: nil,
            downlinkQueueDrops: 0,
            captureCallbackDrops: 0,
            uplinkLostFrames: 0,
            uplinkLatePackets: 0,
            downlinkCorrectionPPM: 0)
    }

    private func render(_ audio: PanelAudioSnapshot, volume: Double) throws -> Data {
        var panel = PanelSnapshot(serviceName: "desk", displayName: "Desk Display")
        panel.audioStatus = audio
        panel.speakerVolume = volume
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])
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

    func testTheAudioSectionRendersStreamingAndRefused() throws {
        let streaming = try render(
            audio(
                source: PanelAudioSession.tappedSourceName,
                message: "Sending this Mac's sound to the display speaker. The "
                    + "Mac's own speakers keep playing."),
            volume: 0.6)
        let refused = try render(
            audio(
                source: "Silence (no permission to record this Mac's sound)",
                message: "The device's speaker gets silence because "
                    + "ESPDisplaySender is not allowed to record this Mac's "
                    + "sound. To send it, turn on ESPDisplaySender in System "
                    + "Settings > Privacy & Security > Screen & System Audio "
                    + "Recording, under System Audio Recording Only."),
            volume: 0.6)
        XCTAssertGreaterThan(streaming.count, 10_000, "the render came out empty")
        XCTAssertNotEqual(streaming, refused, "the refusal is drawn")

        if let dir = ProcessInfo.processInfo.environment["ESPDISP_RENDER_DIR"] {
            let url = URL(fileURLWithPath: dir)
            try streaming.write(to: url.appendingPathComponent("audio-section-streaming.png"))
            try refused.write(to: url.appendingPathComponent("audio-section-refused.png"))
        }
    }
}
