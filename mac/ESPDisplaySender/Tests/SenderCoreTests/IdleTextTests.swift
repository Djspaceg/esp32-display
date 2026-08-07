import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// A panel whose sender goes away used to show only its own name, address, and
/// signal strength, which tells the user nothing they wanted. It can now be
/// given lines to show instead. The panel has no clock and no network of its
/// own, so the text has to be pushed and stamped with its arrival.
final class IdleTextSanitizeTests: XCTestCase {

    func testPlainLinesPassThrough() {
        XCTAssertEqual(
            IdleText.sanitize("Studio\nback at 14:30"), ["Studio", "back at 14:30"])
    }

    func testEmptyInputYieldsNoLines() {
        XCTAssertEqual(IdleText.sanitize(""), [])
        XCTAssertEqual(IdleText.sanitize("\n\n\n"), [])
        XCTAssertEqual(IdleText.sanitize("   "), [])
    }

    /// On a four-line budget a blank line is a wasted one.
    func testBlankLinesAreDropped() {
        XCTAssertEqual(IdleText.sanitize("a\n\n\nb"), ["a", "b"])
    }

    func testSurroundingSpaceIsTrimmed() {
        XCTAssertEqual(IdleText.sanitize("  hello  "), ["hello"])
    }

    /// The panel's font is a 5x7 ASCII bitmap and the firmware refuses anything
    /// else, so unrepresentable characters are dropped before they are sent.
    func testNonASCIIIsDropped() {
        XCTAssertEqual(IdleText.sanitize("café"), ["caf"])
        XCTAssertEqual(IdleText.sanitize("显示器"), [])
        XCTAssertEqual(IdleText.sanitize("a\tb"), ["ab"])
        XCTAssertEqual(IdleText.sanitize("emoji 🎉 here"), ["emoji  here"])
    }

    func testExtraLinesAreDropped() {
        XCTAssertEqual(
            IdleText.sanitize("1\n2\n3\n4\n5\n6"), ["1", "2", "3", "4"])
        XCTAssertEqual(IdleText.sanitize("1\n2\n3\n4\n5\n6").count, IdleText.maxLines)
    }

    func testLongLinesAreTruncated() {
        let long = String(repeating: "x", count: 60)
        let sanitized = IdleText.sanitize(long)

        XCTAssertEqual(sanitized.count, 1)
        XCTAssertEqual(sanitized[0].utf8.count, IdleText.maxLineBytes)
    }

    /// Truncation happens before trimming, so a line of spaces past the limit
    /// cannot leave trailing blanks behind.
    func testTruncationDoesNotLeaveTrailingSpace() {
        let sanitized = IdleText.sanitize("word" + String(repeating: " ", count: 40) + "x")

        XCTAssertEqual(sanitized, ["word"])
    }

    func testCarriageReturnsSplitLines() {
        XCTAssertEqual(IdleText.sanitize("a\r\nb"), ["a", "b"])
    }
}

final class IdleTextPacketTests: XCTestCase {

    func testHeaderAndLines() throws {
        let packet = try XCTUnwrap(IdleText.packet(lines: ["Studio", "back at 14:30"]))

        XCTAssertEqual([UInt8](packet.prefix(8)), [
            0x45, 0x54, 0x58, 0x54,  // ETXT
            0x01,                    // version
            0x02,                    // line count
            0x00, 0x00,              // reserved
        ])
        XCTAssertEqual(packet.count, 8 + (1 + 6) + (1 + 13))
        XCTAssertEqual([UInt8](packet)[8], 6)
        XCTAssertEqual(String(decoding: [UInt8](packet)[9..<15], as: UTF8.self), "Studio")
    }

    /// Clearing is an empty push, not a separate packet type.
    func testEmptyPacketIsValid() throws {
        let packet = try XCTUnwrap(IdleText.packet(lines: []))

        XCTAssertEqual(packet.count, IdleText.headerBytes)
        XCTAssertEqual([UInt8](packet)[5], 0)
    }

    func testMaximumSizedPacket() throws {
        let line = String(repeating: "a", count: IdleText.maxLineBytes)
        let packet = try XCTUnwrap(
            IdleText.packet(lines: Array(repeating: line, count: IdleText.maxLines)))

        XCTAssertEqual(
            packet.count,
            IdleText.headerBytes + IdleText.maxLines * (1 + IdleText.maxLineBytes))
    }

    /// Refusing rather than truncating means a caller cannot send something the
    /// firmware will silently discard.
    func testTooManyLinesIsRefused() {
        XCTAssertNil(IdleText.packet(lines: ["1", "2", "3", "4", "5"]))
    }

    func testOverlongLineIsRefused() {
        let line = String(repeating: "a", count: IdleText.maxLineBytes + 1)

        XCTAssertNil(IdleText.packet(lines: [line]))
    }

    func testUnrenderableBytesAreRefused() {
        XCTAssertNil(IdleText.packet(lines: ["café"]))
        XCTAssertNil(IdleText.packet(lines: ["a\tb"]))
        XCTAssertNil(IdleText.packet(lines: ["\u{0}"]))
    }

