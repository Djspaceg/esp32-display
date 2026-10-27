import XCTest
@testable import SenderProtocol

/// How the Add Device sheet identifies a board: the no-reset readout first,
/// asked again once after the boot-answer delay, and esptool's chip read -
/// which restarts the board - only when that has failed too.
final class UsbOnboardingIdentityTests: XCTestCase {

    // MARK: - asking again before restarting

    /// A board that said nothing is asked again over the same no-reset open
    /// before anything restarts it: a board that was just reset, or one whose
    /// line buffer held an earlier esptool's sync bytes, answers the second time.
    func testASilentBoardIsAskedAgainBeforeItIsRestarted() {
        XCTAssertEqual(
            UsbOnboarding.nextIdentityStep(
                after: .silent, askedAgain: false, needsChip: true, toolInstalled: true),
            .askAgain(after: UsbOnboarding.bootAnswerDelay))
    }

    /// Only a board still silent the second time is restarted to read its chip.
    func testABoardSilentTwiceIsRestartedToReadIt() {
        XCTAssertEqual(
            UsbOnboarding.nextIdentityStep(
                after: .silent, askedAgain: true, needsChip: true, toolInstalled: true),
            .restartToRead)
    }

    private let identified = UsbOnboarding.ExistingFirmware.answered(
        name: "desk", hardwareID: "e8:f6:0a:e0:b5:5a")

    /// A board that identified itself and only needs WiFi is never restarted,
    /// with the chip need worked out exactly as the sheet works it out.
    func testABoardThatIdentifiedItselfForWiFiIsNotRestarted() {
        let needsChip = UsbOnboarding.identityNeedsChip(
            after: identified, chosenMode: .configureOnly, hardwareIDKnown: true)
        XCTAssertFalse(needsChip)
        for askedAgain in [false, true] {
            XCTAssertEqual(
                UsbOnboarding.nextIdentityStep(
                    after: identified, askedAgain: askedAgain, needsChip: needsChip,
                    toolInstalled: true),
                .done)
        }
    }

    /// A flash needs the chip whatever the board said, and restarts the board
    /// anyway, so an identified board chosen for a flash is read at once.
    func testAnIdentifiedBoardChosenForAFlashIsReadAtOnce() {
        let needsChip = UsbOnboarding.identityNeedsChip(
            after: identified, chosenMode: .flashAndConfigure, hardwareIDKnown: true)
        XCTAssertTrue(needsChip)
        XCTAssertEqual(
            UsbOnboarding.nextIdentityStep(
                after: identified, askedAgain: false, needsChip: needsChip,
                toolInstalled: true),
            .restartToRead)
    }

    /// An answer without a hardware ID forces a flash in the plan, so it
    /// needs the chip even with "Set up WiFi only" still chosen and an ID
    /// remembered from before. Without this the sheet asked for a board read it
    /// would never start.
    func testAnAnswerWithoutAnIDNeedsTheChipWhateverModeIsChosen() {
        XCTAssertTrue(UsbOnboarding.identityNeedsChip(
            after: .answered(name: "old", hardwareID: nil),
            chosenMode: .configureOnly, hardwareIDKnown: true))
        XCTAssertTrue(UsbOnboarding.identityNeedsChip(
            after: .silent, chosenMode: .configureOnly, hardwareIDKnown: false))
        XCTAssertFalse(UsbOnboarding.identityNeedsChip(
            after: .silent, chosenMode: .configureOnly, hardwareIDKnown: true))
    }

    /// An answer without a hardware ID is asked again too: current firmware's
    /// reply can lose its tail to another reader of the port.
    func testAnAnswerWithoutAnIDIsAskedAgainBeforeTheChipRead() {
        let answer = UsbOnboarding.ExistingFirmware.answered(name: "old", hardwareID: nil)
        XCTAssertEqual(
            UsbOnboarding.nextIdentityStep(
                after: answer, askedAgain: false, needsChip: true, toolInstalled: true),
            .askAgain(after: UsbOnboarding.bootAnswerDelay))
        XCTAssertEqual(
            UsbOnboarding.nextIdentityStep(
                after: answer, askedAgain: true, needsChip: true, toolInstalled: true),
            .restartToRead)
    }

    /// No esptool, nothing to restart with: the board is still asked again,
    /// which costs no restart, and then the readout is all there is.
    func testWithoutEsptoolNothingIsRestarted() {
        XCTAssertEqual(
            UsbOnboarding.nextIdentityStep(
                after: .silent, askedAgain: false, needsChip: true, toolInstalled: false),
            .askAgain(after: UsbOnboarding.bootAnswerDelay))
        XCTAssertEqual(
            UsbOnboarding.nextIdentityStep(
                after: .silent, askedAgain: true, needsChip: true, toolInstalled: false),
            .done)
    }

    /// Nothing still to learn: no second readout and no restart.
    func testNothingMoreToReadMeansNoFurtherStep() {
        XCTAssertEqual(
            UsbOnboarding.nextIdentityStep(
                after: .silent, askedAgain: false, needsChip: false, toolInstalled: true),
            .done)
    }

    /// Measured on an ESP32-P4-WIFI6-Touch-LCD-4B on 2.1.0: its first CFGSHOW
    /// answer came 3.3 s after an EN reset. The second readout must not be
    /// asked sooner than a just-reset board can answer it.
    func testTheSecondReadoutWaitsAtLeastTheMeasuredBootAnswerTime() {
        XCTAssertGreaterThanOrEqual(UsbOnboarding.bootAnswerDelay, 3.3)
        XCTAssertLessThanOrEqual(UsbOnboarding.bootAnswerDelay, 10)
    }

    // MARK: - saying so

    /// The restart is said plainly while it happens, and every stage reads
    /// differently from every other.
    func testTheRestartIsSaidPlainlyWhileItHappens() {
        let restarting = UsbOnboarding.IdentityStage.restartingToRead.statusText
        XCTAssertTrue(restarting.localizedCaseInsensitiveContains("restart"), restarting)
        let texts = [UsbOnboarding.IdentityStage.reading,
                     .waitingToAskAgain, .restartingToRead].map(\.statusText)
        XCTAssertEqual(Set(texts).count, texts.count, "\(texts)")
        XCTAssertFalse(
            UsbOnboarding.IdentityStage.reading.statusText
                .localizedCaseInsensitiveContains("restart"))
        XCTAssertFalse(
            UsbOnboarding.IdentityStage.waitingToAskAgain.statusText
                .localizedCaseInsensitiveContains("restart"))
    }

    /// After the read, the board's description still says it was restarted,
    /// so a board seen rebooting has its reason on screen.
    func testABoardReadByRestartingItSaysSoAfterwards() {
        let restarted = UsbOnboarding.detectedDescription(
            chip: "esp32p4", mac: "e8:f6:0a:e0:b5:5a", restartedToRead: true)
        XCTAssertTrue(restarted.contains("esp32p4"), restarted)
        XCTAssertTrue(restarted.contains("e8:f6:0a:e0:b5:5a"), restarted)
        XCTAssertTrue(restarted.localizedCaseInsensitiveContains("restart"), restarted)
        XCTAssertEqual(
            UsbOnboarding.detectedDescription(
                chip: "esp32p4", mac: "e8:f6:0a:e0:b5:5a", restartedToRead: false),
            "esp32p4 · e8:f6:0a:e0:b5:5a")
        XCTAssertEqual(
            UsbOnboarding.detectedDescription(chip: "esp32p4", mac: nil, restartedToRead: false),
            "esp32p4")
    }
}
