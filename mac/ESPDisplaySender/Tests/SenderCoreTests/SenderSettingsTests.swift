import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// Frame rate, pacing, and identify duration were command-line flags only.
/// Under the LaunchAgent, which runs with a fixed argument list, that made them
/// unreachable without editing a plist.
final class SenderSettingsTests: XCTestCase {

    func testDefaultsMatchTheOldFlagDefaults() {
        let settings = SenderSettings()

        XCTAssertEqual(settings.fps, 40)
        XCTAssertEqual(settings.spacingMicros, 200)
        XCTAssertTrue(settings.adaptivePacing)
        XCTAssertEqual(settings.identifySeconds, 8)
        XCTAssertEqual(settings.tileQuality, .auto)
        XCTAssertEqual(settings, settings.validated, "defaults must be in range")
    }

    /// A settings.json written by a build that predates a field must keep
    /// every field it does have and default the missing one - the whole file
    /// failing to decode would silently reset the user's settings.
    func testOlderSettingsFileDecodesWithDefaults() throws {
        let old = Data(#"{"fps": 25, "spacingMicros": 300, "#.utf8)
            + Data(#""adaptivePacing": false, "identifySeconds": 12}"#.utf8)
        let decoded = try JSONDecoder().decode(SenderSettings.self, from: old)
        XCTAssertEqual(decoded.fps, 25)
        XCTAssertEqual(decoded.spacingMicros, 300)
        XCTAssertFalse(decoded.adaptivePacing)
        XCTAssertEqual(decoded.identifySeconds, 12)
        XCTAssertEqual(decoded.tileQuality, .auto)
        // An unrecognized quality string (a future build's value) falls back
        // rather than failing the whole file.
        let future = Data(#"{"fps": 25, "tileQuality": "halfRes"}"#.utf8)
        let tolerant = try JSONDecoder().decode(SenderSettings.self, from: future)
        XCTAssertEqual(tolerant.tileQuality, .auto)
        XCTAssertEqual(tolerant.fps, 25)
    }

    func testTileQualityRoundTrips() throws {
        var settings = SenderSettings()
        settings.tileQuality = .losslessOnly
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SenderSettings.self, from: data)
        XCTAssertEqual(decoded.tileQuality, .losslessOnly)
        XCTAssertEqual(decoded, settings)
    }

    /// The pacing bounds come from the sender itself, so the UI cannot offer a
    /// value the sender would silently clamp.
    func testPacingBoundsComeFromTheSender() {
        XCTAssertEqual(SenderSettings.spacingRange, FrameSender.spacingRange)
    }

    /// The identify bounds come from the protocol, which mirrors the firmware's
    /// own check; a value outside it would be rejected by the device.
    func testIdentifyBoundsComeFromTheProtocol() {
        XCTAssertEqual(SenderSettings.identifyRange, DeviceProtocol.identifySecondsRange)
    }

    func testValuesBelowRangeAreRaised() {
        var settings = SenderSettings()
        settings.fps = 0
        settings.spacingMicros = 1
        settings.identifySeconds = 0

        let validated = settings.validated
        XCTAssertEqual(validated.fps, SenderSettings.fpsRange.lowerBound)
        XCTAssertEqual(validated.spacingMicros, SenderSettings.spacingRange.lowerBound)
        XCTAssertEqual(validated.identifySeconds, SenderSettings.identifyRange.lowerBound)
    }

    func testValuesAboveRangeAreLowered() {
        var settings = SenderSettings()
        settings.fps = 1_000
        settings.spacingMicros = 99_999
        settings.identifySeconds = 600

        let validated = settings.validated
        XCTAssertEqual(validated.fps, SenderSettings.fpsRange.upperBound)
        XCTAssertEqual(validated.spacingMicros, SenderSettings.spacingRange.upperBound)
        XCTAssertEqual(validated.identifySeconds, SenderSettings.identifyRange.upperBound)
    }

    func testValidationLeavesTheToggleAlone() {
        var settings = SenderSettings()
        settings.adaptivePacing = false

        XCTAssertFalse(settings.validated.adaptivePacing)
    }
}

final class SettingsStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SettingsStoreTests-\(UUID().uuidString)",
                                    isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL {
        directory.appendingPathComponent("settings.json")
    }

    private func write(_ json: String) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: storeURL)
    }

    func testRoundTripThroughDisk() throws {
        let settings = SenderSettings(
            fps: 24, spacingMicros: 400, adaptivePacing: false, identifySeconds: 15)
        try SettingsStore.save(settings, to: storeURL)

        let loaded = SettingsStore.load(from: storeURL)
        XCTAssertNil(loaded.failure)
        XCTAssertEqual(loaded.settings, settings)
    }

    /// First run has no file, which is not a problem.
    func testMissingFileYieldsDefaults() {
        let loaded = SettingsStore.load(from: storeURL)

        XCTAssertEqual(loaded.settings, SenderSettings())
        XCTAssertNil(loaded.failure)
    }

    func testNilURLYieldsDefaults() {
        let loaded = SettingsStore.load(from: nil)

        XCTAssertEqual(loaded.settings, SenderSettings())
        XCTAssertNil(loaded.failure)
    }

    /// A file that cannot be decoded is reported, and the sender still starts on
    /// the defaults rather than refusing to run.
    func testCorruptFileIsReportedAndFallsBackToDefaults() throws {
        try write("{ not json")

        let loaded = SettingsStore.load(from: storeURL)

        XCTAssertEqual(loaded.settings, SenderSettings())
        XCTAssertNotNil(loaded.failure)
    }

    /// A hand-edited file must not be able to put the sender somewhere its own
    /// UI could not have.
    func testOutOfRangeFileIsClampedOnLoad() throws {
        try write(#"{"fps":999,"spacingMicros":1,"adaptivePacing":true,"identifySeconds":900}"#)

        let loaded = SettingsStore.load(from: storeURL)

        XCTAssertNil(loaded.failure)
        XCTAssertEqual(loaded.settings.fps, SenderSettings.fpsRange.upperBound)
        XCTAssertEqual(
            loaded.settings.spacingMicros, SenderSettings.spacingRange.lowerBound)
        XCTAssertEqual(
            loaded.settings.identifySeconds, SenderSettings.identifyRange.upperBound)
    }

    func testOutOfRangeValuesAreClampedOnSave() throws {
        var settings = SenderSettings()
        settings.fps = 999
        try SettingsStore.save(settings, to: storeURL)

        XCTAssertEqual(
            SettingsStore.load(from: storeURL).settings.fps,
            SenderSettings.fpsRange.upperBound)
    }

    /// It lives beside the panel records, not inside them, so a settings problem
    /// cannot cost the user their display names.
    func testStoredBesideThePanelRecords() throws {
        let panels = try XCTUnwrap(PanelStore.defaultURL)
        let settings = try XCTUnwrap(SettingsStore.defaultURL)

        XCTAssertEqual(
            settings.deletingLastPathComponent(), panels.deletingLastPathComponent())
        XCTAssertNotEqual(settings, panels)
    }
}

