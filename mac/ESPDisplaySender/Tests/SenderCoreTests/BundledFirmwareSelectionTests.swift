import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import SenderCore
@testable import SenderProtocol

@MainActor
final class BundledFirmwareSelectionTests: XCTestCase {
    func testEveryShippingRevisionIsOfferedAsAnOption() throws {
        let releases = try Self.packagedReleaseSet()

        for family in FirmwareReleaseCatalog.requiredFamilies.sorted() {
            let options = releases.revisions(for: family)
            XCTAssertEqual(
                options.count,
                releases.catalog.families[family]?.revisions.count,
                family)
            XCTAssertFalse(options.isEmpty, family)
            XCTAssertEqual(
                options.map(\.revision.artifact),
                releases.catalog.families[family]?.revisions.map(\.artifact))
            XCTAssertTrue(options.allSatisfy {
                $0.revision.build == nil
                    && !$0.revision.artifact.contains("+")
            }, family)
            if family == "c6" {
                XCTAssertEqual(
                    releases.selections[family],
                    options.first?.selection,
                    family)
                XCTAssertTrue(options.allSatisfy(\.isAvailable), family)
            } else {
                XCTAssertNil(releases.selections[family], family)
                XCTAssertTrue(options.allSatisfy { !$0.isAvailable }, family)
                XCTAssertTrue(options.allSatisfy {
                    $0.unavailableReason?.contains("Doom WAD") == true
                }, family)
            }
        }
    }

    func testShippingRevisionRowsRenderDirectionLabelsHeadlessly() throws {
        let releases = try Self.packagedReleaseSet()

        for family in FirmwareReleaseCatalog.requiredFamilies.sorted() {
            let entry = try XCTUnwrap(releases.catalog.families[family])
            let rows = releases.revisions(for: family).map { option in
                guard let selection = option.selection else {
                    return FirmwareRevisionPresentation.unavailableTitle(
                        revision: option.revision,
                        panelVersion: "1.5.0")
                }
                return FirmwareRevisionPresentation.title(
                    revision: option.revision,
                    plan: FirmwareUpdatePlan.make(
                        selection.bundle.availability(
                            forTarget: family,
                            chip: entry.chip,
                            panelVersion: "1.5.0"),
                        chipConfirmed: true))
            }

            XCTAssertEqual(rows.count, entry.revisions.count, family)
            let suffix = family == "c6" ? "" : " - Unavailable"
            XCTAssertEqual(rows, ["1.5.0 - Reinstall\(suffix)"], family)
        }
    }

    func testUnavailableShippingRevisionRowsStillLabelDirection() {
        let revision = FirmwareReleaseCatalog.Revision(
            version: "1.5.0", build: nil,
            artifact: "s3/espdisp-s3-1.5.0.espdispfw",
            sha256: String(repeating: "0", count: 64), byteCount: 1)

        XCTAssertEqual(
            FirmwareRevisionPresentation.unavailableTitle(
                revision: revision, panelVersion: "1.4.0"),
            "1.5.0 - Upgrade - Unavailable")
        XCTAssertEqual(
            FirmwareRevisionPresentation.unavailableTitle(
                revision: revision, panelVersion: "1.5.0"),
            "1.5.0 - Reinstall - Unavailable")
        XCTAssertEqual(
            FirmwareRevisionPresentation.unavailableTitle(
                revision: revision, panelVersion: "1.6.0"),
            "1.5.0 - Downgrade - Unavailable")
    }

    func testUpdatePreselectionUsesCompleteRuntimeIdentityFromMDNSOrMatchedUSB() throws {
        let releases = try Self.releaseSet()

        for family in FirmwareReleaseCatalog.requiredFamilies.sorted() {
            let entry = try XCTUnwrap(releases.catalog.families[family])
            for profile in entry.profiles {
                let complete = FirmwareReleaseCatalog.Identity(
                    family: family,
                    chip: entry.chip,
                    profile: profile,
                    partition: entry.compatibility.partitionScheme)
                let live: FirmwareReleaseCatalog.Identity
                let usb: FirmwareReleaseCatalog.Identity?
                switch family {
                case "s3":
                    live = complete
                    usb = nil
                case "c6":
                    live = .init(
                        family: family, chip: entry.chip,
                        profile: nil, partition: nil)
                    usb = complete
                case "p4":
                    live = .init(
                        family: nil, chip: nil, profile: nil, partition: nil)
                    usb = complete
                default:
                    return XCTFail("unexpected release family \(family)")
                }

                do {
                    let selected = try releases.selectForUpdate(
                        live: live, usb: usb, transport: .ota)
                    XCTAssertEqual(selected.selection.catalogEntry.family, family)
                    XCTAssertEqual(selected.identity, complete)
                } catch {
                    XCTFail("\(family)/\(profile) was not preselected: \(error)")
                }
            }
        }
    }

