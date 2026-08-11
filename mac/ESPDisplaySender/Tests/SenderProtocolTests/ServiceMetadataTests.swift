import XCTest

@testable import SenderProtocol

/// The mDNS TXT records, parsed.
///
/// Every value here is written the way the firmware writes it, taken from
/// `addMdnsService` in firmware/display_stream/display_stream.ino rather than
/// from `ServiceMetadata` itself: `caps` through `%08lx`, `res` through `%ux%u`,
/// `proto` through `%u`, `chip` from `CONFIG_IDF_TARGET`. A test that took its
/// literals from the parser would agree with itself.
final class ServiceMetadataTests: XCTestCase {

    /// What a 172x320 C6 panel running today's firmware advertises.
    private let c6Records = [
        "name": "espdisplay-9050",
        "res": "172x320",
        "fw": "1.2.0",
        "proto": "2",
        // BASE_CAPABILITIES (brightness, brightnessLevel, flip, identify,
        // restart, sleepSync, telemetry, idleText) plus touch, touchLongPress
        // and ota, which is what a C6 Touch board with OTA listening adds up to:
        // bits 0 to 10, and not bit 11, because no C6 board carries a PMU.
        "caps": "000007ff",
        "chip": "esp32c6",
    ]

    func testReadsEveryRecordARealPanelSends() throws {
        let metadata = ServiceMetadata(txtRecords: c6Records)
        XCTAssertEqual(metadata.name, "espdisplay-9050")
        XCTAssertEqual(metadata.geometry, PanelGeometry(width: 172, height: 320))
        XCTAssertEqual(metadata.geometry, .panel172x320, "the same panel by either name")
        XCTAssertEqual(metadata.firmwareVersion, "1.2.0")
        XCTAssertEqual(metadata.chip, "esp32c6")
        XCTAssertEqual(metadata.frameProtocolVersion, 2)
        XCTAssertEqual(
            metadata.frameProtocolVersion, Int(DeviceProtocol.frameProtocolVersion),
            "the app and the firmware agree on which generation this is")
        XCTAssertTrue(metadata.namesAChip)

        // The bits have to mean the same thing here as they do in EINF, which is
        // the whole reason `caps` is worth parsing before a session exists.
        let capabilities = try XCTUnwrap(metadata.capabilities)
        XCTAssertEqual(capabilities.rawValue, 0x7FF)
        XCTAssertTrue(capabilities.contains(.ota))
        XCTAssertTrue(capabilities.contains(.brightness))
        XCTAssertTrue(capabilities.contains(.brightnessLevel))
        XCTAssertTrue(capabilities.contains(.idleText))
        XCTAssertTrue(capabilities.contains(.touch))
        XCTAssertTrue(capabilities.contains(.touchLongPress))
        XCTAssertFalse(capabilities.contains(.battery), "no PMU on a C6 board")
    }

    func testReadsA466SquarePanel() {
        // The whole reason `res` is parsed: this panel exists, and before this
        // the app streamed it as though it were 172x320.
        let metadata = ServiceMetadata(txtRecords: [
            "name": "espdisplay-amoled", "res": "466x466", "fw": "1.2.0",
            "proto": "2", "caps": "00000fff", "chip": "esp32s3",
        ])
        XCTAssertEqual(metadata.geometry, PanelGeometry(width: 466, height: 466))
        XCTAssertEqual(metadata.chip, "esp32s3")
        XCTAssertEqual(metadata.capabilities?.contains(.battery), true)
    }

    func testAPanelThatSaysNothingYieldsNothing() {
        // Not an error and not a partial answer: a panel running firmware older
        // than any of these records must behave exactly as it did before they
        // existed.
        let metadata = ServiceMetadata(txtRecords: [:])
        XCTAssertEqual(metadata, .empty)
        XCTAssertNil(metadata.name)
        XCTAssertNil(metadata.geometry)
        XCTAssertNil(metadata.firmwareVersion)
        XCTAssertNil(metadata.chip)
        XCTAssertNil(metadata.capabilities)
        XCTAssertNil(metadata.frameProtocolVersion)
        XCTAssertFalse(metadata.namesAChip)
    }

