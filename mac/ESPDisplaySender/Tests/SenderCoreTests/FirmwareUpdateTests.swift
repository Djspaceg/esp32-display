import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// The app-side half of a firmware update: what a password has to be, where it is
/// kept, what a chosen bundle is said to mean, and when the control is offered at
/// all.
///
/// NOTHING HERE TOUCHES THE LOGIN KEYCHAIN, and that is not incidental. `swift
/// test` runs unsigned binaries, so a test that reached the real keychain would
/// either prompt or leave items behind on the machine running it. Every test uses
/// `InMemoryOTAPasswordStore` through the same protocol the app uses, so what is
/// exercised is the contract rather than a mock of it.
@MainActor
final class FirmwareUpdateTests: XCTestCase {

    // MARK: - password policy

    /// The bounds are the panel's, mirrored from `otapolicy::verifyPassword`, so
    /// the boundaries themselves are what matter: 7 is refused and 8 is accepted
    /// because that is where the firmware's floor is.
    func testPasswordLengthBoundsMatchTheFirmware() {
        XCTAssertEqual(OTAPasswordPolicy.minimumBytes, 8)
        XCTAssertEqual(OTAPasswordPolicy.maximumBytes, 64)

        XCTAssertEqual(
            OTAPasswordPolicy.judge(String(repeating: "a", count: 7)),
            .tooShort(bytes: 7))
        XCTAssertEqual(
            OTAPasswordPolicy.judge(String(repeating: "a", count: 8)), .accept)
        XCTAssertEqual(
            OTAPasswordPolicy.judge(String(repeating: "a", count: 64)), .accept)
        XCTAssertEqual(
            OTAPasswordPolicy.judge(String(repeating: "a", count: 65)),
            .tooLong(bytes: 65))
        XCTAssertEqual(OTAPasswordPolicy.judge(""), .tooShort(bytes: 0))
    }

    /// BYTES, NOT CHARACTERS. "pässwörd" is 8 grapheme clusters and 10 UTF-8
    /// bytes, and 10 is what the panel measures - so a policy counting characters
    /// would refuse a password the panel accepts. This is the same distinction
    /// `check_password_policy` draws in tools/espdisp.py.
    func testMultiByteUTF8IsMeasuredInBytes() {
        let short = "pässwörd"
        XCTAssertEqual(short.count, 8)
        XCTAssertEqual(short.utf8.count, 10)
        XCTAssertEqual(OTAPasswordPolicy.judge(short), .accept)

        // Four characters, and eight bytes: too short to a character count,
        // exactly at the floor to a byte count. The panel would accept it.
        let fourEmoji = "🔒🔒"
        XCTAssertEqual(fourEmoji.count, 2)
        XCTAssertEqual(fourEmoji.utf8.count, 8)
        XCTAssertEqual(OTAPasswordPolicy.judge(fourEmoji), .accept)

        // And the other way: 33 characters is under the ceiling, but 66 bytes is
        // over it.
        let wide = String(repeating: "ö", count: 33)
        XCTAssertEqual(wide.count, 33)
        XCTAssertEqual(wide.utf8.count, 66)
        XCTAssertEqual(OTAPasswordPolicy.judge(wide), .tooLong(bytes: 66))
    }

    /// A 0x00 refused for the reason ota_policy.h documents: every layer below
    /// the panel's OTA treats the password as a C string, so it would be stored
    /// cut short at that byte.
    func testEmbeddedNulIsRefused() {
        let password = "abcd\u{0}efghij"
        XCTAssertEqual(password.utf8.count, 11, "long enough on length alone")
        XCTAssertEqual(OTAPasswordPolicy.judge(password), .embeddedNul)
    }

    /// The NUL check comes first, so the answer names the disqualifying property
    /// rather than a length that was never going to be the stored length. Same
    /// ordering as the firmware.
    func testEmbeddedNulIsReportedBeforeLength() {
        // Three bytes, one of them zero: too short AND unstorable. The zero wins.
        XCTAssertEqual(OTAPasswordPolicy.judge("a\u{0}b"), .embeddedNul)
    }