    func testCompleteManifestIdentitySelectsEveryRuntimeProfileDirectly() throws {
        let releases = try Self.releaseSet()
        for family in FirmwareReleaseCatalog.requiredFamilies.sorted() {
            let entry = try XCTUnwrap(releases.catalog.families[family])
            for profile in entry.profiles {
                let selected = try releases.select(
                    family: family,
                    chip: entry.chip,
                    profile: profile,
                    partition: entry.compatibility.partitionScheme)
                XCTAssertEqual(selected.catalogEntry.family, family)
            }
        }
    }

    func testPreDoomS3IdentityResolvesForUSBUpdate() throws {
        let releases = try Self.releaseSetForResolution()
        let identity = FirmwareReleaseCatalog.Identity(
            family: "s3",
            chip: "esp32s3",
            profile: "co5300",
            partition: "universal-8m-ota")

        let selected = try releases.selectForUpdate(
            live: identity,
            usb: nil,
            transport: .usb)

        XCTAssertEqual(selected.resolution.canonicalTarget, "s3")
        XCTAssertEqual(
            selected.resolution,
            .partitionMigration(
                selected.selection,
                from: "universal-8m-ota",
                to: "universal-8m-doom-ota"))
        XCTAssertEqual(
            selected.selection.catalogEntry.compatibility.partitionScheme,
            "universal-8m-doom-ota")
        XCTAssertEqual(selected.identity, identity)
    }

    func testPreDoomS3IdentityStillFailsStrictOTASelection() throws {
        let releases = try Self.releaseSetForResolution()
        let identity = FirmwareReleaseCatalog.Identity(
            family: "s3",
            chip: "esp32s3",
            profile: "co5300",
            partition: "universal-8m-ota")

        XCTAssertThrowsError(try releases.selectForUpdate(
            live: identity,
            usb: nil,
            transport: .ota
        )) {
            XCTAssertEqual(
                $0 as? FirmwareReleaseCatalogError,
                .partitionMismatch(
                    expected: "universal-8m-doom-ota",
                    found: "universal-8m-ota"))
        }
    }

    func testUSBPartitionMigrationStillRequiresFamilyChipAndProfile() throws {
        let releases = try Self.releaseSetForResolution()
        let invalid: [(FirmwareReleaseCatalog.Identity, FirmwareReleaseCatalogError)] = [
            (
                .init(
                    family: nil,
                    chip: "esp32s3",
                    profile: "co5300",
                    partition: "universal-8m-ota"),
                .identityIncomplete
            ),
            (
                .init(
                    family: "s3",
                    chip: "esp32p4",
                    profile: "co5300",
                    partition: "universal-8m-ota"),
                .chipMismatch(expected: "esp32s3", found: "esp32p4")
            ),
            (
                .init(
                    family: "s3",
                    chip: "esp32s3",
                    profile: nil,
                    partition: "universal-8m-ota"),
                .identityIncomplete
            ),
            (
                .init(
                    family: "s3",
                    chip: "esp32s3",
                    profile: "st7703-4b",
                    partition: "universal-8m-ota"),
                .profileMismatch(family: "s3", found: "st7703-4b")
            ),
        ]

        for (identity, expectedError) in invalid {
            XCTAssertThrowsError(try releases.selectForUpdate(
                live: identity,
                usb: nil,
                transport: .usb
            )) {
                XCTAssertEqual($0 as? FirmwareReleaseCatalogError, expectedError)
            }
        }
    }

