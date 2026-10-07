import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// The pure pieces behind the reworked detail pane and firmware sheet: the
/// hero's facts, what the Firmware section says is installed, and what the
/// sheet's floating footer shows.
@MainActor
final class LayoutReworkTests: XCTestCase {
    /// The commit the committed bundles were built from, read from one of
    /// them so a regeneration does not have to edit this test.
    private static let shippedCommit: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("firmware-releases/c6/espdisp-c6-1.5.0.espdispfw")
        return (try? FirmwareBundle.read(Data(contentsOf: url)))?.sourceCommit ?? ""
    }()

    private static func releaseRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("firmware-releases")
    }

    private static func releaseSet() throws -> BundledFirmware.ReleaseSet {
        let root = releaseRoot()
        let catalog = try FirmwareReleaseCatalog.read(
            contentsOf: root.appendingPathComponent(FirmwareReleaseCatalog.fileName))
        var options = [String: [BundledFirmware.RevisionOption]]()
        for entry in catalog.families.values {
            options[entry.family] = try entry.revisions.map { revision in
                let url = root.appendingPathComponent(revision.artifact)
                let bundle = try catalog.bundle(
                    for: revision, in: entry, data: Data(contentsOf: url))
                return .init(
                    revision: revision,
                    selection: .init(
                        catalogEntry: entry, revision: revision, bundle: bundle, url: url),
                    unavailableReason: nil)
            }
        }
        return .init(catalog: catalog, revisionOptions: options)
    }

    // MARK: installed firmware

    func testShippedBuildIsRecognisedAsTheBundledRelease() throws {
        let releases = try Self.releaseSet()
        let installed = InstalledFirmware.make(
            version: "1.5.0",
            source: FirmwareSourceIdentity(reported: Self.shippedCommit),
            family: "s3-185", releases: releases)
        guard case .bundled(let revision) = installed.match else {
            return XCTFail("the shipped s3 build should match: \(installed.match)")
        }
        XCTAssertEqual(revision.family, "s3")
        XCTAssertEqual(
            installed.runningText, "1.5.0 · build \(Self.shippedCommit.prefix(12))")
        XCTAssertTrue(installed.matchText.hasPrefix("The bundled s3 1.5.0 release, built 2026-"),
                      installed.matchText)
    }

    func testEveryOtherAnswerIsWordedDifferently() throws {
        let releases = try Self.releaseSet()
        let other = FirmwareSourceIdentity(
            commit: "0123456789abcdef0123456789abcdef01234567", dirty: false)
        let dirty = FirmwareSourceIdentity(commit: Self.shippedCommit, dirty: true)
        let cases: [(InstalledFirmware, InstalledFirmware.Match)] = [
            (.make(version: "1.5.0", source: other, family: "c6", releases: releases),
             .notBundled),
            (.make(version: "1.5.0", source: dirty, family: "c6", releases: releases),
             .uncommitted),
            (.make(version: "1.5.0", source: nil, family: "c6", releases: releases),
             .notReported),
            (.make(version: nil, source: nil, family: nil, releases: releases,
                   heardFrom: false), .unknown),
            (.make(version: nil, source: nil, family: nil, releases: releases,
                   heardFrom: true), .legacy),
        ]
        for (installed, expected) in cases {
            XCTAssertEqual(installed.match, expected)
        }
        XCTAssertEqual(Set(cases.map(\.0.matchText)).count, cases.count)
        // An unrecognised build names the newest bundled release.
        XCTAssertTrue(cases[0].0.matchText.contains("Bundled: c6 2.0.0"), cases[0].0.matchText)
        XCTAssertEqual(cases[2].0.runningText, "1.5.0")
        XCTAssertEqual(cases[4].0.runningText, "Legacy firmware")
    }

    func testAPanelThatHasNotNamedItsFamilyIsStillMatchedByCommit() throws {
        let installed = InstalledFirmware.make(
            version: "1.5.0",
            source: FirmwareSourceIdentity(reported: Self.shippedCommit),
            family: nil, releases: try Self.releaseSet())
        guard case .bundled = installed.match else {
            return XCTFail("a unique commit identifies the bundled build")
        }
        XCTAssertNil(installed.latestBundled, "no family, so no single latest to name")
    }

    // MARK: revision labels keep every revision installable

    func testInstalledRevisionKeepsItsVerb() throws {
        let releases = try Self.releaseSet()
        // The 1.5.0 revision, which shippedCommit was read from; 2.0.0 is
        // listed above it.
        let option = try XCTUnwrap(releases.revisions(for: "c6").first {
            $0.revision.version == "1.5.0"
        })
        let selection = try XCTUnwrap(option.selection)
        let plan = FirmwareUpdatePlan.make(
            selection.bundle.availability(
                forTarget: "c6", chip: "esp32c6", panelVersion: "1.5.0"),
            chipConfirmed: true)
        XCTAssertTrue(plan.canPush, "the installed build is still installable")
        let running = try XCTUnwrap(FirmwareSourceIdentity(reported: Self.shippedCommit))
        XCTAssertEqual(
            FirmwareRevisionPresentation.title(
                revision: option.revision, plan: plan,
                isInstalled: running.isExactly(selection.bundle)),
            "1.5.0 - Reinstall - Installed")
        XCTAssertEqual(
            FirmwareRevisionPresentation.title(revision: option.revision, plan: plan),
            "1.5.0 - Reinstall")
        for (panel, verb) in [("1.4.0", "Upgrade"), ("1.6.0", "Downgrade")] {
            let other = FirmwareUpdatePlan.make(
                selection.bundle.availability(
                    forTarget: "c6", chip: "esp32c6", panelVersion: panel),
                chipConfirmed: true)
            XCTAssertTrue(other.canPush)
            XCTAssertEqual(other.verb, verb)
        }
        XCTAssertEqual(
            FirmwareRevisionPresentation.running(version: "1.5.0", source: running),
            "1.5.0 (build \(Self.shippedCommit.prefix(12)))")
        XCTAssertEqual(
            FirmwareRevisionPresentation.running(version: nil, source: nil),
            "Not reported over USB")
    }

    // MARK: USB write verification

    func testRestartIntoADifferentBuildIsAFailure() throws {
        let bundle = try FirmwareBundle.read(Data(contentsOf: Self.releaseRoot()
            .appendingPathComponent("c6/espdisp-c6-1.5.0.espdispfw")))
        let same = UsbOnboarder.SettledBoard(
            port: "/dev/cu.usbmodem1", firmwareVersion: "1.5.0",
            firmwareSource: FirmwareSourceIdentity(reported: Self.shippedCommit))
        XCTAssertNil(PanelManager.restartedIntoOtherFirmware(bundle: bundle, board: same))

        var old = same
        old.firmwareSource = FirmwareSourceIdentity(
            commit: "0123456789abcdef0123456789abcdef01234567", dirty: false)
        let failure = try XCTUnwrap(
            PanelManager.restartedIntoOtherFirmware(bundle: bundle, board: old))
        XCTAssertEqual(failure.title, "The board restarted into a different build")
        XCTAssertTrue(failure.message.contains("0123456789ab"))

        var dirtyOld = same
        dirtyOld.firmwareSource = FirmwareSourceIdentity(
            commit: Self.shippedCommit, dirty: true)
        XCTAssertEqual(
            PanelManager.restartedIntoOtherFirmware(bundle: bundle, board: dirtyOld)?.title,
            "The board restarted into a different build",
            "a clean bundle answered by a dirty build is not what was written")

        var unnamed = same
        unnamed.firmwareSource = nil
        XCTAssertEqual(
            PanelManager.restartedIntoOtherFirmware(bundle: bundle, board: unnamed)?.title,
            "The board restarted into the old firmware",
            "the shipped image names its build, so a silent board is on older firmware")
        var older = same
        older.firmwareVersion = "1.4.0"
        XCTAssertEqual(
            PanelManager.restartedIntoOtherFirmware(bundle: bundle, board: older)?.title,
            "The board restarted into the old firmware")
    }

    // MARK: CFGSHOW src=

    func testCFGINFOSourceFieldIsReadAndOptional() {
        let line = "CFGINFO ssid64= name64=ZXNwZGlzcGxheQ== id=020000123456 "
            + "connected=0 ip=0.0.0.0 rssi=0 flip=0 rot=0 pwr=on board=st7789 "
            + "profile=st7789 target=c6 chip=esp32c6 partition=default-8m "
            + "bat=-1 ota=off ssid= caps=00002000 bllevel=128 fw=1.5.0"
        XCTAssertNil(WifiConfigUI.usbIdentity(from: line).status?.firmwareSource)
        XCTAssertEqual(
            WifiConfigUI.usbIdentity(from: line).status?.firmwareVersion, "1.5.0")
        let withSource = WifiConfigUI.usbIdentity(from: line + " src=\(Self.shippedCommit)")
        XCTAssertEqual(withSource.status?.firmwareVersion, "1.5.0")
        XCTAssertEqual(withSource.status?.firmwareSource?.commit, Self.shippedCommit)
        XCTAssertNil(
            WifiConfigUI.usbIdentity(from: line + " src=unknown").status?.firmwareSource)
        // On firmware predating src=, an SSID ending in " src=<commit>" is text.
        let ssid = "Cafe src=\(Self.shippedCommit)"
        let spoof = "CFGINFO ssid64=\(Data(ssid.utf8).base64EncodedString()) "
            + "name64=ZXNwZGlzcGxheQ== id=020000123456 connected=1 ip=10.0.0.2 "
            + "rssi=-50 pwr=on board=st7789 target=c6 chip=esp32c6 "
            + "partition=default-8m bat=-1 ota=off ssid=\(ssid) caps=00002000 "
            + "bllevel=128 fw=1.5.0"
        XCTAssertNil(WifiConfigUI.usbIdentity(from: spoof).status?.firmwareSource)
        XCTAssertEqual(
            WifiConfigUI.usbIdentity(from: spoof + " src=\(String(repeating: "a", count: 40))")
                .status?.firmwareSource?.commit,
            String(repeating: "a", count: 40))
    }

    func testBuildIsTiedToTheVersionItCameWith() {
        var panel = PanelSnapshot(serviceName: "p", displayName: "P")
        let build = FirmwareSourceIdentity(reported: Self.shippedCommit)
        panel.firmwareVersion = "1.4.0"
        // mDNS announces the new firmware before EINF reports its version.
        panel.noteFirmwareSource(build, reportedWith: "1.5.0")
        XCTAssertNil(panel.currentFirmwareSource, "not yet the running version")
        panel.firmwareVersion = "1.5.0"
        XCTAssertEqual(panel.currentFirmwareSource, build)
        panel.firmwareVersion = "1.6.0"
        XCTAssertNil(panel.currentFirmwareSource, "a newer version hides the old build")
    }

    // MARK: hero facts

    func testBoardModelComesFromTheReportedProfile() {
        var panel = PanelSnapshot(serviceName: "p", displayName: "P")
        XCTAssertEqual(panel.boardModelDescription, "Not reported yet")
        panel.target = "c6"
        panel.chip = "esp32c6"
        XCTAssertEqual(panel.boardModelDescription, "c6 family · esp32c6")
        panel.profile = "st7789"
        XCTAssertEqual(panel.boardModelDescription, "ESP32-C6-LCD-1.47 (ST7789) · esp32c6")
        panel.chip = ServiceMetadata.unknownChip
        XCTAssertEqual(panel.boardModelDescription, "ESP32-C6-LCD-1.47 (ST7789)")
    }

    func testShapeComesFromThePanelNotOneBoard() {
        var panel = PanelSnapshot(serviceName: "p", displayName: "P")
        XCTAssertNil(panel.shapeDescription)
        panel.geometry = PanelGeometry(width: 466, height: 466)
        XCTAssertEqual(panel.shapeDescription, "1:1")
        panel.geometry = PanelGeometry(width: 172, height: 320)
        XCTAssertEqual(panel.shapeDescription, "172:320")
        panel.rotation = 1
        XCTAssertEqual(panel.shapeDescription, "320:172", "a quarter turn lies it on its side")
        panel.geometry = PanelGeometry(width: 240, height: 320)
        panel.rotation = 0
        XCTAssertEqual(panel.shapeDescription, "3:4")
    }

    func testNetworkAndUptimeSummaries() {
        var panel = PanelSnapshot(serviceName: "p", displayName: "P")
        XCTAssertEqual(panel.networkSummary, "Not on the network")
        XCTAssertEqual(panel.uptimeSummary, "Not reported yet")
        panel.address = "192.168.1.9"
        panel.rssi = -60
        panel.uptimeSeconds = 93_840
        XCTAssertEqual(panel.networkSummary, "192.168.1.9 · Good (-60 dBm)")
        XCTAssertEqual(panel.uptimeSummary, "1d 2h")
    }

    func testUSBAttachmentNamesOnlyTheBoardThatAnsweredWithThisID() {
        var panel = PanelSnapshot(serviceName: "espdisplay", displayName: "Desk")
        panel.hardwareID = "020000123456"
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [],
            usbSerialPorts: ["/dev/cu.usbmodem1101"])
        XCTAssertEqual(manager.usbAttachment(for: "espdisplay").summary, "Not connected by USB")

        let identity = WifiConfigUI.usbIdentity(from:
            "CFGINFO ssid64= name64=RGVzaw== id=020000123456 connected=0 ip=0.0.0.0 "
                + "rssi=0 flip=0 rot=0 pwr=on board=st7789 profile=st7789 target=c6 "
                + "chip=esp32c6 partition=default-8m bat=-1 ota=off ssid= "
                + "caps=00002000 bllevel=128 fw=1.5.0")
        manager.noteUSBIdentity(
            path: "/dev/cu.usbmodem1101", identity: identity,
            generation: manager.usbPathGeneration("/dev/cu.usbmodem1101"))
        let attached = manager.usbAttachment(for: "espdisplay")
        XCTAssertTrue(attached.isVerified)
        XCTAssertEqual(
            attached.summary,
            "cu.usbmodem1101 · identified as \u{201C}Desk\u{201D} (ID 02:00:00:12:34:56)")

        var stranger = PanelSnapshot(serviceName: "other", displayName: "Other")
        stranger.hardwareID = "0200000000ff"
        manager.panels.append(stranger)
        XCTAssertNil(manager.usbAttachment(for: "other").port,
                     "a board answering with another ID is not this panel's")
    }

    // MARK: footer

    func testFooterShowsFailureAssoonAsTheRunRecordsIt() {
        var session = UsbFlashSession(flow: .update)
        session.apply(.phase(.writing(FlashPartProgress(
            index: 4, count: 4, role: "app", address: 0x10000, percent: 50,
            bytesBefore: 100, bytes: 100, totalBytes: 200))), at: 1)
        guard case .progress(let fraction?, let title, _) = FlashFooterStatus.usb(session)
        else { return XCTFail("a running write shows progress") }
        XCTAssertEqual(fraction, 0.75, accuracy: 0.001)
        XCTAssertEqual(title, "Writing the application (part 4 of 4)")

        session.fail(title: "Flashing failed", message: "esptool exited 2", at: 2)
        guard case .failure(let failTitle, let step, let message, _, let next) =
            FlashFooterStatus.usb(session)
        else { return XCTFail("a failed run shows its failure") }
        XCTAssertEqual(failTitle, "Flashing failed")
        XCTAssertEqual(step, "Writing the application (part 4 of 4)")
        XCTAssertEqual(message, "esptool exited 2")
        XCTAssertNotNil(next)
    }
}
