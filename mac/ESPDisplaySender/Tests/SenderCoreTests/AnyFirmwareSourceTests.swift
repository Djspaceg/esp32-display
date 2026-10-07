import Foundation
import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// The add sheet flashes any firmware the user points it at, not only the
/// releases the app shipped with: a catalog folder on disk (firmware-dev, or
/// firmware-releases) and any single bundle file.
final class AnyFirmwareSourceTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// A catalog folder laid out the way espdisp.py writes one - manifest.json
    /// beside one folder per family - loads as a full release set.
    func testACatalogFolderOnDiskLoadsEveryFamily() throws {
        let folder = Self.repoRoot.appendingPathComponent("firmware-releases")
        guard case .ready(let releases) = BundledFirmware.load(catalogDirectory: folder)
        else { return XCTFail("\(BundledFirmware.load(catalogDirectory: folder))") }
        XCTAssertEqual(Set(releases.selections.keys), FirmwareReleaseCatalog.requiredFamilies)
    }

    /// Older builds kept beside the latest one are not a reason to refuse the
    /// folder: firmware-dev keeps every build it retained.
    func testExtraBuildsInAFamilyFolderAreNotAContradiction() throws {
        let source = Self.repoRoot.appendingPathComponent("firmware-releases")
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("any-firmware-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        try Data("older".utf8).write(to: copy.appendingPathComponent(
            "p4/espdisp-p4-1.4.0+12.gabcdef0.espdispfw"))
        guard case .ready = BundledFirmware.load(catalogDirectory: copy) else {
            return XCTFail("\(BundledFirmware.load(catalogDirectory: copy))")
        }
    }

    /// The repo's own dev builds, when this checkout has any.
    func testTheLocalDevCatalogLoadsWithItsBuildNumbers() throws {
        let folder = Self.repoRoot.appendingPathComponent("firmware-dev")
        guard FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(FirmwareReleaseCatalog.fileName).path)
        else { throw XCTSkip("no firmware-dev catalog in this checkout") }
        guard case .ready(let releases) = BundledFirmware.load(catalogDirectory: folder)
        else { return XCTFail("\(BundledFirmware.load(catalogDirectory: folder))") }
        XCTAssertNotNil(releases.selections["p4"]?.bundle.firmwareBuild)
        XCTAssertNotNil(releases.selections["p4"]?.bundle.flashPlan(forTarget: "p4"))
    }

    /// A folder with no catalog says so instead of loading nothing quietly.
    func testAFolderWithoutACatalogSaysWhy() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("any-firmware-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        guard case .unreadable(_, let reason) = BundledFirmware.load(catalogDirectory: empty)
        else { return XCTFail("expected unreadable") }
        XCTAssertTrue(reason.contains(FirmwareReleaseCatalog.fileName), reason)
    }

    /// A build rebuilt in place after the folder's manifest was written - the
    /// state the repo's own firmware-dev was found in - is still offered, as
    /// the file itself describes it.
    func testABuildRebuiltAfterItsManifestIsStillOffered() throws {
        let source = Self.repoRoot.appendingPathComponent("firmware-releases")
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("any-firmware-stale-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let manifest = copy.appendingPathComponent(FirmwareReleaseCatalog.fileName)
        let catalog = try FirmwareReleaseCatalog.read(contentsOf: manifest)
        let stale = try XCTUnwrap(catalog.families["p4"]?.sha256)
        let text = try String(contentsOf: manifest, encoding: .utf8)
            .replacingOccurrences(of: stale, with: String(repeating: "0", count: 64))
        try text.write(to: manifest, atomically: true, encoding: .utf8)

        guard case .ready(let releases) = BundledFirmware.load(catalogDirectory: copy)
        else { return XCTFail("\(BundledFirmware.load(catalogDirectory: copy))") }
        let selection = try XCTUnwrap(releases.selections["p4"])
        XCTAssertNotEqual(selection.revision.sha256, String(repeating: "0", count: 64))
        XCTAssertEqual(selection.bundle.images.first?.chip, "esp32p4")
        // Flagged, never silent.
        XCTAssertNotNil(selection.note)
        XCTAssertNil(releases.selections["c6"]?.note)
    }

    /// A file that is not a bundle for that family is still refused, with why.
    func testAWrongFileUnderAFamilyNameIsStillRefused() throws {
        let source = Self.repoRoot.appendingPathComponent("firmware-releases")
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("any-firmware-wrong-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let catalog = try FirmwareReleaseCatalog.read(
            contentsOf: copy.appendingPathComponent(FirmwareReleaseCatalog.fileName))
        let p4 = try XCTUnwrap(catalog.families["p4"]?.artifact)
        let c6 = try XCTUnwrap(catalog.families["c6"]?.artifact)
        let target = copy.appendingPathComponent(p4)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: copy.appendingPathComponent(c6), to: target)

        guard case .ready(let releases) = BundledFirmware.load(catalogDirectory: copy)
        else { return XCTFail("expected ready") }
        try Self.assertNewestP4Refused(
            releases, artifact: try XCTUnwrap(catalog.families["p4"]?.artifact))
    }

    /// The fallback re-runs the whole family contract. A 4B-only P4 build
    /// placed where the catalog names an all-carrier P4 image is refused, so
    /// it can never be written to a 3.4C chosen from the catalog's list.
    func testARebuiltFileThatBreaksTheFamilyContractIsRefused() throws {
        let narrow = Self.repoRoot.appendingPathComponent(
            "firmware-dev/p4/espdisp-p4-1.5.0+233.g0ecb29e.espdispfw")
        guard FileManager.default.fileExists(atPath: narrow.path) else {
            throw XCTSkip("no 4B-only P4 dev build in this checkout")
        }
        let header = try FirmwareBundle.read(Data(contentsOf: narrow))
        XCTAssertEqual(header.images.first?.profiles, ["st7703-4b"])

        let source = Self.repoRoot.appendingPathComponent("firmware-releases")
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("any-firmware-narrow-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let catalog = try FirmwareReleaseCatalog.read(
            contentsOf: copy.appendingPathComponent(FirmwareReleaseCatalog.fileName))
        let target = copy.appendingPathComponent(try XCTUnwrap(catalog.families["p4"]?.artifact))
        try FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: narrow, to: target)

        guard case .ready(let releases) = BundledFirmware.load(catalogDirectory: copy)
        else { return XCTFail("expected ready") }
        try Self.assertNewestP4Refused(
            releases, artifact: try XCTUnwrap(catalog.families["p4"]?.artifact))
    }

    /// The newest p4 revision, replaced by a file that is not a valid p4
    /// bundle, is refused with why. An older valid revision may still be
    /// offered as the selection, but never the replaced file.
    private static func assertNewestP4Refused(
        _ releases: BundledFirmware.ReleaseSet, artifact: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let newest = try XCTUnwrap(
            releases.revisions(for: "p4").first, file: file, line: line)
        XCTAssertEqual(newest.revision.artifact, artifact, file: file, line: line)
        XCTAssertNil(newest.selection, file: file, line: line)
        XCTAssertNotNil(newest.unavailableReason, file: file, line: line)
        XCTAssertNotEqual(
            releases.selections["p4"]?.revision.artifact, artifact,
            file: file, line: line)
    }
}
