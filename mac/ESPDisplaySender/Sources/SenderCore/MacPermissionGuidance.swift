import Foundation

/// The user-facing path back to a macOS privacy grant. Keeping the wording,
/// Settings link, actions and walkthrough together prevents each feature from
/// inventing a slightly different explanation when a rebuilt app loses a
/// grant tied to its old signature.
enum MacPermission: String, CaseIterable, Equatable, Sendable {
    case screenRecording
    case localNetwork
    case systemAudioRecording
    case accessibility
    case cameraExtension

    /// Order prompts by the features a new sender needs first, then the
    /// optional controls it can make ready before a device tries to use them.
    static let requestOrder: [MacPermission] = [
        .screenRecording,
        .localNetwork,
        .cameraExtension,
        .systemAudioRecording,
        .accessibility,
    ]

    /// The first-launch checklist prepares every Mac capability this app
    /// offers, including the virtual camera the XIAOML Kit needs.
    var isRequiredAtLaunch: Bool { true }

    var isAvailableInThisBuild: Bool { true }

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording permission needed"
        case .accessibility: return "Accessibility permission needed"
        case .systemAudioRecording: return "System Audio Recording permission needed"
        case .localNetwork: return "Local Network permission needed"
        case .cameraExtension: return "Camera extension approval needed"
        }
    }

    var checklistTitle: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .localNetwork: return "Local Network"
        case .systemAudioRecording: return "System Audio Recording"
        case .accessibility: return "Accessibility"
        case .cameraExtension: return "Camera Extension"
        }
    }

    var purpose: String {
        switch self {
        case .screenRecording:
            return "Sends pictures from this Mac to devices."
        case .localNetwork:
            return "Finds and reaches devices over WiFi or Ethernet."
        case .systemAudioRecording:
            return "Plays this Mac's sound on device speakers."
        case .accessibility:
            return "Lets device controls change this Mac's playback and volume."
        case .cameraExtension:
            return "Makes device camera frames available to other video apps."
        }
    }

    var settingsURL: URL {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:"
                + "com.apple.preference.security?Privacy_Accessibility")!
        case .screenRecording, .systemAudioRecording:
            return URL(string: "x-apple.systempreferences:"
                + "com.apple.preference.security?Privacy_ScreenCapture")!
        case .localNetwork:
            return URL(string: "x-apple.systempreferences:"
                + "com.apple.preference.security?Privacy_LocalNetwork")!
        case .cameraExtension:
            return URL(string: "x-apple.systempreferences:"
                + "com.apple.LoginItems-Settings.extension")!
        }
    }

    var settingsButtonTitle: String {
        switch self {
        case .screenRecording:
            return "Open Screen Recording Settings"
        case .accessibility:
            return "Open Accessibility Settings"
        case .systemAudioRecording:
            return "Open System Audio Recording Settings"
        case .localNetwork:
            return "Open Local Network Settings"
        case .cameraExtension:
            return "Open Login Items & Extensions"
        }
    }

    var steps: [String] {
        switch self {
        case .screenRecording:
            return [
                "Open Screen Recording Settings.",
                "Remove an old ESPDisplaySender entry if one is listed.",
                "Turn on this copy of \(AppIdentity.displayName).",
                "Relaunch \(AppIdentity.displayName).",
            ]
        case .accessibility:
            return [
                "Open Accessibility Settings.",
                "Remove an old ESPDisplaySender entry if one is listed.",
                "Turn on this copy of \(AppIdentity.displayName).",
                "Try the device control again.",
            ]
        case .systemAudioRecording:
            return [
                "Open System Audio Recording Settings.",
                "Remove an old ESPDisplaySender entry if one is listed.",
                "Turn on this copy of \(AppIdentity.displayName).",
                "Resume sending Mac sound to the device.",
            ]
        case .localNetwork:
            return [
                "Open System Settings > Privacy & Security > Local Network.",
                "Turn on \(AppIdentity.displayName).",
                "If \(AppIdentity.displayName) is not listed, macOS has no switch for this copy. Restart your Mac, then check this page again.",
                "Relaunch \(AppIdentity.displayName).",
            ]
        case .cameraExtension:
            return [
                "Open System Settings, then General > Login Items & Extensions.",
                "Under Extensions, click the info button next to Camera Extensions.",
                "Turn on ESPDisplay Camera Extension, then click Done.",
                "Return to \(AppIdentity.displayName) and relaunch it if macOS asks.",
            ]
        }
    }

    func message(for state: PermissionIssueState) -> String {
        switch (self, state) {
        case (.screenRecording, .needsAccess):
            return "This copy of \(AppIdentity.displayName) is not allowed to record the screen "
                + "yet. Devices stay connected and controllable, but no picture can "
                + "be sent. A rebuilt or re-signed app needs permission again. If an "
                + "old ESPDisplaySender entry is listed, remove it before turning this "
                + "one on."
        case (.screenRecording, .grantedNeedsRelaunch):
            return "Permission granted - relaunch to start sending pictures."
        case (.accessibility, .needsAccess):
            return "This copy of \(AppIdentity.displayName) is not allowed to control volume, "
                + "playback, or key presses from a device yet. A rebuilt or re-signed "
                + "app needs Accessibility permission again."
        case (.accessibility, .grantedNeedsRelaunch):
            return "Permission granted - try the device control again."
        case (.systemAudioRecording, .needsAccess):
            return "This copy of \(AppIdentity.displayName) is not allowed to record this Mac's "
                + "sound yet. Devices stay connected and their speakers receive "
                + "silence. A rebuilt or re-signed app needs permission again."
        case (.systemAudioRecording, .grantedNeedsRelaunch):
            return "Permission granted - resume sending Mac sound to the device."
        case (.localNetwork, .needsAccess):
            return "\(AppIdentity.displayName) is blocked from reaching devices on your local network. "
                + "Open System Settings > Privacy & Security > Local Network and turn on "
                + "\(AppIdentity.displayName). If it is not listed, macOS has no switch for this copy; "
                + "the app cannot make a request that will appear."
        case (.localNetwork, .grantedNeedsRelaunch):
            return "Permission granted - relaunch to reach devices on your local network."
        case (.cameraExtension, .needsAccess):
            return "\(AppIdentity.displayName) cannot make the device camera available to other "
                + "video apps until its camera extension is approved."
        case (.cameraExtension, .grantedNeedsRelaunch):
            return "Camera extension approved - relaunch if it does not appear in video apps."
        case (.cameraExtension, .grantedNeedsRestart):
            return "Camera extension approved - restart your Mac before it appears in video apps."
        case (_, .grantedNeedsRestart):
            return "Permission granted - restart your Mac before using this feature."
        }
    }

    var appIssue: AppIssue {
        switch self {
        case .screenRecording: return .screenRecording
        case .localNetwork: return .localNetwork
        case .systemAudioRecording: return .systemAudioRecording
        case .accessibility: return .accessibility
        case .cameraExtension: return .cameraExtension
        }
    }

    /// Local Network has no supported repeat-request API after macOS has
    /// already returned a policy denial. Retrying the browse only fails again;
    /// the recovery is the Local Network privacy pane.
    var offersInAppRequestWhenBlocked: Bool {
        self != .localNetwork
    }
}

