import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// The app-side half of onboarding a board over USB: finding esptool, running a
/// process at all, and what the app ships with.
///
/// A FLASH IS NOT EXERCISED HERE and cannot be. The board attached to this machine
/// is the user's only ESP32-S3 and still carries its factory firmware, so it was
/// probed read-only and never written. What these tests do is the thing that IS
/// testable about spawning a process: that the runner runs one, reads both its
/// streams, splits its lines, reports its exit status and stops when cancelled -
/// against harmless commands that ship with macOS.
final class UsbOnboardingAppTests: XCTestCase {

    // MARK: - finding the tool

    /// The default arduino-cli data directory on macOS, plus the older one, plus the
    /// documented override. The list is asserted because it is also what the "not
    /// installed" message shows the user, and a message that names a directory
    /// nobody searched is worse than none.
    func testSearchRootsAreTheDefaultsAndTheDocumentedOverride() {
        XCTAssertEqual(
            EsptoolInstallation.searchRoots(home: "/Users/x"),
            ["/Users/x/Library/Arduino15", "/Users/x/.arduino15"])
        XCTAssertEqual(
            EsptoolInstallation.searchRoots(
                home: "/Users/x",
                environment: ["ARDUINO_DIRECTORIES_DATA": "/opt/arduino"]),
            ["/opt/arduino", "/Users/x/Library/Arduino15", "/Users/x/.arduino15"])
    }

    /// An override naming the default must not make the message list one directory
    /// twice.
    func testAnOverrideThatNamesTheDefaultIsNotListedTwice() {
        XCTAssertEqual(
            EsptoolInstallation.searchRoots(
                home: "/Users/x",
                environment: ["ARDUINO_DIRECTORIES_DATA": "/Users/x/Library/Arduino15"]),
            ["/Users/x/Library/Arduino15", "/Users/x/.arduino15"])
    }

    func testAnEmptyOverrideIsIgnoredRatherThanSearched() {
        XCTAssertEqual(
            EsptoolInstallation.searchRoots(
                home: "/Users/x", environment: ["ARDUINO_DIRECTORIES_DATA": "  "]),
            ["/Users/x/Library/Arduino15", "/Users/x/.arduino15"])
    }

    func testTheToolDirectoryIsWhereArduinoCLIKeepsIt() {
        XCTAssertEqual(
            EsptoolInstallation.toolDirectory(inRoot: "/Users/x/Library/Arduino15"),
            "/Users/x/Library/Arduino15/packages/esp32/tools/esptool_py")
    }

    /// NEWEST VERSION DIRECTORY WINS, by string order - the same lexicographic
    /// caveat `esptool_path()` documents in tools/espdisp.py, kept identical so the
    /// two implementations pick the same tool.
    func testTheNewestVersionDirectoryWins() {
        let chosen = EsptoolInstallation.choose(from: [
            "/core/esptool_py/4.9.0/esptool",
            "/core/esptool_py/5.3.1/esptool",
            "/core/esptool_py/5.0.0/esptool",
        ])
        XCTAssertEqual(chosen?.path, "/core/esptool_py/5.3.1/esptool")
    }

    /// A binary beats a script when both are present: it needs no interpreter, and
    /// the interpreter path is the part of this that has never been exercised.
    func testABinaryIsPreferredToAScript() {
        let chosen = EsptoolInstallation.choose(from: [
            "/core/esptool_py/5.3.1/esptool.py",
            "/core/esptool_py/5.3.1/esptool",
        ])
        XCTAssertEqual(chosen?.path, "/core/esptool_py/5.3.1/esptool")
        XCTAssertFalse(chosen?.isPythonScript ?? true)
    }

    /// And a script is used when it is all there is, rather than reporting nothing
    /// installed.
    func testAScriptIsUsedWhenItIsAllThereIs() {
        let chosen = EsptoolInstallation.choose(from: [
            "/core/esptool_py/4.9.0/esptool.py",
        ])
        XCTAssertEqual(chosen?.path, "/core/esptool_py/4.9.0/esptool.py")
        XCTAssertTrue(chosen?.isPythonScript ?? false)
    }

    func testNothingFoundMeansNoTool() {
        XCTAssertNil(EsptoolInstallation.choose(from: []))
    }

