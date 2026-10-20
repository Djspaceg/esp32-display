import XCTest
@testable import SenderCore

/// The boards are devices; "display" in this app means the Mac's screen.
final class DeviceReachabilityTextTests: XCTestCase {
    func testReachabilityMessagesCallTheBoardADevice() {
        let messages = [
            DeviceReachabilityText.parked,
            DeviceReachabilityText.suspended,
            DeviceReachabilityText.awaitingIdentity,
            DeviceReachabilityText.noSession,
            DeviceReachabilityText.answeredAgain,
            DeviceReachabilityText.retrying,
        ]
        for message in messages {
            let lower = message.lowercased()
            XCTAssertFalse(lower.contains("display"), message)
            XCTAssertFalse(lower.contains("panel"), message)
            XCTAssertTrue(lower.contains("device"), message)
        }
    }

    func testTheParkedMessageSaysCaptureResumesOnItsOwn() {
        XCTAssertTrue(DeviceReachabilityText.parked.hasPrefix("Not reachable"))
        XCTAssertTrue(DeviceReachabilityText.parked.contains("resumes automatically"))
    }
}
