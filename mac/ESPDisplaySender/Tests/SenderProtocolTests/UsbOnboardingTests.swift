import XCTest
@testable import SenderProtocol

/// What the app decides while onboarding a board over USB.
///
/// Held to the standard `FirmwareUpdatePlanTests` set: every case reachable, every
/// case saying something different from every other, and a definite contradiction
/// refusing while missing information does not. The sheet is not tested; everything
/// it decides is decided here.
final class UsbOnboardingTests: XCTestCase {

    // MARK: - fixtures

    private let tool = UsbOnboarding.ToolAvailability.installed(
        path: "/core/esptool_py/5.3.1/esptool")
    private let ports = ["/dev/cu.usbmodem101"]

    /// A request that is ready to go, which every test below breaks in exactly one
    /// way. Written this way on purpose: a test that assembles its own request from
    /// scratch can pass because of a field it forgot rather than the field it meant.
    private func ready(
        mode: UsbOnboarding.Mode = .flashAndConfigure,
        chip: String = "esp32s3"
    ) -> UsbOnboarding.Request {
        UsbOnboarding.Request(
            port: "/dev/cu.usbmodem101",
            availablePorts: ports,
            mode: mode,
            tool: tool,
            bundle: EsptoolCommandTests.bundle(chip: chip, bootloader: 0x0, app: 0x10000),
            detection: .detected(chip: chip, mac: "28:84:85:55:55:94"),
            existing: .silent,
            ssid: "Home",
            credential: .ready(.set("hunter2hunter2")))
    }

    // MARK: - the ready cases

    func testAReadyRequestOffersToFlash() {
        let plan = UsbOnboardingPlan.make(ready())
        XCTAssertEqual(plan.action, .flash)
        XCTAssertTrue(plan.canStart)
        XCTAssertTrue(plan.writesFlash)
        XCTAssertEqual(plan.verb, "Flash and Add")
        // The detail says what will be written and where the parts came from, and
        // names the network the board is going to try.
        XCTAssertTrue(plan.headline.contains("1.2.0"))
        XCTAssertTrue(plan.headline.contains("esp32s3"))
        XCTAssertTrue(plan.detail.contains("\"Home\""))
        XCTAssertTrue(plan.detail.contains("4 parts"))
    }

    func testConfigureOnlyDoesNotWriteFlashAndSaysSo() {
        var request = ready(mode: .configureOnly)
        request.existing = .answered(name: "desk-panel")
        let plan = UsbOnboardingPlan.make(request)
        XCTAssertEqual(plan.action, .configureOnly)
        XCTAssertTrue(plan.canStart)
        XCTAssertFalse(plan.writesFlash)
        XCTAssertEqual(plan.verb, "Set Up WiFi")
        XCTAssertTrue(plan.detail.contains("desk-panel"))
        XCTAssertTrue(plan.detail.contains("firmware on it is left alone"))
    }

    /// Configure-only needs no esptool and no bundle at all: nothing is written, so
    /// a Mac without the esp32 core can still adopt a board that already works.
    func testConfigureOnlyNeedsNeitherEsptoolNorABundle() {
        var request = ready(mode: .configureOnly)
        request.tool = .missing(searched: ["/nowhere"])
        request.bundle = nil
        request.detection = .notAttempted
        request.existing = .answered(name: "")
        XCTAssertEqual(UsbOnboardingPlan.make(request).action, .configureOnly)
    }

    // MARK: - the device

    func testNoPortAndNoDevicesAsksForTheCable() {
        var request = ready()
        request.port = ""
        request.availablePorts = []
        let plan = UsbOnboardingPlan.make(request)
        XCTAssertEqual(plan.action, .connectDevice)
        XCTAssertFalse(plan.canStart)
        // The charge-only cable is the single most common cause of a board that is
        // powered and invisible, so it is named.
        XCTAssertTrue(plan.detail.contains("charge-only"))
    }

