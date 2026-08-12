import Foundation
import SenderProtocol

/// Finding the esptool the Arduino esp32 core ships.
///
/// WHY THIS DOES NOT ASK arduino-cli, which is what tools/espdisp.py does
/// (`esptool_path()` runs `arduino-cli config get directories.data`). A GUI app
/// launched from Finder or a LaunchAgent inherits PATH=/usr/bin:/bin:/usr/sbin:
/// /sbin, and arduino-cli lives in /opt/homebrew/bin or /usr/local/bin, so the
/// spawn that would answer the question authoritatively is the one most likely to
/// fail in an app. The default data directory is checked instead, which is where
/// arduino-cli puts it unless someone has moved it.
///
/// The cost, and it is surfaced rather than hidden: a non-default
/// `directories.data` is not found, and `UsbOnboardingPlan.esptoolMissing` names
/// the directories that were searched so the message is actionable rather than
/// merely negative. `ARDUINO_DIRECTORIES_DATA` is honoured because that is the
/// documented override and it costs one lookup.
///
/// The version directory is globbed, never pinned. 5.3.1 is installed here today
/// and the core upgrades it.
enum EsptoolInstallation {

    /// Where to look, in order. Pure so the list is testable and so the message
    /// in `esptoolMissing` is the same list that was searched.
    ///
    /// `~/Library/Arduino15` is arduino-cli's default on macOS;
    /// `~/.arduino15` was the older default and costs nothing to keep.
    static func searchRoots(
        home: String, environment: [String: String] = [:]
    ) -> [String] {
        var roots: [String] = []
        if let override = environment["ARDUINO_DIRECTORIES_DATA"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            roots.append(override)
        }
        roots.append(home + "/Library/Arduino15")
        roots.append(home + "/.arduino15")
        // Deduplicated, so an override that names the default does not make the
        // message say the same directory twice.
        var seen = Set<String>()
        return roots.filter { seen.insert($0).inserted }
    }

    /// The directory each root keeps esptool versions in.
    static func toolDirectory(inRoot root: String) -> String {
        root + "/packages/esp32/tools/esptool_py"
    }

    /// Pick one candidate out of everything that was found.
    ///
    /// NEWEST VERSION DIRECTORY WINS, by string order, which is the same
    /// lexicographic caveat `esptool_path()` in tools/espdisp.py documents: it is
    /// not a true version sort, so a hypothetical 10.0 would lose to 9.0. Left as
    /// it is deliberately, so the two implementations agree with each other.
    ///
    /// A 5.x binary beats a 4.x script in the same directory, because the binary
    /// needs no interpreter and the script path here is UNVERIFIED.
    static func choose(from candidates: [String]) -> EsptoolCommand.Tool? {
        guard !candidates.isEmpty else { return nil }
        let sorted = candidates.sorted()
        if let binary = sorted.last(where: { !$0.hasSuffix(".py") }) {
            return EsptoolCommand.Tool(path: binary)
        }
        return sorted.last.map { EsptoolCommand.Tool(path: $0) }
    }

    /// Look for it on disk.
    static func locate(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> UsbOnboarding.ToolAvailability {
        let roots = searchRoots(home: home, environment: environment)
        var candidates: [String] = []
        for root in roots {
            let base = toolDirectory(inRoot: root)
            let versions = (try? fileManager.contentsOfDirectory(atPath: base)) ?? []
            for version in versions {
                for name in ["esptool", "esptool.py"] {
                    let path = base + "/" + version + "/" + name
                    if fileManager.isExecutableFile(atPath: path)
                        || (name.hasSuffix(".py") && fileManager.fileExists(atPath: path))
                    {
                        candidates.append(path)
                    }
                }
            }
        }
        guard let tool = choose(from: candidates) else {
            return .missing(searched: roots.map(Self.toolDirectory(inRoot:)))
        }
        return .installed(path: tool.path)
    }
}
