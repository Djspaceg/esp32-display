import XCTest
@testable import SenderCore

final class MacPermissionGuidanceTests: XCTestCase {
    func testScreenCaptureSessionsUseTheForegroundAuthorizationSnapshot() {
        defer { ScreenCapturePermissionGate.observeAuthorization(false) }

        ScreenCapturePermissionGate.observeAuthorization(false)
        XCTAssertFalse(ScreenCapturePermissionGate.permitsScreenCaptureKit())

        ScreenCapturePermissionGate.observeAuthorization(true)
        XCTAssertTrue(ScreenCapturePermissionGate.permitsScreenCaptureKit())
    }

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

    func testDeniedPickerDoesNotActivateOrPresentScreenCaptureKit() {
        var activationCount = 0
        var presentationCount = 0
        let picker = PickerSource(
            hasScreenRecordingPermission: { false },
            activateSystemPicker: { _ in activationCount += 1 },
            presentSystemPicker: { _ in presentationCount += 1 })

        XCTAssertFalse(picker.activate())
        XCTAssertFalse(picker.present())
        XCTAssertEqual(activationCount, 0)
        XCTAssertEqual(presentationCount, 0)
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
                permission: .localNetwork, status: .allowed, requiresRelaunch: false),
            PermissionChecklistItem(
                permission: .cameraExtension, status: .notYetAsked, requiresRelaunch: false),
            PermissionChecklistItem(
                permission: .systemAudioRecording, status: .notYetAsked, requiresRelaunch: false),
        ]

        XCTAssertEqual(PermissionRequestSequence.next(in: items), .cameraExtension)
        XCTAssertTrue(PermissionRequestSequence.shouldRequestAutomatically(items[2]))
    }

    func testUnknownPermissionDoesNotOpenSettingsAtLaunch() {
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

        XCTAssertFalse(PermissionChecklistLaunchDecision.shouldOpenSettings(for: items))
        XCTAssertNil(PermissionRequestSequence.next(in: items))
        XCTAssertEqual(items[1].statusText, "Checking")
    }

    func testFirstUnknownLocalNetworkCheckOpensSettingsWithoutCallingItMissing() {
        let items = [
            PermissionChecklistItem(
                permission: .screenRecording, status: .allowed, requiresRelaunch: false),
            PermissionChecklistItem(
                permission: .localNetwork, status: .checking, requiresRelaunch: false),
        ]

        XCTAssertTrue(PermissionChecklistLaunchDecision.shouldOpenSettings(
            for: items, localNetworkWasPreviouslyVerified: false))
        XCTAssertEqual(items[1].statusText, "Checking")
    }

    func testLocalNetworkLaunchHistoryDoesNotCarryAcrossSigningTeams() {
        let oldIdentity = LocalNetworkLiveAccessHistory.identity(
            bundleIdentifier: "com.resourcefork.espdisplay",
            teamIdentifier: "OLDTEAM123")
        let newIdentity = LocalNetworkLiveAccessHistory.identity(
            bundleIdentifier: "com.resourcefork.espdisplay",
            teamIdentifier: "4D22XL743H")
        let suite = "LocalNetworkLaunchHistoryTests." + UUID().uuidString
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LocalNetworkLiveAccessHistory.key(for: oldIdentity))

        XCTAssertNotEqual(
            LocalNetworkLiveAccessHistory.key(for: oldIdentity),
            LocalNetworkLiveAccessHistory.key(for: newIdentity))
        XCTAssertTrue(
            LocalNetworkLiveAccessHistory.wasPreviouslyVerified(
                for: oldIdentity, defaults: defaults))
        XCTAssertFalse(
            LocalNetworkLiveAccessHistory.wasPreviouslyVerified(
                for: newIdentity, defaults: defaults))
    }

    func testKnownMissingPermissionOpensSettingsAtLaunch() {
        let items = [
            PermissionChecklistItem(
                permission: .screenRecording, status: .allowed, requiresRelaunch: false),
            PermissionChecklistItem(
                permission: .localNetwork, status: .notYetAsked, requiresRelaunch: false),
        ]

        XCTAssertTrue(PermissionChecklistLaunchDecision.shouldOpenSettings(for: items))
        XCTAssertEqual(PermissionRequestSequence.next(in: items), .localNetwork)
    }

    func testScreenRecordingStatusUsesTheLivePreflightResult() {
        var state = ScreenRecordingPermissionState.ready
        state.observeAuthorization(false)

        XCTAssertEqual(state.checklistStatus, .blocked)
    }

    func testARequestControlNeverBecomesDisabledForAMissingGrant() {
        for permission in [
            MacPermission.screenRecording,
            .accessibility,
            .systemAudioRecording,
            .cameraExtension,
        ] {
            let item = PermissionChecklistItem(
                permission: permission, status: .blocked, requiresRelaunch: false)
            XCTAssertTrue(PermissionChecklistActions.isRequestEnabled(for: item))
        }
    }

    func testAutomaticSetupAdvancesPastATerminalResult() {
        let blocked = PermissionChecklistItem(
            permission: .screenRecording, status: .blocked, requiresRelaunch: false)
        let checking = PermissionChecklistItem(
            permission: .screenRecording, status: .checking, requiresRelaunch: false)

        XCTAssertTrue(PermissionRequestSequence.shouldAdvanceAfter(blocked))
        XCTAssertFalse(PermissionRequestSequence.shouldAdvanceAfter(checking))
    }

    func testScreenAndAccessibilityWaitForForegroundBeforeAutomaticNextRequest() {
        XCTAssertTrue(
            PermissionRequestSequence.waitsForForegroundActivationAfterRequest(
                .screenRecording))
        XCTAssertTrue(
            PermissionRequestSequence.waitsForForegroundActivationAfterRequest(
                .accessibility))
        XCTAssertFalse(
            PermissionRequestSequence.waitsForForegroundActivationAfterRequest(
                .localNetwork))
    }

    func testACompletedSystemAudioCheckOpensSettingsAtLaunch() {
        let items = [
            PermissionChecklistItem(
                permission: .screenRecording, status: .allowed, requiresRelaunch: false),
            PermissionChecklistItem(
                permission: .localNetwork, status: .allowed, requiresRelaunch: false),
            PermissionChecklistItem(
                permission: .systemAudioRecording, status: .blocked, requiresRelaunch: false),
        ]

        XCTAssertTrue(PermissionChecklistLaunchDecision.shouldOpenSettings(for: items))
        XCTAssertEqual(PermissionRequestSequence.next(in: items), .systemAudioRecording)
    }

    func testIndeterminateSystemAudioDoesNotOpenSettingsAtLaunch() {
        let items = [
            PermissionChecklistItem(
                permission: .screenRecording, status: .allowed, requiresRelaunch: false),
            PermissionChecklistItem(
                permission: .localNetwork, status: .allowed, requiresRelaunch: false),
            PermissionChecklistItem(
                permission: .systemAudioRecording, status: .checking,
                requiresRelaunch: false),
        ]

        XCTAssertFalse(PermissionChecklistLaunchDecision.shouldOpenSettings(for: items))
        XCTAssertNil(PermissionRequestSequence.next(in: items))
        XCTAssertEqual(items[2].statusText, "Checking")
    }

    func testCameraExtensionIsIncludedInAutomaticSetupAfterLocalNetwork() {
        XCTAssertTrue(MacPermission.cameraExtension.isRequiredAtLaunch)
        XCTAssertTrue(MacPermission.requestOrder.contains(.cameraExtension))
        XCTAssertTrue(MacPermission.allCases.allSatisfy(\.isAvailableInThisBuild))
        XCTAssertEqual(
            MacPermission.allCases,
            [.screenRecording, .localNetwork, .systemAudioRecording, .accessibility,
             .cameraExtension])
        XCTAssertEqual(
            MacPermission.requestOrder,
            [.screenRecording, .localNetwork, .cameraExtension, .systemAudioRecording,
             .accessibility])
    }

    func testChecklistRequestsCameraAfterABlockedLocalNetworkDecision() {
        let blocked = PermissionChecklistItem(
            permission: .localNetwork, status: .blocked, requiresRelaunch: false)
        let later = PermissionChecklistItem(
            permission: .cameraExtension, status: .notYetAsked, requiresRelaunch: false)

        XCTAssertEqual(PermissionRequestSequence.next(in: [blocked, later]), .localNetwork)
        XCTAssertEqual(
            PermissionRequestSequence.nextAutomaticRequest(
                in: [blocked, later], attempted: [.localNetwork]),
            .cameraExtension)
        XCTAssertTrue(PermissionRequestSequence.shouldRequestAutomatically(later))
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
        XCTAssertEqual(
            permission.settingsButtonTitle, "Open Login Items & Extensions")
        XCTAssertFalse(permission.message(for: .needsAccess).localizedCaseInsensitiveContains("declin"))
        XCTAssertEqual(permission.steps, [
            "Open System Settings, then General > Login Items & Extensions.",
            "Under Extensions, click the info button next to Camera Extensions.",
            "Turn on ESPDisplay Camera Extension, then click Done.",
            "Return to ESPDisplaySender and relaunch it if macOS asks.",
        ])
        XCTAssertFalse(permission.steps.joined(separator: " ")
            .localizedCaseInsensitiveContains("Camera pane"))
    }

    func testEmbeddedCameraExtensionUsesItsIdentifierAsItsBundleName() {
        XCTAssertEqual(
            CameraExtensionInstaller.extensionBundleName,
            "com.resourcefork.espdisplay.camera-extension.systemextension")
    }

    func testLocalNetworkBlockUsesSettingsInsteadOfAnUnrepeatableRequest() {
        let item = PermissionChecklistItem(
            permission: .localNetwork, status: .blocked, requiresRelaunch: false)

        XCTAssertFalse(PermissionChecklistActions.offersInAppRequest(for: item))
        XCTAssertFalse(MacPermission.localNetwork.message(for: .needsAccess)
            .localizedCaseInsensitiveContains("request again"))
        XCTAssertEqual(
            MacPermission.localNetwork.steps.first,
            "Open System Settings > Privacy & Security > Local Network.")
    }

    func testBlockedLocalNetworkDoesNotDisableCameraSetup() {
        let camera = PermissionChecklistItem(
            permission: .cameraExtension, status: .notYetAsked, requiresRelaunch: false)

        XCTAssertTrue(PermissionChecklistActions.offersInAppRequest(for: camera))
        XCTAssertTrue(PermissionChecklistActions.isRequestEnabled(for: camera))
    }

    func testCheckingCameraRequestStaysActionable() {
        let camera = PermissionChecklistItem(
            permission: .cameraExtension, status: .checking, requiresRelaunch: false)

        XCTAssertTrue(PermissionChecklistActions.isRequestEnabled(for: camera))
    }

    func testCameraRestartResultStaysActionableUntilTheMacRestarts() {
        let item = PermissionChecklistItem(
            permission: .cameraExtension, status: .allowed, requiresRelaunch: false,
            requiresRestart: true)

        XCTAssertEqual(item.statusText, "Approved - restart Mac required")
        XCTAssertFalse(item.isReady)
        XCTAssertTrue(PermissionChecklistLaunchDecision.shouldOpenSettings(for: [item]))
        XCTAssertEqual(
            MacPermission.cameraExtension.message(for: .grantedNeedsRestart),
            "Camera extension approved - restart your Mac before it appears in video apps.")
    }

    func testCameraExtensionPropertiesUseTheSystemExtensionEnabledState() {
        let result = CameraExtensionInstaller.activation(
            for: [
                CameraExtensionPropertiesSnapshot(
                    enabled: true, awaitingUserApproval: false, uninstalling: false)
            ])

        if case .installed = result {
            return
        }
        XCTFail("An enabled System Extension must report Allowed.")
    }

    func testEnabledCameraExtensionWinsOverOldCopiesWaitingToUninstall() {
        let result = CameraExtensionInstaller.activation(
            for: [
                CameraExtensionPropertiesSnapshot(
                    enabled: false, awaitingUserApproval: false, uninstalling: true,
                    bundleVersion: "634.6"),
                CameraExtensionPropertiesSnapshot(
                    enabled: true, awaitingUserApproval: false, uninstalling: false,
                    bundleVersion: "634.10"),
                CameraExtensionPropertiesSnapshot(
                    enabled: false, awaitingUserApproval: false, uninstalling: true,
                    bundleVersion: "634.5"),
            ])

        if case .installed = result {
            return
        }
        XCTFail("An activated enabled extension must stay Allowed while older copies uninstall.")
    }

    func testCameraActivationOnlyReplacesAnActiveVersionWhenTheEmbeddedVersionDiffers() {
        let properties = [
            CameraExtensionPropertiesSnapshot(
                enabled: false, awaitingUserApproval: false, uninstalling: true,
                bundleVersion: "634.6"),
            CameraExtensionPropertiesSnapshot(
                enabled: true, awaitingUserApproval: false, uninstalling: false,
                bundleVersion: "634.10"),
            CameraExtensionPropertiesSnapshot(
                enabled: false, awaitingUserApproval: false, uninstalling: true,
                bundleVersion: "634.9"),
        ]

        XCTAssertFalse(CameraExtensionInstaller.shouldSubmitActivation(
            embeddedVersion: "634.10", properties: properties))
        XCTAssertTrue(CameraExtensionInstaller.shouldSubmitActivation(
            embeddedVersion: "634.12", properties: properties))
        if case .installed? = CameraExtensionInstaller.activationAfterAssessment(
            embeddedVersion: "634.10", properties: properties)
        {
            // The callback completes without replacing the active version.
        } else {
            XCTFail("The activation-assessment callback should complete for the active version.")
        }
        XCTAssertNil(CameraExtensionInstaller.activationAfterAssessment(
            embeddedVersion: "634.12", properties: properties))
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

    func testLocalNetworkPositiveProbeUsesAPrivateUnicastAddress() {
        XCTAssertEqual(LocalNetworkPermissionProbe.unicastProbeHost, "192.168.254.254")
        XCTAssertFalse(LocalNetworkPermissionProbe.unicastProbeHost.hasSuffix(".255"))
    }

    @MainActor
    func testLocalNetworkBrowserAndMDNSReadyDoNotClearAProhibitedUnicastPath() {
        let manager = PanelManager(
            previewPanels: [], savedNetworkNames: [], usbSerialPorts: [])

        manager.observeLocalNetworkPermission(
            .policyDenied(technicalDetail: "PolicyDenied(-65570)"))
        XCTAssertEqual(
            manager.issues.first?.detail,
            "ESPDisplaySender is blocked from reaching devices on your local network. "
                + "Open System Settings > Privacy & Security > Local Network and turn on "
                + "ESPDisplaySender. If it is not listed, macOS has no switch for this copy; "
                + "the app cannot make a request that will appear.")
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
