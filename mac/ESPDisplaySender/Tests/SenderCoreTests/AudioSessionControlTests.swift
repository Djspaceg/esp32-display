import XCTest

@testable import SenderCore
@testable import SenderProtocol

final class AudioSessionControlTests: XCTestCase {
    private let descriptor = AudioStreamDescriptor(
        port: 5_569,
        version: 1,
        sampleRateHz: 48_000,
        playbackChannels: 2,
        captureChannels: 1)

    func testLateDescriptorInstallsIntoAPreviouslyVideoOnlySession() {
        XCTAssertEqual(
            AudioSessionReconciler.decide(
                current: nil,
                advertisement: .available(descriptor)),
            .install(descriptor))
    }

    func testAbsentTXTDoesNotEraseALiveDescriptor() {
        XCTAssertEqual(
            AudioSessionReconciler.decide(
                current: descriptor,
                advertisement: .unknown),
            .keep)
    }

    func testExplicitAudioRemovalStopsTheAdapter() {
        XCTAssertEqual(
            AudioSessionReconciler.decide(
                current: descriptor,
                advertisement: .unavailable),
            .remove)
    }

    func testLateAdapterInheritsProvisionalPauseBeforeRunStarts() {
        XCTAssertFalse(AudioSessionActivationPolicy.isEnabled(
            paused: true, parked: false))
        XCTAssertFalse(AudioSessionActivationPolicy.isEnabled(
            paused: false, parked: true))
        XCTAssertTrue(AudioSessionActivationPolicy.isEnabled(
            paused: false, parked: false))
    }

    func testAddressGenerationChangesOnEveryVideoResolution() {
        let address = PanelPeerAddress()
        XCTAssertEqual(
            address.snapshot,
            PanelPeerAddressSnapshot(address: nil, generation: 0))
        address.publish("192.168.1.10")
        XCTAssertEqual(address.snapshot.generation, 1)
        address.publish("192.168.1.10")
        XCTAssertEqual(
            address.snapshot.generation,
            2,
            "a reconnect on the same IP still restarts the audio generation")
    }
}
