import AppKit
import Foundation
import Security

enum DisplayAudioDriverAction: Equatable, Sendable {
    case install
    case remove
}

/// What the macOS administrator prompt and the command behind it came to.
enum PrivilegedRunResult: Equatable, Sendable {
    case succeeded
    case cancelled
    case failed(String)
}

/// The Audio section's driver row: whether the driver is installed, the
/// Install or Remove button, and the outcome of the last click. Pure, so every
/// step of a click is tested without the password prompt.
struct DisplayAudioDriverSetup: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        /// The macOS administrator prompt is up, or its command is running.
        case asking(DisplayAudioDriverAction)
        /// Done as root; waiting for coreaudiod to load or unload the driver.
        case waiting(DisplayAudioDriverAction, since: Date)
    }

    struct Button: Equatable, Sendable {
        let title: String
        let action: DisplayAudioDriverAction
        let enabled: Bool
        /// Why it is disabled, or what it does.
        let help: String?
    }

    struct Presentation: Equatable, Sendable {
        let status: String
        let button: Button?
        let busy: Bool
        /// Selectable and copyable: the last outcome, or what to do now.
        let message: String?
    }

    /// How long coreaudiod may take to show a driver it has just been given
    /// or to drop one it lost, after its restart.
    static let loadTimeout: TimeInterval = 20

    /// Whether this app carries a driver to install.
    let bundledDriver: Bool
    /// The developer team this app is signed by; the installer accepts only a
    /// driver signed by the same team.
    let signingTeam: String?
    private(set) var phase = Phase.idle
    private(set) var message: String?

    init(bundledDriver: Bool, signingTeam: String?) {
        self.bundledDriver = bundledDriver
        self.signingTeam = signingTeam
    }

    /// Returns false, changing nothing, while another click is in progress.
    @discardableResult
    mutating func begin(_ action: DisplayAudioDriverAction, now: Date) -> Bool {
        guard phase == .idle else { return false }
        phase = .asking(action)
        message = nil
        return true
    }

    mutating func finished(
        _ action: DisplayAudioDriverAction, _ result: PrivilegedRunResult, now: Date
    ) {
        guard phase == .asking(action) else { return }
        let verb = action == .install ? "Installing" : "Removing"
        switch result {
        case .succeeded:
            phase = .waiting(action, since: now)
        case .cancelled:
            phase = .idle
            message = "\(verb) the audio driver was cancelled."
        case .failed(let error):
            phase = .idle
            let what = action == .install ? "installed" : "removed"
            message = "The audio driver could not be \(what): \(error)"
        }
    }

    /// The driver as the last two-second pass found it.
    mutating func observe(_ availability: DisplayAudioDriverAvailability?, now: Date) {
        guard case .waiting(let action, let since) = phase else { return }
        let done: Bool
        switch action {
        case .install: done = availability == .ready
        case .remove: done = availability == .absent
        }
        if done {
            phase = .idle
            message = nil
        } else if now.timeIntervalSince(since) > Self.loadTimeout {
            phase = .idle
            message = action == .install
                ? "The driver was installed, but macOS has not loaded it after "
                    + "\(Int(Self.loadTimeout)) seconds. Restart the Mac if it "
                    + "does not appear."
                : "The driver was removed, but macOS still lists it after "
                    + "\(Int(Self.loadTimeout)) seconds. Restart the Mac to unload it."
        }
    }

    func presentation(availability: DisplayAudioDriverAvailability?) -> Presentation {
        switch phase {
        case .asking(.install):
            return Presentation(
                status: "Installing…", button: nil, busy: true,
                message: "Enter your Mac password in the macOS prompt to install "
                    + "the driver.")
        case .asking(.remove):
            return Presentation(
                status: "Removing…", button: nil, busy: true,
                message: "Enter your Mac password in the macOS prompt to remove "
                    + "the driver.")
        case .waiting(.install, _):
            return Presentation(
                status: "Installed; waiting for macOS to load it…", button: nil,
                busy: true, message: nil)
        case .waiting(.remove, _):
            return Presentation(
                status: "Removed; waiting for macOS to unload it…", button: nil,
                busy: true, message: nil)
        case .idle:
            break
        }
        switch availability {
        case nil:
            return Presentation(status: "Checking…", button: nil, busy: false, message: message)
        case .absent?:
            let button = installButton("Install Audio Driver…")
            return Presentation(
                status: "Not installed", button: button, busy: false,
                message: message ?? (button.enabled ? nil : Self.developerHint(button)))
        case .ready?:
            return Presentation(
                status: "Installed",
                button: Button(
                    title: "Remove Audio Driver…", action: .remove, enabled: true,
                    help: "Remove the audio driver for ESP devices from this Mac"),
                busy: false, message: message)
        case .incompatible(let version)?:
            let found = version.map { "version \($0)" } ?? "an unreadable version"
            let button = installButton("Reinstall Audio Driver…")
            return Presentation(
                status: "Installed, \(found) (this app needs version "
                    + "\(DisplayAudioDriverProtocol.version))",
                button: button, busy: false,
                message: message ?? (button.enabled ? nil : Self.developerHint(button)))
        }
    }

    /// A build that cannot install still says how to get the driver.
    private static func developerHint(_ button: Button) -> String {
        (button.help ?? "") + " To install it by hand, run "
            + "mac/AudioDriver/build-driver.sh and then sudo "
            + "mac/AudioDriver/install-driver.sh from the esp32-display source folder."
    }

    private func installButton(_ title: String) -> Button {
        if !bundledDriver {
            return Button(
                title: title, action: .install, enabled: false,
                help: "This build of ESPDisplaySender carries no audio driver.")
        }
        if signingTeam == nil {
            return Button(
                title: title, action: .install, enabled: false,
                help: "This build is not signed by a developer team, so its "
                    + "driver cannot be installed.")
        }
        return Button(
            title: title, action: .install, enabled: true,
            help: "Install the audio driver for ESP devices this app carries; macOS asks "
                + "for your password")
    }
}

