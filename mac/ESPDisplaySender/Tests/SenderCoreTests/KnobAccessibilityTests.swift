import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// The knob's media keys need the Accessibility grant. After a declined
/// prompt macOS never asks again, so the app itself has to say what is wrong
/// and offer the way to System Settings.
///
/// The authorization check, the prompt and the key sender are injected: a
/// real media key would change the volume of whoever runs the suite, and the
/// real prompt would take the screen.
@MainActor
final class KnobAccessibilityTests: XCTestCase {

    private var sentKeys: [MediaControl.Key] = []
    private var prompts = 0

    private func manager(authorized: Bool) -> PanelManager {
        let subject = PanelManager(
            previewPanels: [PanelSnapshot(serviceName: "knob", displayName: "Knob")],
            savedNetworkNames: [],
            usbSerialPorts: [])
        subject.mediaKeysAuthorized = { authorized }
        subject.requestMediaKeyAuthorization = { [unowned self] in prompts += 1 }
        subject.mediaKeySender = { [unowned self] key in
            sentKeys.append(key)
            return nil
        }
        return subject
    }

    private func knob(
        _ gesture: DeviceProtocol.TouchGesture, _ sequence: UInt16
    ) -> FrameSender.DeviceEvent {
        .touch(
            DeviceProtocol.TouchEvent(
                gesture: gesture, sequence: sequence, x: 0, y: 0, landscape: false))
    }

    func testAKnobWithoutTheGrantShowsANoticeThatOpensAccessibilitySettings() throws {
        let subject = manager(authorized: false)

        subject.update(knob(.knobClockwise, 1), for: "knob")

        let issue = try XCTUnwrap(subject.issues.first { $0.issue == .accessibility })
        XCTAssertTrue(issue.detail.contains("Accessibility"))
        XCTAssertEqual(
            issue.issue.settingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        XCTAssertEqual(prompts, 1)
        XCTAssertTrue(sentKeys.isEmpty, "a key was posted without the grant")
        // The notice replaces the per-detent alert, so a turn is one banner.
        XCTAssertNil(subject.operationOutcome)
    }

    func testFurtherDetentsKeepOneNotice() {
        let subject = manager(authorized: false)

        subject.update(knob(.knobClockwise, 1), for: "knob")
        subject.update(knob(.knobClockwise, 2), for: "knob")
        subject.update(knob(.knobPress, 3), for: "knob")

        XCTAssertEqual(subject.issues.filter { $0.issue == .accessibility }.count, 1)
    }

    func testWithTheGrantTheKnobSendsItsKeysAndTheNoticeGoes() {
        let subject = manager(authorized: false)
        subject.update(knob(.knobClockwise, 1), for: "knob")
        XCTAssertFalse(subject.issues.isEmpty)

        subject.mediaKeysAuthorized = { true }
        subject.update(knob(.knobClockwise, 2), for: "knob")
        subject.update(knob(.knobCounterclockwise, 3), for: "knob")
        subject.update(knob(.knobPress, 4), for: "knob")

        XCTAssertEqual(sentKeys, [.volumeUp, .volumeDown, .mute])
        XCTAssertFalse(subject.issues.contains { $0.issue == .accessibility })
    }

    func testOnlyAccessibilityOffersASettingsButton() {
        for issue in AppIssue.allCases where issue != .accessibility {
            XCTAssertNil(issue.settingsURL, "\(issue)")
        }
        XCTAssertFalse(AppIssue.accessibility.title.isEmpty)
    }
}
