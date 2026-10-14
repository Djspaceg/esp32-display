import XCTest

@testable import SenderCore

/// The Install / Remove Audio Driver row: what it shows for each driver
/// state, and how a click, the macOS password prompt's answer and the driver
/// appearing move it along. No test runs the privileged command.
final class DisplayAudioDriverSetupTests: XCTestCase {
    func testTheTokenIsReplacedOnlyWhenMissing() {
        var saved: [String] = []
        let found = DisplayAudioDriverToken.resolve(
            .found("kept"), fresh: { "new" }, save: { saved.append($0) })
        XCTAssertEqual(found, "kept")
        XCTAssertEqual(saved, [])
        let missing = DisplayAudioDriverToken.resolve(
            .notFound, fresh: { "new" }, save: { saved.append($0) })
        XCTAssertEqual(missing, "new")
        XCTAssertEqual(saved, ["new"])
        let locked = DisplayAudioDriverToken.resolve(
            .unavailable, fresh: { "launch-only" }, save: { saved.append($0) })
        XCTAssertEqual(locked, "launch-only")
        XCTAssertEqual(saved, ["new"], "a Keychain that will not answer keeps what it has")
    }

    func testTheDeviceUIDCarriesTheOwnersSuffix() {
        // SHA-256("abc") begins ba7816bf8f01cfea.
        XCTAssertEqual(
            DisplayAudioDriverProtocol.deviceUID(for: "u", token: "abc"),
            "u.ba7816bf8f01cfea")
    }

    /// A click, its command, the prompt's answer and the driver going, with a
    /// runner standing in for the prompt.
    @MainActor
    func testAClickRunsTheCommandAndFollowsTheDriver() async throws {
        let manager = PanelManager(previewPanels: [], savedNetworkNames: [], usbSerialPorts: [])
        manager.macAudio.showForTesting(
            driver: .ready,
            setup: DisplayAudioDriverSetup(bundledDriver: true, signingTeam: "T"))
        let ran = expectation(description: "the command ran")
        var commands: [String] = []
        manager.macAudio.runner = PrivilegedRunner(run: { command in
            commands.append(command)
            ran.fulfill()
            return .succeeded
        })
        manager.runDisplayAudioDriverAction(.remove)
        XCTAssertEqual(manager.displayAudioDriverRow?.status, "Removing…")
        await fulfillment(of: [ran], timeout: 2)
        for _ in 0..<20 where manager.displayAudioDriverRow?.status == "Removing…" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(commands, [DisplayAudioDriverInstaller.removeCommand()])
        XCTAssertTrue(
            manager.displayAudioDriverRow?.status.contains("waiting for macOS") == true,
            manager.displayAudioDriverRow?.status ?? "")
        manager.macAudio.showForTesting(driver: .absent, setup: manager.macAudio.setup)
        manager.macAudio.setup.observe(.absent, now: Date())
        XCTAssertEqual(manager.displayAudioDriverRow?.button?.action, .install)
    }

    private let start = Date(timeIntervalSince1970: 1_000)
    private func ready() -> DisplayAudioDriverSetup {
        DisplayAudioDriverSetup(bundledDriver: true, signingTeam: "YSHQQLS73U")
    }

    func testNotInstalledOffersInstall() {
        let shown = ready().presentation(availability: .absent)
        XCTAssertEqual(shown.status, "Not installed")
        XCTAssertEqual(shown.button?.title, "Install Audio Driver…")
        XCTAssertEqual(shown.button?.action, .install)
        XCTAssertEqual(shown.button?.enabled, true)
        XCTAssertFalse(shown.busy)
        XCTAssertNil(shown.message)
    }

    func testInstalledOffersRemove() {
        let shown = ready().presentation(availability: .ready)
        XCTAssertEqual(shown.status, "Installed")
        XCTAssertEqual(shown.button?.title, "Remove Audio Driver…")
        XCTAssertEqual(shown.button?.action, .remove)
    }

    func testAnotherVersionOffersReinstall() {
        let shown = ready().presentation(availability: .incompatible(version: 1))
        XCTAssertTrue(shown.status.contains("version 1"), shown.status)
        XCTAssertEqual(shown.button?.title, "Reinstall Audio Driver…")
        XCTAssertEqual(shown.button?.action, .install)
    }

