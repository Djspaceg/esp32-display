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

    static func failure(_ failure: WifiConfigUI.ConfigFailure) -> OperationOutcome {
        OperationOutcome(kind: .failure, title: failure.title, message: failure.message)
    }

    static func failure(_ title: String, _ message: String) -> OperationOutcome {
        OperationOutcome(kind: .failure, title: title, message: message)
    }

    static func success(_ title: String, _ message: String) -> OperationOutcome {
        OperationOutcome(kind: .success, title: title, message: message)
    }
}

/// A process-wide problem the app cannot resolve on its own, so the user has
/// to be told rather than having it recorded in a log they will never read.
enum AppIssue: String, CaseIterable, Sendable {
    case screenRecording
    case deviceConfig
    case persistence
    case wifiPresetSync

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording permission needed"
        case .deviceConfig: return "Per-display source file ignored"
        case .persistence: return "Display settings could not be saved"
        case .wifiPresetSync: return "WiFi presets could not be copied"
        }
    }
}

/// An `AppIssue` together with the specific detail behind it.
struct ReportedIssue: Identifiable, Equatable {
    let issue: AppIssue
    let detail: String

    var id: String { issue.rawValue }
    var title: String { issue.title }
}

