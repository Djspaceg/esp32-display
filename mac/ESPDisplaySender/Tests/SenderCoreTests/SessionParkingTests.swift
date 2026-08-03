import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// A session used to keep capturing the screen and pushing frames at a device
/// that had stopped answering, which is where 213,000 send errors against a
/// switched-off panel came from. Parking is the fix, and it has two decisions:
/// when to give up, and what counts as the device coming back.
final class SessionParkingTests: XCTestCase {

    // MARK: when to park

    /// Nothing heard yet is the startup case, handled by the connect retries in
    /// run(). Parking there would fight those retries.
    func testNeverHeardFromDoesNotPark() {
        XCTAssertFalse(DeviceSession.shouldPark(silentFor: nil))
    }

    func testBriefSilenceDoesNotPark() {
        for age in [0, 1, 5, 9, 10, 20, 29] as [TimeInterval] {
            XCTAssertFalse(
                DeviceSession.shouldPark(silentFor: age),
                "parked after only \(age)s")
        }
    }

    /// The threshold sits well past the 10s reconnect trigger, so a WiFi stumble
    /// is healed by re-resolving rather than by stopping capture.
    func testSilenceLongerThanTheReconnectWindowParks() {
        XCTAssertTrue(DeviceSession.shouldPark(silentFor: 31))
        XCTAssertTrue(DeviceSession.shouldPark(silentFor: 60))
        XCTAssertTrue(DeviceSession.shouldPark(silentFor: 86_400))
    }

    // MARK: when to resume

    /// The trap this avoids: reconnecting refreshes the heartbeat grace period,
    /// so heartbeat age reads as fresh again even against a dead panel. Only a
    /// genuine new reply counts.
    func testNoNewReplyMeansStillParked() {
        XCTAssertFalse(
            DeviceSession.hasDeviceReturned(repliesNow: 42, repliesWhenParked: 42))
    }

    func testANewReplyResumes() {
        XCTAssertTrue(
            DeviceSession.hasDeviceReturned(repliesNow: 43, repliesWhenParked: 42))
    }

    /// The counter is a wrapping add, so a session must not stay parked forever
    /// if it happens to wrap while waiting.
    func testWrappedCounterResumes() {
        XCTAssertTrue(
            DeviceSession.hasDeviceReturned(
                repliesNow: 0, repliesWhenParked: UInt64.max))
    }
}

/// The sender half of parking: a parked sender drops frames rather than queuing
/// them, so nothing is sent at a device that is not there.
final class SenderParkingTests: XCTestCase {

    private func makeSender() -> FrameSender {
        // Never started, so no socket is opened.
        FrameSender(host: "127.0.0.1", port: 5568)
    }

    func testStartsUnparked() {
        XCTAssertFalse(makeSender().parked)
    }

    func testParkingRoundTrips() {
        let sender = makeSender()

        sender.setParked(true)
        XCTAssertTrue(sender.parked)

        sender.setParked(false)
        XCTAssertFalse(sender.parked)
    }

    /// Parking is automatic and must not be confused with the user's own pause,
    /// or resuming a panel would silently undo the other.
    func testParkingIsIndependentOfPausing() {
        let sender = makeSender()

        sender.setParked(true)
        XCTAssertFalse(sender.paused)

        sender.setPaused(true)
        XCTAssertTrue(sender.parked)

        sender.setParked(false)
        XCTAssertTrue(sender.paused, "unparking cleared the user's pause")
    }

    /// The reply counter is the parking signal, so it must start from a known
    /// value and never be advanced by anything other than a real reply.
    func testReplyCounterStartsAtZero() {
        XCTAssertEqual(makeSender().deviceRepliesReceived, 0)
    }

    func testParkingDoesNotCountAsAReply() {
        let sender = makeSender()

        sender.setParked(true)
        sender.setParked(false)

        XCTAssertEqual(sender.deviceRepliesReceived, 0)
    }
}

/// The manager side: a parked panel has to look different from an idle one.
@MainActor
final class ParkedPanelPresentationTests: XCTestCase {

    private func status(
        parked: Bool, serviceName: String = "studio-display"
    ) -> DeviceSession.Status {
        DeviceSession.Status(
            serviceName: serviceName,
            displayFPS: parked ? 0 : 39.5,
            framesSent: 1_000,
            sendErrors: 0,
            diffPercent: 12,
            heartbeatAge: parked ? 45 : 0.5,
            stats: BandProtocol.DeviceStats(shown: 990, heap: 180_000),
            info: nil,
            resolvedAddress: "192.168.1.42",
            spacingMicros: 200,
            paused: false,
            parked: parked,
            sourceDescription: "Tiny Monitor",
            updatedAt: Date())
    }

    func testParkedSessionExplainsItselfOnThePanel() {
        let manager = PanelManager(
            previewPanels: [], savedNetworkNames: [], usbSerialPorts: [])

        manager.update(status(parked: true))

        XCTAssertNotNil(manager.panels.first?.lastError)
    }

    func testResumingClearsTheExplanation() {
        let manager = PanelManager(
            previewPanels: [], savedNetworkNames: [], usbSerialPorts: [])
        manager.update(status(parked: true))
        XCTAssertNotNil(manager.panels.first?.lastError)

        manager.update(status(parked: false))

        XCTAssertNil(manager.panels.first?.lastError)
    }

    /// Parking is not pausing: the pause control must not appear engaged.
    func testParkedPanelIsNotShownAsPaused() {
        let manager = PanelManager(
            previewPanels: [], savedNetworkNames: [], usbSerialPorts: [])

        manager.update(status(parked: true))

        XCTAssertFalse(manager.panels.first?.paused == true)
    }
}
