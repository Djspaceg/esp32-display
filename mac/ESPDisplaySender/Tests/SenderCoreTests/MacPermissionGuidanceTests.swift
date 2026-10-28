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
            .localNetwork,
        ] {
            XCTAssertFalse(permission.settingsButtonTitle.isEmpty)
            XCTAssertTrue((3...4).contains(permission.steps.count))
            XCTAssertFalse(permission.message(for: .needsAccess).isEmpty)
        }
    }

    func testLocalNetworkPolicyDeniedDNSCodeIsRecognized() {
        XCTAssertTrue(
            LocalNetworkPermissionProbe.isPolicyDeniedDNSServiceError(-65_570))
        XCTAssertFalse(
            LocalNetworkPermissionProbe.isPolicyDeniedDNSServiceError(-65_569))
    }

    @MainActor
    func testLocalNetworkBannerClearsWhenABrowseBecomesReadyWithoutADevice() {
        let manager = PanelManager(
            previewPanels: [], savedNetworkNames: [], usbSerialPorts: [])

        manager.observeLocalNetworkPermission(
            .policyDenied(technicalDetail: "PolicyDenied(-65570)"))
        XCTAssertEqual(
            manager.issues.first?.detail,
            "ESPDisplaySender isn't allowed to reach devices on your local network.")
        XCTAssertEqual(manager.issues.first?.permissionState, .needsAccess)
        manager.observeLocalNetworkPermission(.authorized)
        XCTAssertFalse(manager.issues.contains { $0.issue == .localNetwork })
    }

    func testOldBrowserCallbacksAreIgnoredAfterANewAccessRequest() {
        XCTAssertFalse(LocalNetworkPermissionProbe.isCurrent(1, currentGeneration: 2))
        XCTAssertTrue(LocalNetworkPermissionProbe.isCurrent(2, currentGeneration: 2))
    }
}
