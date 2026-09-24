import XCTest

@testable import SenderCore

final class AudioDeviceResolverTests: XCTestCase {
    private let microphone = AudioDeviceOption(
        uid: "input-1",
        name: "Desk Microphone",
        supportsInput: true,
        supportsOutput: false)
    private let headset = AudioDeviceOption(
        uid: "duplex-1",
        name: "USB Headset",
        supportsInput: true,
        supportsOutput: true)
    private let speakers = AudioDeviceOption(
        uid: "output-1",
        name: "Studio Speakers",
        supportsInput: false,
        supportsOutput: true)

    func testNilPreferenceUsesSystemDefault() {
        XCTAssertEqual(
            AudioDeviceResolver.resolve(
                preferredUID: nil,
                direction: .input,
                devices: [microphone, headset, speakers]),
            AudioDeviceResolution(
                uid: nil,
                name: AudioDeviceResolver.systemDefaultName,
                missingPreferredUID: nil))
    }

    func testExistingPreferenceUsesStableUID() {
        XCTAssertEqual(
            AudioDeviceResolver.resolve(
                preferredUID: "duplex-1",
                direction: .output,
                devices: [microphone, headset, speakers]),
            AudioDeviceResolution(
                uid: "duplex-1",
                name: "USB Headset",
                missingPreferredUID: nil))
    }

    func testVanishedPreferenceFallsBackWithoutForgettingIt() {
        let resolution = AudioDeviceResolver.resolve(
            preferredUID: "output-1",
            direction: .output,
            devices: [microphone, headset])

        XCTAssertEqual(resolution.uid, nil)
        XCTAssertEqual(resolution.name, AudioDeviceResolver.systemDefaultName)
        XCTAssertEqual(resolution.missingPreferredUID, "output-1")
        XCTAssertTrue(resolution.usedFallback)
    }

    func testWrongDirectionIsTreatedAsUnavailable() {
        let resolution = AudioDeviceResolver.resolve(
            preferredUID: "output-1",
            direction: .input,
            devices: [microphone, headset, speakers])

        XCTAssertTrue(resolution.usedFallback)
        XCTAssertNil(resolution.uid)
    }

    func testRouteSnapshotChangesWhenOnlyTheSystemDefaultChanges() {
        let before = CoreAudioRouteSnapshot(
            options: [microphone, headset, speakers],
            defaultInputUID: microphone.uid,
            defaultOutputUID: speakers.uid)
        let after = CoreAudioRouteSnapshot(
            options: [microphone, headset, speakers],
            defaultInputUID: headset.uid,
            defaultOutputUID: headset.uid)

        XCTAssertNotEqual(
            before,
            after,
            "a default switch must restart an unpinned System Default route")
    }
}
