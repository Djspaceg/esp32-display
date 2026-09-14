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
        var catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sourceCatalog) as? [String: Any])
        var families = try XCTUnwrap(catalog["families"] as? [String: Any])

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("espdisp-shipping-isolation-" + UUID().uuidString)
        let wrapper = directory.appendingPathComponent("Fixture.bundle")
        let resources = wrapper.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(
            at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for family in FirmwareReleaseCatalog.requiredFamilies.sorted() {
            var entry = try XCTUnwrap(families[family] as? [String: Any])
            let filename = "espdisp-\(family)-1.5.0.espdispfw"
            let data = try Data(contentsOf: releaseRoot
                .appendingPathComponent(family, isDirectory: true)
                .appendingPathComponent(filename))
            entry.removeValue(forKey: "latest_build")
            entry["artifact"] = "\(family)/\(filename)"
            entry["bytes"] = data.count
            entry["sha256"] = FirmwareBundle.sha256Hex(data)
            families[family] = entry
            try data.write(to: resources.appendingPathComponent(filename))
        }
        catalog["schema"] = FirmwareReleaseCatalog.legacySchema
        catalog["families"] = families
        let catalogData = try JSONSerialization.data(
            withJSONObject: catalog, options: [.sortedKeys])
        try catalogData.write(to: resources.appendingPathComponent(
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
