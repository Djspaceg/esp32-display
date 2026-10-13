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

    /// The 4C's real CFGSHOW reply, from its own console on 2026-10-11.
    private static let bigRoundReply = "CFGINFO ssid64=U3RlcGhlbnMgTWFub3I= "
        + "name64=YmlnLXJvdW5k id=e8f60ae0a0e4 connected=1 ip=192.168.1.137 "
        + "rssi=-49 flip=0 rot=0 mirrorx=0 autorot=1 auto=0 effective=0 motion=0 "
        + "bl=high blfixed=0 bllow=24 blhigh=128 blidle=10 blsurvey=255 pwr=on "
        + "board=jd9365-4c profile=jd9365-4c target=p4 chip=esp32p4 "
        + "partition=p4-32m-saves-ota bat=-1 ota=on ssid=Stephens Manor caps=007967ff "
        + "bllevel=83 fw=2.0.0 src=094824ca50bdf5dedc93672254ef80fa2f365f84 "
        + "c6fw=2.12.13 c6=current"

    /// Another program reading the same port - a serial capture - takes the
    /// rest of the board's reply, so the app reads only its start. That piece
    /// carries no id=, and was taken as the board's answer: the port lost the
    /// board's hardware ID, counted as answered, and was never asked again, so
    /// the WiFi pop-up said to connect USB to a board connected by USB until
    /// it was replugged. Seen on the P4 4C. A cut-short answer is asked again,
    /// and the pop-up enables when the board's next reply is whole.
    func testAReplyCutShortByAnotherReaderIsAskedAgainAndTheWifiRowEnables() async throws {
        let asked = LockedLines()
        let board = try FakeSerialBoard(onCommand: { command in
            guard command == "CFGSHOW" else { return nil }
            asked.append(command)
            return asked.lines.count == 1
                ? "CFGINFO ssid64=U3RlcGhlbnMgTWFub3I= name64=YmlnLXJv"
                : Self.bigRoundReply + "\n"
        })
        defer { board.stop() }
        var panel = PanelSnapshot(serviceName: "big-round", displayName: "big-round")
        panel.hardwareID = "e8f60ae0a0e4"
        panel.usbHardwareID = "e8f60ae0a0e4"
        panel.usbPort = board.path
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])
        manager.usbIdentifyRetryDelays = [0.3]
        func tick() { manager.identifyUSBPorts(manager.updateUSBPorts([board.path])) }

        tick()
        let deadline = Date(timeIntervalSinceNow: 10)
        var enabled = false
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
            tick()
            if manager.wifiSwitchUnavailableReason(for: "big-round") == nil {
                enabled = true
                break
            }
        }

        XCTAssertGreaterThanOrEqual(
            asked.lines.count, 2, "a cut-short reply was taken as the board's answer")
        XCTAssertTrue(
            enabled,
            "the WiFi pop-up stayed disabled (\(manager.wifiSwitchUnavailableReason(for: "big-round") ?? "")) "
                + "with the board on USB after \(asked.lines.count) check(s)")
        XCTAssertEqual(
            manager.usbDevices.first { $0.path == board.path }?.hardwareID,
            "e8f60ae0a0e4")
    }
}
