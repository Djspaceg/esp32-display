import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// Choosing a source in the picker used to store only a description string
/// ("a window (800x600)"), so the choice was lost on every restart and the
/// panel silently went back to tracking the default display. What is stored now
/// is the identity the source can be re-resolved from.
final class PanelSourceTests: XCTestCase {

    // MARK: persisted form

    func testAutomaticStoresNothing() {
        XCTAssertNil(PanelSource.automatic.spec)
    }

    func testDisplayAndWindowRoundTripThroughSpec() {
        let cases: [PanelSource] = [.display("Tiny Monitor"), .window("Music")]

        for source in cases {
            XCTAssertEqual(PanelSource(source.spec), source)
        }
    }

    func testMissingSpecIsAutomatic() {
        XCTAssertEqual(PanelSource(nil), .automatic)
    }

    func testEmptySpecIsAutomatic() {
        XCTAssertEqual(PanelSource(SourceSpec()), .automatic)
    }

    /// Blank strings would otherwise resolve to "match anything".
    func testBlankNamesAreAutomatic() {
        XCTAssertEqual(PanelSource(SourceSpec(display: "")), .automatic)
        XCTAssertEqual(PanelSource(SourceSpec(window: "")), .automatic)
    }

    /// Same precedence as a hand-written devices.json entry: the window is the
    /// more specific intent.
    func testWindowWinsOverDisplay() {
        let spec = SourceSpec(display: "Tiny Monitor", window: "Music")

        XCTAssertEqual(PanelSource(spec), .window("Music"))
    }

    // MARK: mapping onto a session

    func testAutomaticBecomesTrackingTheDefaultDisplay() {
        let source = PanelSource.automatic.sessionSource(defaultDisplay: "Tiny Monitor")

        guard case .auto(let display) = source else {
            return XCTFail("expected automatic tracking, got \(source)")
        }
        XCTAssertEqual(display, "Tiny Monitor")
    }

    func testDisplayBecomesADisplaySource() {
        let source = PanelSource.display("Sidecar").sessionSource(defaultDisplay: "Tiny Monitor")

        guard case .display(let name) = source else {
            return XCTFail("expected a display source, got \(source)")
        }
        XCTAssertEqual(name, "Sidecar")
    }

    func testWindowBecomesAWindowSource() {
        let source = PanelSource.window("Music").sessionSource(defaultDisplay: "Tiny Monitor")

        guard case .window(let name) = source else {
            return XCTFail("expected a window source, got \(source)")
        }
        XCTAssertEqual(name, "Music")
    }

    // MARK: labels

    func testLabelsReadAsAChoice() {
        XCTAssertEqual(PanelSource.automatic.label, "Automatic")
        XCTAssertEqual(PanelSource.display("Tiny Monitor").label, "Display: Tiny Monitor")
        XCTAssertEqual(PanelSource.window("Music").label, "Window: Music")
    }
}

/// The source has to survive the trip to disk and back, which is the whole
/// point of storing an identity rather than a description.
final class PersistedSourceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PersistedSourceTests-\(UUID().uuidString)",
                                    isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func reloaded(_ source: PanelSource) throws -> PanelSource {
        var snapshot = PanelSnapshot(
            serviceName: "studio-display", displayName: "studio-display")
        snapshot.source = source
        let url = directory.appendingPathComponent("panels.json")
        try PanelStore.save([PersistedPanel(snapshot: snapshot)], to: url)

        let loaded = PanelStore.load(from: url)
        XCTAssertNil(loaded.failure)
        return try XCTUnwrap(loaded.records.first).snapshot.source
    }

    func testChosenDisplaySurvivesARestart() throws {
        XCTAssertEqual(try reloaded(.display("Tiny Monitor")), .display("Tiny Monitor"))
    }

    func testChosenWindowSurvivesARestart() throws {
        XCTAssertEqual(try reloaded(.window("Music")), .window("Music"))
    }

    func testAutomaticSurvivesARestart() throws {
        XCTAssertEqual(try reloaded(.automatic), .automatic)
    }

    /// Automatic is the default, so it should not add noise to the file.
    func testAutomaticIsNotWrittenToDisk() throws {
        var snapshot = PanelSnapshot(
            serviceName: "studio-display", displayName: "studio-display")
        snapshot.source = .automatic
        let url = directory.appendingPathComponent("panels.json")
        try PanelStore.save([PersistedPanel(snapshot: snapshot)], to: url)

        let json = try XCTUnwrap(String(data: try Data(contentsOf: url), encoding: .utf8))
        XCTAssertFalse(json.contains("\"source\""))
    }

    func testAChosenSourceIsWrittenInTheDevicesFileShape() throws {
        var snapshot = PanelSnapshot(
            serviceName: "studio-display", displayName: "studio-display")
        snapshot.source = .display("Tiny Monitor")
        let url = directory.appendingPathComponent("panels.json")
        try PanelStore.save([PersistedPanel(snapshot: snapshot)], to: url)

        let json = try XCTUnwrap(String(data: try Data(contentsOf: url), encoding: .utf8))
        XCTAssertTrue(json.contains("\"source\""))
        XCTAssertTrue(json.contains("\"display\""))
        XCTAssertTrue(json.contains("Tiny Monitor"))
    }

    /// Records written before sources were stored have no source key and must
    /// load as automatic rather than failing.
    func testRecordWithoutASourceLoadsAsAutomatic() throws {
        let url = directory.appendingPathComponent("panels.json")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data(#"[{"serviceName":"a","displayName":"a"}]"#.utf8).write(to: url)

        let loaded = PanelStore.load(from: url)

        XCTAssertNil(loaded.failure)
        XCTAssertEqual(try XCTUnwrap(loaded.records.first).snapshot.source, .automatic)
    }
}

/// The manager exposes the stored sources so startup can decide what each
/// session captures.
@MainActor
final class PersistedSourceLookupTests: XCTestCase {

    private func panel(_ name: String, source: PanelSource) -> PanelSnapshot {
        var snapshot = PanelSnapshot(serviceName: name, displayName: name)
        snapshot.source = source
        return snapshot
    }

    func testEveryPanelIsReported() {
        let manager = PanelManager(
            previewPanels: [
                panel("studio-display", source: .display("Tiny Monitor")),
                panel("travel-display", source: .window("Music")),
                panel("desk-display", source: .automatic),
            ],
            savedNetworkNames: [],
            usbSerialPorts: [])

        let sources = manager.persistedSources()

        XCTAssertEqual(sources["studio-display"], .display("Tiny Monitor"))
        XCTAssertEqual(sources["travel-display"], .window("Music"))
        XCTAssertEqual(sources["desk-display"], .automatic)
    }

    func testUnknownPanelHasNoStoredSource() {
        let manager = PanelManager(
            previewPanels: [], savedNetworkNames: [], usbSerialPorts: [])

        XCTAssertNil(manager.persistedSources()["ghost"])
    }

    func testResettingToAutomaticClearsTheChoice() {
        let manager = PanelManager(
            previewPanels: [panel("studio-display", source: .display("Tiny Monitor"))],
            savedNetworkNames: [],
            usbSerialPorts: [])

        manager.useAutomaticSource(for: "studio-display")

        XCTAssertEqual(manager.panels.first?.source, .automatic)
        XCTAssertEqual(manager.panels.first?.sourceDescription, "Automatic")
    }
}
