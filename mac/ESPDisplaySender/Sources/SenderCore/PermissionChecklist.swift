import Foundation
import Security

/// The three states a person can act on without needing to interpret a macOS
/// framework error. A granted permission can separately ask for a relaunch.
enum PermissionChecklistStatus: Equatable, Sendable {
    case allowed
    /// macOS has not returned an answer yet. This is deliberately distinct
    /// from "Not yet asked": an unknown result must not flash the launch
    /// checklist for an otherwise configured app.
    case checking
    case notYetAsked
    case blocked

    var title: String {
        switch self {
        case .allowed: return "Allowed"
        case .checking: return "Checking"
        case .notYetAsked: return "Not yet asked"
        case .blocked: return "Blocked"
        }
    }
}

/// One row in the app's permission checklist. The state is rebuilt from
/// macOS's live checks, rather than surviving only as a dismissible warning.
struct PermissionChecklistItem: Identifiable, Equatable {
    let permission: MacPermission
    let status: PermissionChecklistStatus
    let requiresRelaunch: Bool

    var id: MacPermission { permission }
    var title: String { permission.checklistTitle }
    var purpose: String { permission.purpose }
    var statusText: String {
        requiresRelaunch ? "Allowed - relaunch required" : status.title
    }

    var isReady: Bool {
        status == .allowed && !requiresRelaunch
    }

    var needsAttention: Bool {
        requiresRelaunch || status == .notYetAsked || status == .blocked
    }
}

/// Decides when a known permission problem should open the launch sheet. A
/// pending probe is not evidence that permission is missing.
enum PermissionChecklistPresentation {
    static func shouldPresent(for items: [PermissionChecklistItem]) -> Bool {
        items.contains { $0.permission.isRequiredAtLaunch && $0.needsAttention }
    }
}

/// The fixed first-launch order keeps system prompts from stacking. A blocked
/// row holds the sequence there so the user sees its explanation before the
/// next prompt can be requested.
enum PermissionRequestSequence {
    static func next(in items: [PermissionChecklistItem]) -> MacPermission? {
        items.first(where: { !$0.isReady && $0.status != .checking })?.permission
    }

    static func shouldRequestAutomatically(_ item: PermissionChecklistItem) -> Bool {
        item.status == .notYetAsked && !item.requiresRelaunch
    }
}

/// A privacy decision is tied to the app identity, not merely its bundle ID.
/// Remembering which prompt this identity has already requested lets the
/// checklist distinguish "not yet asked" from "blocked" on a later launch.
struct PermissionPromptHistory {
    private static let prefix = "ESPDisplaySender.permission-requested."

    let identity: String
    private let defaults: UserDefaults

    init(identity: String = AppPermissionIdentity.current, defaults: UserDefaults = .standard) {
        self.identity = identity
        self.defaults = defaults
    }

    func wasRequested(_ permission: MacPermission) -> Bool {
        defaults.bool(forKey: key(for: permission))
    }

    func markRequested(_ permission: MacPermission) {
        defaults.set(true, forKey: key(for: permission))
    }

    private func key(for permission: MacPermission) -> String {
        let encoded = Data(identity.utf8).base64EncodedString()
        return Self.prefix + encoded + "." + permission.rawValue
    }
}

/// The current designated requirement is the identity macOS sees after a
/// rebuild or re-sign. The bundle version is only a fallback for a malformed
/// local development signature.
enum AppPermissionIdentity {
    static var current: String {
        var staticCode: SecStaticCode?
        let url = Bundle.main.bundleURL as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            return fallback
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement
        else {
            return fallback
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              let text
        else {
            return fallback
        }
        return text as String
    }

    private static var fallback: String {
        let identifier = Bundle.main.bundleIdentifier ?? "ESPDisplaySender"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return identifier + "." + version
    }
}
