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
                    help: "Remove the display audio driver from this Mac"),
                busy: false, message: message)
        case .incompatible(let version)?:
            let found = version.map { "version \($0)" } ?? "an unreadable version"
            return Presentation(
                status: "Installed, \(found) (this app needs version "
                    + "\(DisplayAudioDriverProtocol.version))",
                button: installButton("Reinstall Audio Driver…"),
                busy: false, message: message)
        }
    }

    /// A build that cannot install still says how to get the driver.
    private static func developerHint(_ button: Button) -> String {
        (button.help ?? "") + " From the esp32-display source folder, "
            + "mac/AudioDriver/build-driver.sh and then sudo "
            + "mac/AudioDriver/install-driver.sh install it by hand."
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
            help: "Install the display audio driver this app carries; macOS asks "
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
        let requirement = "=anchor apple generic and identifier \""
            + DisplayAudioDriverProtocol.bundleID
            + "\" and certificate leaf[subject.OU] = \"\(team)\""
        let stagingPath = shellQuoted(staging)
        let stagedPath = shellQuoted(staged)
        return [
            "set -e",
            "/bin/mkdir -p \(shellQuoted(halFolder))",
            "/bin/rm -rf \(stagingPath)",
            "/bin/mkdir -m 700 \(stagingPath)",
            "/usr/sbin/chown root:wheel \(stagingPath)",
            "/usr/bin/ditto \(shellQuoted(source.path)) \(stagedPath)",
            "/usr/sbin/chown -R root:wheel \(stagedPath)",
            "/bin/chmod -R go-w \(stagedPath)",
            "/usr/bin/codesign --verify --strict -R \(shellQuoted(requirement)) \(stagedPath)"
                + " || { /bin/rm -rf \(stagingPath); echo 'the driver is not signed by "
                + "this app'\\''s team' >&2; exit 3; }",
            "/bin/rm -rf \(shellQuoted(target))",
            "/bin/mv \(stagedPath) \(shellQuoted(target))",
            "/bin/rmdir \(stagingPath)",
            "/usr/bin/killall coreaudiod || true",
        ].joined(separator: "; ")
    }

    static func removeCommand() -> String {
        [
            "set -e",
            "/bin/rm -rf \(shellQuoted(target))",
            "/usr/bin/killall coreaudiod || true",
        ].joined(separator: "; ")
    }

    /// The AppleScript that runs `command` as root behind the standard macOS
    /// administrator prompt, which names this app.
    static func appleScript(for command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }
}

/// Runs a root command behind the macOS administrator prompt. Injectable so
/// tests never raise the prompt.
struct PrivilegedRunner: Sendable {
    let run: @MainActor @Sendable (_ command: String) async -> PrivilegedRunResult

    /// AppleScript's `do shell script ... with administrator privileges`:
    /// Authorization Services' own password prompt, naming this app, with no
    /// helper left installed. NSAppleScript belongs on the main thread, and
    /// the call waits there while the prompt is up; it is deferred one turn
    /// of the run loop so the row shows "Installing…" first.
    static let appleScript = PrivilegedRunner(run: { command in
        await Task.yield()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let source = DisplayAudioDriverInstaller.appleScript(for: command)
        guard let script = NSAppleScript(source: source) else {
            return .failed("the install script could not be prepared.")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return .succeeded }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        let text = (error[NSAppleScript.errorMessage] as? String)
            ?? (error[NSAppleScript.errorBriefMessage] as? String)
            ?? "error \(error[NSAppleScript.errorNumber] as? Int ?? 0)"
        return .failed(text)
    })
}
