import Foundation
import XCTest
@testable import SenderProtocol

final class FirmwareReleaseCatalogTests: XCTestCase {
    func testSchemaThreeReadsShippingRevisionsAndPinsLatestAliases() throws {
        let catalog = try FirmwareReleaseCatalog.read(
            Self.catalogData(
                schema: 3,
                revisionVersions: ["1.5.0", "1.4.2"]))
        let entry = try XCTUnwrap(catalog.families["s3"])
        XCTAssertEqual(entry.revisions.map(\.version), ["1.5.0", "1.4.2"])
        XCTAssertTrue(entry.revisions.allSatisfy { $0.build == nil })
        XCTAssertEqual(entry.revisions.first?.artifact, entry.artifact)
        XCTAssertEqual(entry.revisions.first?.sha256, entry.sha256)
        XCTAssertEqual(entry.revisions.first?.byteCount, entry.byteCount)
        XCTAssertEqual(entry.revisions.first?.version, entry.latestVersion)
        XCTAssertEqual(entry.revisions.first?.build, entry.latestBuild)
    }

    func testSchemaThreeRejectsMissingRevisionsAndNonDescendingVersions() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Self.catalogData(
                    schema: 3,
                    revisionVersions: ["1.5.0", "1.4.2"])
            ) as? [String: Any])
        var families = object["families"] as! [String: Any]
        var c6 = families["c6"] as! [String: Any]
        c6.removeValue(forKey: "revisions")
        families["c6"] = c6
        object["families"] = families
        XCTAssertThrowsError(try FirmwareReleaseCatalog.read(
            JSONSerialization.data(withJSONObject: object)))

        object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Self.catalogData(
                    schema: 3,
                    revisionVersions: ["1.4.2", "1.5.0"])
            ) as? [String: Any])
        XCTAssertThrowsError(try FirmwareReleaseCatalog.read(
            JSONSerialization.data(withJSONObject: object))) {
            XCTAssertEqual(
                $0 as? FirmwareReleaseCatalogError,
                .invalidRevisions("c3"))
        }

        object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Self.catalogData(
                    schema: 3,
                    revisionVersions: ["1.5.0", "1.4.2"])
            ) as? [String: Any])
        families = object["families"] as! [String: Any]
        c6 = families["c6"] as! [String: Any]
        var revisions = c6["revisions"] as! [[String: Any]]
        revisions[0]["build"] = 192
        c6["revisions"] = revisions
        families["c6"] = c6
        object["families"] = families
        XCTAssertThrowsError(try FirmwareReleaseCatalog.read(
            JSONSerialization.data(withJSONObject: object))) {
            XCTAssertEqual(
                $0 as? FirmwareReleaseCatalogError,
                .invalidKeys("c6.revisions[0]"))
        }
    }

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

    func testReadsExactlyFourFamiliesAndSelectsWithIndependentEvidence() throws {
        let catalog = try FirmwareReleaseCatalog.read(Self.catalogData())
        XCTAssertEqual(Set(catalog.families.keys), ["c3", "c6", "s3", "p4"])
        let c3 = try catalog.entry(for: .init(
            family: "c3", chip: "esp32c3", profile: "gc9a01a-240",
            partition: "c3-4m-ota"))
        XCTAssertEqual(c3.family, "c3")
        XCTAssertEqual(c3.profiles, ["gc9a01a-240"])
        let s3 = try catalog.entry(for: .init(
            family: "s3", chip: "esp32s3", profile: "co5300",
            partition: "universal-8m-doom-ota"))
        XCTAssertEqual(s3.family, "s3")
        XCTAssertEqual(s3.profiles, ["gc9107", "st7789-130", "st7789-154", "st7789-190", "co5300", "st77916", "gc9a01-knob-128"])
    }

    func testSelectionFailsClosedForMissingOrContradictoryEvidence() throws {
        let catalog = try FirmwareReleaseCatalog.read(Self.catalogData())
        XCTAssertThrowsError(try catalog.entry(for: .init(
            family: "s3", chip: "esp32s3", profile: nil,
            partition: "universal-8m-doom-ota"))) {
            XCTAssertEqual($0 as? FirmwareReleaseCatalogError, .identityIncomplete)
        }
        XCTAssertThrowsError(try catalog.entry(for: .init(
            family: "s3", chip: "esp32p4", profile: "co5300",
            partition: "universal-8m-doom-ota"))) {
            XCTAssertEqual(
                $0 as? FirmwareReleaseCatalogError,
                .chipMismatch(expected: "esp32s3", found: "esp32p4"))
        }
        XCTAssertThrowsError(try catalog.entry(for: .init(
            family: "s3", chip: "esp32s3", profile: "st7703-4b",
            partition: "universal-8m-doom-ota")))
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
        schema: Int = 1, latestBuild: UInt32? = nil,
        revisionVersions: [String]? = nil
    ) throws -> Data {
        let profiles: [String: [String]] = [
            "c3": ["gc9a01a-240"],
            "c6": ["st7789", "jd9853"],
            "s3": ["gc9107", "st7789-130", "st7789-154", "st7789-190", "co5300", "st77916", "gc9a01-knob-128"],
            "p4": ["st7703-4b"],
        ]
        let chips = [
            "c3": "esp32c3", "c6": "esp32c6",
            "s3": "esp32s3", "p4": "esp32p4",
        ]
        let partitions = [
            "c3": "c3-4m-ota", "c6": "default-8m",
            "s3": "universal-8m-doom-ota", "p4": "p4-32m-ota",
        ]
        let flashes: [String: [Int]] = [
            "c3": [4 * 1024 * 1024],
            "c6": [8 * 1024 * 1024],
            "s3": [8 * 1024 * 1024, 16 * 1024 * 1024, 32 * 1024 * 1024],
            "p4": [32 * 1024 * 1024],
        ]
        var families = [String: Any]()
        for family in ["c3", "c6", "s3", "p4"] {
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
            if schema == 2, let latestBuild {
                entry["latest_build"] = latestBuild
            }
            if let revisionVersions {
                entry["revisions"] = revisionVersions.map { version in
                    [
                        "version": version,
                        "artifact": "\(family)/espdisp-\(family)-\(version).espdispfw",
                        "sha256": String(repeating: "a", count: 64),
                        "bytes": 123,
                    ] as [String: Any]
                }
            }
            families[family] = entry
        }
        return try JSONSerialization.data(withJSONObject: [
            "schema": schema,
            "generated_at": "2026-01-02T03:04:05Z",
            "families": families,
        ])
    }
}