    func testEveryRefusalExplainsItselfAndAcceptanceDoesNot() {
        XCTAssertNil(OTAPasswordPolicy.explain(.accept))
        let messages = [
            OTAPasswordPolicy.explain(.tooShort(bytes: 7)),
            OTAPasswordPolicy.explain(.tooLong(bytes: 65)),
            OTAPasswordPolicy.explain(.embeddedNul),
        ]
        XCTAssertEqual(messages.compactMap { $0 }.count, 3)
        XCTAssertEqual(Set(messages.compactMap { $0 }).count, 3, "each says its own thing")
        // Distinctness is not enough on its own: three messages can differ from
        // each other and still describe the wrong property, which is what a
        // mutation of the NUL message showed. Each one is matched on the thing it
        // is supposed to be about.
        XCTAssertTrue(
            OTAPasswordPolicy.explain(.embeddedNul)?.contains("zero byte") == true,
            "got: \(OTAPasswordPolicy.explain(.embeddedNul) ?? "nil")")
        // The numbers in the message are the panel's bounds, so a change to one
        // without the other is visible.
        XCTAssertTrue(
            OTAPasswordPolicy.explain(.tooShort(bytes: 7))?.contains("at least 8 bytes") == true)
        XCTAssertTrue(
            OTAPasswordPolicy.explain(.tooLong(bytes: 65))?.contains("at most 64 bytes") == true)
    }

    // MARK: - the password store

    func testStoreRoundTripsAndForgets() throws {
        let store = InMemoryOTAPasswordStore()
        XCTAssertNil(store.password(forHardwareID: "020000123456"))

        try store.store("a-real-password", forHardwareID: "020000123456")
        XCTAssertEqual(store.password(forHardwareID: "020000123456"), "a-real-password")

        // Storing again replaces rather than duplicating, which is the bug the
        // keychain implementation's update-then-add exists to avoid.
        try store.store("a-second-password", forHardwareID: "020000123456")
        XCTAssertEqual(store.password(forHardwareID: "020000123456"), "a-second-password")

        try store.remove(forHardwareID: "020000123456")
        XCTAssertNil(store.password(forHardwareID: "020000123456"))
        // Removing what is not there is the outcome the caller asked for.
        XCTAssertNoThrow(try store.remove(forHardwareID: "020000123456"))
    }

    func testStoreKeepsPanelsApart() throws {
        let store = InMemoryOTAPasswordStore()
        try store.store("first", forHardwareID: "020000111111")
        try store.store("second", forHardwareID: "020000222222")

        XCTAssertEqual(store.password(forHardwareID: "020000111111"), "first")
        XCTAssertEqual(store.password(forHardwareID: "020000222222"), "second")
        try store.remove(forHardwareID: "020000111111")
        XCTAssertEqual(store.password(forHardwareID: "020000222222"), "second")
    }

    /// THE REASON THE KEY IS THE HARDWARE ID. A rename changes the Bonjour
    /// service name and the display name; the EINF device ID does not move. Keyed
    /// on the name, the password would be lost the first time anyone renamed a
    /// panel, and the next update would silently ask for it again.
    func testPasswordSurvivesARename() throws {
        let store = InMemoryOTAPasswordStore()
        var panel = Self.panel(serviceName: "espdisplay", hardwareID: "020000123456")
        let manager = Self.manager([panel], store: store)
        _ = manager.setRememberedOTAPassword("a-real-password", for: "020000123456")

        // The same board comes back under a new service name, as it does after a
        // USB rename.
        panel.serviceName = "espdisplay-9050"
        panel.displayName = "espdisplay-9050"
        let renamed = Self.manager([panel], store: store)

        XCTAssertEqual(
            renamed.rememberedOTAPassword(for: "020000123456"), "a-real-password",
            "the password is filed under the hardware ID, not the service name")
    }

    /// The keychain's own account key, asserted at the level the app controls it:
    /// the manager looks a password up by the hardware ID it was given and by
    /// nothing else, so a panel that reports a different ID gets no password.
    func testAPanelWithADifferentHardwareIDGetsNoPassword() {
        let store = InMemoryOTAPasswordStore(["020000123456": "a-real-password"])
        let manager = Self.manager(
            [Self.panel(serviceName: "espdisplay", hardwareID: "0200009999FF")],
            store: store)

        XCTAssertNil(manager.rememberedOTAPassword(for: "0200009999FF"))
        XCTAssertEqual(
            manager.rememberedOTAPassword(for: "020000123456"), "a-real-password")
    }

    /// The service name is fixed, and the account is the hardware ID. Pinned
    /// because changing either one orphans every password already stored.
    func testKeychainServiceNameIsPinned() {
        XCTAssertEqual(KeychainOTAPasswordStore.service, "com.espdisplay.sender.ota")
    }