    /// Anything sanitize produces must be encodable, or the two would disagree.
    func testSanitizedTextIsAlwaysEncodable() {
        let awkward = [
            "café ☕ time\nnext meeting 15:00\nline three\nline four\nline five",
            String(repeating: "x", count: 200),
            "显示器",
            "",
            "  \n  \n  ",
        ]

        for raw in awkward {
            let lines = IdleText.sanitize(raw)
            XCTAssertNotNil(
                IdleText.packet(lines: lines), "could not encode sanitized \(raw)")
        }
    }

    func testCapabilityBitMatchesTheFirmware() {
        XCTAssertEqual(DeviceProtocol.Capabilities.idleText.rawValue, 0x100)
    }
}

/// The manager stores the text as typed and only sanitizes on the way out, so
/// the text field round-trips what the user wrote.
@MainActor
final class IdleTextManagerTests: XCTestCase {

    private func makeManager(capabilities: DeviceProtocol.Capabilities) -> PanelManager {
        let panel = PanelSnapshot(
            serviceName: "studio-display",
            displayName: "studio-display",
            lastSeen: Date(),
            lastHeartbeatAt: Date(),
            controlProtocolVersion: Int(DeviceProtocol.controlProtocolVersion),
            capabilitiesRaw: capabilities.rawValue)
        return PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])
    }

    func testTextIsStoredAsTyped() {
        let manager = makeManager(capabilities: .idleText)

        manager.setIdleText("café ☕\nsecond line", for: "studio-display")

        XCTAssertEqual(manager.panels.first?.idleText, "café ☕\nsecond line")
    }

    /// The preview is what the panel will really show, so the user can see what
    /// was dropped instead of guessing.
    func testPreviewShowsWhatThePanelWillRender() {
        let manager = makeManager(capabilities: .idleText)

        manager.setIdleText("café ☕\n\nsecond line", for: "studio-display")

        XCTAssertEqual(
            manager.screensaverPreview(for: "studio-display").lines,
            ["caf", "second line"])
    }

    func testPreviewIsEmptyWithoutText() {
        let manager = makeManager(capabilities: .idleText)

        XCTAssertEqual(manager.screensaverPreview(for: "studio-display").lines, [])
    }

    func testUnknownPanelIsIgnored() {
        let manager = makeManager(capabilities: .idleText)

        manager.setIdleText("hello", for: "ghost")

        XCTAssertEqual(manager.panels.count, 1)
        XCTAssertEqual(manager.panels.first?.idleText, "")
        XCTAssertEqual(manager.screensaverPreview(for: "ghost").lines, [])
    }

    /// Storing it for firmware that cannot show it is still worth doing: the
    /// text survives a reflash that adds the capability.
    func testTextIsStoredEvenWithoutTheCapability() {
        let manager = makeManager(capabilities: [])

        manager.setIdleText("hello", for: "studio-display")

        XCTAssertEqual(manager.panels.first?.idleText, "hello")
    }
}

/// The text has to survive a restart, which is the point of storing it.
final class IdleTextPersistenceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IdleTextTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func reloaded(_ text: String) throws -> String {
        var snapshot = PanelSnapshot(
            serviceName: "studio-display", displayName: "studio-display")
        snapshot.idleText = text
        let url = directory.appendingPathComponent("panels.json")
        try PanelStore.save([PersistedPanel(snapshot: snapshot)], to: url)

        let loaded = PanelStore.load(from: url)
        XCTAssertNil(loaded.failure)
        return try XCTUnwrap(loaded.records.first).snapshot.idleText
    }

    func testTextSurvivesARestart() throws {
        XCTAssertEqual(try reloaded("Studio\nback at 14:30"), "Studio\nback at 14:30")
    }

    /// Stored as typed, including characters the panel cannot render, so the
    /// field still shows what the user wrote after a restart.
    func testUnrenderableCharactersSurviveInTheRecord() throws {
        XCTAssertEqual(try reloaded("café ☕"), "café ☕")
    }

    /// No text is the default, so it should not add noise to the file.
    func testEmptyTextIsNotWritten() throws {
        var snapshot = PanelSnapshot(
            serviceName: "studio-display", displayName: "studio-display")
        snapshot.idleText = ""
        let url = directory.appendingPathComponent("panels.json")
        try PanelStore.save([PersistedPanel(snapshot: snapshot)], to: url)

        let json = try XCTUnwrap(String(data: try Data(contentsOf: url), encoding: .utf8))
        XCTAssertFalse(json.contains("\"idleText\""))
    }

    func testRecordWithoutTheFieldLoadsEmpty() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("panels.json")
        try Data(#"[{"serviceName":"a","displayName":"a"}]"#.utf8).write(to: url)

        let loaded = PanelStore.load(from: url)

        XCTAssertNil(loaded.failure)
        XCTAssertEqual(try XCTUnwrap(loaded.records.first).snapshot.idleText, "")
    }
}