    func testP4PartitionMismatchAlsoResolvesForUSBUpdate() throws {
        let releases = try Self.releaseSetForResolution(
            p4PartitionScheme: "future-p4-layout")

        let selected = try releases.selectForUpdate(
            live: .init(
                family: "p4",
                chip: "esp32p4",
                profile: "st7703-4b",
                partition: "p4-32m-ota"),
            usb: nil,
            transport: .usb)

        XCTAssertEqual(
            selected.resolution,
            .partitionMigration(
                selected.selection,
                from: "p4-32m-ota",
                to: "future-p4-layout"))
    }

    func testUpdatePreselectionRejectsEveryCrossTransportConflict() throws {
        let releases = try Self.releaseSet()
        let entry = try XCTUnwrap(releases.catalog.families["c6"])
        let complete = FirmwareReleaseCatalog.Identity(
            family: "c6",
            chip: entry.chip,
            profile: "st7789",
            partition: entry.compatibility.partitionScheme)
        let conflicts: [(String, FirmwareReleaseCatalog.Identity)] = [
            ("family", .init(
                family: "s3", chip: complete.chip,
                profile: complete.profile, partition: complete.partition)),
            ("chip", .init(
                family: complete.family, chip: "esp32s3",
                profile: complete.profile, partition: complete.partition)),
            ("profile", .init(
                family: complete.family, chip: complete.chip,
                profile: "jd9853", partition: complete.partition)),
            ("partition", .init(
                family: complete.family, chip: complete.chip,
                profile: complete.profile, partition: "universal-8m-doom-ota")),
        ]

        for (field, usb) in conflicts {
            XCTAssertThrowsError(
                try releases.selectForUpdate(
                    live: complete, usb: usb, transport: .ota),
                "conflicting \(field) evidence must fail closed"
            ) {
                guard case let BundledFirmware.UpdateIdentityError.conflictingEvidence(
                    found, _, _) = $0
                else { return XCTFail("unexpected error \($0)") }
                XCTAssertEqual(found, field)
            }
        }
    }

    func testUpdatePreselectionStillRejectsUnknownIdentity() throws {
        let releases = try Self.releaseSet()

        let selected = try releases.selectForUpdate(
            live: .init(
                family: "c6", chip: "esp32c6",
                profile: nil, partition: nil),
            usb: .init(
                family: "c6", chip: "esp32c6",
                profile: nil, partition: "default-8m"),
            transport: .usb)

        XCTAssertEqual(selected.selection.catalogEntry.family, "c6")
        XCTAssertEqual(
            selected.identity,
            .init(
                family: "c6",
                chip: "esp32c6",
                profile: nil,
                partition: "default-8m"))

        XCTAssertThrowsError(try releases.selectForUpdate(
            live: .init(
                family: "c6", chip: ServiceMetadata.unknownChip,
                profile: "st7789", partition: "default-8m"),
            usb: nil,
            transport: .ota))
    }

    func testUpdatePreselectionUsesMatchedUSBChipWhenLiveChipIsUnknown() throws {
        let releases = try Self.releaseSet()
        let complete = FirmwareReleaseCatalog.Identity(
            family: "c6",
            chip: "esp32c6",
            profile: "st7789",
            partition: "default-8m")

        let selected = try releases.selectForUpdate(
            live: .init(
                family: "c6",
                chip: ServiceMetadata.unknownChip,
                profile: "st7789",
                partition: "default-8m"),
            usb: complete,
            transport: .usb)

        XCTAssertEqual(selected.selection.catalogEntry.family, "c6")
        XCTAssertEqual(selected.identity, complete)
    }

    func testUpdatePreselectionFallsBackFromAChipOnlyC6USBProbe() throws {
        let releases = try Self.releaseSet()

        let selected = try releases.selectForUpdate(
            live: .init(
                family: nil,
                chip: nil,
                profile: nil,
                partition: nil),
            usb: .init(
                family: nil,
                chip: "esp32c6",
                profile: nil,
                partition: nil),
            transport: .usb)

        XCTAssertEqual(selected.selection.catalogEntry.family, "c6")
        XCTAssertEqual(
            selected.identity,
            .init(
                family: "c6",
                chip: "esp32c6",
                profile: nil,
                partition: nil))
    }