    /// A DIFFERENT SENTENCE from the one above, because it is a different situation:
    /// there is something to pick.
    func testNoPortWithDevicesPresentAsksForAChoice() {
        var request = ready()
        request.port = ""
        let plan = UsbOnboardingPlan.make(request)
        XCTAssertEqual(plan.action, .chooseDevice)
        XCTAssertNotEqual(plan.detail, UsbOnboardingPlan.make({
            var empty = request
            empty.availablePorts = []
            return empty
        }()).detail)
    }

    func testAWhitespacePortCountsAsNoPort() {
        var request = ready()
        request.port = "   "
        XCTAssertEqual(UsbOnboardingPlan.make(request).action, .chooseDevice)
    }

    /// The port is checked before anything else, including before the missing
    /// esptool: a request with two things wrong asks for the one that has to come
    /// first.
    func testThePortIsAskedForBeforeTheTool() {
        var request = ready()
        request.port = ""
        request.tool = .missing(searched: ["/nowhere"])
        XCTAssertEqual(UsbOnboardingPlan.make(request).action, .chooseDevice)
    }

    // MARK: - missing information does not refuse

    /// The chip not being read yet is a step, not a problem, and it must not read
    /// like one.
    func testAChipThatHasNotBeenReadYetIsAStep() {
        var request = ready()
        request.detection = .notAttempted
        let plan = UsbOnboardingPlan.make(request)
        XCTAssertEqual(plan.action, .detectChip)
        XCTAssertFalse(plan.canStart)
        XCTAssertTrue(plan.detail.contains("read off the board"))
    }

    /// Read and failed IS different: something is wrong with the board, the cable
    /// or the port, and the message says which three.
    func testAChipThatCouldNotBeReadSaysWhatLooksLikeThat() {
        var request = ready()
        request.detection = .failed(reason: "A fatal error occurred: no serial data received.")
        let plan = UsbOnboardingPlan.make(request)
        XCTAssertEqual(plan.action, .chipUnreadable)
        XCTAssertFalse(plan.canStart)
        XCTAssertTrue(plan.detail.contains("no serial data received"))
        XCTAssertTrue(plan.detail.contains("Nothing is written to a board that has not said"))
    }

    // MARK: - definite contradictions refuse

    /// The wrong file: the board said what it is and the bundle has nothing for it.
    func testABundleWithNoImageForThisChipIsRefusedByName() {
        var request = ready()
        request.detection = .detected(chip: "esp32c6", mac: nil)
        let plan = UsbOnboardingPlan.make(request)
        XCTAssertEqual(plan.action, .noImageForChip)
        XCTAssertFalse(plan.canStart)
        XCTAssertTrue(plan.detail.contains("esp32c6"))
        XCTAssertTrue(plan.detail.contains("an image for esp32s3"))
    }

    /// A generation-1 bundle is the RIGHT file for a different job, so it is refused
    /// for this one by name and told it is still good for an update.
    func testAnOTAOnlyBundleIsRefusedForABlankBoardAndSaidToBeUsefulStill() {
        var request = ready()
        request.bundle = EsptoolCommandTests.otaOnlyBundle(chip: "esp32s3")
        let plan = UsbOnboardingPlan.make(request)
        XCTAssertEqual(plan.action, .bundleIsOTAOnly)
        XCTAssertFalse(plan.canStart)
        XCTAssertTrue(plan.detail.contains("format 1"))
        XCTAssertTrue(plan.detail.contains("over-the-air"))
        XCTAssertTrue(plan.detail.contains("bootloader"))
    }

    /// And the two are told apart. A v1 bundle DOES have an image for the chip, so a
    /// classifier that only asked `flashPlan == nil` would report the wrong one of
    /// these two.
    func testTheOTAOnlyRefusalIsNotTheWrongChipRefusal() {
        var otaOnly = ready()
        otaOnly.bundle = EsptoolCommandTests.otaOnlyBundle(chip: "esp32s3")
        var wrongChip = ready()
        wrongChip.detection = .detected(chip: "esp32c6", mac: nil)
        XCTAssertNotEqual(
            UsbOnboardingPlan.make(otaOnly).action,
            UsbOnboardingPlan.make(wrongChip).action)
        XCTAssertNotEqual(
            UsbOnboardingPlan.make(otaOnly).headline,
            UsbOnboardingPlan.make(wrongChip).headline)
    }

