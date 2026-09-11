import XCTest

@testable import SenderProtocol

final class GeneratedReleaseCrossReadTests: XCTestCase {
    func testShippingCatalogCrossReadsWithPerRevisionValidation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = root.appendingPathComponent("firmware-releases/manifest.json")
        let catalog = try FirmwareReleaseCatalog.read(contentsOf: catalogURL)
        for family in ["c6", "s3", "p4"] {
            let entry = try XCTUnwrap(catalog.families[family])
            XCTAssertFalse(entry.revisions.isEmpty)
            XCTAssertNil(entry.latestBuild)
            for revision in entry.revisions {
                let data = try Data(contentsOf: root.appendingPathComponent(
                    "firmware-releases/\(revision.artifact)"))
                let bundle = try FirmwareBundle.read(data)
                XCTAssertEqual(bundle.targets, [family])
                XCTAssertEqual(bundle.firmwareVersion, revision.version)
                XCTAssertNil(bundle.firmwareBuild)
                XCTAssertFalse(revision.artifact.contains("+"))
                XCTAssertEqual(bundle.releaseNotes?.count, 10)
                if family == "c6" {
                    XCTAssertNoThrow(try catalog.bundle(
                        for: revision, in: entry, data: data))
                } else {
                    XCTAssertThrowsError(try catalog.bundle(
                        for: revision, in: entry, data: data)) {
                            XCTAssertEqual(
                                $0 as? FirmwareReleaseCatalogError,
                                .revisionMissingPayload(
                                    family: family, role: "doom_wad"))
                        }
                }
            }
        }
    }
}
