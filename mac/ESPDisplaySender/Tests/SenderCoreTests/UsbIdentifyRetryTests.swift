import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// A board plugged in while it is still booting misses the app's first CFGSHOW.
/// The app used to ask once and never again, so the board stayed unverified -
/// Apply greyed out, not shown as connected - until the user pressed refresh or
/// replugged it. Seen on the P4 4C.
@MainActor
final class UsbIdentifyRetryTests: XCTestCase {

    private static let hardwareID = "1cdbd47b5b94"

    func manager(port: String) -> PanelManager {
        var panel = PanelSnapshot(serviceName: "espdisplay-5b94", displayName: "Desk")
        panel.hardwareID = Self.hardwareID
        panel.usbHardwareID = Self.hardwareID
        panel.usbPort = port
        return PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])
    }

    /// The board ignores the first CFGSHOW, as one still booting does, and
    /// answers every one after. Driven through the app's own two-second port
    /// refresh, with the port list a test can supply.
    func testABoardThatMissesItsFirstIdentityCheckIsAskedAgainUntilItAnswers() async throws {
        let asked = LockedLines()
        let board = try FakeSerialBoard(onCommand: { command in
            guard command == "CFGSHOW" else { return nil }
            asked.append(command)
            return asked.lines.count == 1 ? nil : SerialReplyFramingTests.reply + "\n"
        })
        defer { board.stop() }
        let manager = manager(port: board.path)
        let serviceName = try XCTUnwrap(manager.panels.first?.serviceName)
        func tick() { manager.identifyUSBPorts(manager.updateUSBPorts([board.path])) }

        tick()
        let deadline = Date(timeIntervalSinceNow: 12)
        var verified = false
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
            tick()
            if case .verified = manager.usbSerialState(for: serviceName) {
                verified = true
                break
            }
        }

        XCTAssertGreaterThanOrEqual(
            asked.lines.count, 2,
            "a missed identity check must be asked again without a refresh or replug")
        XCTAssertTrue(
            verified,
            "the board answered its second CFGSHOW but stayed "
                + "\(manager.usbSerialState(for: serviceName)) after "
                + "\(asked.lines.count) check(s)")
        // Slow to answer is not a failure: nothing was reported.
        XCTAssertNil(manager.operationOutcome)
        XCTAssertTrue(manager.issues.isEmpty, "\(manager.issues)")
    }
}
