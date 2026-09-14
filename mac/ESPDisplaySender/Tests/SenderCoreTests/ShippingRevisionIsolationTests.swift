import Foundation
import XCTest

@testable import SenderCore
@testable import SenderProtocol

final class ShippingRevisionIsolationTests: XCTestCase {
    func testInvalidOnlyShippingRevisionDoesNotHideCatalog() throws {
        let releaseRoot = Self.repoRoot()
            .appendingPathComponent("firmware-releases", isDirectory: true)
        let sourceCatalog = try Data(contentsOf: releaseRoot.appendingPathComponent(
            FirmwareReleaseCatalog.fileName))
        let catalog = try FirmwareReleaseCatalog.read(sourceCatalog)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("espdisp-shipping-isolation-" + UUID().uuidString)
        let wrapper = directory.appendingPathComponent("Fixture.bundle")
        let resources = wrapper.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(
            at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for entry in catalog.families.values {
            for revision in entry.revisions {
                let filename = URL(fileURLWithPath: revision.artifact).lastPathComponent
                var data = try Data(contentsOf: releaseRoot.appendingPathComponent(
                    revision.artifact))
                if entry.family != "c6" {
                    data[data.index(before: data.endIndex)] ^= 0x01
                }
                try data.write(to: resources.appendingPathComponent(filename))
            }
        }
        try sourceCatalog.write(to: resources.appendingPathComponent(
            FirmwareReleaseCatalog.fileName))
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>\
            <key>CFBundleIdentifier</key>\
            <string>com.espdisplay.test.shipping-isolation</string>\
            </dict></plist>
            """.utf8).write(to: wrapper.appendingPathComponent("Contents/Info.plist"))

        let bundle = try XCTUnwrap(Bundle(url: wrapper))
        guard case .ready(let releases) = BundledFirmware.load(in: bundle) else {
            return XCTFail("one invalid shipping revision hid the entire catalog")
        }
        XCTAssertNotNil(releases.selections["c6"])
        for family in ["s3", "p4"] {
            let options = releases.revisions(for: family)
            let option = try XCTUnwrap(options.only)
            XCTAssertFalse(option.isAvailable, family)
            XCTAssertNil(option.selection, family)
            XCTAssertTrue(
                try XCTUnwrap(option.unavailableReason)
                    .contains("artifact hash does not match"),
                "\(family): \(String(describing: option.unavailableReason))")
            XCTAssertNil(releases.selections[family], family)
        }
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