/// The root commands behind the buttons, and how they are run.
enum DisplayAudioDriverInstaller {
    static let halFolder = "/Library/Audio/Plug-Ins/HAL"
    static let target = halFolder + "/ESPDisplayAudio.driver"
    /// Root-only (mode 700), and not a .driver name, so the HAL never loads
    /// anything from it.
    static let staging = halFolder + "/.ESPDisplayAudio.installing"
    static let staged = staging + "/ESPDisplayAudio.driver"
    /// Held for the whole of an install or removal, by this app and by
    /// mac/AudioDriver/install-driver.sh alike, so two can never interleave
    /// (a relaunched app's against one still pending, say).
    static let lock = halFolder + "/.ESPDisplayAudio.lock"

    /// Where the app's build puts its driver (mac/AudioDriver/embed-driver.sh).
    static func bundledDriver(in bundle: Bundle = .main) -> URL? {
        let url = bundle.bundleURL
            .appendingPathComponent("Contents/Library/Audio/ESPDisplayAudio.driver")
        return FileManager.default.fileExists(
            atPath: url.appendingPathComponent("Contents/Info.plist").path) ? url : nil
    }

    /// The team the running app is signed by, from its own signature.
    static func signingTeam() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let values = info as? [String: Any]
        else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Copies the driver into a staging folder only root can enter, checks
    /// that copy (not the user-writable original) is Apple-signed by `team`,
    /// moves it into place and restarts coreaudiod. The folder is made
    /// root-only before anything is copied, so nothing running as the user
    /// can reach the copy between the check and the move. Absolute tool paths
    /// throughout: it runs as root.
    static func installCommand(source: URL, team: String) -> String {
        locked(installScript(source: source, team: team))
    }

    static func removeCommand() -> String { locked(removeScript()) }