    /// A bundle whose image is missing one of the three required roles cannot bring
    /// up a blank board either, and lands in the same case as a v1 file - which is
    /// right, because for this purpose it is the same problem.
    func testAnImageMissingAFlashPartCannotFlashABlankBoard() {
        var request = ready()
        let full = EsptoolCommandTests.bundle(
            chip: "esp32s3", bootloader: 0x0, app: 0x10000)
        let image = full.images[0]
        let stripped = FirmwareBundle.Image(
            board: image.board, chip: image.chip, fqbn: image.fqbn,
            filename: image.filename, offset: image.offset,
            byteCount: image.byteCount, sha256: image.sha256,
            appAddress: image.appAddress,
            flashParts: image.flashParts.filter { $0.role != "boot_app0" })
        request.bundle = FirmwareBundle(
            format: full.format, firmwareVersion: full.firmwareVersion,
            builtAt: full.builtAt, sourceCommit: full.sourceCommit,
            sourceDirty: full.sourceDirty, tool: full.tool,
            images: [stripped], payloads: full.payloads,
            flashPayloads: full.flashPayloads)
        XCTAssertEqual(UsbOnboardingPlan.make(request).action, .bundleIsOTAOnly)
    }

    func testNoBundleAtAllAsksForOne() {
        var request = ready()
        request.bundle = nil
        let plan = UsbOnboardingPlan.make(request)
        XCTAssertEqual(plan.action, .chooseBundle)
        XCTAssertTrue(plan.detail.contains("espdisp.py bundle"))
    }

    // MARK: - the tool

    /// The cost of shelling out to esptool, surfaced rather than hidden: the message
    /// names the fix, names where it looked, and names the route that works today.
    func testAMissingEsptoolNamesTheFixAndWhereItLooked() {
        var request = ready()
        request.tool = .missing(searched: [
            "/Users/x/Library/Arduino15/packages/esp32/tools/esptool_py",
        ])
        let plan = UsbOnboardingPlan.make(request)
        XCTAssertEqual(plan.action, .esptoolMissing)
        XCTAssertFalse(plan.canStart)
        XCTAssertTrue(plan.detail.contains("arduino-cli core install esp32:esp32"))
        XCTAssertTrue(plan.detail.contains("tools/espdisp.py flash"))
        XCTAssertTrue(plan.detail.contains("Library/Arduino15"))
    }

    /// Before the chip, because reading the chip IS an esptool run: a request with
    /// no tool and no detection has to be told about the tool.
    func testTheToolIsReportedBeforeTheChip() {
        var request = ready()
        request.tool = .missing(searched: [])
        request.detection = .notAttempted
        XCTAssertEqual(UsbOnboardingPlan.make(request).action, .esptoolMissing)
    }

    // MARK: - the network

    func testNoNetworkIsRefusedForBothModes() {
        for mode in UsbOnboarding.Mode.allCases {
            var request = ready(mode: mode)
            request.existing = .answered(name: "panel")
            request.ssid = "   "
            let plan = UsbOnboardingPlan.make(request)
            XCTAssertEqual(plan.action, .chooseNetwork, "\(mode)")
            XCTAssertFalse(plan.canStart)
        }
    }

    /// A blank password is not read as an open network, because the two mean
    /// different things and one of them leaves a board unable to join with nothing
    /// on screen to say why.
    func testANamedNetworkWithNoPasswordAsksForOne() {
        var request = ready()
        request.credential = .incomplete
        let plan = UsbOnboardingPlan.make(request)
        XCTAssertEqual(plan.action, .enterPassword)
        XCTAssertFalse(plan.canStart)
        XCTAssertTrue(plan.headline.contains("\"Home\""))
        XCTAssertTrue(plan.detail.contains("open"))
    }

    func testAnOpenNetworkIsAllowedThrough() {
        var request = ready()
        request.credential = .ready(.openNetwork)
        XCTAssertEqual(UsbOnboardingPlan.make(request).action, .flash)
        XCTAssertEqual(
            UsbOnboarding.Credential.ready(.openNetwork).passwordChange, .openNetwork)
        XCTAssertNil(UsbOnboarding.Credential.incomplete.passwordChange)
    }