/// Applying settings has to reach the sessions that are already running, not
/// only the ones started afterwards.
@MainActor
final class SettingsApplicationTests: XCTestCase {

    private func makeManager() -> PanelManager {
        PanelManager(previewPanels: [], savedNetworkNames: [], usbSerialPorts: [])
    }

    /// Never started, so no socket is opened.
    private func makeSender() -> FrameSender {
        FrameSender(host: "127.0.0.1", port: 5568, spacingMicros: 200, adaptivePacing: true)
    }

    private func makeSession(name: String, sender: FrameSender, fps: Int) -> DeviceSession {
        DeviceSession(
            name: name, sender: sender, source: .auto(defaultDisplay: ""),
            picker: nil, fps: fps)
    }

    func testFrameRateReachesALiveSession() {
        let manager = makeManager()
        let session = makeSession(name: "a", sender: makeSender(), fps: 40)
        manager.register(session)

        manager.updateSettings(
            SenderSettings(fps: 24, spacingMicros: 200, adaptivePacing: true,
                           identifySeconds: 8))

        XCTAssertEqual(session.fps, 24)
        XCTAssertEqual(manager.settings.fps, 24)
    }

    func testFixedPacingReachesALiveSender() {
        let manager = makeManager()
        let sender = makeSender()
        manager.register(makeSession(name: "a", sender: sender, fps: 40))
        XCTAssertTrue(sender.adaptivePacing)

        manager.updateSettings(
            SenderSettings(fps: 40, spacingMicros: 600, adaptivePacing: false,
                           identifySeconds: 8))

        XCTAssertFalse(sender.adaptivePacing)
        XCTAssertEqual(sender.spacingMicros, 600)
    }

    /// With self-tuning on, an explicit pacing value would be overwritten by the
    /// next climb step, so it is deliberately not forced.
    func testAdaptivePacingLeavesTheSenderTuning() {
        let manager = makeManager()
        let sender = makeSender()
        manager.register(makeSession(name: "a", sender: sender, fps: 40))

        manager.updateSettings(
            SenderSettings(fps: 40, spacingMicros: 2_000, adaptivePacing: true,
                           identifySeconds: 8))

        XCTAssertTrue(sender.adaptivePacing)
        XCTAssertEqual(sender.spacingMicros, 200, "pacing was forced while tuning")
    }

    /// A session discovered after a settings change must not keep the old rate.
    func testRegisteringBringsASessionUpToDate() {
        let manager = makeManager()
        manager.updateSettings(
            SenderSettings(fps: 15, spacingMicros: 800, adaptivePacing: false,
                           identifySeconds: 8))

        let sender = makeSender()
        let session = makeSession(name: "late", sender: sender, fps: 40)
        manager.register(session)

        XCTAssertEqual(session.fps, 15)
        XCTAssertEqual(sender.spacingMicros, 800)
        XCTAssertFalse(sender.adaptivePacing)
    }

    func testOutOfRangeSettingsAreClampedBeforeBeingApplied() {
        let manager = makeManager()
        let session = makeSession(name: "a", sender: makeSender(), fps: 40)
        manager.register(session)

        manager.updateSettings(
            SenderSettings(fps: 5_000, spacingMicros: 1, adaptivePacing: false,
                           identifySeconds: 5_000))

        XCTAssertEqual(session.fps, SenderSettings.fpsRange.upperBound)
        XCTAssertEqual(
            manager.settings.identifySeconds, SenderSettings.identifyRange.upperBound)
    }

    /// Changing the frame rate has to restart capture, because ScreenCaptureKit
    /// only reads it when the stream starts.
    func testChangingFrameRateIsNoticedBySession() {
        let session = makeSession(name: "a", sender: makeSender(), fps: 40)

        session.setFPS(40)
        XCTAssertEqual(session.fps, 40)

        session.setFPS(24)
        XCTAssertEqual(session.fps, 24)
    }
}