    func testABuildWithoutADriverOrATeamCannotInstall() {
        let noDriver = DisplayAudioDriverSetup(bundledDriver: false, signingTeam: "T")
            .presentation(availability: .absent)
        XCTAssertEqual(noDriver.button?.enabled, false)
        XCTAssertTrue(noDriver.button?.help?.contains("carries no audio driver") == true)
        XCTAssertTrue(
            noDriver.message?.contains("sudo mac/AudioDriver/install-driver.sh") == true,
            "a build that cannot install still says how")
        let noTeam = DisplayAudioDriverSetup(bundledDriver: true, signingTeam: nil)
            .presentation(availability: .absent)
        XCTAssertEqual(noTeam.button?.enabled, false)
        XCTAssertTrue(noTeam.button?.help?.contains("not signed") == true)
        // Removing needs neither.
        let remove = DisplayAudioDriverSetup(bundledDriver: false, signingTeam: nil)
            .presentation(availability: .ready)
        XCTAssertEqual(remove.button?.enabled, true)
    }

    func testNothingIsShownBeforeTheDriverWasLookedFor() {
        XCTAssertNil(ready().presentation(availability: nil).button)
    }

    func testAClickWaitsForThePasswordWithNoButton() {
        var setup = ready()
        XCTAssertTrue(setup.begin(.install, now: start))
        let shown = setup.presentation(availability: .absent)
        XCTAssertTrue(shown.busy)
        XCTAssertNil(shown.button)
        XCTAssertEqual(shown.status, "Installing…")
        XCTAssertTrue(shown.message?.contains("password") == true)
        XCTAssertFalse(setup.begin(.install, now: start), "a second click is ignored")
    }

    func testCancellingThePromptSaysSoAndOffersInstallAgain() {
        var setup = ready()
        setup.begin(.install, now: start)
        setup.finished(.install, .cancelled, now: start)
        let shown = setup.presentation(availability: .absent)
        XCTAssertFalse(shown.busy)
        XCTAssertEqual(shown.button?.action, .install)
        XCTAssertEqual(shown.message, "Installing the audio driver was cancelled.")
    }

    func testAFailureShowsTheErrorAndOffersInstallAgain() {
        var setup = ready()
        setup.begin(.install, now: start)
        setup.finished(.install, .failed("codesign said no"), now: start)
        let shown = setup.presentation(availability: .absent)
        XCTAssertEqual(shown.button?.action, .install)
        XCTAssertTrue(shown.message?.contains("could not be installed") == true)
        XCTAssertTrue(shown.message?.contains("codesign said no") == true)
    }

    func testAnInstallFinishesWhenTheDriverAppears() {
        var setup = ready()
        setup.begin(.install, now: start)
        setup.finished(.install, .succeeded, now: start)
        var shown = setup.presentation(availability: .absent)
        XCTAssertTrue(shown.busy)
        XCTAssertTrue(shown.status.contains("waiting for macOS"), shown.status)
        setup.observe(.absent, now: start.addingTimeInterval(3))
        XCTAssertTrue(setup.presentation(availability: .absent).busy)
        setup.observe(.ready, now: start.addingTimeInterval(4))
        shown = setup.presentation(availability: .ready)
        XCTAssertFalse(shown.busy)
        XCTAssertEqual(shown.status, "Installed")
        XCTAssertEqual(shown.button?.action, .remove)
        XCTAssertNil(shown.message)
    }

    func testADriverThatNeverLoadsSaysSo() {
        var setup = ready()
        setup.begin(.install, now: start)
        setup.finished(.install, .succeeded, now: start)
        setup.observe(.absent, now: start.addingTimeInterval(DisplayAudioDriverSetup.loadTimeout + 1))
        let shown = setup.presentation(availability: .absent)
        XCTAssertFalse(shown.busy)
        XCTAssertEqual(shown.button?.action, .install)
        XCTAssertTrue(shown.message?.contains("has not loaded it") == true, shown.message ?? "")
    }

