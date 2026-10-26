import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// A board already in the sidebar whose firmware cannot say who it is - it does
/// not recognise its board, is silent, or is sitting in flashing mode - is still
/// on USB, and must still be updatable there. Its identity comes from esptool in
/// download mode (chip, flash size, PSRAM, MAC) and from what the app already
/// knows about the record, never from the firmware.
@MainActor
final class UsbDownloadModeUpdateTests: XCTestCase {
    private static let hardwareID = "7c0c5f4239a4"
    private static let consoleSerial = "5B90170069"

    private func manager(
        serials: [String: String], chip: String? = "esp32s3", family: String? = "s3",
        profile: String? = nil, learned: [String] = [UsbDownloadModeUpdateTests.consoleSerial]
    ) -> PanelManager {
        var panel = PanelSnapshot(serviceName: "watch", displayName: "watch")
        panel.hardwareID = Self.hardwareID
        panel.usbHardwareID = Self.hardwareID
        panel.firmwareVersion = "2.0.0"
        panel.chip = chip
        panel.target = family
        panel.profile = profile
        panel.usbSerialNumbers = learned
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])
        manager.usbSerialReader = { serials[$0] }
        return manager
    }

    /// The board answered behind this USB serial before, so the port is this
    /// record's even though its firmware now answers nothing usable. That is a
    /// USB update target; esptool proves the MAC before anything is written.
    func testABoardThatCannotIdentifyItselfIsStillAUSBUpdateTarget() {
        let path = "/dev/cu.usbmodem12401"
        let manager = manager(serials: [path: Self.consoleSerial])
        manager.updateUSBPorts([path])
        guard case .ready(let target) = manager.firmwareUpdateReadiness("watch") else {
            return XCTFail("not ready: \(manager.firmwareUpdateReadiness("watch"))")
        }
        XCTAssertEqual(target.usbDevice?.path, path)
        XCTAssertEqual(target.hardwareID, Self.hardwareID)
        XCTAssertTrue(target.usbIdentityFromEsptool)
        XCTAssertEqual(target.familyForUpdate, "s3")
        // Game data needs the firmware answering; it says so instead.
        guard case .notReady(let reason) = manager.gameDataReadiness("watch") else {
            return XCTFail("game data offered to a board whose firmware is not answering")
        }
        XCTAssertTrue(reason.contains("Update its firmware first"), reason)
    }

    /// A native USB port reports the MAC as its USB serial: a record that never
    /// learned a serial is still matched by it.
    func testANativeUSBPortIsMatchedByTheMACItReports() {
        let path = "/dev/cu.usbmodem101"
        let manager = manager(serials: [path: "7C:0C:5F:42:39:A4"], learned: [])
        manager.updateUSBPorts([path])
        guard case .ready(let target) = manager.firmwareUpdateReadiness("watch") else {
            return XCTFail("not ready: \(manager.firmwareUpdateReadiness("watch"))")
        }
        XCTAssertEqual(target.usbDevice?.path, path)
    }

    /// A P4 shows two ports: its console behind a USB bridge, whose serial the
    /// record learned, and its JTAG port reporting the MAC. The learned console
    /// wins rather than the pair being ambiguous.
    func testALearnedSerialOutranksAMACShapedOne() {
        let console = "/dev/cu.usbmodem5B901700691"
        let jtag = "/dev/cu.usbmodem1101"
        let manager = manager(serials: [
            console: Self.consoleSerial, jtag: "7C:0C:5F:42:39:A4",
        ], chip: "esp32p4", family: "p4")
        manager.updateUSBPorts([console, jtag])
        XCTAssertEqual(manager.usbDownloadModeDevice(for: "watch")?.path, console)
    }

    /// Two ports both claiming the learned serial, or one that answered as a
    /// different board, are never a write target.
    func testAmbiguousOrOtherBoardPortsAreNotTargets() {
        let a = "/dev/cu.usbmodem-a"
        let b = "/dev/cu.usbmodem-b"
        let both = manager(serials: [a: Self.consoleSerial, b: Self.consoleSerial])
        both.updateUSBPorts([a, b])
        XCTAssertNil(both.usbDownloadModeDevice(for: "watch"))

        let other = manager(serials: [a: Self.consoleSerial])
        other.updateUSBPorts([a])
        other.noteUSBIdentity(path: a, name: "someone-else", hardwareID: "aabbccddeeff")
        XCTAssertNil(other.usbDownloadModeDevice(for: "watch"))
        guard case .notReady = other.firmwareUpdateReadiness("watch") else {
            return XCTFail("a port answering as another board was offered")
        }
    }

    /// Bridge chips often share one serial. Two ports behind the learned one
    /// fall through to the port whose own serial is this board's MAC.
    func testASharedBridgeSerialFallsThroughToTheMACPort() {
        let a = "/dev/cu.usbserial-a"
        let b = "/dev/cu.usbserial-b"
        let native = "/dev/cu.usbmodem101"
        let manager = manager(serials: [
            a: Self.consoleSerial, b: Self.consoleSerial, native: "7C:0C:5F:42:39:A4",
        ])
        manager.updateUSBPorts([a, b, native])
        XCTAssertEqual(manager.usbDownloadModeDevice(for: "watch")?.path, native)
    }

    // MARK: choosing the image

    private func shipped(_ family: String) throws -> FirmwareBundle {
        let releases = try UsbRescueTests.releaseSet()
        return try XCTUnwrap(
            releases.revisions(for: family).lazy.compactMap(\.selection).first?.bundle,
            "no shipped \(family) bundle")
    }

    private func identity(
        _ chip: String, flash: Int? = 16 << 20, psram: Int? = 8 << 20
    ) -> PanelManager.DownloadModeIdentity {
        .init(chip: chip, mac: Self.hardwareID, flashBytes: flash, psramBytes: psram)
    }

    /// The chip esptool read picks the one image for it, with or without the
    /// family the record names.
    func testTheChipPicksTheImageWhetherOrNotTheFamilyIsKnown() throws {
        let s3 = try shipped("s3")
        for family in [nil, "s3"] as [String?] {
            let chosen = PanelManager.downloadModeImage(
                in: s3, for: identity("esp32s3"), family: family, profile: nil)
            XCTAssertEqual(try? chosen.get(), "s3", "\(String(describing: family))")
        }
        // The T-Watch's own board is supported by this version.
        XCTAssertEqual(try? PanelManager.downloadModeImage(
            in: s3, for: identity("esp32s3"), family: nil,
            profile: "st7789-twatch").get(), "s3")
        // A flash size esptool could not read does not stop the write.
        XCTAssertEqual(try? PanelManager.downloadModeImage(
            in: s3, for: identity("esp32s3", flash: nil), family: nil,
            profile: nil).get(), "s3")
    }

    /// Writes that could not start the board are refused before esptool writes:
    /// another chip's firmware, a flash size the image does not support, and a
    /// version that does not support the board the record knows.
    func testWritesThatCannotWorkAreRefusedInWords() throws {
        let s3 = try shipped("s3")
        func failure(_ result: Result<String, WifiConfigUI.ConfigFailure>)
            -> WifiConfigUI.ConfigFailure? {
            if case .failure(let failure) = result { return failure }
            return nil
        }
        let wrongChip = failure(PanelManager.downloadModeImage(
            in: s3, for: identity("esp32c6"), family: nil, profile: nil))
        XCTAssertEqual(wrongChip?.title, "No firmware here for this chip")
        let tooSmall = failure(PanelManager.downloadModeImage(
            in: s3, for: identity("esp32s3", flash: 4 << 20), family: nil, profile: nil))
        XCTAssertEqual(tooSmall?.title, "This firmware does not fit this board")
        let unsupported = failure(PanelManager.downloadModeImage(
            in: s3, for: identity("esp32s3"), family: nil, profile: "jd9853"))
        XCTAssertEqual(unsupported?.title, "This firmware version does not support this board")
        for refusal in [wrongChip, tooSmall, unsupported] {
            XCTAssertTrue(refusal?.message.hasSuffix("Nothing was written.") == true,
                          refusal?.message ?? "nil")
            UsbUnrecognisedBoardTests.assertPlainWording(refusal?.message ?? "")
        }
    }

    /// A P4 image drives carrier pins, so it is written only once the board is
    /// named, by the record or by the person.
    func testAP4IsWrittenOnlyOnceItsBoardIsNamed() throws {
        let p4 = try shipped("p4")
        let unnamed = PanelManager.downloadModeImage(
            in: p4, for: identity("esp32p4", flash: 32 << 20), family: "p4", profile: nil)
        guard case .failure(let failure) = unnamed else {
            return XCTFail("a P4 was written without its board named")
        }
        XCTAssertEqual(failure.title, "Choose which board this is")
        XCTAssertEqual(try? PanelManager.downloadModeImage(
            in: p4, for: identity("esp32p4", flash: 32 << 20), family: "p4",
            profile: "jd9365-4c").get(), "p4")
    }

    /// With nothing naming the family, the sheet offers every family, or only
    /// the chip's, and each P4 board on its own row.
    func testFamilyChoicesCoverEveryFamilyAndNameEachP4Board() throws {
        let catalog = try UsbRescueTests.releaseSet().catalog
        let all = PanelManager.firmwareFamilyChoices(catalog: catalog, chip: nil)
        XCTAssertEqual(Set(all.map(\.family)), ["c3", "c6", "p4", "s3"])
        XCTAssertEqual(all.first { $0.family == "s3" }?.label, "ESP32-S3 boards")
        let p4 = all.filter { $0.family == "p4" }
        XCTAssertEqual(Set(p4.compactMap(\.profile)),
                       Set(catalog.families["p4"]?.profiles ?? []))
        XCTAssertTrue(p4.allSatisfy { $0.label.contains("ESP32-P4") }, "\(p4)")
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        let s3Only = PanelManager.firmwareFamilyChoices(catalog: catalog, chip: "esp32s3")
        XCTAssertEqual(s3Only.map(\.family), ["s3"])

        // Every choice resolves to bundled firmware the way the sheet asks for
        // it, so choosing one is enough to write.
        let releases = try UsbRescueTests.releaseSet()
        for choice in all {
            let identity = FirmwareReleaseCatalog.Identity(
                family: choice.family, chip: choice.chip,
                profile: choice.profile, partition: nil)
            XCTAssertNoThrow(
                try releases.resolveFamilyForUpdate(live: identity, usb: nil, transport: .usb),
                choice.label)
        }
    }

    /// Packaged PSRAM is read off chip-id's Features line; none named is nil.
    func testPackagedPSRAMIsReadFromChipID() {
        XCTAssertEqual(EsptoolOutput.embeddedPSRAMBytes(
            in: "Features: Wi-Fi, BT 5 (LE), Dual Core + LP Core, 240MHz, "
                + "Embedded PSRAM 8MB (AP_3v3)\n"), 8 << 20)
        XCTAssertNil(EsptoolOutput.embeddedPSRAMBytes(
            in: "Features: Wi-Fi, BT 5 (LE), Dual Core, 240MHz\n"))
    }

    // MARK: every branch, over plain image facts

    private typealias Candidate = PanelManager.DownloadModeCandidate

    private static let universalS3 = Candidate(
        chip: "esp32s3", targets: ["s3"], profiles: ["st7789-154", "co5300", "st7789-twatch"],
        flashSizes: [8 << 20, 16 << 20, 32 << 20], writableTargets: ["s3"])
    private static let legacyS3085 = Candidate(
        chip: "esp32s3", targets: ["s3-085"], profiles: [], flashSizes: [],
        writableTargets: ["s3-085"])
    private static let legacyP44B = Candidate(
        chip: "esp32p4", targets: ["p4-4b"], profiles: [], flashSizes: [],
        writableTargets: ["p4-4b"])

    private func pick(
        _ candidates: [Candidate], chip: String = "esp32s3", family: String? = nil,
        profile: String? = nil
    ) -> Result<String, WifiConfigUI.ConfigFailure> {
        PanelManager.downloadModeImage(
            candidates: candidates, version: "2.1.0",
            for: identity(chip, flash: chip == "esp32p4" ? 32 << 20 : 16 << 20),
            family: family, profile: profile)
    }

    private func title(_ result: Result<String, WifiConfigUI.ConfigFailure>) -> String? {
        if case .failure(let failure) = result { return failure.title }
        return nil
    }

    /// A historical image is built for one board: it is never the fallback for
    /// a board nothing names, and never written to a board of another target.
    func testAHistoricalImageIsWrittenOnlyToTheBoardItWasBuiltFor() {
        XCTAssertEqual(title(pick([Self.legacyS3085])), "Choose the firmware family")
        XCTAssertEqual(try? pick([Self.legacyS3085], family: "s3-085").get(), "s3-085")
        XCTAssertEqual(title(pick([Self.legacyS3085], family: "s3-154")),
                       "This firmware has nothing for this board's family")
        // Named by its target but recorded as another board: refused.
        XCTAssertEqual(title(pick([Self.legacyS3085], family: "s3-085", profile: "st7789-154")),
                       "This firmware version does not support this board")
        // A universal family name never lands on a one-board image.
        XCTAssertEqual(title(pick([Self.legacyS3085], family: "s3")),
                       "This firmware has nothing for this board's family")
    }

    /// The 4B-only image is a carrier image under its legacy name too: a 4C
    /// is refused and a board nobody named is asked for.
    func testALegacyP4ImageKeepsTheCarrierRule() {
        XCTAssertEqual(title(pick([Self.legacyP44B], chip: "esp32p4", family: "p4-4b")),
                       "Choose which board this is")
        XCTAssertEqual(title(pick([Self.legacyP44B], chip: "esp32p4", family: "p4-4b",
                                  profile: "jd9365-4c")),
                       "This firmware version does not support this board")
        XCTAssertEqual(try? pick([Self.legacyP44B], chip: "esp32p4", family: "p4-4b",
                                 profile: "st7703-4b").get(), "p4-4b")
        XCTAssertTrue(Self.legacyP44B.drivesCarrierPins)
        XCTAssertFalse(Self.universalS3.drivesCarrierPins)
    }

    /// A legacy name the record kept finds the current family image; with two
    /// current images and nothing named, the person chooses.
    func testLegacyNamesFindTheFamilyImageAndTwoImagesAreAChoice() {
        XCTAssertEqual(try? pick([Self.universalS3, Self.legacyS3085], family: "s3-175").get(), "s3")
        XCTAssertEqual(try? pick([Self.universalS3, Self.legacyS3085]).get(), "s3",
                       "one current image is the answer beside a historical one")
        var second = Self.universalS3
        second.targets = ["s3-32"]
        second.writableTargets = ["s3-32"]
        XCTAssertEqual(title(pick([Self.universalS3, second])), "Choose the firmware family")
        XCTAssertEqual(try? pick([Self.universalS3, second], family: "s3-32").get(), "s3-32")
    }

    /// The sheet asks only when the record leaves the image open, and its
    /// rows are what the chooser accepts back.
    func testTheSheetAsksOnlyWhenTheRecordLeavesItOpen() {
        let file = [Self.universalS3, Self.legacyS3085, Self.legacyP44B]
        XCTAssertFalse(PanelManager.downloadModeNeedsChoice(
            candidates: file, chip: "esp32s3", family: nil, profile: nil))
        XCTAssertTrue(PanelManager.downloadModeNeedsChoice(
            candidates: file, chip: nil, family: nil, profile: nil))
        XCTAssertTrue(PanelManager.downloadModeNeedsChoice(
            candidates: file, chip: "esp32p4", family: "p4-4b", profile: nil))
        XCTAssertFalse(PanelManager.downloadModeNeedsChoice(
            candidates: file, chip: nil, family: "s3-085", profile: nil))

        let rows = PanelManager.firmwareFamilyChoices(candidates: file, chip: nil)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        for row in rows {
            let chosen = pick(file, chip: row.chip, family: row.family, profile: row.profile)
            XCTAssertNotNil(try? chosen.get(), "\(row.label): \(String(describing: title(chosen)))")
        }
        XCTAssertEqual(
            PanelManager.firmwareFamilyChoices(candidates: file, chip: "esp32p4").map(\.profile),
            ["st7703-4b"])
    }
}
