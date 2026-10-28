import XCTest
@testable import SenderCore

final class MacPermissionGuidanceTests: XCTestCase {
    func testScreenRecordingMessageExplainsTheNewAppIdentityWithoutBlamingTheUser() {
        let message = MacPermission.screenRecording.message(for: .needsAccess)

        XCTAssertEqual(
            message,
            "This copy of ESPDisplaySender is not allowed to record the screen "
                + "yet. Devices stay connected and controllable, but no picture can "
                + "be sent. A rebuilt or re-signed app needs permission again. If an "
                + "old ESPDisplaySender entry is listed, remove it before turning this "
                + "one on.")
        XCTAssertFalse(message.localizedCaseInsensitiveContains("declin"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("tcc"))
    }

    func testScreenRecordingWalkthroughHasTheRecoveryStepsInOrder() {
        XCTAssertEqual(
            MacPermission.screenRecording.steps,
            [
                "Open Screen Recording Settings.",
                "Remove an old ESPDisplaySender entry if one is listed.",
                "Turn on this copy of ESPDisplaySender.",
                "Relaunch ESPDisplaySender.",
            ])
    }

    func testScreenRecordingStateClearsAsSoonAsCaptureWorks() {
        var state = ScreenRecordingPermissionState.ready

        state.observeAuthorization(false)
        XCTAssertEqual(state, .needsAccess)
        state.observeAuthorization(true)
        XCTAssertEqual(state, .grantedNeedsRelaunch)
        state.observeCaptureResult(works: true, authorized: true)
        XCTAssertEqual(state, .ready)
        XCTAssertNil(state.issueState)
    }

    func testGrantThatStillCannotCaptureAsksForRelaunch() {
        var state = ScreenRecordingPermissionState.needsAccess

        state.observeCaptureResult(works: false, authorized: true)

        XCTAssertEqual(state.issueState, .grantedNeedsRelaunch)
        XCTAssertEqual(
            MacPermission.screenRecording.message(for: .grantedNeedsRelaunch),
            "Permission granted - relaunch to start sending pictures.")
    }

    func testEveryUsedPermissionSharesActionsAndAWalkthrough() {
        for permission in [
            MacPermission.screenRecording,
            .accessibility,
            .systemAudioRecording,
        ] {
            XCTAssertFalse(permission.settingsButtonTitle.isEmpty)
            XCTAssertEqual(permission.steps.count, 4)
            XCTAssertFalse(permission.message(for: .needsAccess).isEmpty)
        }
    }
}