    /// The network is asked for AFTER the firmware questions, so a user with the
    /// wrong file is told about the file rather than about a password they are about
    /// to be told does not help.
    func testTheFirmwareProblemIsReportedBeforeTheNetworkOne() {
        var request = ready()
        request.bundle = EsptoolCommandTests.otaOnlyBundle(chip: "esp32s3")
        request.ssid = ""
        XCTAssertEqual(UsbOnboardingPlan.make(request).action, .bundleIsOTAOnly)
    }

    // MARK: - adopting a board that already works

    /// Configure-only against a board that answered nothing is the one contradiction
    /// this mode has: there is nothing on the other end to configure.
    func testConfigureOnlyAgainstASilentBoardIsRefusedAndOffersTheOtherMode() {
        var request = ready(mode: .configureOnly)
        request.existing = .silent
        let plan = UsbOnboardingPlan.make(request)
        XCTAssertEqual(plan.action, .boardNotAnswering)
        XCTAssertFalse(plan.canStart)
        XCTAssertTrue(plan.detail.contains(UsbOnboarding.Mode.flashAndConfigure.label))
    }

    /// Not yet checked is not the same as checked and silent: the first must not
    /// refuse.
    func testConfigureOnlyBeforeTheBoardHasBeenCheckedDoesNotRefuse() {
        var request = ready(mode: .configureOnly)
        request.existing = .notChecked
        XCTAssertEqual(UsbOnboardingPlan.make(request).action, .configureOnly)
    }

    /// A BOARD THAT ALREADY WORKS IS NOT RE-FLASHED BY DEFAULT: it answered, so what
    /// it is missing is credentials, and writing flash to change a WiFi password
    /// would be a much bigger action than the one asked for.
    func testTheSuggestedModeFollowsWhatTheBoardAnswered() {
        XCTAssertEqual(
            UsbOnboarding.suggestedMode(for: .answered(name: "panel")), .configureOnly)
        XCTAssertEqual(
            UsbOnboarding.suggestedMode(for: .answered(name: "")), .configureOnly)
        XCTAssertEqual(UsbOnboarding.suggestedMode(for: .silent), .flashAndConfigure)
        XCTAssertEqual(UsbOnboarding.suggestedMode(for: .notChecked), .flashAndConfigure)
    }

    /// Re-flashing a working board stays available, and the plan says the board is
    /// already known rather than pretending it is blank.
    func testAWorkingBoardCanStillBeReflashedDeliberately() {
        var request = ready(mode: .flashAndConfigure)
        request.existing = .answered(name: "desk-panel")
        let plan = UsbOnboardingPlan.make(request)
        XCTAssertEqual(plan.action, .flash)
        XCTAssertTrue(plan.detail.contains("already runs this firmware"))
        XCTAssertTrue(plan.detail.contains("desk-panel"))
    }

    // MARK: - every case is reachable and distinct

    /// The property `FirmwareUpdatePlanTests` asserts for the update sheet: each
    /// action is producible, and no two of them say the same thing. A copied case
    /// with a copied message would pass every test above and fail this one.
    func testEveryActionIsReachableAndSaysSomethingOfItsOwn() {
        var reachable: [UsbOnboardingPlan.Action: UsbOnboardingPlan] = [:]
        func record(_ mutate: (inout UsbOnboarding.Request) -> Void) {
            var request = ready()
            mutate(&request)
            let plan = UsbOnboardingPlan.make(request)
            reachable[plan.action] = plan
        }
        record { _ in }
        record { $0.mode = .configureOnly; $0.existing = .answered(name: "p") }
        record { $0.port = "" }
        record { $0.port = ""; $0.availablePorts = [] }
        record { $0.detection = .notAttempted }
        record { $0.detection = .failed(reason: "nothing answered") }
        record { $0.bundle = nil }
        record { $0.detection = .detected(chip: "esp32c6", mac: nil) }
        record { $0.bundle = EsptoolCommandTests.otaOnlyBundle(chip: "esp32s3") }
        record { $0.tool = .missing(searched: []) }
        record { $0.ssid = "" }
        record { $0.credential = .incomplete }
        record { $0.mode = .configureOnly; $0.existing = .silent }

        let expected: [UsbOnboardingPlan.Action] = [
            .flash, .configureOnly, .chooseDevice, .connectDevice, .detectChip,
            .chipUnreadable, .chooseBundle, .noImageForChip, .bundleIsOTAOnly,
            .esptoolMissing, .chooseNetwork, .enterPassword, .boardNotAnswering,
        ]
        XCTAssertEqual(Set(reachable.keys), Set(expected))
        let headlines = expected.map { reachable[$0]?.headline ?? "" }
        let details = expected.map { reachable[$0]?.detail ?? "" }
        XCTAssertFalse(headlines.contains(""))
        XCTAssertEqual(Set(headlines).count, expected.count, "two cases share a headline")
        XCTAssertEqual(Set(details).count, expected.count, "two cases share a detail")
    }