    func testUntickingRememberForgetsTheStoredPassword() {
        let store = InMemoryOTAPasswordStore(["020000123456": "a-real-password"])
        let manager = Self.manager(
            [Self.panel(serviceName: "espdisplay", hardwareID: "020000123456")],
            store: store)

        XCTAssertNil(manager.setRememberedOTAPassword(nil, for: "020000123456"))
        XCTAssertNil(store.password(forHardwareID: "020000123456"))
    }

    /// A store that will not write is reported rather than swallowed, and the
    /// message is the store's own.
    func testAStoreThatRefusesIsReported() {
        let store = InMemoryOTAPasswordStore()
        store.writesFail = true
        let manager = Self.manager(
            [Self.panel(serviceName: "espdisplay", hardwareID: "020000123456")],
            store: store)

        let failure = manager.setRememberedOTAPassword("a-real-password", for: "020000123456")
        XCTAssertNotNil(failure)
        XCTAssertTrue(failure?.contains("Keychain") == true, "got: \(failure ?? "nil")")
    }

    // MARK: - setting/clearing the password over USB
    //
    // The serial round trip itself needs hardware and is verified manually
    // against a board; what is tested here is what happens on either side of
    // it: an invalid password never reaches the serial layer at all, and a
    // successful set/clear keeps the Keychain copy in sync with what was
    // just sent. `WifiConfigUI.setOTAPassword`/`clearOTAPassword` fail with
    // "No device found" in this environment (no USB device is attached to a
    // test run), which is itself useful signal - it proves validation ran
    // and failed the way an unreachable panel fails, not the way a rejected
    // password fails.

    /// An invalid password is refused before any serial command is built, so
    /// a typo costs nothing and never restarts a panel that was never going
    /// to accept it.
    func testSetOTAPasswordRefusesAnInvalidPasswordBeforeAnySerialWrite() {
        let manager = Self.manager(
            [Self.panel(serviceName: "espdisplay", hardwareID: "020000123456")])
        manager.register(Self.session(name: "espdisplay"))

        manager.setOTAPassword("short", remember: true, for: "espdisplay")

        XCTAssertEqual(manager.operationOutcome?.kind, .failure)
        XCTAssertEqual(manager.operationOutcome?.title, "Invalid OTA password")
        XCTAssertTrue(
            manager.operationOutcome?.message.contains("at least 8 bytes") == true,
            "got: \(manager.operationOutcome?.message ?? "nil")")
        // Nothing was remembered for a password that was never sent.
        XCTAssertNil(manager.rememberedOTAPassword(for: "020000123456"))
    }

    /// A valid password reaches the serial layer - which fails here for lack
    /// of hardware, not for lack of validity - and the failure is reported
    /// through the same outcome alert as every other USB action, not through
    /// the "Invalid OTA password" title that a rejected password gets.
    func testSetOTAPasswordWithAValidPasswordReachesTheSerialLayer() {
        let manager = Self.manager(
            [Self.panel(serviceName: "espdisplay", hardwareID: "020000123456")])
        manager.register(Self.session(name: "espdisplay"))

        manager.setOTAPassword("a-real-password", remember: true, for: "espdisplay")

        XCTAssertEqual(manager.operationOutcome?.kind, .failure)
        XCTAssertNotEqual(manager.operationOutcome?.title, "Invalid OTA password")
        // No USB device answered, so nothing was actually set - and nothing
        // should have been remembered for a password that never reached the
        // panel.
        XCTAssertNil(manager.rememberedOTAPassword(for: "020000123456"))
    }

    /// A panel not known to the manager is a no-op rather than a crash - the
    /// same defensive stance `rename`/`applySavedNetwork` take for an
    /// unrecognised service name.
    func testSetAndClearOTAPasswordIgnoreAnUnknownPanel() {
        let manager = Self.manager()
        manager.setOTAPassword("a-real-password", remember: true, for: "ghost")
        manager.clearOTAPassword(for: "ghost")
        XCTAssertNil(manager.operationOutcome)
    }

    // MARK: - readiness
    //
    // Which panels are offered an update at all, and the wording of the refusal,
    // are in PanelManagerTests with the rest of the capability gating.

