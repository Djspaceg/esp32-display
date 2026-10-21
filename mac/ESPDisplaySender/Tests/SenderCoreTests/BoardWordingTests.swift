import XCTest
@testable import SenderCore

/// The boards are devices; "display" in this app means the Mac's screen, and
/// "panel" is not a word the user sees for a board. A representative sample of
/// the text the app shows about a board, from errors, settings and controls.
final class BoardWordingTests: XCTestCase {
    private func assertCallsTheBoardADevice(
        _ messages: [String], file: StaticString = #filePath, line: UInt = #line
    ) {
        for message in messages {
            let lower = message.lowercased()
            XCTAssertFalse(lower.contains("display"), message, file: file, line: line)
            XCTAssertFalse(lower.contains("panel"), message, file: file, line: line)
        }
    }

    func testFirmwareUpdateFailuresSayDevice() {
        let wifi: [FirmwarePusher.Failure] = [
            .noReplyToInvitation(attempts: 3),
            .passwordRequired,
            .legacyMD5Firmware,
            .noReplyToAuthentication,
            .panelNeverConnected(seconds: 10),
            .replyTimedOut(waitingFor: "the result"),
        ]
        let stream: [StreamFirmwarePusher.Failure] = [
            .noReplyToBegin(attempts: 3),
            .notConfigured,
            .authenticationFailed,
            .hashMismatch,
            .cancelled,
        ]
        assertCallsTheBoardADevice(
            wifi.compactMap(\.errorDescription) + stream.compactMap(\.errorDescription))
    }

    func testPasswordPolicySaysDevice() {
        assertCallsTheBoardADevice([
            OTAPasswordPolicy.explain(.tooShort(bytes: 2)),
            OTAPasswordPolicy.explain(.tooLong(bytes: 200)),
            OTAPasswordPolicy.explain(.embeddedNul),
        ].compactMap { $0 })
    }

    func testSettingsAndControlsSayDevice() {
        assertCallsTheBoardADevice(
            SettingsPane.allCases.map(\.summary)
                + GesturePreset.allCases.map(\.summary)
                + BoardFunction.allCases.map(\.summary)
                + [AppIssue.deviceConfig.title, AppIssue.persistence.title])
    }
}