    func testUpdatePreselectionFallsBackFromAChipOnlyP4USBProbe() throws {
        let releases = try Self.releaseSet()

        let selected = try releases.selectForUpdate(
            live: .init(
                family: nil,
                chip: nil,
                profile: nil,
                partition: nil),
            usb: .init(
                family: nil,
                chip: "esp32p4",
                profile: nil,
                partition: nil),
            transport: .usb)

        XCTAssertEqual(selected.selection.catalogEntry.family, "p4")
        XCTAssertEqual(
            selected.identity,
            .init(
                family: "p4",
                chip: "esp32p4",
                profile: nil,
                partition: nil))
    }

    func testUpdatePreselectionCanonicalizesLegacyS3FamilyAliases() throws {
        let releases = try Self.releaseSet()

        let selected = try releases.selectForUpdate(
            live: .init(
                family: "s3-175",
                chip: "esp32s3",
                profile: "co5300",
                partition: "universal-8m-doom-ota"),
            usb: nil,
            transport: .ota)

        XCTAssertEqual(selected.selection.catalogEntry.family, "s3")
        XCTAssertEqual(
            selected.identity,
            .init(
                family: "s3",
                chip: "esp32s3",
                profile: "co5300",
                partition: "universal-8m-doom-ota"))
    }

    func testUpdatePreselectionAcceptsLegacyLiveS3AliasMatchedToCanonicalUSBFamily() throws {
        let releases = try Self.releaseSet()

        let selected = try releases.selectForUpdate(
            live: .init(
                family: "s3-175",
                chip: "esp32s3",
                profile: "co5300",
                partition: "universal-8m-doom-ota"),
            usb: .init(
                family: "s3",
                chip: "esp32s3",
                profile: "co5300",
                partition: "universal-8m-doom-ota"),
            transport: .usb)

        XCTAssertEqual(selected.selection.catalogEntry.family, "s3")
        XCTAssertEqual(
            selected.identity,
            .init(
                family: "s3",
                chip: "esp32s3",
                profile: "co5300",
                partition: "universal-8m-doom-ota"))
    }

    func testUpdatePreselectionStillRejectsGenuineCrossTransportFamilyConflicts() throws {
        let releases = try Self.releaseSet()

        XCTAssertThrowsError(try releases.selectForUpdate(
            live: .init(
                family: "s3-175",
                chip: "esp32s3",
                profile: "co5300",
                partition: "universal-8m-doom-ota"),
            usb: .init(
                family: "p4",
                chip: "esp32s3",
                profile: "co5300",
                partition: "universal-8m-doom-ota"),
            transport: .usb)) {
                    guard case let BundledFirmware.UpdateIdentityError
                        .conflictingEvidence(field, live, usb) = $0
                    else { return XCTFail("unexpected error \($0)") }
                    XCTAssertEqual(field, "family")
                    XCTAssertEqual(live, "s3-175")
                    XCTAssertEqual(usb, "p4")
                }
    }

    func testCaptureC6UpdateSheetWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment[
            "ESPDISP_UX_CAPTURE_PATH"]
        else { return }