    func testEachFieldIsIndependent() {
        // One unreadable record must not take its neighbours with it. Checked by
        // corrupting exactly one key at a time and requiring every other field
        // to survive - a parser that gave up on the first failure would pass a
        // test that only corrupted one key.
        for key in c6Records.keys {
            var records = c6Records
            records[key] = "!!! not a valid value !!!"
            let metadata = ServiceMetadata(txtRecords: records)
            let survivors: [Bool] = [
                key == "name" ? true : metadata.name == "espdisplay-9050",
                key == "res" ? metadata.geometry == nil : metadata.geometry == .panel172x320,
                key == "fw" ? true : metadata.firmwareVersion == "1.2.0",
                key == "chip" ? true : metadata.chip == "esp32c6",
                key == "caps" ? metadata.capabilities == nil
                    : metadata.capabilities?.rawValue == 0x7FF,
                key == "proto" ? metadata.frameProtocolVersion == nil
                    : metadata.frameProtocolVersion == 2,
            ]
            XCTAssertFalse(survivors.contains(false), "corrupting \(key) broke another field")
        }
        // name, fw and chip are free-form strings, so the "invalid" value above
        // is a legitimate value for them. Spelled out so the loop's exceptions
        // are not mistaken for gaps.
        XCTAssertEqual(
            ServiceMetadata(txtRecords: ["fw": "!!! not a valid value !!!"]).firmwareVersion,
            "!!! not a valid value !!!",
            "the version is not validated here - EINF is the authority")
    }

    func testAnEmptyValueIsTheSameAsNoKey() {
        // ESPmDNS can carry a key with no value, and NWTXTRecord reports that as
        // an empty string. An empty name is not a name.
        let metadata = ServiceMetadata(txtRecords: [
            "name": "", "res": "", "fw": "", "proto": "", "caps": "", "chip": "",
        ])
        XCTAssertEqual(metadata, .empty)
    }

    // MARK: - res

    func testRefusesResolutionsThatAreNotTwoNumbers() {
        let bad = [
            "466",        // one number
            "466x",       // missing the second
            "x466",       // missing the first
            "466x466x2",  // three
            "466 x 466",  // spaces, which %ux%u never writes
            "466X466",    // capital X, likewise
            "466*466",
            "0x1d0",      // a hex-looking value, which would parse as 0 and 464
            "-172x320",   // a sign
            "+172x320",
            "172.0x320",
            "",
            "x",
        ]
        for value in bad {
            XCTAssertNil(
                ServiceMetadata.parseResolution(value), "res=\(value) must not be believed")
        }
        XCTAssertNil(ServiceMetadata.parseResolution(nil))
    }

    func testRefusesResolutionsThisProtocolCannotStream() {
        // A parsed geometry drives band arithmetic and frame allocation on every
        // frame, so an implausible one has to be refused at the edge rather than
        // propagated. `PanelGeometry.isStreamable` documents where each bound
        // comes from.
        XCTAssertNil(ServiceMetadata.parseResolution("0x0"), "divides by zero downstream")
        XCTAssertNil(ServiceMetadata.parseResolution("0x320"))
        XCTAssertNil(ServiceMetadata.parseResolution("172x0"))
        XCTAssertNil(ServiceMetadata.parseResolution("60000x60000"), "a 7GB frame")
        XCTAssertNil(ServiceMetadata.parseResolution("800x480"), "a row wider than a packet")
        XCTAssertNil(ServiceMetadata.parseResolution("697x697"), "more bands than 512")

        // And the sizes that must keep working, including one from the
        // firmware's own roadmap comment.
        XCTAssertEqual(
            ServiceMetadata.parseResolution("172x320"), PanelGeometry(width: 172, height: 320))
        XCTAssertEqual(
            ServiceMetadata.parseResolution("466x466"), PanelGeometry(width: 466, height: 466))
        XCTAssertEqual(
            ServiceMetadata.parseResolution("480x480"), PanelGeometry(width: 480, height: 480))
    }

    // MARK: - caps and proto

    func testParsesCapabilitiesAsHex() {
        XCTAssertEqual(ServiceMetadata.parseCapabilities("00000e3f")?.rawValue, 0xE3F)
        XCTAssertEqual(ServiceMetadata.parseCapabilities("e3f")?.rawValue, 0xE3F,
                       "shorter than %08lx writes, but unambiguous")
        XCTAssertEqual(ServiceMetadata.parseCapabilities("00000E3F")?.rawValue, 0xE3F,
                       "uppercase is not what the firmware writes, but it is one number")
        XCTAssertEqual(ServiceMetadata.parseCapabilities("00000000")?.rawValue, 0)
        XCTAssertEqual(ServiceMetadata.parseCapabilities("ffffffff")?.rawValue, 0xFFFF_FFFF)
        // Nine digits is a value Capabilities cannot hold, and would be refused
        // by UInt32 alone.
        XCTAssertNil(ServiceMetadata.parseCapabilities("100000000"))
        // This is the case the width limit itself decides: a wide field carrying
        // a small value parses perfectly, and taking it would mean disagreeing
        // with the producer about how wide `caps` is.
        XCTAssertNil(
            ServiceMetadata.parseCapabilities("000000000e3f"), "twelve digits is not %08lx")
        XCTAssertNil(ServiceMetadata.parseCapabilities("0000083g"), "g is not hex")
        XCTAssertNil(ServiceMetadata.parseCapabilities("0x00083f"), "nor is a 0x prefix")
        // A sign, which UInt32(_:radix:) accepts on its own: "+e3f" parses to
        // 0xE3F without the digit check in front of it.
        XCTAssertNil(ServiceMetadata.parseCapabilities("+e3f"))
        XCTAssertNil(ServiceMetadata.parseCapabilities("-1"))
        XCTAssertNil(ServiceMetadata.parseCapabilities(""))
        XCTAssertNil(ServiceMetadata.parseCapabilities(nil))
    }