    func testReadinessGathersEverythingAPushNeeds() throws {
        let manager = Self.manager()
        let session = Self.session(name: "espdisplay")
        manager.register(session)
        manager.noteDiscovery([Self.device("espdisplay", chip: "esp32c6")])
        manager.update(
            .info(try Self.info(
                name: "espdisplay", deviceID: [2, 0, 0, 0x12, 0x34, 0x56],
                capabilities: .ota, firmware: "1.1.0")),
            for: "espdisplay")

        // No socket has been opened - `run()` is never called here - so the
        // address is not resolved, and the readiness check says so instead of
        // guessing.
        guard case .notReady(let reason) =
            manager.firmwareUpdateReadiness("espdisplay")
        else { return XCTFail("an unresolved address cannot be ready") }
        XCTAssertTrue(reason.contains("address"), "got: \(reason)")
        XCTAssertNil(manager.beginFirmwareUpdate("espdisplay"))
        // And the refusal reaches the user through the same alert as every other
        // device action rather than being dropped.
        XCTAssertEqual(manager.operationOutcome?.kind, .failure)
    }

    /// The two facts a push needs beyond a reachable panel, and the order the
    /// readiness check asks for them in.
    ///
    /// Both of these are defensive: a panel that advertises capabilities has
    /// reported an EINF, and an EINF carries the device ID and the firmware
    /// version in the same packet, so neither can be missing on a panel that got
    /// this far in practice. They are still checked, because the update flow needs
    /// a key to file the password under and a version to compare a bundle
    /// against, and "cannot" is a better answer than a blank. What the test pins
    /// is the contract of the function rather than a route through the UI - the
    /// same stance FEAT-003 took about `discovery_seconds(0)`.
    func testReadinessNeedsAHardwareIDAndAVersion() {
        var noID = Self.panel(
            serviceName: "espdisplay", hardwareID: "020000123456", capabilities: .ota)
        noID.hardwareID = nil
        let withoutID = Self.manager([noID])
        withoutID.register(Self.session(name: "espdisplay"))
        guard case .notReady(let idReason) =
            withoutID.firmwareUpdateReadiness("espdisplay")
        else { return XCTFail("no hardware ID means nowhere to keep the password") }
        XCTAssertTrue(idReason.contains("hardware ID"), "got: \(idReason)")

        var noVersion = Self.panel(
            serviceName: "espdisplay", hardwareID: "020000123456", capabilities: .ota)
        noVersion.firmwareVersion = nil
        let withoutVersion = Self.manager([noVersion])
        withoutVersion.register(Self.session(name: "espdisplay"))
        guard case .notReady(let versionReason) =
            withoutVersion.firmwareUpdateReadiness("espdisplay")
        else { return XCTFail("no version means nothing to compare against") }
        XCTAssertTrue(versionReason.contains("firmware version"), "got: \(versionReason)")
        XCTAssertNotEqual(idReason, versionReason, "two facts, two answers")
    }

    /// THE STALE ADDRESS HAZARD. `PanelSnapshot.address` is persisted, so a panel
    /// record loaded from disk carries whatever IP it had last time. An update is
    /// sent to an address directly rather than through the streaming socket, so
    /// taking that one would mean pushing two megabytes of firmware at whatever
    /// now holds it. The readiness check reads the LIVE session's resolved address
    /// and nothing else, which is why a panel with a remembered address but no
    /// resolved socket is still not ready.
    func testARememberedAddressIsNotGoodEnough() throws {
        var panel = Self.panel(
            serviceName: "espdisplay", hardwareID: "020000123456", capabilities: .ota)
        panel.address = "192.168.1.120"
        let manager = Self.manager([panel])
        manager.register(Self.session(name: "espdisplay"))

        XCTAssertEqual(manager.panels.first?.address, "192.168.1.120")
        guard case .notReady(let reason) =
            manager.firmwareUpdateReadiness("espdisplay")
        else {
            return XCTFail("a persisted address must not stand in for a resolved one")
        }
        XCTAssertTrue(reason.contains("address"), "got: \(reason)")
    }

    /// A panel with no CAP_OTA is refused with the actionable reason, through the
    /// readiness check as well as through the button's disabled state, so the two
    /// cannot disagree.
    func testReadinessRefusesAPanelWithoutOTA() throws {
        let manager = Self.manager()
        manager.register(Self.session(name: "espdisplay"))
        manager.update(
            .info(try Self.info(
                name: "espdisplay", deviceID: [2, 0, 0, 0x12, 0x34, 0x56],
                capabilities: .restart)),
            for: "espdisplay")

        guard case .notReady(let reason) =
            manager.firmwareUpdateReadiness("espdisplay")
        else { return XCTFail("a panel without CAP_OTA is not ready") }
        XCTAssertTrue(reason.contains("set-password"), "got: \(reason)")
    }

