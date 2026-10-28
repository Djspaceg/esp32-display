import Foundation

/// The user-facing path back to a macOS privacy grant. Keeping the wording,
/// Settings link, actions and walkthrough together prevents each feature from
/// inventing a slightly different explanation when a rebuilt app loses a
/// grant tied to its old signature.
enum MacPermission: Equatable, Sendable {
    case screenRecording
    case accessibility
    case systemAudioRecording
    case localNetwork

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording permission needed"
        case .accessibility: return "Accessibility permission needed"
        case .systemAudioRecording: return "System Audio Recording permission needed"
        case .localNetwork: return "Local Network permission needed"
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
