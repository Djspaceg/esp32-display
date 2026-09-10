import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import SenderCore
@testable import SenderProtocol

@MainActor
final class BundledFirmwareSelectionTests: XCTestCase {
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
                    let selected = try releases.selectForUpdate(live: live, usb: usb)
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
                try releases.selectForUpdate(live: complete, usb: usb),
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
                profile: nil, partition: "default-8m"))

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
            usb: nil))
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
            usb: complete)

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
                partition: nil))

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
                partition: nil))

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
            usb: nil)

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
                partition: "universal-8m-doom-ota"))

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
                partition: "universal-8m-doom-ota"))) {
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
        var selections = [String: BundledFirmware.Selection]()
        for entry in catalog.families.values {
            let url = releaseRoot.appendingPathComponent(entry.artifact)
            let bundle = try catalog.bundle(
                for: entry, data: Data(contentsOf: url))
            selections[entry.family] = .init(
                catalogEntry: entry, bundle: bundle, url: url)
        }
        return .init(catalog: catalog, selections: selections)
    }
}