        let releases = try Self.releaseSet()
        let hardwareID = "020000123456"
        let usb = WifiConfigUI.USBDeviceOption(
            path: "/dev/cu.usbmodem-c6",
            name: "Desk Panel",
            hardwareID: hardwareID,
            target: "c6",
            board: "st7789",
            chip: "esp32c6",
            partition: "default-8m")
        let target = PanelManager.FirmwareUpdateTarget(
            serviceName: "desk-panel",
            displayName: "Desk Panel",
            hardwareID: hardwareID,
            address: nil,
            chip: "esp32c6",
            target: "c6",
            profile: nil,
            partition: nil,
            firmwareVersion: "1.4.2",
            usbDevice: usb,
            usbPathGeneration: 1)
        let manager = PanelManager(
            previewPanels: [],
            savedNetworkNames: [],
            usbSerialPorts: [])
        let view = FirmwareUpdateSheet(
            manager: manager,
            target: target,
            bundledFirmware: .ready(releases))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 620)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        host.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(
            host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        let png = try XCTUnwrap(
            representation.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output), options: .atomic)
        window.orderOut(nil)
    }

    private static func releaseSet() throws -> BundledFirmware.ReleaseSet {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let releaseRoot = root.appendingPathComponent("firmware-releases")
        let catalog = try FirmwareReleaseCatalog.read(
            contentsOf: releaseRoot.appendingPathComponent(
                FirmwareReleaseCatalog.fileName))
        var options = [String: [BundledFirmware.RevisionOption]]()
        for entry in catalog.families.values {
            options[entry.family] = try entry.revisions.map { revision in
                let url = releaseRoot.appendingPathComponent(revision.artifact)
                let bundle = try FirmwareBundle.read(Data(contentsOf: url))
                let selection = BundledFirmware.Selection(
                    catalogEntry: entry, revision: revision,
                    bundle: bundle, url: url)
                return BundledFirmware.RevisionOption(
                    revision: revision, selection: selection,
                    unavailableReason: nil)
            }
        }
        return .init(catalog: catalog, revisionOptions: options)
    }

    private static func packagedReleaseSet() throws -> BundledFirmware.ReleaseSet {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let releaseRoot = root.appendingPathComponent("firmware-releases")
        let catalog = try FirmwareReleaseCatalog.read(
            contentsOf: releaseRoot.appendingPathComponent(
                FirmwareReleaseCatalog.fileName))
        var options = [String: [BundledFirmware.RevisionOption]]()
        for entry in catalog.families.values {
            options[entry.family] = entry.revisions.map { revision in
                let url = releaseRoot.appendingPathComponent(revision.artifact)
                do {
                    let bundle = try catalog.bundle(
                        for: revision, in: entry,
                        data: Data(contentsOf: url))
                    let selection = BundledFirmware.Selection(
                        catalogEntry: entry, revision: revision,
                        bundle: bundle, url: url)
                    return BundledFirmware.RevisionOption(
                        revision: revision, selection: selection,
                        unavailableReason: nil)
                } catch {
                    return BundledFirmware.RevisionOption(
                        revision: revision, selection: nil,
                        unavailableReason: error.localizedDescription)
                }
            }
        }
        return .init(catalog: catalog, revisionOptions: options)
    }

    private static func releaseSetForResolution(
        p4PartitionScheme: String? = nil
    ) throws -> BundledFirmware.ReleaseSet {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let releaseRoot = root.appendingPathComponent("firmware-releases")
        var catalog = try FirmwareReleaseCatalog.read(
            contentsOf: releaseRoot.appendingPathComponent(
                FirmwareReleaseCatalog.fileName))
        if let p4PartitionScheme, let p4 = catalog.families["p4"] {
            var families = catalog.families
            families["p4"] = .init(
                family: p4.family,
                latestVersion: p4.latestVersion,
                latestBuild: p4.latestBuild,
                artifact: p4.artifact,
                sha256: p4.sha256,
                byteCount: p4.byteCount,
                chip: p4.chip,
                profiles: p4.profiles,
                hardware: p4.hardware,
                compatibility: .init(
                    flashBytes: p4.compatibility.flashBytes,
                    partitionScheme: p4PartitionScheme,
                    bootloaderAddress: p4.compatibility.bootloaderAddress,
                    partitionsAddress: p4.compatibility.partitionsAddress,
                    bootApp0Address: p4.compatibility.bootApp0Address,
                    appAddress: p4.compatibility.appAddress,
                    identityRequired: p4.compatibility.identityRequired))
            catalog = .init(
                schema: catalog.schema,
                generatedAt: catalog.generatedAt,
                families: families)
        }
        let fixtureURL = root
            .appendingPathComponent("mac/ESPDisplaySender/Tests/SenderProtocolTests")
            .appendingPathComponent("Fixtures/release-notes-from-espdisp-v3.espdispfw")
        let fixture = try FirmwareBundle.read(contentsOf: fixtureURL)
        let selections = Dictionary(uniqueKeysWithValues: catalog.families.values.map {
            (
                $0.family,
                BundledFirmware.Selection(
                    catalogEntry: $0,
                    bundle: fixture,
                    url: releaseRoot.appendingPathComponent($0.artifact))
            )
        })
        return .init(catalog: catalog, selections: selections)
    }
}
