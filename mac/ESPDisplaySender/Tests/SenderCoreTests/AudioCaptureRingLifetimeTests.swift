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
        lease: AudioCaptureRingCallbackLease,
        entered: XCTestExpectation,
        release: DispatchSemaphore,
        exited: XCTestExpectation
    ) {
        DispatchQueue.global().async { [lease] in
            entered.fulfill()
            release.wait()
            let samples = [Float](repeating: 0, count: 4)
            samples.withUnsafeBufferPointer { buffer in
                guard let channelZero = buffer.baseAddress else { return }
                _ = lease.write(
                    channelZero: channelZero,
                    channelOne: nil,
                    frameCount: 4)
            }
            exited.fulfill()
        }
    }

    private func releaseOwner(
        _ lifetime: AudioCaptureRingLifetime,
        started: XCTestExpectation
    ) {
        DispatchQueue.global().async { [lifetime] in
            started.fulfill()
            withExtendedLifetime(lifetime) {}
        }
    }

    func testInFlightCallbackLeaseBlocksRingDestructionUntilExit() throws {
        let entered = expectation(description: "callback entered")
        let exited = expectation(description: "callback exited")
        let ownerReleaseStarted = expectation(description: "owner release started")
        let release = DispatchSemaphore(value: 0)
        let destroyed = DispatchSemaphore(value: 0)
        var lifetime = AudioCaptureRingLifetime(
            slotCount: 2,
            maximumFrames: 4,
            channels: 1,
            onDestroy: {
                destroyed.signal()
            })
        let weakLifetime = WeakBox(try XCTUnwrap(lifetime))
        var lease: AudioCaptureRingCallbackLease? =
            try XCTUnwrap(lifetime).makeCallbackLease()

        launchCallback(
            lease: try XCTUnwrap(lease),
            entered: entered,
            release: release,
            exited: exited)
        lease = nil

        wait(for: [entered], timeout: 1)
        releaseOwner(
            try XCTUnwrap(lifetime),
            started: ownerReleaseStarted)
        lifetime = nil
        wait(for: [ownerReleaseStarted], timeout: 1)
        XCTAssertEqual(
            destroyed.wait(timeout: .now() + .milliseconds(50)),
            .timedOut,
            "the ring must remain alive while the callback lease can reach C")
        release.signal()
        wait(for: [exited], timeout: 1)
        XCTAssertEqual(destroyed.wait(timeout: .now() + 1), .success)
        XCTAssertNil(weakLifetime.value)
    }
}
