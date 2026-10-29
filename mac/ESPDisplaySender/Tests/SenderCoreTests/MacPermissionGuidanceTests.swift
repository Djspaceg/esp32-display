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
            .cameraExtension,
        ] {
            XCTAssertFalse(permission.settingsButtonTitle.isEmpty)
            XCTAssertTrue((3...4).contains(permission.steps.count))
            XCTAssertFalse(permission.message(for: .needsAccess).isEmpty)
        }
    }

    func testChecklistKeepsTheFirstUnavailablePermissionAsTheNextRequest() {
        let items = [
            PermissionChecklistItem(
                permission: .screenRecording, status: .allowed, requiresRelaunch: false),
            PermissionChecklistItem(
                permission: .localNetwork, status: .notYetAsked, requiresRelaunch: false),
            PermissionChecklistItem(
                permission: .systemAudioRecording, status: .notYetAsked, requiresRelaunch: false),
        ]

        XCTAssertEqual(PermissionRequestSequence.next(in: items), .localNetwork)
        XCTAssertTrue(PermissionRequestSequence.shouldRequestAutomatically(items[1]))
    }

    func testCheckingPermissionDoesNotFlashTheLaunchChecklist() {
        let items = [
            PermissionChecklistItem(
                permission: .screenRecording, status: .allowed, requiresRelaunch: false),
            PermissionChecklistItem(
                permission: .localNetwork, status: .checking, requiresRelaunch: false),
            PermissionChecklistItem(
                permission: .systemAudioRecording, status: .allowed, requiresRelaunch: false),
            PermissionChecklistItem(
                permission: .accessibility, status: .allowed, requiresRelaunch: false),
        ]

        XCTAssertFalse(PermissionChecklistPresentation.shouldPresent(for: items))
        XCTAssertNil(PermissionRequestSequence.next(in: items))
        XCTAssertEqual(items[1].statusText, "Checking")
    }

    func testKnownMissingPermissionStillPresentsAfterChecksFinish() {
        let items = [
            PermissionChecklistItem(
                permission: .screenRecording, status: .allowed, requiresRelaunch: false),
            PermissionChecklistItem(
                permission: .localNetwork, status: .notYetAsked, requiresRelaunch: false),
        ]

        XCTAssertTrue(PermissionChecklistPresentation.shouldPresent(for: items))
        XCTAssertEqual(PermissionRequestSequence.next(in: items), .localNetwork)
    }

    func testACompletedSystemAudioCheckCanPresentItsRecoveryAction() {
        let items = [
            PermissionChecklistItem(
                permission: .screenRecording, status: .allowed, requiresRelaunch: false),
            PermissionChecklistItem(
                permission: .localNetwork, status: .allowed, requiresRelaunch: false),
            PermissionChecklistItem(
                permission: .systemAudioRecording, status: .blocked, requiresRelaunch: false),
        ]

        XCTAssertTrue(PermissionChecklistPresentation.shouldPresent(for: items))
        XCTAssertEqual(PermissionRequestSequence.next(in: items), .systemAudioRecording)
    }

    func testIndeterminateSystemAudioDoesNotFlashTheLaunchChecklist() {
        let items = [
            PermissionChecklistItem(
                permission: .screenRecording, status: .allowed, requiresRelaunch: false),
            PermissionChecklistItem(
                permission: .localNetwork, status: .allowed, requiresRelaunch: false),
            PermissionChecklistItem(
                permission: .systemAudioRecording, status: .checking,
                requiresRelaunch: false),
        ]

        XCTAssertFalse(PermissionChecklistPresentation.shouldPresent(for: items))
        XCTAssertNil(PermissionRequestSequence.next(in: items))
        XCTAssertEqual(items[2].statusText, "Checking")
    }

    func testCameraExtensionIsVisibleButNotInTheAutomaticSetupSequence() {
        XCTAssertFalse(MacPermission.cameraExtension.isRequiredAtLaunch)
        XCTAssertFalse(MacPermission.requestOrder.contains(.cameraExtension))
        XCTAssertEqual(
            MacPermission.allCases,
            [.screenRecording, .localNetwork, .systemAudioRecording, .accessibility,
             .cameraExtension])
        XCTAssertEqual(
            MacPermission.requestOrder,
            [.screenRecording, .localNetwork, .systemAudioRecording, .accessibility])
    }

    func testChecklistDoesNotAutoRequestPastABlockedPermission() {
        let blocked = PermissionChecklistItem(
            permission: .screenRecording, status: .blocked, requiresRelaunch: false)
        let later = PermissionChecklistItem(
            permission: .localNetwork, status: .notYetAsked, requiresRelaunch: false)

        XCTAssertEqual(PermissionRequestSequence.next(in: [blocked, later]), .screenRecording)
        XCTAssertFalse(PermissionRequestSequence.shouldRequestAutomatically(blocked))
    }

    func testChecklistShowsAllowedButRelaunchRequiredSeparately() {
        let item = PermissionChecklistItem(
            permission: .screenRecording, status: .allowed, requiresRelaunch: true)

        XCTAssertEqual(item.statusText, "Allowed - relaunch required")
        XCTAssertFalse(item.isReady)
    }

    func testCameraExtensionWordingExplainsWhatItDoes() {
        let permission = MacPermission.cameraExtension

        XCTAssertEqual(
            permission.purpose,
            "Makes device camera frames available to other video apps.")
        XCTAssertEqual(permission.settingsButtonTitle, "Open Extensions Settings")
        XCTAssertFalse(permission.message(for: .needsAccess).localizedCaseInsensitiveContains("declin"))
    }

    func testLocalNetworkPolicyDeniedDNSCodeIsRecognized() {
        XCTAssertTrue(
            LocalNetworkPermissionProbe.isPolicyDeniedDNSServiceError(-65_570))
        XCTAssertFalse(
            LocalNetworkPermissionProbe.isPolicyDeniedDNSServiceError(-65_569))
    }

    func testLocalNetworkNoRouteToHostIsRecognized() {
        XCTAssertTrue(
            LocalNetworkPermissionProbe.isLocalNetworkDenied(.posix(.EHOSTUNREACH)))
        XCTAssertFalse(
            LocalNetworkPermissionProbe.isLocalNetworkDenied(.posix(.ECONNREFUSED)))
    }

    @MainActor
    func testLocalNetworkBrowserAndMDNSReadyDoNotClearAProhibitedUnicastPath() {
        let manager = PanelManager(
            previewPanels: [], savedNetworkNames: [], usbSerialPorts: [])

        manager.observeLocalNetworkPermission(
            .policyDenied(technicalDetail: "PolicyDenied(-65570)"))
        XCTAssertEqual(
            manager.issues.first?.detail,
            "ESPDisplaySender isn't allowed to reach devices on your local network.")
        XCTAssertEqual(manager.issues.first?.permissionState, .needsAccess)
        manager.observeLocalNetworkPermission(.browserReady)
        XCTAssertTrue(manager.issues.contains { $0.issue == .localNetwork })
        // Build 628.1 reported Bonjour and mDNS ready while device UDP paths
        // were "unsatisfied (Local network prohibited)".
        manager.observeLocalNetworkPermission(
            .policyDenied(technicalDetail: "unicast path: Local network prohibited"))
        XCTAssertTrue(manager.issues.contains { $0.issue == .localNetwork })
        manager.observeLocalNetworkPermission(.unicastPathReady)
        XCTAssertFalse(manager.issues.contains { $0.issue == .localNetwork })
    }

    func testLocalNetworkEndpointPathDenialUsesTheExplicitPrivacyReason() {
        XCTAssertTrue(
            LocalNetworkPermissionProbe.isLocalNetworkDenied(.localNetworkDenied))
        XCTAssertFalse(LocalNetworkPermissionProbe.isLocalNetworkDenied(nil))
        XCTAssertFalse(
            LocalNetworkPermissionProbe.isLocalNetworkDenied(.notAvailable))
    }

    func testLocalNetworkProbeRechecksOnItsInterval() {
        let lastStarted = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertFalse(
            LocalNetworkPermissionProbe.shouldRecheck(
                lastStartedAt: lastStarted,
                now: lastStarted.addingTimeInterval(
                    LocalNetworkPermissionProbe.recheckInterval - 0.1)))
        XCTAssertTrue(
            LocalNetworkPermissionProbe.shouldRecheck(
                lastStartedAt: lastStarted,
                now: lastStarted.addingTimeInterval(
                    LocalNetworkPermissionProbe.recheckInterval)))
    }

    func testOldBrowserCallbacksAreIgnoredAfterANewAccessRequest() {
        XCTAssertFalse(LocalNetworkPermissionProbe.isCurrent(1, currentGeneration: 2))
        XCTAssertTrue(LocalNetworkPermissionProbe.isCurrent(2, currentGeneration: 2))
    }
}
