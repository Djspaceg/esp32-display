import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// Pairing a port with a display by the USB serial number macOS reports for
/// the device behind it, read from the IORegistry without opening the port.
/// The serial is learned from a port where the board answered CFGSHOW with the
/// record's hardware ID, so a P4's console chip is learned and its JTAG port,
/// which answers nothing, never is.
@MainActor
final class UsbSerialPairingTests: XCTestCase {
    private static let hardwareID = "e8f60ae0a0e4"
    private static let consoleSerial = "5B90170069"

    private func manager(serials: [String: String]) -> PanelManager {
        var panel = PanelSnapshot(serviceName: "big-round", displayName: "big-round")
        panel.hardwareID = Self.hardwareID
        panel.usbHardwareID = Self.hardwareID
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])
        manager.usbSerialReader = { serials[$0] }
        return manager
    }

    func testAnAnswerTeachesTheRecordItsPortsUSBSerial() {
        let manager = manager(serials: ["/dev/cu.usbmodem-a": Self.consoleSerial])
        manager.updateUSBPorts(["/dev/cu.usbmodem-a"])
        manager.noteUSBIdentity(
            path: "/dev/cu.usbmodem-a", name: "big-round", hardwareID: Self.hardwareID)
        XCTAssertEqual(manager.panels.first?.usbSerialNumbers, [Self.consoleSerial])
        let restored = PersistedPanel(snapshot: manager.panels[0]).snapshot
        XCTAssertEqual(restored.usbSerialNumbers, [Self.consoleSerial])
    }

    /// Plugged in again on a new path and silent while it boots: the serial
    /// says it is this display's board at once, so it is asked until it
    /// answers, and the WiFi row says it is waiting rather than asking for USB.
    func testASilentBoardIsPairedByItsUSBSerialOnAnyPath() async throws {
        let board = try FakeSerialBoard(onCommand: { _ in nil })
        defer { board.stop() }
        let manager = manager(serials: [board.path: Self.consoleSerial])
        manager.panels[0].usbSerialNumbers = [Self.consoleSerial]
        manager.usbUnknownPortRetryAttempts = 2
        manager.updateUSBPorts([board.path])
        for _ in 0..<4 {
            if let pending = manager.usbIdentifyRetries[board.path] {
                manager.usbIdentifyRetries[board.path]?.nextAt = pending.nextAt - 100
            }
            _ = await manager.probeUSBDevice(board.path, timeout: 0.1)
        }
        XCTAssertNotNil(manager.usbIdentifyRetries[board.path],
            "a port the display's USB serial is on was let go")
        XCTAssertEqual(
            manager.wifiSwitchUnavailableReason(for: "big-round"),
            "Connected by USB. Waiting for this display to answer.")
    }

    /// The P4's JTAG port reports the board's MAC as its serial and carries
    /// no console. Nothing answered there, so it is not paired.
    func testAPortThatNeverAnsweredIsNotPairedByAMACShapedSerial() {
        let manager = manager(serials: [
            "/dev/cu.usbmodem-console": Self.consoleSerial,
            "/dev/cu.usbmodem-jtag": "E8:F6:0A:E0:A0:E4",
        ])
        manager.updateUSBPorts(["/dev/cu.usbmodem-console", "/dev/cu.usbmodem-jtag"])
        manager.noteUSBIdentity(
            path: "/dev/cu.usbmodem-console", name: "big-round",
            hardwareID: Self.hardwareID)
        XCTAssertEqual(manager.panels.first?.usbSerialNumbers, [Self.consoleSerial])
        XCTAssertFalse(manager.usbPortBelongsToADisplay("/dev/cu.usbmodem-jtag"))
        XCTAssertTrue(manager.usbPortBelongsToADisplay("/dev/cu.usbmodem-console"))
    }

    /// A serial belongs to one board: learned by another record, it moves.
    func testASerialMovesToTheRecordWhoseBoardAnswersBehindIt() {
        let manager = manager(serials: ["/dev/cu.usbmodem-a": "SHARED"])
        var other = PanelSnapshot(serviceName: "other", displayName: "other")
        other.hardwareID = "020000123456"
        other.usbSerialNumbers = ["SHARED"]
        manager.panels.append(other)
        manager.updateUSBPorts(["/dev/cu.usbmodem-a"])
        manager.noteUSBIdentity(
            path: "/dev/cu.usbmodem-a", name: "big-round", hardwareID: Self.hardwareID)
        XCTAssertEqual(manager.panels.first { $0.serviceName == "big-round" }?
            .usbSerialNumbers, ["SHARED"])
        XCTAssertEqual(manager.panels.first { $0.serviceName == "other" }?
            .usbSerialNumbers, [])
    }

    /// A board on the display's USB serial that answers CFGSHOW without id=
    /// (firmware from before it, or a reply another reader keeps cutting
    /// short) is asked again a bounded number of times, then left, and the
    /// WiFi row says why instead of waiting forever.
    func testABoardThatKeepsAnsweringWithoutAnIDIsLeftAndTheRowSaysWhy() async throws {
        let asked = LockedLines()
        let board = try FakeSerialBoard(onCommand: { command in
            guard command == "CFGSHOW" else { return nil }
            asked.append(command)
            return "CFGINFO ssid64=U3RlcGhlbnMgTWFub3I= name64=YmlnLXJvdW5k\n"
        })
        defer { board.stop() }
        let manager = manager(serials: [board.path: Self.consoleSerial])
        manager.panels[0].usbSerialNumbers = [Self.consoleSerial]
        manager.updateUSBPorts([board.path])
        for _ in 0..<(PanelManager.usbIDlessAnswerLimit + 3) {
            if let pending = manager.usbIdentifyRetries[board.path] {
                manager.usbIdentifyRetries[board.path]?.nextAt = pending.nextAt - 100
            }
            if manager.usbPortsDueForIdentifyRetry().contains(board.path)
                || asked.lines.isEmpty {
                _ = await manager.probeUSBDevice(board.path, timeout: 0.5)
            }
        }
        XCTAssertEqual(asked.lines.count, PanelManager.usbIDlessAnswerLimit,
            "a board answering without an ID was asked without end")
        XCTAssertNil(manager.usbIdentifyRetries[board.path])
        XCTAssertEqual(
            manager.wifiSwitchUnavailableReason(for: "big-round"),
            "This display answers over USB without reporting its hardware ID, so "
                + "it cannot be paired. Update its firmware, then unplug it and "
                + "plug it in again.")

        // Plugged in again, it is asked again from the start.
        manager.updateUSBPorts([])
        manager.updateUSBPorts([board.path])
        XCTAssertEqual(
            manager.wifiSwitchUnavailableReason(for: "big-round"),
            "Connected by USB. Waiting for this display to answer.")
    }
}
