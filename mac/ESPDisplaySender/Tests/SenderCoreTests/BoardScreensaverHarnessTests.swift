import AppKit
import Foundation
import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// Gives a real board the default screensaver through the code path the app
/// uses: a blank record, a `DeviceSession` over a real `FrameSender`, and the
/// EINF the board answers with. Runs only when ESPDISP_BOARD_HOST,
/// ESPDISP_BOARD_SERVICE and ESPDISP_BOARD_ID (the board's hardware ID) are set.
/// It opens no serial port and no window, and it replaces the board's saved
/// screensaver. Hold it for ESPDISP_BOARD_HOLD_SECONDS (default 75) so the
/// firmware's once-a-minute NVS check saves what was pushed.
///
/// Skipped while the app is running: the board answers whichever sender spoke
/// last, and the app would push its own template over this one.
@MainActor
final class BoardScreensaverHarnessTests: XCTestCase {

    func testBlankBoardIsGivenTheDefaultWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["ESPDISP_BOARD_HOST"],
              let service = environment["ESPDISP_BOARD_SERVICE"],
              let hardwareID = environment["ESPDISP_BOARD_ID"]
        else { throw XCTSkip("no board configured") }
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: AppIdentity.bundleIdentifier).isEmpty
        else { throw XCTSkip("ESPDisplaySender is running and would push over this") }
        let requested = Double(environment["ESPDISP_BOARD_HOLD_SECONDS"] ?? "") ?? 75
        let hold = requested.isFinite ? min(max(requested, 0), 600) : 75

        // The hardware ID makes the manager reject any other board that
        // answers, such as one at a stale cached address. A malformed one
        // would read as no ID at all and let any board through, so it stops
        // the run instead; the USB serial number is not this ID.
        let expectedID = try XCTUnwrap(
            ConfigCommands.canonicalHardwareID(hardwareID),
            "ESPDISP_BOARD_ID must be the board's 12-hex-digit id= value")
        var record = PanelSnapshot(serviceName: service, displayName: service)
        record.hardwareID = expectedID
        let manager = PanelManager(
            previewPanels: [record], savedNetworkNames: [], usbSerialPorts: [])
        manager.serialIODisabled = true
        XCTAssertEqual(manager.panels.first?.idleText, "")

        let sender = FrameSender(
            host: host, port: 5568,
            onDeviceEvent: { event in
                Task { @MainActor in manager.update(event, for: service) }
            })
        manager.register(DeviceSession(
            name: service, sender: sender,
            source: .auto(defaultDisplay: ""), picker: nil, fps: 30))
        try await sender.start()
        defer { sender.stop() }

        let deadline = Date(timeIntervalSinceNow: 15)
        while manager.panels.first?.idleText.isEmpty ?? true, Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let panel = try XCTUnwrap(manager.panels.first)
        // firmwareVersion and address come only from the board's EINF, so
        // "?" here means the board never answered.
        print("harness: expected id=\(expectedID), board reported "
            + "fw=\(panel.firmwareVersion ?? "?") address=\(panel.address ?? "?")")
        XCTAssertTrue(panel.capabilities.contains(.idleText), "board lacks idleText")
        XCTAssertEqual(panel.idleText, ScreensaverTemplate.standard)
        guard panel.idleText == ScreensaverTemplate.standard else { return }
        print("harness: stored template \(panel.idleText.debugDescription)")
        print("harness: pushed lines \(manager.screensaverPreview(for: service).lines)")

        try await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
        print("harness: last pushed lines \(manager.screensaverPreview(for: service).lines)")
    }
}
