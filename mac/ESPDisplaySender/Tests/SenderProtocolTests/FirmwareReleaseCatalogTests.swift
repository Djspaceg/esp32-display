import Foundation
import XCTest
@testable import SenderProtocol

final class FirmwareReleaseCatalogTests: XCTestCase {
    func testSchemaTwoReadsLatestBuild() throws {
        let catalog = try FirmwareReleaseCatalog.read(
            Self.catalogData(schema: 2, latestBuild: 192))
        XCTAssertEqual(try XCTUnwrap(catalog.families["c6"]).latestBuild, 192)
    }

    func testSchemaOneReadsLatestBuildAsUnknown() throws {
        let catalog = try FirmwareReleaseCatalog.read(Self.catalogData())
        XCTAssertNil(try XCTUnwrap(catalog.families["c6"]).latestBuild)
    }

    func testSchemaTwoAcceptsBranchSuffixAndRejectsInvalidBuilds() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Self.catalogData(schema: 2, latestBuild: 192)
            ) as? [String: Any])
        var families = object["families"] as! [String: Any]
        var c6 = families["c6"] as! [String: Any]
        c6["artifact"] = "c6/espdisp-c6-1.5.0+192.g346728d.espdispfw"
        families["c6"] = c6
        object["families"] = families
        XCTAssertNoThrow(try FirmwareReleaseCatalog.read(
            JSONSerialization.data(withJSONObject: object)))

        for invalid: Any in [0, -1, 4_294_967_296, true, 192.5] {
            c6["latest_build"] = invalid
            families["c6"] = c6
            object["families"] = families
            XCTAssertThrowsError(try FirmwareReleaseCatalog.read(
                JSONSerialization.data(withJSONObject: object)), "\(invalid)")
        }
    }

    func testReadsExactlyThreeFamiliesAndSelectsWithIndependentEvidence() throws {
        let catalog = try FirmwareReleaseCatalog.read(Self.catalogData())
        XCTAssertEqual(Set(catalog.families.keys), ["c6", "s3", "p4"])
        let s3 = try catalog.entry(for: .init(
            family: "s3", chip: "esp32s3", profile: "co5300",
            partition: "universal-8m-ota"))
        XCTAssertEqual(s3.family, "s3")
        XCTAssertEqual(s3.profiles, ["gc9107", "st7789-130", "st7789-154", "co5300", "st77916"])
    }

    func testSelectionFailsClosedForMissingOrContradictoryEvidence() throws {
        let catalog = try FirmwareReleaseCatalog.read(Self.catalogData())
        XCTAssertThrowsError(try catalog.entry(for: .init(
            family: "s3", chip: "esp32s3", profile: nil,
            partition: "universal-8m-ota"))) {
            XCTAssertEqual($0 as? FirmwareReleaseCatalogError, .identityIncomplete)
        }
        XCTAssertThrowsError(try catalog.entry(for: .init(
            family: "s3", chip: "esp32p4", profile: "co5300",
            partition: "universal-8m-ota"))) {
            XCTAssertEqual(
                $0 as? FirmwareReleaseCatalogError,
                .chipMismatch(expected: "esp32s3", found: "esp32p4"))
        }
        XCTAssertThrowsError(try catalog.entry(for: .init(
            family: "s3", chip: "esp32s3", profile: "st7703-4b",
            partition: "universal-8m-ota")))
        XCTAssertThrowsError(try catalog.entry(for: .init(
            family: "s3", chip: "esp32s3", profile: "co5300",
            partition: "p4-32m-ota")))
    }

    func testDuplicateSemanticMemberNamesAreRejected() {
        let raw = Data(#"{"schema":1,"schema":1,"generated_at":"x","families":{}}"#.utf8)
        XCTAssertThrowsError(try FirmwareReleaseCatalog.read(raw)) {
            XCTAssertEqual(
                $0 as? FirmwareReleaseCatalogError,
                .duplicateKey("schema"))
        }
    }

    func testNonCanonicalAndTraversalPathsAreRejected() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Self.catalogData()) as? [String: Any])
        var families = object["families"] as! [String: Any]
        var s3 = families["s3"] as! [String: Any]
        s3["artifact"] = "../espdisp-s3-1.5.0.espdispfw"
        families["s3"] = s3
        object["families"] = families
        XCTAssertThrowsError(try FirmwareReleaseCatalog.read(
            JSONSerialization.data(withJSONObject: object))) {
            XCTAssertEqual(
                $0 as? FirmwareReleaseCatalogError,
                .invalidArtifact("s3"))
        }
    }

    private static func catalogData(
        schema: Int = 1, latestBuild: UInt32? = nil
    ) throws -> Data {
        let profiles: [String: [String]] = [
            "c6": ["st7789", "jd9853"],
            "s3": ["gc9107", "st7789-130", "st7789-154", "co5300", "st77916"],
            "p4": ["st7703-4b"],
        ]
        let chips = ["c6": "esp32c6", "s3": "esp32s3", "p4": "esp32p4"]
        let partitions = [
            "c6": "default-8m", "s3": "universal-8m-ota", "p4": "p4-32m-ota",
        ]
        let flashes: [String: [Int]] = [
            "c6": [8 * 1024 * 1024],
            "s3": [8 * 1024 * 1024, 16 * 1024 * 1024, 32 * 1024 * 1024],
            "p4": [32 * 1024 * 1024],
        ]
        var families = [String: Any]()
        for family in ["c6", "s3", "p4"] {
            let profileList = profiles[family]!
            var hardware = [String: [String]]()
            for profile in profileList { hardware[profile] = ["Fixture \(profile)"] }
            var entry: [String: Any] = [
                "latest_version": "1.5.0",
                "artifact": "\(family)/espdisp-\(family)-1.5.0"
                    + (latestBuild.map { "+\($0)" } ?? "") + ".espdispfw",
                "sha256": String(repeating: "a", count: 64),
                "bytes": 123,
                "chip": chips[family]!,
                "profiles": profileList,
                "hardware": hardware,
                "compatibility": [
                    "flash_bytes": flashes[family]!,
                    "partition_scheme": partitions[family]!,
                    "bootloader_address": family == "p4" ? 0x2000 : 0,
                    "partitions_address": 0x8000,
                    "boot_app0_address": 0xE000,
                    "app_address": 0x10000,
                    "identity_required": ["family", "chip", "profile", "partition"],
                ],
            ]
            if let latestBuild { entry["latest_build"] = latestBuild }
            families[family] = entry
        }
        return try JSONSerialization.data(withJSONObject: [
            "schema": schema,
            "generated_at": "2026-01-02T03:04:05Z",
            "families": families,
        ])
    }
}