    /// What lockf runs: `script` in a shell of its own, so its `set -e` holds
    /// (a subshell on the left of `||` would switch it off). Exit 75 is
    /// lockf's "timed out"; the script's own 75, should a tool ever return
    /// it, is passed on as 70 so it is not read as one.
    static func lockedBody(_ script: String) -> String {
        "/bin/sh -c \(shellQuoted(script)) || { s=$?; if [ $s -eq 75 ]; then exit 70; fi; exit $s; }"
    }

    /// Seconds to wait for another install or removal to finish.
    static let lockWaitSeconds = 30

    /// `script` run by /bin/sh under the install lock. The lock file is made
    /// root-only first, so no other user can hold it to stall an install, and
    /// the wait for it is bounded and said plainly when it runs out.
    static func locked(_ script: String) -> String {
        let lockPath = shellQuoted(lock)
        let inner = lockedBody(script)
        return "/bin/mkdir -p \(shellQuoted(halFolder))"
            + " && (umask 077 && /usr/bin/touch \(lockPath))"
            + " && /usr/sbin/chown root:wheel \(lockPath)"
            + " && /bin/chmod 600 \(lockPath)"
            + " && { /usr/bin/lockf -s -k -t \(lockWaitSeconds) \(lockPath)"
            + " /bin/sh -c \(shellQuoted(inner)) || { status=$?;"
            + " if [ $status -eq 75 ]; then echo 'another install or removal of the"
            + " audio driver is still running; try again in a minute' >&2; fi;"
            + " exit $status; }; }"
    }

    static func installScript(source: URL, team: String) -> String {
        let requirement = "=anchor apple generic and identifier \""
            + DisplayAudioDriverProtocol.bundleID
            + "\" and certificate leaf[subject.OU] = \"\(team)\""
        let stagingPath = shellQuoted(staging)
        let stagedPath = shellQuoted(staged)
        return [
            "set -e",
            "/bin/mkdir -p \(shellQuoted(halFolder))",
            "/bin/rm -rf \(stagingPath)",
            // Whatever happens next, the staging folder goes with the shell.
            "trap \(shellQuoted("/bin/rm -rf " + shellQuoted(staging))) EXIT",
            "/bin/mkdir -m 700 \(stagingPath)",
            "/usr/sbin/chown root:wheel \(stagingPath)",
            "/usr/bin/ditto \(shellQuoted(source.path)) \(stagedPath)",
            "/usr/sbin/chown -R root:wheel \(stagedPath)",
            "/bin/chmod -R go-w \(stagedPath)",
            "/usr/bin/codesign --verify --strict -R \(shellQuoted(requirement)) \(stagedPath)"
                + " || { echo 'the driver is not signed by this app'\\''s team' >&2; exit 3; }",
            "/bin/rm -rf \(shellQuoted(target))",
            "/bin/mv \(stagedPath) \(shellQuoted(target))",
            "/usr/bin/killall coreaudiod || true",
        ].joined(separator: "; ")
    }

    static func removeScript() -> String {
        [
            "set -e",
            "/bin/rm -rf \(shellQuoted(target))",
            "/usr/bin/killall coreaudiod || true",
        ].joined(separator: "; ")
    }

    /// What the macOS password dialog says. osascript runs the command, so
    /// the dialog names osascript; this says who is asking, and for what.
    static func prompt(for action: DisplayAudioDriverAction) -> String {
        switch action {
        case .install:
            return "ESPDisplaySender wants to install its audio driver, so your "
                + "ESP devices can be this Mac's sound output."
        case .remove:
            return "ESPDisplaySender wants to remove its audio driver."
        }
    }

    /// The AppleScript that runs `command` as root behind the standard macOS
    /// administrator prompt, showing `prompt`.
    static func appleScript(for command: String, prompt: String) -> String {
        "do shell script \"\(appleScriptEscaped(command))\" with prompt \""
            + appleScriptEscaped(prompt) + "\" with administrator privileges"
    }

