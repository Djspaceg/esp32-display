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
    let requiresRestart: Bool

    init(
        permission: MacPermission,
        status: PermissionChecklistStatus,
        requiresRelaunch: Bool,
        requiresRestart: Bool = false
    ) {
        self.permission = permission
        self.status = status
        self.requiresRelaunch = requiresRelaunch
        self.requiresRestart = requiresRestart
    }

    var id: MacPermission { permission }
    var title: String { permission.checklistTitle }
    var purpose: String { permission.purpose }
    var statusText: String {
        if requiresRestart { return "Approved - restart Mac required" }
        return requiresRelaunch ? "Allowed - relaunch required" : status.title
    }

    var isReady: Bool {
        status == .allowed && !requiresRelaunch && !requiresRestart
    }

    var needsAttention: Bool {
        requiresRelaunch || requiresRestart || status == .notYetAsked || status == .blocked
    }
}

/// Decides when a known permission problem should open the launch sheet. A
/// pending probe is not evidence that permission is missing.
enum PermissionChecklistPresentation {
    static func shouldPresent(for items: [PermissionChecklistItem]) -> Bool {
        items.contains { $0.permission.isRequiredAtLaunch && $0.needsAttention }
    }
}

/// Shared action policy for the permanent Settings page and the launch sheet.
/// A blocked row is not an in-flight macOS request, so it must not prevent a
/// person from setting up another capability such as the camera extension.
enum PermissionChecklistActions {
    static func waitingForAnotherRequest(
        active: MacPermission?,
        items: [PermissionChecklistItem],
        current: MacPermission
    ) -> Bool {
        guard let active, active != current,
              let activeItem = items.first(where: { $0.permission == active })
        else { return false }
        return activeItem.status == .checking
    }

    static func offersInAppRequest(for item: PermissionChecklistItem) -> Bool {
        item.status != .allowed
            && (item.status != .blocked || item.permission.offersInAppRequestWhenBlocked)
    }
}

/// The fixed first-launch order keeps system prompts from stacking. A terminal
/// Local Network policy denial leaves its recovery steps visible, then lets
/// the next independent capability ask so camera setup is not held hostage by
/// a network decision.
enum PermissionRequestSequence {
    /// The first row still needing attention. This includes a blocked row so
    /// callers can keep its recovery guidance as the visible next problem.
    static func next(in items: [PermissionChecklistItem]) -> MacPermission? {
        MacPermission.requestOrder.first { permission in
            guard let item = items.first(where: { $0.permission == permission }) else {
                return false
            }
            return !item.isReady && item.status != .checking
        }
    }

    /// The first row whose macOS request has not yet been attempted. Unlike
    /// `next(in:)`, this moves past a terminal block so independent features
    /// such as the camera extension can still be requested.
    static func nextAutomaticRequest(in items: [PermissionChecklistItem]) -> MacPermission? {
        MacPermission.requestOrder.first { permission in
            guard let item = items.first(where: { $0.permission == permission }) else {
                return false
            }
            return shouldRequestAutomatically(item)
        }
    }

    static func shouldRequestAutomatically(_ item: PermissionChecklistItem) -> Bool {
        item.status == .notYetAsked && !item.requiresRelaunch && !item.requiresRestart
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
