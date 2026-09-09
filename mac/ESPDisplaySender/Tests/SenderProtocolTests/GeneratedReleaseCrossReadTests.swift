import XCTest

@testable import SenderProtocol

final class GeneratedReleaseCrossReadTests: XCTestCase {
    func testCanonicalGeneratedFamiliesCrossReadInSwift() throws {
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
            let data = try Data(contentsOf: root.appendingPathComponent(
                "firmware-releases/\(entry.artifact)"))
            let bundle = try catalog.bundle(for: entry, data: data)
            XCTAssertEqual(bundle.targets, [family])
            XCTAssertEqual(bundle.releaseNotes?.count, 10)
        }
    }
}