    /// A home directory with no core in it reports missing, and reports the
    /// directories it looked in so `UsbOnboardingPlan.esptoolMissing` can name them.
    func testAnEmptyMachineReportsMissingWithWhereItLooked() {
        let availability = EsptoolInstallation.locate(
            home: "/nonexistent-home-for-tests", environment: [:])
        guard case .missing(let searched) = availability else {
            return XCTFail("expected missing, got \(availability)")
        }
        XCTAssertEqual(searched, [
            "/nonexistent-home-for-tests/Library/Arduino15/packages/esp32/tools/esptool_py",
            "/nonexistent-home-for-tests/.arduino15/packages/esp32/tools/esptool_py",
        ])
    }

    /// Found on disk, with a directory tree built here rather than depending on what
    /// this machine happens to have installed.
    func testAToolOnDiskIsFound() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("espdisp-tool-" + UUID().uuidString)
        let versionDirectory = root
            .appendingPathComponent("Library/Arduino15/packages/esp32/tools/esptool_py/5.3.1")
        try FileManager.default.createDirectory(
            at: versionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = versionDirectory.appendingPathComponent("esptool")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let availability = EsptoolInstallation.locate(home: root.path, environment: [:])
        XCTAssertEqual(availability, .installed(path: tool.path))
    }

    /// A file that is there and not executable is not a tool: reporting it as one
    /// would turn "install the core" into a spawn failure.
    func testANonExecutableFileIsNotATool() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("espdisp-tool-" + UUID().uuidString)
        let versionDirectory = root
            .appendingPathComponent("Library/Arduino15/packages/esp32/tools/esptool_py/5.3.1")
        try FileManager.default.createDirectory(
            at: versionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a program".utf8).write(
            to: versionDirectory.appendingPathComponent("esptool"))
        guard case .missing = EsptoolInstallation.locate(home: root.path, environment: [:])
        else { return XCTFail("a non-executable file was taken for a tool") }
    }

    // MARK: - running a process at all

    /// The first process this app has ever spawned, exercised against something that
    /// cannot do any harm.
    func testARunReportsOutputAndSuccess() async throws {
        let outcome = try await EsptoolRunner.run(
            EsptoolCommand(executable: "/bin/echo", arguments: ["esptool v5.3.1"]))
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertEqual(outcome.output, "esptool v5.3.1\n")
    }

    func testLinesAreStreamedAsTheyArriveIncludingCarriageReturns() async throws {
        let lines = LineBox()
        _ = try await EsptoolRunner.run(
            EsptoolCommand(
                executable: "/bin/sh",
                arguments: ["-c", "printf 'Writing 10 %%\\rWriting 20 %%\\rdone\\n'"])
        ) { line in
            lines.append(line)
        }
        XCTAssertEqual(lines.all, ["Writing 10 %", "Writing 20 %", "done"])
    }

    /// STDERR IS NOT A FAILURE. esptool 5.3.1 prints its deprecation warnings to the
    /// normal output stream and exits 0, and a runner that treated any stderr output
    /// as failure would fail a working flash.
    func testStderrIsCapturedAndIsNotTakenForFailure() async throws {
        let outcome = try await EsptoolRunner.run(
            EsptoolCommand(
                executable: "/bin/sh",
                arguments: ["-c", "echo 'Warning: Deprecated' >&2; echo fine; exit 0"]))
        XCTAssertTrue(outcome.succeeded)
        XCTAssertTrue(outcome.output.contains("Warning: Deprecated"))
        XCTAssertTrue(outcome.output.contains("fine"))
    }

    /// Only the exit status decides, and the transcript comes back with it so the
    /// failure can be explained in esptool's own words.
    func testANonZeroExitIsReportedWithItsTranscript() async throws {
        // The message is passed as an argument rather than interpolated into the
        // script, because esptool's real wording contains an apostrophe and this
        // test is about the transcript rather than about shell quoting.
        let fatal = "A fatal error occurred: Could not open /dev/cu.usbmodem101, the "
            + "port is busy or doesn't exist."
        let outcome = try await EsptoolRunner.run(
            EsptoolCommand(
                executable: "/bin/sh",
                arguments: ["-c", "printf '%s\\n' \"$1\"; exit 2", "sh", fatal]))
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.exitCode, 2)
        XCTAssertEqual(EsptoolOutput.failureSummary(in: outcome.output), fatal)
    }

    /// A tool that is not there fails as "could not start", which is a different
    /// thing from a tool that ran and refused - and the message names the path, since
    /// a wrong path is the likely cause.
    func testAMissingExecutableFailsBeforeSpawning() async {
        do {
            _ = try await EsptoolRunner.run(
                EsptoolCommand(executable: "/nonexistent/esptool", arguments: []))
            XCTFail("a missing executable was not refused")
        } catch let failure as EsptoolRunner.Failure {
            XCTAssertEqual(
                failure,
                .couldNotStart(
                    tool: "/nonexistent/esptool",
                    reason: "it is not an executable file on this Mac"))
            XCTAssertTrue(
                failure.localizedDescription.contains("/nonexistent/esptool"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// Cancellation terminates the child rather than leaving it holding the port.
    /// Timed loosely: what is asserted is that a five-second sleep does not take five
    /// seconds to abandon.
    func testCancellationStopsTheChild() async throws {
        let started = Date()
        let task = Task {
            try await EsptoolRunner.run(
                EsptoolCommand(executable: "/bin/sleep", arguments: ["5"]))
        }
        // Long enough for the process to be running, short enough that a five-second
        // sleep completing would be obvious.
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled run reported success")
        } catch let failure as EsptoolRunner.Failure {
            XCTAssertEqual(failure, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    /// The runner does not run on the main actor, which is what keeps a multi-minute
    /// flash from stalling the window. Asserted by observing that the main thread is
    /// free while a child is running.
    func testTheMainThreadIsNotBlockedWhileAChildRuns() async throws {
        let ticks = LineBox()
        let ticker = Task { @MainActor in
            for index in 0..<5 {
                ticks.append("tick\(index)")
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        _ = try await EsptoolRunner.run(
            EsptoolCommand(executable: "/bin/sleep", arguments: ["0.3"]))
        await ticker.value
        XCTAssertEqual(ticks.all.count, 5)
    }

    // MARK: - the firmware the app ships with

    /// `swift test` builds no app wrapper, so the test bundle has no default firmware
    /// in it. That is the packaged-without-one case, and it must read as "choose a
    /// file" rather than as an error.
    func testATestBundleShipsNoDefaultFirmwareAndThatIsNotAnError() {
        XCTAssertEqual(BundledFirmware.load(in: Bundle(for: Self.self)), .none)
        XCTAssertNil(BundledFirmware.defaultBundleURL(in: Bundle(for: Self.self)))
    }

    /// The resource name is one string in one place, because make-app.sh writes it
    /// and this reads it, and a rename that only happened on one side would ship an
    /// app that quietly could not find its own firmware.
    func testTheResourceNameIsWhatTheScriptInstalls() {
        XCTAssertEqual(BundledFirmware.resourceName, "espdisp-default")
        XCTAssertEqual(FirmwareBundle.fileExtension, "espdispfw")
    }

    /// A shipped bundle that cannot be read is a packaging fault, and it is reported
    /// as one rather than as "this app does not do that".
    func testAnUnreadableShippedBundleIsItsOwnCase() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("espdisp-resources-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(
            BundledFirmware.resourceName + "." + FirmwareBundle.fileExtension)
        try Data("not a bundle".utf8).write(to: file)
        let bundle = try XCTUnwrap(Bundle(url: makeBundleWrapper(around: file)))
        guard case .unreadable(let path, let reason) = BundledFirmware.load(in: bundle)
        else { return XCTFail("a damaged bundle was not reported as damaged") }
        XCTAssertEqual(path, file.lastPathComponent)
        XCTAssertFalse(reason.isEmpty)
    }

    /// A minimal .bundle wrapper around one resource file, so `Bundle` can be asked
    /// for it the way `Bundle.main` is asked in the app.
    private func makeBundleWrapper(around file: URL) throws -> URL {
        let wrapper = file.deletingLastPathComponent()
            .appendingPathComponent("Fixture.bundle")
        let resources = wrapper.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(
            at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: file, to: resources.appendingPathComponent(file.lastPathComponent))
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>\
            <key>CFBundleIdentifier</key><string>com.espdisplay.test.fixture</string>\
            </dict></plist>
            """.utf8).write(to: wrapper.appendingPathComponent("Contents/Info.plist"))
        return wrapper
    }
}

/// A thread-safe collector, because the runner's callback arrives on a Dispatch
/// queue rather than on the test's thread.
private final class LineBox: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
