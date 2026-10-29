import Foundation
import OSLog

/// Retires the pre-Resource Fork agent that executed the app binary directly.
/// A direct executable launch can make TCC attribute a request to the old
/// bundle identity instead of the foreground app opened by LaunchServices.
enum LegacyLaunchAgentCleanup {
    static let currentBundleIdentifier = "com.resourcefork.espdisplay"
    static let legacyLabel = "com.espdisplay.sender"
    private static let logger = Logger(
        subsystem: currentBundleIdentifier, category: "login-item")

    static func shouldRetireLegacyAgent(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == currentBundleIdentifier
    }

    static func launchServicesArguments(appPath: String) -> [String] {
        ["/usr/bin/open", "-gj", appPath, "--args", "--background"]
    }

    static func retireOnCurrentAppLaunch() {
        guard shouldRetireLegacyAgent(bundleIdentifier: Bundle.main.bundleIdentifier) else {
            return
        }
        let fileManager = FileManager.default
        let plist = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(legacyLabel + ".plist")

        unloadLegacyService()
        guard fileManager.fileExists(atPath: plist.path) else { return }
        do {
            var resultingURL: NSURL?
            try fileManager.trashItem(at: plist, resultingItemURL: &resultingURL)
            logger.notice("Retired stale legacy login agent")
        } catch {
            logger.error(
                "Could not retire the stale legacy login agent: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func unloadLegacyService() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [
            "bootout",
            "gui/\(getuid())/\(legacyLabel)",
        ]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // A non-loaded legacy agent is the expected state after the
            // one-time cleanup. The on-disk plist is still retired below.
        }
    }
}
