import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// Persistence used to swallow every error with `try?`. The file holds display
/// names and USB port assignments, so a failure to read or write it is exactly
/// the kind of thing the user needs told about rather than losing quietly.
final class PanelStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PanelStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL {
        directory.appendingPathComponent("panels.json")
    }

    private func record(_ name: String, usbPort: String? = nil) -> PersistedPanel {
        var snapshot = PanelSnapshot(serviceName: name, displayName: name)
        snapshot.usbPort = usbPort
        return PersistedPanel(snapshot: snapshot)
    }

    func testSaveCreatesTheContainingDirectory() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        try PanelStore.save([record("studio-display")], to: storeURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
    }

    func testRoundTripThroughDisk() throws {
        let records = [
            record("studio-display", usbPort: "/dev/cu.usbmodem-1"),
            record("travel-display"),
        ]
        try PanelStore.save(records, to: storeURL)

        let loaded = PanelStore.load(from: storeURL)
        XCTAssertNil(loaded.failure)
        XCTAssertEqual(loaded.records, records)
    }

    /// First run has no file. That is not a problem and must not be reported as
    /// one, or every fresh install would open with a warning banner.
    func testMissingFileIsNotAFailure() {
        let loaded = PanelStore.load(from: storeURL)

        XCTAssertTrue(loaded.records.isEmpty)
        XCTAssertNil(loaded.failure)
    }

    func testNilURLIsNotAFailure() {
        let loaded = PanelStore.load(from: nil)

        XCTAssertTrue(loaded.records.isEmpty)
        XCTAssertNil(loaded.failure)
    }

    /// A file that exists but cannot be decoded means settings are about to be
    /// dropped, so it has to surface.
    func testCorruptFileReportsAFailure() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: storeURL)

        let loaded = PanelStore.load(from: storeURL)

        XCTAssertTrue(loaded.records.isEmpty)
        XCTAssertNotNil(loaded.failure)
    }

    /// Valid JSON of the wrong shape is the other way this file goes bad, for
    /// instance if it was hand-edited into an object.
    func testWrongShapeReportsAFailure() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data(#"{"studio-display": {}}"#.utf8).write(to: storeURL)

        let loaded = PanelStore.load(from: storeURL)

        XCTAssertTrue(loaded.records.isEmpty)
        XCTAssertNotNil(loaded.failure)
    }

    /// A record missing a required key must not take the rest of the file with
    /// it silently.
    func testRecordMissingRequiredKeyReportsAFailure() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data(#"[{"displayName": "no service name"}]"#.utf8).write(to: storeURL)

        let loaded = PanelStore.load(from: storeURL)

        XCTAssertTrue(loaded.records.isEmpty)
        XCTAssertNotNil(loaded.failure)
    }

    func testSaveToAnUnwritablePathThrows() {
        let unwritable = URL(fileURLWithPath: "/System/espdisplay-test/panels.json")

        XCTAssertThrowsError(try PanelStore.save([record("studio-display")], to: unwritable))
    }
}

/// Problems that used to reach only stderr: Screen Recording denial, a
/// malformed device-source file, a panel the sender gave up on, and persistence
/// failures. A LaunchAgent's stderr goes to a log file nobody opens, so these
/// have to reach the window.
@MainActor
final class IssueReportingTests: XCTestCase {

    private func makeManager(_ panels: [PanelSnapshot] = []) -> PanelManager {
        PanelManager(previewPanels: panels, savedNetworkNames: [], usbSerialPorts: [])
    }

    private func makeSession(name: String) -> DeviceSession {
        DeviceSession(
            name: name,
            sender: FrameSender(host: "127.0.0.1", port: 5568),
            source: .auto(defaultDisplay: ""),
            picker: nil,
            fps: 30)
    }

    // MARK: app-wide issues

