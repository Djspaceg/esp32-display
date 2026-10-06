import XCTest
@testable import SenderProtocol

/// A board detected on USB is never left with a greyed-out button and nothing
/// said. The case that set this: a P4 4B read as esp32p4 with its MAC, whose
/// CFGSHOW went unanswered, set to "Set up WiFi only" on a saved network.
final class UsbOnboardingDetectedBoardTests: XCTestCase {

    private let mac = "e8:f6:0a:e0:b5:5a"

    private func reported4B(mode: UsbOnboarding.Mode) -> UsbOnboarding.Request {
        UsbOnboarding.Request(
            port: "/dev/cu.usbmodem5B901669681",
            availablePorts: ["/dev/cu.usbmodem5B901669681"],
            mode: mode,
            tool: .installed(path: "/core/esptool_py/5.3.1/esptool"),
            bundle: nil,
            target: nil,
            detection: .detected(chip: "esp32p4", mac: mac),
            existing: .silent,
            ssid: "Stephens Manor",
            credential: .ready(.set("hunter2hunter2")))
    }

    /// An unanswered first CFGSHOW is not proof that nothing is there: the run
    /// asks again, verifies the MAC with esptool, and only then sends.
    func testWifiOnlyCanStartForADetectedBoardWhoseFirstProbeWentUnanswered() {
        let plan = UsbOnboardingPlan.make(reported4B(mode: .configureOnly))
        XCTAssertEqual(plan.action, .configureOnly)
        XCTAssertTrue(plan.canStart)
        XCTAssertFalse(plan.writesFlash)
        XCTAssertEqual(plan.verb, "Set Up WiFi")
        XCTAssertTrue(plan.detail.contains("asked again"), plan.detail)
    }

    /// A P4 whose model it does not report gets a board picker, never "this app
    /// has no firmware", while the app ships a P4 image.
    func testFlashForAP4WithAnUnknownModelOffersTheBoardChoice() {
        var request = reported4B(mode: .flashAndConfigure)
        request.shipsFirmware = true
        request.boardChoices = ["st7703-4b", "jd9365-4c", "jd9365-34c"]
        let plan = UsbOnboardingPlan.make(request)
        XCTAssertEqual(plan.action, .chooseBoard)
        XCTAssertFalse(plan.canStart)
        XCTAssertFalse(plan.detail.contains("did not come with a firmware"), plan.detail)
        XCTAssertTrue(plan.detail.contains(
            GeneratedBoardCatalog.boardNameByProfile["st7703-4b"] ?? "st7703-4b"),
            plan.detail)
    }

    /// Choosing the 4B then makes it flashable.
    func testFlashForAP4BecomesReadyOnceItsBoardIsChosen() {
        var request = reported4B(mode: .flashAndConfigure)
        request.shipsFirmware = true
        request.boardChoices = ["st7703-4b"]
        request.bundle = EsptoolCommandTests.bundle(
            chip: "esp32p4", bootloader: 0x2000, app: 0x10000, target: "p4")
        request.target = "p4"
        let plan = UsbOnboardingPlan.make(request)
        XCTAssertEqual(plan.action, .flash)
        XCTAssertTrue(plan.canStart)
    }

    /// While the chip is still being read, shipped firmware is not "nothing to
    /// write".
    func testShippedFirmwareWaitsForTheChipRatherThanAskingForAFile() {
        var request = reported4B(mode: .flashAndConfigure)
        request.shipsFirmware = true
        request.detection = .notAttempted
        XCTAssertEqual(UsbOnboardingPlan.make(request).action, .detectChip)
    }

    /// Without esptool an unanswered board cannot be confirmed, and the refusal
    /// says so in words.
    func testWifiOnlyWithoutEsptoolOnASilentBoardSaysWhy() {
        var request = reported4B(mode: .configureOnly)
        request.tool = .missing(searched: [])
        let plan = UsbOnboardingPlan.make(request)
        XCTAssertEqual(plan.action, .boardNotAnswering)
        XCTAssertTrue(plan.detail.contains("esptool"))
    }

    /// The hardware-ID gate used to be a silent extra condition on the button.
    /// It is a plan with a reason now, for both modes.
    func testAMissingHardwareIDIsAReasonNotASilentlyGreyButton() {
        for mode in UsbOnboarding.Mode.allCases {
            var request = reported4B(mode: mode)
            request.hardwareIDKnown = false
            request.existing = .answered(name: "white-square-4b")
            request.bundle = EsptoolCommandTests.bundle(
                chip: "esp32p4", bootloader: 0x2000, app: 0x10000, target: "p4")
            request.target = "p4"
            let plan = UsbOnboardingPlan.make(request)
            XCTAssertEqual(plan.action, .identifyBoard, "\(mode)")
            XCTAssertFalse(plan.canStart)
            XCTAssertFalse(plan.detail.isEmpty)
        }
    }
}

/// What a flash does to the version the board reports: named, and never a
/// reason to refuse.
final class UsbOnboardingFlashDirectionTests: XCTestCase {
    private func request(board: String?, bundleVersion: String) -> UsbOnboarding.Request {
        UsbOnboarding.Request(
            port: "/dev/cu.usbmodem101",
            availablePorts: ["/dev/cu.usbmodem101"],
            mode: .flashAndConfigure,
            tool: .installed(path: "/core/esptool"),
            bundle: EsptoolCommandTests.bundle(
                chip: "esp32p4", bootloader: 0x2000, app: 0x10000,
                version: bundleVersion, target: "p4"),
            target: "p4",
            detection: .detected(chip: "esp32p4", mac: "e8:f6:0a:e0:b5:5a"),
            existing: .answered(name: "white-square-4b", hardwareID: "e8f60ae0b55a"),
            ssid: "Home",
            credential: .ready(.keepCurrent),
            boardFirmwareVersion: board)
    }

    func testEachDirectionIsNamedAndStillStarts() {
        let cases: [(String?, String, String)] = [
            ("1.5.0", "2.0.0", "Upgrade"),
            ("2.0.0+192.g04ac678", "2.0.0", "Reinstall"),
            ("2.0.0+100", "2.0.0", "Upgrade"),
            ("2.0.0+500", "2.0.0", "Downgrade"),
            ("2.1.0", "2.0.0", "Downgrade"),
        ]
        for (board, bundle, word) in cases {
            let plan = UsbOnboardingPlan.make(request(board: board, bundleVersion: bundle))
            XCTAssertEqual(plan.action, .flash, word)
            XCTAssertTrue(plan.canStart, word)
            XCTAssertTrue(plan.headline.hasPrefix(word), plan.headline)
            XCTAssertTrue(plan.verb.hasPrefix(word), plan.verb)
            XCTAssertTrue(plan.detail.contains(board ?? ""), plan.detail)
        }
    }

    /// A version the app cannot place - a dev build string, a newer release it
    /// has never heard of - is shown as reported, and flashing stays offered.
    func testAnUnplaceableBoardVersionIsShownAsIsAndStillStarts() {
        for board in ["2.0.0+369.g04ac678", "9.9.9-local", "banana"] {
            let plan = UsbOnboardingPlan.make(request(board: board, bundleVersion: "1.5.0"))
            XCTAssertTrue(plan.canStart, board)
            XCTAssertTrue(plan.detail.contains(board), plan.detail)
        }
    }

    /// No reported version keeps the plain verb.
    func testNoBoardVersionKeepsThePlainVerb() {
        let plan = UsbOnboardingPlan.make(request(board: nil, bundleVersion: "2.0.0"))
        XCTAssertEqual(plan.verb, "Flash and Add")
        XCTAssertTrue(plan.canStart)
    }
}
