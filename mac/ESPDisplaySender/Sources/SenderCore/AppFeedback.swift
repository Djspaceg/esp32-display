import Foundation

/// The result of something the user just asked for, success or failure, shown
/// in one place. Previously failures arrived either here or as an NSAlert put
/// up by the serial layer, depending on which code path produced them.
struct OperationOutcome: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case success
        case failure
    }

    var kind: Kind
    var title: String
    var message: String
    /// What to do about a failure, when the step that failed does not already
    /// say it. USB runs fill this from the phase that was running.
    var nextAction: String? = nil
    /// The port of a board found in flashing mode, which the sheet offers to
    /// restart into its firmware (`PanelManager.restartBoardFromFlashingMode`).
    var restartPort: String? = nil
    /// Whether a USB run's failure shows the raw lines it last saw. Off when
    /// the message already says what they mean in words; the transcript
    /// behind Details still has them.
    var showsLastSeen = true

    static func failure(_ failure: WifiConfigUI.ConfigFailure) -> OperationOutcome {
        OperationOutcome(
            kind: .failure, title: failure.title, message: failure.message,
            nextAction: failure.nextAction, showsLastSeen: failure.showsLastSeen)
    }

    /// The message and what to do next, as an alert shows them when the sheet
    /// that ran the operation is no longer there to.
    var alertText: String {
        nextAction.map { message + "\n\nNext: " + $0 } ?? message
    }

    static func failure(_ title: String, _ message: String) -> OperationOutcome {
        OperationOutcome(kind: .failure, title: title, message: message)
    }

    static func success(_ title: String, _ message: String) -> OperationOutcome {
        OperationOutcome(kind: .success, title: title, message: message)
    }

    /// Successful work is useful feedback, but never a blocking alert. The
    /// manager renders it as a compact copyable notice instead.
    var appearsAsNonmodalNotice: Bool {
        kind == .success
    }
}

/// A process-wide problem the app cannot resolve on its own, so the user has
/// to be told rather than having it recorded in a log they will never read.
enum AppIssue: String, CaseIterable, Sendable {
    case screenRecording
    case deviceConfig
    case persistence
    case wifiPresetSync
    case credentialTransition
    case accessibility
    case systemAudioRecording
    case localNetwork
    case cameraExtension

    var title: String {
        switch self {
        case .screenRecording: return MacPermission.screenRecording.title
        case .deviceConfig: return "Per-device source file ignored"
        case .persistence: return "Device settings could not be saved"
        case .wifiPresetSync: return "WiFi presets could not be copied"
        case .credentialTransition: return "Saved credentials could not be moved"
        case .accessibility: return MacPermission.accessibility.title
        case .systemAudioRecording: return MacPermission.systemAudioRecording.title
        case .localNetwork: return MacPermission.localNetwork.title
        case .cameraExtension: return MacPermission.cameraExtension.title
        }
    }

    /// The permission associated with this issue, when macOS Settings can fix
    /// it. The shared banner uses this to offer the same actions and recovery
    /// walkthrough for every privacy grant.
    var permission: MacPermission? {
        switch self {
        case .screenRecording: return .screenRecording
        case .accessibility: return .accessibility
        case .systemAudioRecording: return .systemAudioRecording
        case .localNetwork: return .localNetwork
        case .cameraExtension: return .cameraExtension
        case .deviceConfig, .persistence, .wifiPresetSync, .credentialTransition: return nil
        }
    }

    var settingsURL: URL? {
        permission?.settingsURL
    }
}

/// An `AppIssue` together with the specific detail behind it.
struct ReportedIssue: Identifiable, Equatable {
    let issue: AppIssue
    let detail: String
    /// Framework diagnostics stay out of the main explanation. They remain
    /// copyable under Technical details for a support report.
    let technicalDetail: String?
    let permissionState: PermissionIssueState?

    var id: String { issue.rawValue }
    var title: String { issue.title }
}