    func testARemovalFinishesWhenTheDriverIsGone() {
        var setup = ready()
        XCTAssertTrue(setup.begin(.remove, now: start))
        XCTAssertEqual(setup.presentation(availability: .ready).status, "Removing…")
        setup.finished(.remove, .succeeded, now: start)
        XCTAssertTrue(setup.presentation(availability: .ready).busy)
        setup.observe(.absent, now: start.addingTimeInterval(2))
        let shown = setup.presentation(availability: .absent)
        XCTAssertFalse(shown.busy)
        XCTAssertEqual(shown.button?.action, .install)
    }

    // MARK: - The privileged command

    func testTheInstallCommandVerifiesTheTeamOnTheRootOwnedCopy() {
        let command = DisplayAudioDriverInstaller.installCommand(
            source: URL(fileURLWithPath: "/Users/x/Applications/My App.app/Contents/Library/Audio/ESPDisplayAudio.driver"),
            team: "YSHQQLS73U")
        XCTAssertTrue(command.contains(
            "/usr/bin/ditto '/Users/x/Applications/My App.app/Contents/Library/Audio/ESPDisplayAudio.driver' "
                + "'/Library/Audio/Plug-Ins/HAL/.ESPDisplayAudio.installing/ESPDisplayAudio.driver'"),
            command)
        let ditto = command.range(of: "/usr/bin/ditto")!.lowerBound
        let lockedDown = command.range(
            of: "/bin/mkdir -m 700 '/Library/Audio/Plug-Ins/HAL/.ESPDisplayAudio.installing'")!
            .lowerBound
        XCTAssertLessThan(lockedDown, ditto, "the staging folder is root-only before the copy")
        let verify = command.range(of: "/usr/bin/codesign --verify")!.lowerBound
        let move = command.range(of: "/bin/mv")!.lowerBound
        XCTAssertLessThan(ditto, verify)
        XCTAssertLessThan(verify, move, "the staged copy is checked before it is put in place")
        XCTAssertTrue(command.contains("certificate leaf[subject.OU] = \"YSHQQLS73U\""))
        XCTAssertTrue(command.contains("anchor apple generic"))
        XCTAssertTrue(command.contains("/usr/bin/killall coreaudiod"))
        XCTAssertTrue(command.hasPrefix("set -e;"))
    }

    /// Both commands parse as shell, quotes in the path and all; parsing
    /// runs nothing.
    func testTheCommandsParseAsShell() throws {
        for command in [
            DisplayAudioDriverInstaller.installCommand(
                source: URL(fileURLWithPath: "/Users/o'brien/Applications/A b.app/Contents/Library/Audio/ESPDisplayAudio.driver"),
                team: "YSHQQLS73U"),
            DisplayAudioDriverInstaller.removeCommand(),
        ] {
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-n", "-c", command]
            let errors = Pipe()
            shell.standardError = errors
            try shell.run()
            shell.waitUntilExit()
            let text = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(shell.terminationStatus, 0, "\(command)\n\(text)")
        }
    }

    func testTheRemoveCommandTouchesOnlyTheDriver() {
        let command = DisplayAudioDriverInstaller.removeCommand()
        XCTAssertTrue(command.contains("/bin/rm -rf '/Library/Audio/Plug-Ins/HAL/ESPDisplayAudio.driver'"))
        XCTAssertTrue(command.contains("/usr/bin/killall coreaudiod"))
        XCTAssertFalse(command.contains("Plug-Ins/HAL'"), "never the HAL folder itself")
    }

    func testShellQuotingSurvivesQuotes() {
        XCTAssertEqual(DisplayAudioDriverInstaller.shellQuoted("a'b c"), "'a'\\''b c'")
    }

    /// The real AppleScript compiles, quotes and all. Compiling runs nothing.
    func testTheAppleScriptCompiles() throws {
        let command = DisplayAudioDriverInstaller.installCommand(
            source: URL(fileURLWithPath: #"/Users/a"b\c/X.app/Contents/Library/Audio/ESPDisplayAudio.driver"#),
            team: "YSHQQLS73U")
        let script = try XCTUnwrap(
            NSAppleScript(source: DisplayAudioDriverInstaller.appleScript(for: command)))
        var error: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error), "\(String(describing: error))")
    }

    func testTheAppleScriptEscapesTheCommand() {
        let script = DisplayAudioDriverInstaller.appleScript(for: #"echo "hi" \ there"#)
        XCTAssertEqual(
            script,
            #"do shell script "echo \"hi\" \\ there" with administrator privileges"#)
    }
}