    // MARK: - what a bundle means for a panel

    /// The ordinary case, and the one sentence that has to be right: the version
    /// the panel is on and the version it would go to.
    func testNewerBundleOffersAnUpdate() throws {
        let plan = try Self.plan(bundleVersion: "1.3.0", panelVersion: "1.2.0")

        XCTAssertEqual(plan.action, .update)
        XCTAssertEqual(plan.verb, "Update")
        XCTAssertTrue(plan.canPush)
        XCTAssertFalse(plan.isCautionary)
        XCTAssertTrue(plan.headline.contains("1.3.0"), "got: \(plan.headline)")
        XCTAssertTrue(plan.detail.contains("1.2.0"), "got: \(plan.detail)")
    }

    func testSameVersionIsAReinstallNotAnUpdate() throws {
        let plan = try Self.plan(bundleVersion: "1.2.0", panelVersion: "1.2.0")

        XCTAssertEqual(plan.action, .reinstall)
        XCTAssertEqual(plan.verb, "Reinstall")
        XCTAssertTrue(plan.canPush, "reinstalling is a legitimate recovery move")
    }

    /// The case a boolean would get wrong. An older bundle is offered, because
    /// going back after a bad release is a real thing to want, but it is never
    /// called an update and its confirmation is the cautionary one.
    func testOlderBundleIsADowngradeAndSaysSo() throws {
        let plan = try Self.plan(bundleVersion: "1.1.0", panelVersion: "1.2.0")

        XCTAssertEqual(plan.action, .downgrade)
        XCTAssertEqual(plan.verb, "Downgrade")
        XCTAssertTrue(plan.canPush)
        XCTAssertTrue(plan.isCautionary)
        XCTAssertTrue(plan.detail.contains("downgrade"), "got: \(plan.detail)")
        XCTAssertFalse(
            plan.headline.lowercased().contains("update"),
            "a downgrade must not be labelled an update; got: \(plan.headline)")
    }

    func testIncomparableVersionsSayTheyCannotBeCompared() throws {
        let plan = try Self.plan(bundleVersion: "nightly-42", panelVersion: "1.2.0")

        XCTAssertEqual(plan.action, .uncertain)
        XCTAssertEqual(plan.verb, "Push")
        XCTAssertTrue(plan.canPush)
        XCTAssertTrue(plan.isCautionary)
        XCTAssertTrue(plan.detail.contains("nightly-42"), "got: \(plan.detail)")
        XCTAssertTrue(plan.detail.contains("1.2.0"), "got: \(plan.detail)")
    }

    /// The only genuinely wrong file: the panel said what it is and this bundle
    /// has nothing for it. Refused, and the message names both sides.
    func testNoImageForThisChipIsBlocked() throws {
        let bundle = try Self.bundle(version: "1.3.0", chips: ["esp32s3"])
        let plan = FirmwareUpdatePlan.make(
            bundle.availability(forChip: "esp32c6", panelVersion: "1.2.0"),
            chipConfirmed: true)

        XCTAssertEqual(plan.action, .blocked)
        XCTAssertFalse(plan.canPush)
        XCTAssertTrue(plan.detail.contains("esp32c6"), "got: \(plan.detail)")
        XCTAssertTrue(plan.detail.contains("esp32s3"), "got: \(plan.detail)")
    }

    /// An unknown chip is missing information, not a contradiction. The push is
    /// offered once an image is chosen by hand, with the caveat attached - and
    /// nil and the firmware's "unknown" token behave the same way.
    func testUnknownChipAsksForAnImageRatherThanRefusing() throws {
        let bundle = try Self.bundle(version: "1.3.0", chips: ["esp32c6", "esp32s3"])

        for reported in [nil, ServiceMetadata.unknownChip, ""] as [String?] {
            let plan = FirmwareUpdatePlan.make(
                bundle.availability(forChip: reported, panelVersion: "1.2.0"),
                chipConfirmed: false)
            XCTAssertEqual(plan.action, .chooseImage, "for chip \(reported ?? "nil")")
            XCTAssertFalse(plan.canPush, "nothing to push until an image is chosen")
            XCTAssertTrue(plan.detail.contains("esp32c6"), "got: \(plan.detail)")
            XCTAssertTrue(plan.detail.contains("esp32s3"), "got: \(plan.detail)")
        }

        // Once the user picks one, it becomes an ordinary verdict plus a warning.
        let chosen = FirmwareUpdatePlan.make(
            bundle.availability(forChip: "esp32c6", panelVersion: "1.2.0"),
            chipConfirmed: false)
        XCTAssertEqual(chosen.action, .update)
        XCTAssertTrue(chosen.canPush)
        XCTAssertTrue(
            chosen.detail.contains("did not report which chip"), "got: \(chosen.detail)")
        XCTAssertTrue(
            chosen.detail.contains("refused rather than installed"),
            "the warning has to say what a wrong choice costs; got: \(chosen.detail)")
    }