    func testReportedIssueIsPublishedWithItsTitle() {
        let manager = makeManager()

        manager.report(.screenRecording, detail: "allow it in System Settings")

        XCTAssertEqual(manager.issues.count, 1)
        XCTAssertEqual(manager.issues.first?.issue, .screenRecording)
        XCTAssertEqual(manager.issues.first?.detail, "allow it in System Settings")
        XCTAssertEqual(manager.issues.first?.title, AppIssue.screenRecording.title)
    }

    /// A failure that repeats every few seconds must not grow the banner list.
    func testRepeatedReportsOfTheSameKindDoNotStack() {
        let manager = makeManager()

        for _ in 0..<5 {
            manager.report(.persistence, detail: "disk full")
        }

        XCTAssertEqual(manager.issues.count, 1)
    }

    func testRepeatedReportKeepsTheLatestDetail() {
        let manager = makeManager()

        manager.report(.persistence, detail: "disk full")
        manager.report(.persistence, detail: "permission denied")

        XCTAssertEqual(manager.issues.count, 1)
        XCTAssertEqual(manager.issues.first?.detail, "permission denied")
    }

    func testDifferentKindsCoexistInReportOrder() {
        let manager = makeManager()

        manager.report(.screenRecording, detail: "one")
        manager.report(.deviceConfig, detail: "two")

        XCTAssertEqual(manager.issues.map(\.issue), [.screenRecording, .deviceConfig])
    }

    /// Re-reporting an existing kind must not reorder the banners under the
    /// user's cursor.
    func testReportingAgainKeepsPosition() {
        let manager = makeManager()

        manager.report(.screenRecording, detail: "one")
        manager.report(.deviceConfig, detail: "two")
        manager.report(.screenRecording, detail: "one again")

        XCTAssertEqual(manager.issues.map(\.issue), [.screenRecording, .deviceConfig])
    }

    func testResolvingRemovesOnlyThatKind() {
        let manager = makeManager()
        manager.report(.screenRecording, detail: "one")
        manager.report(.deviceConfig, detail: "two")

        manager.resolve(.screenRecording)

        XCTAssertEqual(manager.issues.map(\.issue), [.deviceConfig])
    }

    func testResolvingSomethingNotReportedIsHarmless() {
        let manager = makeManager()

        manager.resolve(.persistence)

        XCTAssertTrue(manager.issues.isEmpty)
    }

    func testDismissingRemovesTheIssue() {
        let manager = makeManager()
        manager.report(.deviceConfig, detail: "bad json")

        manager.dismissIssue(.deviceConfig)

        XCTAssertTrue(manager.issues.isEmpty)
    }

    /// Every kind needs a title, since the banner shows it as the headline.
    func testEveryIssueKindHasATitle() {
        for issue in AppIssue.allCases {
            XCTAssertFalse(issue.title.isEmpty, "\(issue) has no title")
        }
    }

    // MARK: per-panel errors

    /// Giving up on a device previously left the row saying "Offline" with the
    /// reason only in the log.
    func testRetirementExplainsItselfOnThePanel() {
        let manager = makeManager()
        manager.register(makeSession(name: "studio-display"))

        manager.retire("studio-display")

        let panel = manager.panels.first
        XCTAssertNotNil(panel?.lastError)
        XCTAssertFalse(panel?.discovered == true)
    }

    func testHeartbeatClearsTheRetirementMessage() {
        let manager = makeManager()
        manager.register(makeSession(name: "studio-display"))
        manager.retire("studio-display")
        XCTAssertNotNil(manager.panels.first?.lastError)

        manager.update(
            .heartbeat(BandProtocol.DeviceStats(shown: 10, heap: 100_000)),
            for: "studio-display")

        XCTAssertNil(manager.panels.first?.lastError)
        XCTAssertTrue(manager.panels.first?.isOnline == true)
    }

    /// A panel that never had a problem must not gain an error field from
    /// ordinary traffic.
    func testHealthyPanelHasNoError() {
        let manager = makeManager()
        manager.register(makeSession(name: "studio-display"))

        manager.update(
            .heartbeat(BandProtocol.DeviceStats(shown: 1)), for: "studio-display")

        XCTAssertNil(manager.panels.first?.lastError)
    }
}