    func testParsesProtoAsAnUnsignedDecimal() {
        XCTAssertEqual(ServiceMetadata.parseUnsignedDecimal("2"), 2)
        XCTAssertEqual(ServiceMetadata.parseUnsignedDecimal("02"), 2)
        XCTAssertEqual(ServiceMetadata.parseUnsignedDecimal("0"), 0)
        XCTAssertEqual(ServiceMetadata.parseUnsignedDecimal("255"), 255)
        // %u writes none of these, and Int(_:) alone would accept some of them.
        XCTAssertNil(ServiceMetadata.parseUnsignedDecimal("-1"))
        XCTAssertNil(ServiceMetadata.parseUnsignedDecimal("+1"))
        XCTAssertNil(ServiceMetadata.parseUnsignedDecimal(" 1"))
        XCTAssertNil(ServiceMetadata.parseUnsignedDecimal("1 "))
        XCTAssertNil(ServiceMetadata.parseUnsignedDecimal("1.0"))
        XCTAssertNil(ServiceMetadata.parseUnsignedDecimal("2a"))
        XCTAssertNil(ServiceMetadata.parseUnsignedDecimal("١"), "not an ASCII digit")
        XCTAssertNil(ServiceMetadata.parseUnsignedDecimal(""))
        XCTAssertNil(
            ServiceMetadata.parseUnsignedDecimal("99999999999999999999"), "overflows Int")
    }

    // MARK: - chip

    func testTellsAnUnknownChipApartFromNoChip() {
        // Both mean "could not tell", and they are kept apart anyway: nil is a
        // panel whose firmware predates the record, "unknown" is a panel whose
        // firmware has the record and could not fill it in. Only one of those is
        // a reason to suggest reflashing over USB.
        XCTAssertNil(ServiceMetadata(txtRecords: ["res": "172x320"]).chip)
        let unknown = ServiceMetadata(txtRecords: ["chip": "unknown"])
        XCTAssertEqual(unknown.chip, "unknown")
        XCTAssertFalse(unknown.namesAChip)
        XCTAssertEqual(ServiceMetadata.unknownChip, "unknown",
                       "chipidentity::TOKEN_UNKNOWN, spelled out by hand")

        // A chip this build has never heard of is still a named chip: it is not
        // this parser's business to hold the list of chips that exist, and a
        // bundle either has an image for the token or it does not.
        let future = ServiceMetadata(txtRecords: ["chip": "esp32p4"])
        XCTAssertEqual(future.chip, "esp32p4")
        XCTAssertTrue(future.namesAChip)
    }

    // MARK: - keys

    func testKeysAreReadWithoutRegardToCase() {
        // RFC 6763 6.4: a TXT key is compared case-insensitively. The firmware
        // writes them lowercase, so this only matters for a record that reached
        // us through something that rewrote it.
        let metadata = ServiceMetadata(txtRecords: [
            "NAME": "panel", "Res": "466x466", "FW": "1.2.0", "CHIP": "esp32s3",
        ])
        XCTAssertEqual(metadata.name, "panel")
        XCTAssertEqual(metadata.geometry, PanelGeometry(width: 466, height: 466))
        XCTAssertEqual(metadata.firmwareVersion, "1.2.0")
        XCTAssertEqual(metadata.chip, "esp32s3")
    }

    func testTwoKeysDifferingOnlyInCaseAreDropped() {
        // `[String: String]` has no defined iteration order, so choosing one
        // would choose differently on different runs. There is no reading of an
        // ambiguous record better than not having it.
        let folded = ServiceMetadata.caseFolded(["chip": "esp32c6", "CHIP": "esp32s3"])
        XCTAssertNil(folded["chip"])
        let metadata = ServiceMetadata(txtRecords: ["chip": "esp32c6", "CHIP": "esp32s3"])
        XCTAssertNil(metadata.chip)
        // Only the ambiguous key is dropped; the rest of the record survives.
        let mixed = ServiceMetadata(
            txtRecords: ["chip": "esp32c6", "CHIP": "esp32s3", "res": "172x320"])
        XCTAssertNil(mixed.chip)
        XCTAssertEqual(mixed.geometry, .panel172x320)
    }

    func testUnknownKeysAreIgnored() {
        // A future firmware adding a record must not disturb this app.
        var records = c6Records
        records["hostname"] = "espdisplay-9050.local"
        records["batt"] = "88"
        let metadata = ServiceMetadata(txtRecords: records)
        XCTAssertEqual(metadata, ServiceMetadata(txtRecords: c6Records))
    }
}