    /// The caveat appears only when the chip was NOT confirmed. Without this, a
    /// panel that reported its chip perfectly well would be warned about a
    /// guess nobody made.
    func testConfirmedChipCarriesNoCaveat() throws {
        let plan = try Self.plan(bundleVersion: "1.3.0", panelVersion: "1.2.0")

        XCTAssertFalse(plan.detail.contains("chosen by hand"), "got: \(plan.detail)")
        XCTAssertFalse(
            plan.detail.contains("did not report which chip"), "got: \(plan.detail)")
    }

    /// All six answers are reachable and none of them says the same thing as
    /// another. This is the acceptance criterion for the sheet stated as a test:
    /// the point of the type is that the awkward cases are told apart.
    func testEveryVerdictIsDistinct() throws {
        let twoChip = try Self.bundle(version: "1.3.0", chips: ["esp32c6", "esp32s3"])
        let older = try Self.bundle(version: "1.1.0", chips: ["esp32c6"])
        let same = try Self.bundle(version: "1.2.0", chips: ["esp32c6"])
        let odd = try Self.bundle(version: "nightly-42", chips: ["esp32c6"])
        let wrong = try Self.bundle(version: "1.3.0", chips: ["esp32s3"])

        let plans = [
            FirmwareUpdatePlan.make(
                twoChip.availability(forChip: "esp32c6", panelVersion: "1.2.0"),
                chipConfirmed: true),
            FirmwareUpdatePlan.make(
                same.availability(forChip: "esp32c6", panelVersion: "1.2.0"),
                chipConfirmed: true),
            FirmwareUpdatePlan.make(
                older.availability(forChip: "esp32c6", panelVersion: "1.2.0"),
                chipConfirmed: true),
            FirmwareUpdatePlan.make(
                odd.availability(forChip: "esp32c6", panelVersion: "1.2.0"),
                chipConfirmed: true),
            FirmwareUpdatePlan.make(
                wrong.availability(forChip: "esp32c6", panelVersion: "1.2.0"),
                chipConfirmed: true),
            FirmwareUpdatePlan.make(
                twoChip.availability(forChip: nil, panelVersion: "1.2.0"),
                chipConfirmed: false),
        ]

        XCTAssertEqual(Set(plans.map(\.action)).count, 6, "six distinct actions")
        XCTAssertEqual(Set(plans.map(\.headline)).count, 6, "six distinct headlines")
        XCTAssertEqual(Set(plans.map(\.detail)).count, 6, "six distinct explanations")
        // Exactly two are refusals, and they are the two where no image can be
        // sent: the wrong file, and no chosen image.
        XCTAssertEqual(plans.filter { !$0.canPush }.count, 2)
    }

    /// A one-image bundle names its single chip in the singular, because "images
    /// for esp32c6" reads like there are several.
    func testSingleImageBundleIsDescribedInTheSingular() throws {
        let bundle = try Self.bundle(version: "1.3.0", chips: ["esp32c6"])
        let plan = FirmwareUpdatePlan.make(
            bundle.availability(forChip: nil, panelVersion: "1.2.0"),
            chipConfirmed: false)

        XCTAssertTrue(plan.detail.contains("an image for esp32c6"), "got: \(plan.detail)")
    }

    // MARK: - helpers

    private static func manager(
        _ panels: [PanelSnapshot] = [],
        store: OTAPasswordStoring = InMemoryOTAPasswordStore()
    ) -> PanelManager {
        PanelManager(
            previewPanels: panels, savedNetworkNames: [], usbSerialPorts: [],
            otaPasswords: store)
    }

    /// A session that is registered but never started: `DeviceSession.init` and
    /// `FrameSender.init` only store their arguments, and nothing here calls
    /// `run()`, so no socket is opened and no address is resolved.
    private static func session(name: String) -> DeviceSession {
        DeviceSession(
            name: name,
            sender: FrameSender(host: "127.0.0.1", port: 5568),
            source: .auto(defaultDisplay: ""),
            picker: nil,
            fps: 30)
    }

