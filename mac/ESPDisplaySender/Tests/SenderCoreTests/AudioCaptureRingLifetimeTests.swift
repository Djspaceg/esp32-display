import Dispatch
import XCTest

@testable import SenderCore

final class AudioCaptureRingLifetimeTests: XCTestCase {
    private final class WeakBox<Object: AnyObject> {
        weak var value: Object?

        init(_ value: Object?) {
            self.value = value
        }
    }

    private func launchCallback(
        lifetime: AudioCaptureRingLifetime,
        entered: XCTestExpectation,
        release: DispatchSemaphore,
        exited: XCTestExpectation
    ) {
        DispatchQueue.global().async { [lifetime] in
            entered.fulfill()
            release.wait()
            lifetime.setAccepting(false)
            exited.fulfill()
        }
    }

    func testInFlightCallbackRetainsRingUntilCallbackExit() throws {
        let entered = expectation(description: "callback entered")
        let exited = expectation(description: "callback exited")
        let destroyed = expectation(description: "ring destroyed")
        let release = DispatchSemaphore(value: 0)
        var lifetime = AudioCaptureRingLifetime(
            slotCount: 2,
            maximumFrames: 4,
            channels: 1,
            onDestroy: {
                destroyed.fulfill()
            })
        let weakLifetime = WeakBox(try XCTUnwrap(lifetime))

        launchCallback(
            lifetime: try XCTUnwrap(lifetime),
            entered: entered,
            release: release,
            exited: exited)
        lifetime = nil

        wait(for: [entered], timeout: 1)
        XCTAssertNotNil(
            weakLifetime.value,
            "the callback capture must retain the ring while it can reach C")
        release.signal()
        wait(for: [exited, destroyed], timeout: 1, enforceOrder: true)
        XCTAssertNil(weakLifetime.value)
    }
}
