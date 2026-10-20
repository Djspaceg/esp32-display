import XCTest

@testable import SenderProtocol

final class FirmwareSourceIdentityTests: XCTestCase {
    private let commit = "0123456789abcdef0123456789abcdef01234567"

    func testParsesWhatTheBoardReports() {
        XCTAssertEqual(
            FirmwareSourceIdentity(reported: commit),
            FirmwareSourceIdentity(commit: commit, dirty: false))
        XCTAssertEqual(
            FirmwareSourceIdentity(reported: commit + "-dirty")?.dirty, true)
        XCTAssertEqual(
            FirmwareSourceIdentity(reported: commit.uppercased())?.commit, commit)
    }

    func testAnythingButACommitIsNoBuild() {
        for bad in [nil, "", "unknown", "0123abc", commit + "x", commit + "-clean",
                    "-dirty", String(commit.dropLast()) + "g"] {
            XCTAssertNil(FirmwareSourceIdentity(reported: bad), String(describing: bad))
        }
    }

    func testSummaryIsTwelveDigits() {
        let clean = FirmwareSourceIdentity(commit: commit, dirty: false)!
        XCTAssertEqual(clean.summary, "0123456789ab")
        let dirty = FirmwareSourceIdentity(commit: commit, dirty: true)!
        XCTAssertEqual(dirty.summary, "0123456789ab with uncommitted changes")
    }

    func testTheShippedBundlesNameTheirBuild() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("firmware-releases")
        // S3 rolled forward past 1.5.0 when the XIAO joined its family.
        for (family, version) in [("c3", "1.5.0"), ("c6", "1.5.0"), ("s3", "2.0.0"),
                                  ("p4", "1.5.0")] {
            let bundle = try FirmwareBundle.read(Data(contentsOf: root
                .appendingPathComponent("\(family)/espdisp-\(family)-\(version).espdispfw")))
            let built = try XCTUnwrap(FirmwareSourceIdentity(bundle: bundle), family)
            XCTAssertFalse(built.dirty, family)
            XCTAssertTrue(built.isExactly(bundle), family)
            // A dirty tree at the same commit proves nothing about the bytes.
            XCTAssertFalse(
                FirmwareSourceIdentity(commit: built.commit, dirty: true)!
                    .isExactly(bundle), family)
            XCTAssertFalse(
                FirmwareSourceIdentity(commit: commit, dirty: false)!
                    .isExactly(bundle), family)
        }
    }

    func testMDNSSourceRecord() {
        let metadata = ServiceMetadata(txtRecords: ["fw": "1.5.0", "src": commit])
        XCTAssertEqual(metadata.firmwareSource?.commit, commit)
        XCTAssertNil(ServiceMetadata(txtRecords: ["fw": "1.5.0"]).firmwareSource)
        XCTAssertNil(
            ServiceMetadata(txtRecords: ["fw": "1.5.0", "src": "unknown"]).firmwareSource)
    }

    func testEsptoolProgressBarIsDropped() {
        XCTAssertEqual(
            EsptoolOutput.withoutProgressBar(
                "Writing at 0x001280ef [========================>   ] 83.3% 737280/885283 bytes..."),
            "Writing at 0x001280ef 83.3% 737280/885283 bytes...")
        XCTAssertEqual(
            EsptoolOutput.withoutProgressBar(
                "Writing at 0x00000000 [                              ]   0.0% 0/13062 bytes..."),
            "Writing at 0x00000000 0.0% 0/13062 bytes...",
            "an empty bar at 0% is a bar too")
        XCTAssertEqual(
            EsptoolOutput.withoutProgressBar("Writing at 0x00010000... (12 %)"),
            "Writing at 0x00010000... (12 %)")
        XCTAssertEqual(
            EsptoolOutput.withoutProgressBar("Chip type: ESP32-S3 (QFN56) [rev v0.2]"),
            "Chip type: ESP32-S3 (QFN56) [rev v0.2]")
    }

    func testTranscriptKeepsTheNumbersWithoutTheBar() {
        var transcript = UsbFlashTranscript()
        transcript.append(
            .esptool,
            "Writing at 0x0001a000 [==>                 ]  12.3% 98304/800000 bytes...",
            at: 1)
        XCTAssertEqual(
            transcript.entries.last?.text,
            "Writing at 0x0001a000 12.3% 98304/800000 bytes...")
        var tracker = EsptoolFlashTracker(parts: [.init(role: "app", address: 0x10000, size: 800000)])
        guard case .writing(let part)? = tracker.consume(transcript.entries[0].text)
        else { return XCTFail("the stripped line still reads as a write") }
        XCTAssertEqual(part.percent, 12)
    }
}