    private static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Runs a root command behind the macOS administrator prompt. Injectable so
/// tests never raise the prompt.
struct PrivilegedRunner: Sendable {
    let run: @MainActor @Sendable (_ command: String, _ prompt: String) async
        -> PrivilegedRunResult

    /// Runs osascript with the given arguments and returns its exit status and
    /// standard error. Blocks until it exits, which is as long as the user
    /// leaves the password dialog up.
    typealias Executor = @Sendable (_ arguments: [String]) -> (status: Int32, error: String)

    /// AppleScript's `do shell script ... with administrator privileges`, in
    /// /usr/bin/osascript: Authorization Services' own password dialog, with
    /// no helper left installed. A separate process waited on from a
    /// background queue, so the main thread (the window, the busy row, the
    /// driver's two-second heartbeat) carries on while the dialog is up, and
    /// the outcome comes back on the main actor.
    static let system = osascript(executor: runOsascript)

    /// osascript processes still waiting on their dialog. Ended when the app
    /// quits, so a dialog answered after the app is gone runs nothing.
    private static let running = RunningProcesses()

    static func terminateRunning() { running.terminateAll() }

    /// For tests only: admit processes again after `terminateRunning`.
    static func reopenForTesting() { running.reopen() }

    static func osascript(executor: @escaping Executor) -> PrivilegedRunner {
        PrivilegedRunner(run: { command, prompt in
            let arguments = [
                "-e", DisplayAudioDriverInstaller.appleScript(for: command, prompt: prompt),
            ]
            let (status, error) = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: executor(arguments))
                }
            }
            return outcome(status: status, error: error)
        })
    }

    /// osascript prints "<range>: execution error: <message> (<number>)";
    /// -128 is the user cancelling the dialog.
    static func outcome(status: Int32, error: String) -> PrivilegedRunResult {
        guard status != 0 else { return .succeeded }
        var text = error.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the error line counts: anything a framework logs around it
        // does not change what happened.
        if let line = text.split(separator: "\n").last(where: { $0.contains("execution error: ") }) {
            text = String(line)
        }
        if text.hasSuffix("(-128)") { return .cancelled }
        if let marker = text.range(of: "execution error: ") {
            text = String(text[marker.upperBound...])
        } else if let range = text.range(of: #"^\d+:\d+: "#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        if let open = text.range(of: " (", options: .backwards), text.hasSuffix(")"),
           Int(text[open.upperBound..<text.index(before: text.endIndex)]) != nil {
            text = String(text[..<open.lowerBound])
        }
        return .failed(text.isEmpty ? "osascript exited with status \(status)." : text)
    }

    static let runOsascript: Executor = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        guard running.admits else { return (-1, "the app is quitting.") }
        do {
            try process.run()
        } catch {
            return (-1, "osascript could not be started: \(error.localizedDescription)")
        }
        // Registered before it starts, and ended at once if the app began
        // quitting in between, so no window is left for a dialog to outlive it.
        guard running.add(process) else {
            process.terminate()
            return (-1, "the app is quitting.")
        }
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        running.remove(process)
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

/// The osascript processes PrivilegedRunner has running.
final class RunningProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]
    private var closed = false

    /// False once the app has begun quitting.
    var admits: Bool { lock.withLock { !closed } }

    /// Returns false, keeping nothing, once the app has begun quitting.
    func add(_ process: Process) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            processes[ObjectIdentifier(process)] = process
            return true
        }
    }

    func remove(_ process: Process) { lock.withLock { processes[ObjectIdentifier(process)] = nil } }

    /// Ends every process and admits no more.
    func terminateAll() {
        let all = lock.withLock {
            closed = true
            return Array(processes.values)
        }
        for process in all where process.isRunning { process.terminate() }
    }

    /// For tests, which quit more than once.
    func reopen() { lock.withLock { closed = false } }
}
