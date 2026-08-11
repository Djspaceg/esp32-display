import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// A battery reading has to expire.
///
/// EBAT arrives unprompted on the panel's own 10s timer and only when a sample
/// succeeded, so a PMU that stops answering produces silence rather than a
/// correction. The panel keeps heartbeating and keeps reporting EINF perfectly
/// well, so nothing else in the pipeline clears the last reading - the manager row
/// would show a percentage from hours ago as though it were current, in the one
/// place whose only job is to say what the cell is doing.
final class BatteryStalenessTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func panel(
        battery: DeviceProtocol.BatteryStatus?, age: TimeInterval?
    ) -> PanelSnapshot {
        var panel = PanelSnapshot(
            serviceName: "studio-display",
            displayName: "studio-display",
            lastSeen: now,
            lastHeartbeatAt: now,
            capabilitiesRaw: DeviceProtocol.Capabilities.battery.rawValue)
        panel.battery = battery
        panel.batteryAt = age.map { now.addingTimeInterval(-$0) }
        return panel
    }

    private func reading(
        percent: UInt8? = 87, present: Bool = true, externalPower: Bool = false,
        state: DeviceProtocol.ChargeState = .discharging
    ) -> DeviceProtocol.BatteryStatus {
        DeviceProtocol.BatteryStatus(
            present: present, externalPower: externalPower, percent: percent,
            state: state, millivolts: 4012)
    }

    /// Written out by hand rather than derived, so it stands as an independent
    /// statement of the same number the firmware header carries
    /// (deviceproto::BATTERY_MAX_AGE_MS, asserted as 45000 in the host tests).
    /// Both sides must call a reading stale at the same moment or the panel's own
    /// serial line and the manager row would disagree about the same cell.
    func testMaxAgeMatchesTheFirmwareCeiling() {
        XCTAssertEqual(DeviceProtocol.batteryMaxAge, 45)
    }

    func testFreshReadingReadsAsTheLevel() {
        let panel = panel(battery: reading(), age: 3)

        XCTAssertEqual(panel.batteryDescription(asOf: now), "87%, on battery")
    }

    /// The boundary, both sides of it. 45s is four missed samples, so one dropped
    /// datagram or one transient I2C failure must not blank the row.
    func testTheCeilingIsInclusive() {
        XCTAssertEqual(
            panel(battery: reading(), age: 44).batteryDescription(asOf: now),
            "87%, on battery")
        XCTAssertEqual(
            panel(battery: reading(), age: 45).batteryDescription(asOf: now),
            "87%, on battery")
        XCTAssertEqual(
            panel(battery: reading(), age: 46).batteryDescription(asOf: now),
            "No recent reading")
    }

    /// The failure the ceiling exists for: a PMU that answered at boot and then
    /// went quiet. The percentage must not still be on screen an hour later.
    func testAPmuThatStopsAnsweringStopsBeingQuoted() {
        let stale = panel(battery: reading(percent: 42), age: 3600)

        let text = stale.batteryDescription(asOf: now)
        XCTAssertEqual(text, "No recent reading")
        XCTAssertFalse(text.contains("42"))
        XCTAssertFalse(text.contains("%"))
    }

    /// Every phrase a fresh reading can produce, so the expiry cannot be
    /// mistaken for one of them. Four distinguishable states, and "stale" is the
    /// fifth - an unknown battery, a flat one, an absent one and a silent PMU are
    /// four different things to do about it.
    func testStaleIsDistinctFromEveryOtherAnswer() {
        XCTAssertEqual(
            panel(battery: nil, age: nil).batteryDescription(asOf: now),
            "Waiting for a reading")
        XCTAssertEqual(
            panel(battery: reading(percent: nil), age: 1)
                .batteryDescription(asOf: now),
            "Level unknown, on battery")
        XCTAssertEqual(
            panel(battery: reading(percent: 0), age: 1)
                .batteryDescription(asOf: now),
            "0%, on battery")
        XCTAssertEqual(
            panel(
                battery: reading(present: false, externalPower: true),
                age: 1
            ).batteryDescription(asOf: now),
            "No battery (USB power)")
        XCTAssertEqual(
            panel(battery: reading(), age: 600).batteryDescription(asOf: now),
            "No recent reading")
    }

    /// An expiry cannot be reported for a reading that never arrived: "waiting"
    /// and "stopped" are different, and a panel that has said nothing yet has not
    /// stopped saying anything.
    func testNoReadingIsNotReportedAsStale() {
        XCTAssertEqual(
            panel(battery: nil, age: 3600).batteryDescription(asOf: now),
            "Waiting for a reading")
    }

    /// Belt and braces on the accessor the UI actually calls: it must read the
    /// clock rather than being pinned to some fixed moment, or the row would never
    /// expire in the running app no matter what the tested function does.
    func testTheLiveAccessorUsesTheCurrentTime() {
        var live = panel(battery: reading(), age: nil)
        live.batteryAt = Date().addingTimeInterval(-DeviceProtocol.batteryMaxAge * 4)

        XCTAssertEqual(live.batteryDescription, "No recent reading")

        live.batteryAt = Date()
        XCTAssertEqual(live.batteryDescription, "87%, on battery")
    }
}

/// The timestamp has to be written where the reading is, or the expiry above can
/// never trigger.
@MainActor
final class BatteryTimestampTests: XCTestCase {

    private func makeManager() -> PanelManager {
        let panel = PanelSnapshot(
            serviceName: "studio-display",
            displayName: "studio-display",
            lastSeen: Date(),
            lastHeartbeatAt: Date(),
            capabilitiesRaw: DeviceProtocol.Capabilities.battery.rawValue)
        return PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])
    }

    /// Fed as bytes, the same vector the firmware test writes by hand, so the
    /// wiring is exercised end to end from a datagram rather than from a struct
    /// the parser might never produce.
    func testAnEbatDatagramStampsItsArrival() throws {
        let manager = makeManager()
        let packet = Data([
            0x45, 0x42, 0x41, 0x54,  // EBAT
            0x01,                    // battery version
            0x03,                    // present + external power
            0x57,                    // 87%
            0x01,                    // charging
            0xAC, 0x0F,              // 4012 mV
            0x00, 0x00,              // reserved
        ])
        let status = try XCTUnwrap(DeviceProtocol.parseBattery(packet))

        XCTAssertNil(manager.panels.first?.batteryAt)
        manager.update(.battery(status), for: "studio-display")

        let panel = try XCTUnwrap(manager.panels.first)
        let at = try XCTUnwrap(panel.batteryAt)
        XCTAssertEqual(at.timeIntervalSinceNow, 0, accuracy: 5)
        XCTAssertEqual(panel.batteryDescription, "87%, charging")
    }
}
