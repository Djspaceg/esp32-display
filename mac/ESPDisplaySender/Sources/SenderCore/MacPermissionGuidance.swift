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
        .systemAudioRecording,
        .accessibility,
    ]

    /// The camera extension remains visible in the checklist, but it is a
    /// separate optional feature rather than permission needed to send a
    /// picture or reach a device.
    var isRequiredAtLaunch: Bool {
        self != .cameraExtension
    }

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
            return "Open Extensions Settings"
        }
    }

    var steps: [String] {
        switch self {
        case .screenRecording:
            return [
                "Open Screen Recording Settings.",
                "Remove an old ESPDisplaySender entry if one is listed.",
                "Turn on this copy of ESPDisplaySender.",
                "Relaunch ESPDisplaySender.",
            ]
        case .accessibility:
            return [
                "Open Accessibility Settings.",
                "Remove an old ESPDisplaySender entry if one is listed.",
                "Turn on this copy of ESPDisplaySender.",
                "Try the device control again.",
            ]
        case .systemAudioRecording:
            return [
                "Open System Audio Recording Settings.",
                "Remove an old ESPDisplaySender entry if one is listed.",
                "Turn on this copy of ESPDisplaySender.",
                "Resume sending Mac sound to the device.",
            ]
        case .localNetwork:
            return [
                "Open Local Network Settings.",
                "Turn on ESPDisplaySender, or turn it off and on again if it is already on.",
                "Relaunch ESPDisplaySender.",
            ]
        case .cameraExtension:
            return [
                "Request installation.",
                "Approve ESPDisplay Camera Extension in Login Items & Extensions.",
                "Relaunch ESPDisplaySender if macOS asks for it.",
            ]
        }
    }

    func message(for state: PermissionIssueState) -> String {
        switch (self, state) {
        case (.screenRecording, .needsAccess):
            return "This copy of ESPDisplaySender is not allowed to record the screen "
                + "yet. Devices stay connected and controllable, but no picture can "
                + "be sent. A rebuilt or re-signed app needs permission again. If an "
                + "old ESPDisplaySender entry is listed, remove it before turning this "
                + "one on."
        case (.screenRecording, .grantedNeedsRelaunch):
            return "Permission granted - relaunch to start sending pictures."
        case (.accessibility, .needsAccess):
            return "This copy of ESPDisplaySender is not allowed to control volume, "
                + "playback, or key presses from a device yet. A rebuilt or re-signed "
                + "app needs Accessibility permission again."
        case (.accessibility, .grantedNeedsRelaunch):
            return "Permission granted - try the device control again."
        case (.systemAudioRecording, .needsAccess):
            return "This copy of ESPDisplaySender is not allowed to record this Mac's "
                + "sound yet. Devices stay connected and their speakers receive "
                + "silence. A rebuilt or re-signed app needs permission again."
        case (.systemAudioRecording, .grantedNeedsRelaunch):
            return "Permission granted - resume sending Mac sound to the device."
        case (.localNetwork, .needsAccess):
            return "ESPDisplaySender isn't allowed to reach devices on your local network."
        case (.localNetwork, .grantedNeedsRelaunch):
            return "Permission granted - relaunch to reach devices on your local network."
        case (.cameraExtension, .needsAccess):
            return "ESPDisplaySender cannot make the device camera available to other "
                + "video apps until its camera extension is approved."
        case (.cameraExtension, .grantedNeedsRelaunch):
            return "Camera extension approved - relaunch if it does not appear in video apps."
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
}

enum PermissionIssueState: Equatable, Sendable {
    case needsAccess
    case grantedNeedsRelaunch
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
}