    /// Exactly two actions may start, which is the property the button is disabled
    /// on. Adding a case without deciding this consciously breaks here.
    func testOnlyTheTwoReadyActionsCanStart() {
        let starts: [UsbOnboardingPlan.Action] = [.flash, .configureOnly]
        for action in [
            UsbOnboardingPlan.Action.flash, .configureOnly, .chooseDevice,
            .connectDevice, .detectChip, .chipUnreadable, .chooseBundle,
            .noImageForChip, .bundleIsOTAOnly, .esptoolMissing, .chooseNetwork,
            .enterPassword, .boardNotAnswering,
        ] {
            let plan = UsbOnboardingPlan(headline: "", detail: "", action: action)
            XCTAssertEqual(plan.canStart, starts.contains(action), "\(action)")
        }
    }

    // MARK: - the order the board is configured in

    /// WIFI GOES LAST. Both CFG* handlers restart the board, so the last one sent
    /// decides what the board is doing when it comes back - and the thing the
    /// sidebar is waiting for is a board that has joined the network.
    func testWifiIsSentLastSoTheFinalRestartIsTheOneThatJoins() {
        let steps = UsbOnboarding.configurationSteps(
            name: "Desk Panel", ssid: "Home", password: .set("hunter2hunter2"))
        XCTAssertEqual(steps.map(\.kind), [.name, .wifi])
        XCTAssertEqual(steps.last?.kind, .wifi)
    }

    func testAnEmptyNameCostsNoRestartAtAll() {
        for blank in ["", "   ", "\n"] {
            let steps = UsbOnboarding.configurationSteps(
                name: blank, ssid: "Home", password: .openNetwork)
            XCTAssertEqual(steps.map(\.kind), [.wifi], "\(blank.debugDescription)")
        }
    }

    /// The commands themselves are `ConfigCommands`' and not rebuilt here, so a
    /// change to the wire format cannot apply to one caller and not another.
    func testTheStepsCarryTheCommandsConfigCommandsBuilds() {
        let steps = UsbOnboarding.configurationSteps(
            name: "desk", ssid: "Home", password: .set("hunter2hunter2"))
        XCTAssertEqual(steps[0].command, ConfigCommands.setName("desk"))
        XCTAssertEqual(
            steps[1].command,
            ConfigCommands.setWifi(ssid: "Home", password: .set("hunter2hunter2")))
        // Each step says what it is doing while it is in flight, and says which
        // network or name rather than "configuring…".
        XCTAssertTrue(steps[0].label.contains("desk"))
        XCTAssertTrue(steps[1].label.contains("WiFi"))
    }

    /// All three password cases survive into the command, including keep-current -
    /// which is meaningful when a board is re-flashed without erasing, because its
    /// NVS is still there.
    func testEveryPasswordCaseReachesTheCommand() {
        for change: ConfigCommands.PasswordChange in [
            .set("hunter2hunter2"), .openNetwork, .keepCurrent,
        ] {
            let steps = UsbOnboarding.configurationSteps(
                name: "", ssid: "Home", password: change)
            XCTAssertEqual(
                steps[0].command,
                ConfigCommands.setWifi(ssid: "Home", password: change))
        }
    }
}
