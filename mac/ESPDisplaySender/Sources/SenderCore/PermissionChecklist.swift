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

/// Decides whether the foreground launch should open Settings > Permissions.
/// Unknown checks are not treated as missing grants, so a configured app does
/// not open Settings merely while macOS is still answering.
enum PermissionChecklistLaunchDecision {
    static func shouldOpenSettings(
        for items: [PermissionChecklistItem],
        localNetworkWasPreviouslyVerified: Bool = true
    ) -> Bool {
        if items.contains(where: { $0.permission.isRequiredAtLaunch && $0.needsAttention }) {
            return true
        }
        // Local Network has no preflight API. On the first foreground launch
        // for this app identity, make the explanatory page visible before the
        // real probe runs. The row continues to say Checking, never Missing.
        return !localNetworkWasPreviouslyVerified
            && items.contains {
                $0.permission == .localNetwork && $0.status == .checking
            }
    }
}

/// A prior *live* unicast path success is a launch-routing hint only. It is
/// never used to label the row: the live probe remains the source of Allowed,
/// Blocked, or Checking. Remembering that proof avoids opening Settings on
/// each later launch before Network.framework has replied.
enum LocalNetworkLiveAccessHistory {
    private static let keyPrefix = "ESPDisplaySender.local-network-live-access."

    static var wasPreviouslyVerified: Bool {
        wasPreviouslyVerified(for: currentIdentity())
    }

    static func record(allowed: Bool) {
        UserDefaults.standard.set(allowed, forKey: key(for: currentIdentity()))
    }

    static func wasPreviouslyVerified(
        for identity: String, defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: key(for: identity))
    }

    static func key(for identity: String) -> String {
        keyPrefix + identity
    }

    static func identity(
        bundleIdentifier: String, teamIdentifier: String?
    ) -> String {
        bundleIdentifier + "." + (teamIdentifier ?? "unsigned")
    }

    private static func currentIdentity() -> String {
        identity(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            teamIdentifier: signingTeamIdentifier())
    }

    private static func signingTeamIdentifier() -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code)
            == errSecSuccess,
              let code
        else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(), &information) == errSecSuccess,
              let information = information as? [String: Any]
        else {
            return nil
        }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// Shared action policy for the permanent Settings page and its in-context
/// banner links. A blocked row must remain actionable until macOS reports a
/// grant, even while another permission is being checked.
enum PermissionChecklistActions {
    static func offersInAppRequest(for item: PermissionChecklistItem) -> Bool {
        item.status != .allowed
            && (item.status != .blocked || item.permission.offersInAppRequestWhenBlocked)
    }

    /// A missing grant remains actionable. A request in progress may have to
    /// be completed in System Settings, but it must never turn this control
    /// into a dead end.
    static func isRequestEnabled(for item: PermissionChecklistItem) -> Bool {
        offersInAppRequest(for: item)
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

    /// The first unresolved row this launch has not requested yet. The status
    /// remains a live macOS result; `attempted` is only the one-shot request
    /// sequencer and is never used to label a row.
    static func nextAutomaticRequest(
        in items: [PermissionChecklistItem],
        attempted: Set<MacPermission>
    ) -> MacPermission? {
        MacPermission.requestOrder.first { permission in
            guard let item = items.first(where: { $0.permission == permission }) else {
                return false
            }
            return !attempted.contains(permission)
                && shouldRequestAutomatically(item)
        }
    }

    static func shouldRequestAutomatically(_ item: PermissionChecklistItem) -> Bool {
        !item.isReady
            && !item.requiresRelaunch
            && !item.requiresRestart
            && (item.status != .checking || item.permission == .localNetwork)
    }

    static func shouldAdvanceAfter(_ item: PermissionChecklistItem) -> Bool {
        item.isReady || item.status == .blocked
    }

    /// These APIs show their own prompt but provide no callback for a
    /// dismissal. An automatic setup sequence waits until AppKit reports the
    /// app active again before advancing to another native request.
    static func waitsForForegroundActivationAfterRequest(_ permission: MacPermission) -> Bool {
        permission == .screenRecording || permission == .accessibility
    }
}