    private static func device(_ name: String, chip: String) -> DeviceBrowser.Device {
        DeviceBrowser.Device(
            name: name,
            endpoint: .hostPort(host: "127.0.0.1", port: 5568),
            metadata: ServiceMetadata(txtRecords: ["chip": chip]))
    }

    private static func panel(
        serviceName: String,
        hardwareID: String,
        capabilities: DeviceProtocol.Capabilities = .ota,
        heartbeatAt: Date = Date()
    ) -> PanelSnapshot {
        PanelSnapshot(
            serviceName: serviceName,
            displayName: serviceName,
            hardwareID: hardwareID,
            lastSeen: heartbeatAt,
            lastHeartbeatAt: heartbeatAt,
            firmwareVersion: "1.2.0",
            controlProtocolVersion: Int(DeviceProtocol.controlProtocolVersion),
            capabilitiesRaw: capabilities.rawValue)
    }

    /// A real `DeviceInfo`, built by encoding an EINF packet and parsing it, so
    /// these tests cannot drift from the wire format the firmware sends. Same
    /// shape as the helper in PanelManagerTests.
    private static func info(
        name: String,
        deviceID: [UInt8],
        capabilities: DeviceProtocol.Capabilities,
        controlProtocolVersion: UInt8 = DeviceProtocol.controlProtocolVersion,
        firmware: String = "1.2.0"
    ) throws -> DeviceProtocol.DeviceInfo {
        var packet = Data("EINF".utf8)
        packet.append(contentsOf: [
            DeviceProtocol.infoVersion,
            DeviceProtocol.frameProtocolVersion,
            controlProtocolVersion,
            0x11,
        ])
        packet.append(contentsOf: [
            UInt8(capabilities.rawValue & 0xFF),
            UInt8((capabilities.rawValue >> 8) & 0xFF),
            UInt8((capabilities.rawValue >> 16) & 0xFF),
            UInt8((capabilities.rawValue >> 24) & 0xFF),
        ])
        packet.append(contentsOf: [0x3C, 0x00, 0x00, 0x00])
        packet.append(contentsOf: [0xCC, 0xFF])
        packet.append(255)
        packet.append(UInt8(name.utf8.count))
        packet.append(UInt8(firmware.utf8.count))
        packet.append(contentsOf: deviceID)
        packet.append(contentsOf: name.utf8)
        packet.append(contentsOf: firmware.utf8)
        return try XCTUnwrap(DeviceProtocol.parseInfo(packet), "EINF vector is malformed")
    }

    private static func plan(
        bundleVersion: String, panelVersion: String, chip: String = "esp32c6"
    ) throws -> FirmwareUpdatePlan {
        let bundle = try Self.bundle(version: bundleVersion, chips: [chip])
        return FirmwareUpdatePlan.make(
            bundle.availability(forChip: chip, panelVersion: panelVersion),
            chipConfirmed: true)
    }

    /// The update path answers the same way for a generation-1 bundle.
    ///
    /// The point of reading both generations, stated as a test rather than left as
    /// a comment: a v1 file cannot bring up a blank board and is still a perfectly
    /// good OTA payload, and the person holding one may have no way to rebuild it.
    /// Nothing on this path asks about flash parts - it reads `payload(forChip:)`
    /// and the version - so every verdict has to come out identical.
    func testTheUpdatePathIsUnchangedByTheBundleGeneration() throws {
        for chipConfirmed in [true, false] {
            for (bundleVersion, panelVersion) in [
                ("1.3.0", "1.2.0"), ("1.2.0", "1.2.0"), ("1.1.0", "1.2.0"),
                ("1.3.0", "nightly"),
            ] {
                let new = try Self.bundle(version: bundleVersion, chips: ["esp32c6"])
                let old = try Self.bundle(
                    version: bundleVersion, chips: ["esp32c6"],
                    generation: FirmwareBundle.formatV1)
                XCTAssertEqual(old.format, 1)
                XCTAssertEqual(new.format, 2)
                XCTAssertEqual(
                    old.payload(forChip: "esp32c6"), new.payload(forChip: "esp32c6"),
                    "the OTA payload is the same bytes in both generations")
                let fromOld = FirmwareUpdatePlan.make(
                    old.availability(forChip: "esp32c6", panelVersion: panelVersion),
                    chipConfirmed: chipConfirmed)
                let fromNew = FirmwareUpdatePlan.make(
                    new.availability(forChip: "esp32c6", panelVersion: panelVersion),
                    chipConfirmed: chipConfirmed)
                XCTAssertEqual(
                    fromOld, fromNew,
                    "\(bundleVersion) over \(panelVersion) must read the same either way")
            }
        }
    }