enum PermissionIssueState: Equatable, Sendable {
    case needsAccess
    case grantedNeedsRelaunch
    case grantedNeedsRestart
}

/// The status visible to the app after a screen-capture attempt. A positive
/// permission preflight alone is not enough: some macOS releases need a new
/// process before ScreenCaptureKit can use a newly granted entitlement.
enum ScreenRecordingPermissionState: Equatable, Sendable {
    case ready
    case needsAccess
    case grantedNeedsRelaunch

    mutating func observeAuthorization(_ authorized: Bool) {
        guard !authorized else {
            if self == .needsAccess { self = .grantedNeedsRelaunch }
            return
        }
        self = .needsAccess
    }

    mutating func observeCaptureResult(works: Bool, authorized: Bool) {
        if works {
            self = .ready
        } else {
            self = authorized ? .grantedNeedsRelaunch : .needsAccess
        }
    }

    var issueState: PermissionIssueState? {
        switch self {
        case .ready: return nil
        case .needsAccess: return .needsAccess
        case .grantedNeedsRelaunch: return .grantedNeedsRelaunch
        }
    }

    var checklistStatus: PermissionChecklistStatus {
        switch self {
        case .ready, .grantedNeedsRelaunch:
            return .allowed
        case .needsAccess:
            return .blocked
        }
    }
}
