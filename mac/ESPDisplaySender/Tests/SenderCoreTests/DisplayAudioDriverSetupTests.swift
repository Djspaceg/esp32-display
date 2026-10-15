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
        var prompts: [String] = []
        manager.macAudio.runner = PrivilegedRunner(run: { command, prompt in
            commands.append(command)
            prompts.append(prompt)
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
        XCTAssertEqual(prompts, [DisplayAudioDriverInstaller.prompt(for: .remove)])
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

    /// Install and removal both run under the one lock, which
    /// install-driver.sh takes too, so two never interleave.
    func testTheCommandsRunUnderTheInstallLock() {
        let source = URL(fileURLWithPath: "/A b.app/Contents/Library/Audio/ESPDisplayAudio.driver")
        let install = DisplayAudioDriverInstaller.installCommand(source: source, team: "T")
        XCTAssertEqual(
            install,
            DisplayAudioDriverInstaller.locked(
                DisplayAudioDriverInstaller.installScript(source: source, team: "T")))
        XCTAssertEqual(
            DisplayAudioDriverInstaller.removeCommand(),
            DisplayAudioDriverInstaller.locked(DisplayAudioDriverInstaller.removeScript()))
        let lock = "'/Library/Audio/Plug-Ins/HAL/.ESPDisplayAudio.lock'"
        // Root-only before it is waited on, and the wait is bounded.
        let created = install.range(of: "(umask 077 && /usr/bin/touch \(lock))")!.lowerBound
        let chmod = install.range(of: "/bin/chmod 600 \(lock)")!.lowerBound
        XCTAssertLessThan(created, chmod, "never readable, even before the chmod")
        let wait = install.range(of: "/usr/bin/lockf -s -k -t 30 \(lock) /bin/sh -c ")!.lowerBound
        XCTAssertLessThan(chmod, wait)
        XCTAssertTrue(install.contains("another install or removal of the audio driver is still running"))
    }

    /// The body lockf runs keeps the script's `set -e`: a failing step stops
    /// it and its failure comes back, rather than the steps after it running
    /// and the whole reading as success. Its own exit 75 is passed on as 70,
    /// so only lockf's timeout reads as "still running". Run as the user;
    /// nothing here needs root.
    func testTheLockedBodyKeepsTheScriptsFailures() throws {
        func run(_ script: String) throws -> (status: Int32, output: String) {
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-c", DisplayAudioDriverInstaller.lockedBody(script)]
            let output = Pipe()
            shell.standardOutput = output
            try shell.run()
            shell.waitUntilExit()
            let text = String(
                data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (shell.terminationStatus, text)
        }
        let failed = try run("set -e; false; echo after")
        XCTAssertNotEqual(failed.status, 0)
        XCTAssertFalse(failed.output.contains("after"), "set -e stopped the script")
        XCTAssertEqual(try run("set -e; echo fine").status, 0)
        XCTAssertEqual(try run("exit 3").status, 3)
        XCTAssertEqual(try run("exit 75").status, 70)
        let trapped = try run("trap 'echo cleaned' EXIT; set -e; false")
        XCTAssertTrue(trapped.output.contains("cleaned"), "the script's own trap still runs")
    }

    func testTheInstallCommandVerifiesTheTeamOnTheRootOwnedCopy() {
        let command = DisplayAudioDriverInstaller.installScript(
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
        let source = URL(fileURLWithPath: "/Users/o'brien/Applications/A b.app/Contents/Library/Audio/ESPDisplayAudio.driver")
        for command in [
            DisplayAudioDriverInstaller.installCommand(source: source, team: "YSHQQLS73U"),
            DisplayAudioDriverInstaller.installScript(source: source, team: "YSHQQLS73U"),
            DisplayAudioDriverInstaller.removeCommand(),
            DisplayAudioDriverInstaller.removeScript(),
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
        let command = DisplayAudioDriverInstaller.removeScript()
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
        let script = try XCTUnwrap(NSAppleScript(source: DisplayAudioDriverInstaller.appleScript(
            for: command, prompt: DisplayAudioDriverInstaller.prompt(for: .install))))
        var error: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error), "\(String(describing: error))")
    }

    func testTheAppleScriptEscapesTheCommandAndThePrompt() {
        let script = DisplayAudioDriverInstaller.appleScript(
            for: #"echo "hi" \ there"#, prompt: #"Say "why""#)
        XCTAssertEqual(
            script,
            #"do shell script "echo \"hi\" \\ there" with prompt "Say \"why\"" with administrator privileges"#)
    }

    /// osascript shows macOS's own dialog, which names osascript; the prompt
    /// text says it is this app asking, and for what.
    func testThePromptSaysWhoIsAskingAndWhy() {
        XCTAssertTrue(DisplayAudioDriverInstaller.prompt(for: .install)
            .contains("ESPDisplaySender wants to install its display audio driver"))
        XCTAssertTrue(DisplayAudioDriverInstaller.prompt(for: .remove)
            .contains("ESPDisplaySender wants to remove its display audio driver"))
    }

    // MARK: - Off the main thread

    /// The password prompt can stay up for as long as the user takes. It is
    /// waited on away from the main thread, so the window keeps drawing (the
    /// busy row included) and the two-second pass keeps running meanwhile.
    @MainActor
    func testThePromptIsWaitedOnOffTheMainThread() async {
        let release = DispatchSemaphore(value: 0)
        let seen = OsascriptCall()
        let runner = PrivilegedRunner.osascript(executor: { arguments in
            seen.record(arguments: arguments, onMain: Thread.isMainThread)
            // Bounded, so a regression onto the main thread fails rather
            // than hanging the suite.
            let released = release.wait(timeout: .now() + 5) == .success
            return released ? (0, "") : (1, "never released")
        })
        var mainTurns = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                mainTurns += 1
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let run = Task { @MainActor in await runner.run("true", "Why") }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let turnsWhileWaiting = mainTurns
        release.signal()
        let result = await run.value
        ticker.cancel()
        XCTAssertEqual(result, .succeeded)
        XCTAssertGreaterThan(turnsWhileWaiting, 5, "the main thread ran while the prompt was up")
        XCTAssertEqual(seen.onMain, false)
        XCTAssertEqual(seen.arguments, [
            "-e", DisplayAudioDriverInstaller.appleScript(for: "true", prompt: "Why"),
        ])
    }

    /// The real /usr/bin/osascript, with scripts that need no administrator
    /// rights and raise no prompt: it runs, and its errors read back plainly.
    func testTheRealOsascriptRunsAndItsErrorsReadBack() {
        let fine = PrivilegedRunner.runOsascript(["-e", #"do shell script "true""#])
        XCTAssertEqual(PrivilegedRunner.outcome(status: fine.status, error: fine.error), .succeeded)
        let boom = PrivilegedRunner.runOsascript(["-e", #"error "boom" number 7"#])
        XCTAssertEqual(
            PrivilegedRunner.outcome(status: boom.status, error: boom.error), .failed("boom"))
        let cancelled = PrivilegedRunner.runOsascript(["-e", #"error "User canceled." number -128"#])
        XCTAssertEqual(
            PrivilegedRunner.outcome(status: cancelled.status, error: cancelled.error), .cancelled)
    }

    /// Quitting ends an osascript still waiting (here on a harmless delay,
    /// standing in for an unanswered password dialog), so nothing it was
    /// asked to do runs after the app is gone.
    func testQuittingEndsAWaitingOsascript() {
        defer { PrivilegedRunner.reopenForTesting() }
        let done = expectation(description: "osascript ended")
        let result = OsascriptCall()
        DispatchQueue.global().async {
            let outcome = PrivilegedRunner.runOsascript(["-e", "delay 30"])
            result.record(arguments: ["\(outcome.status)"], onMain: false)
            done.fulfill()
        }
        let started = Date()
        Thread.sleep(forTimeInterval: 0.5)
        PrivilegedRunner.terminateRunning()
        wait(for: [done], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertNotEqual(result.arguments, ["0"], "it was ended, not left to finish")
        // One asked for after the quit began never starts at all.
        let late = PrivilegedRunner.runOsascript(["-e", "delay 30"])
        XCTAssertEqual(late.status, -1)
        XCTAssertTrue(late.error.contains("quitting"))
    }

    /// The window stays live through the app's real click path while the
    /// privileged step waits: the real osascript process, running a harmless
    /// `do shell script "sleep 1"` (waited on as the admin command is, with
    /// no prompt), through the real runner. A main-queue timer keeps firing
    /// throughout. The same probe on 3847300's runner, NSAppleScript on the
    /// main actor, fired 6 times in 1.22 s (red-first-off-main.log).
    @MainActor
    func testTheWindowKeepsWorkingThroughAClickWhileThePrivilegedStepWaits() async throws {
        let manager = PanelManager(previewPanels: [], savedNetworkNames: [], usbSerialPorts: [])
        manager.macAudio.showForTesting(
            driver: .ready,
            setup: DisplayAudioDriverSetup(bundledDriver: true, signingTeam: "T"))
        let finished = expectation(description: "runner finished")
        let real = PrivilegedRunner.osascript(executor: { _ in
            PrivilegedRunner.runOsascript(["-e", #"do shell script "sleep 1""#])
        })
        manager.macAudio.runner = PrivilegedRunner(run: { command, prompt in
            let result = await real.run(command, prompt)
            finished.fulfill()
            return result
        })
        var ticks = 0
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in ticks += 1 }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        let start = Date()
        manager.runDisplayAudioDriverAction(.remove)
        await fulfillment(of: [finished], timeout: 5)
        let seconds = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(seconds, 0.9, "the stand-in really waited")
        XCTAssertGreaterThan(
            ticks, Int(seconds / 0.02 / 2),
            "the main thread kept servicing work: \(ticks) ticks in \(seconds) s")
    }

    func testOsascriptOutcomesAreReadFromItsExit() {
        XCTAssertEqual(PrivilegedRunner.outcome(status: 0, error: ""), .succeeded)
        XCTAssertEqual(
            PrivilegedRunner.outcome(
                status: 1, error: "0:120: execution error: User canceled. (-128)\n"),
            .cancelled)
        XCTAssertEqual(
            PrivilegedRunner.outcome(
                status: 1,
                error: "0:120: execution error: The administrator user name or password "
                    + "was incorrect. (-60007)\n"),
            .failed("The administrator user name or password was incorrect."))
        XCTAssertEqual(
            PrivilegedRunner.outcome(
                status: 1,
                error: "0:900: execution error: the driver is not signed by this app's team (3)\n"),
            .failed("the driver is not signed by this app's team"))
        XCTAssertEqual(
            PrivilegedRunner.outcome(status: 1, error: ""),
            .failed("osascript exited with status 1."))
        // A line logged after the error does not hide a cancel.
        XCTAssertEqual(
            PrivilegedRunner.outcome(
                status: 1,
                error: "0:120: execution error: User canceled. (-128)\n"
                    + "2026-10-14 objc[1]: some framework note\n"),
            .cancelled)
        XCTAssertEqual(
            PrivilegedRunner.outcome(status: 1, error: "0:12: syntax error: Expected end of line."),
            .failed("syntax error: Expected end of line."))
    }
}

final class OsascriptCall: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: (arguments: [String], onMain: Bool)?
    func record(arguments: [String], onMain: Bool) {
        lock.withLock { recorded = (arguments, onMain) }
    }
    var arguments: [String]? { lock.withLock { recorded?.arguments } }
    var onMain: Bool? { lock.withLock { recorded?.onMain } }
}