    /// A valid bundle, assembled here rather than read from a fixture.
    ///
    /// Built through the real reader so the plan tests are working with a bundle
    /// that would actually be accepted from a file, and written by hand for the
    /// reason FirmwareBundleTests gives at length: a fixture agrees with whatever
    /// produced it.
    ///
    /// `generation` decides whether the file carries the parts a blank board needs.
    /// The default is the current generation, so these tests run against what the
    /// tool writes today; `testTheUpdatePathIsUnchangedByTheBundleGeneration` is
    /// what pins that an older file still answers the same questions.
    private static func bundle(
        version: String, chips: [String], generation: Int = FirmwareBundle.format
    ) throws -> FirmwareBundle {
        let payloads = chips.enumerated().map { index, chip in
            Data("image for \(chip) ".utf8) + Data(repeating: UInt8(index + 1), count: 8)
        }
        // The three parts a board with nothing on it needs, at the addresses
        // boards.txt and the core's upload recipe give them. Distinct per chip so a
        // reader that mixed two boards up could not pass.
        func parts(for chip: String) -> [(role: String, address: Int, payload: Data)] {
            [
                ("bootloader", 0x0, Data([0xE9]) + Data("\(chip) boot\n".utf8)),
                ("partitions", 0x8000, Data([0xAA, 0x50]) + Data("\(chip)\n".utf8)),
                ("boot_app0", 0xE000, Data("ota \(chip)\n".utf8)),
            ]
        }
        var manifest: [String: Any] = [
            "format": generation,
            "firmware_version": version,
            "built_at": "2026-01-02T03:04:05Z",
            "source_commit": String(repeating: "a", count: 40),
            "source_dirty": false,
            "tool": "espdisp.py bundle",
            "images": zip(chips, payloads).map { chip, payload in
                var entry: [String: Any] = [
                    "board": String(chip.dropFirst("esp32".count)),
                    "chip": chip,
                    "fqbn": "esp32:esp32:\(chip)",
                    "filename": "display_stream.ino.bin",
                    "offset": 0,
                    "bytes": payload.count,
                    "sha256": FirmwareBundle.sha256Hex(payload),
                ]
                if generation != FirmwareBundle.formatV1 {
                    entry["app_address"] = 0x10000
                    entry["flash_parts"] = parts(for: chip).map { part in
                        [
                            "role": part.role,
                            "address": part.address,
                            "filename": "\(part.role).bin",
                            "offset": 0,
                            "bytes": part.payload.count,
                            "sha256": FirmwareBundle.sha256Hex(part.payload),
                        ] as [String: Any]
                    }
                }
                return entry
            },
        ]
        // The offsets are absolute from the start of the file, so the manifest
        // describes its own length: assign, re-encode, repeat until it stops
        // moving. The same solve tools/espdisp.py does when it writes one, over the
        // same payload order - each image, then that image's flash parts.
        var encodedLength = -1
        var encoded = Data()
        while true {
            encoded = try JSONSerialization.data(
                withJSONObject: manifest, options: [.sortedKeys])
            if encoded.count == encodedLength { break }
            encodedLength = encoded.count
            var cursor = FirmwareBundle.headerBytes + encoded.count
            var images = manifest["images"] as! [[String: Any]]
            for index in images.indices {
                images[index]["offset"] = cursor
                cursor += images[index]["bytes"] as! Int
                if var flashParts = images[index]["flash_parts"] as? [[String: Any]] {
                    for partIndex in flashParts.indices {
                        flashParts[partIndex]["offset"] = cursor
                        cursor += flashParts[partIndex]["bytes"] as! Int
                    }
                    images[index]["flash_parts"] = flashParts
                }
            }
            manifest["images"] = images
        }
        let lengthLine = Data(String(format: "%010d\n", encoded.count).utf8)
        let area = zip(chips, payloads).reduce(Data()) { area, pair in
            guard generation != FirmwareBundle.formatV1 else { return area + pair.1 }
            return parts(for: pair.0).reduce(area + pair.1) { $0 + $1.payload }
        }
        let file = (generation == FirmwareBundle.formatV1
            ? FirmwareBundle.magicV1 : FirmwareBundle.magic)
            + lengthLine + encoded + area
        return try FirmwareBundle.read(file)
    }
}
