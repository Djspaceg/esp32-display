import AVFoundation
import CoreAudio
import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// "Play sound on" has two answers: follow the Mac's Sound setting, where a
/// display plays only while its own device is the Mac's chosen output and is
/// silent otherwise, or also copy the Mac's sound to the displays. Routes are
/// read here as a saved settings file names them, so these tests say what a
/// stored choice does whatever the choices are called in code.
@MainActor
final class FollowMacSoundTests: XCTestCase {
    private let follow = "Follow the Mac's Sound setting"
    private let alsoCopy = "Also copy the Mac's sound to the devices"
    private let speakers = MacOutputDevice(
        uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")
    private let desk = DisplayAudioDeviceSpec(
        uid: AppIdentity.audioDeviceUIDPrefix + "AAAA", name: "Desk", latencyFrames: 7_200)

    private func stored(_ json: String) throws -> MacAudioRoute {
        try JSONDecoder().decode(SenderSettings.self, from: Data(json.utf8)).macAudioRoute
    }

    // MARK: - The choices and stored settings

    func testTheMenuOffersFollowingTheMacOrAlsoCopying() {
        XCTAssertEqual(MacAudioRoute.allCases.map(\.label), [follow, alsoCopy])
    }

    func testStoredChoicesLoadAsTheirNearestNewChoice() throws {
        // The old copy stays the copy; the old "displays only", which already
        // played on a display only through its own device, follows the Mac.
        XCTAssertEqual(try stored(#"{"macAudioRoute": "copy"}"#).label, alsoCopy)
        XCTAssertEqual(try stored(#"{"macAudioRoute": "displaysOnly"}"#).label, follow)
        // Mirror played on the Mac and the displays together, as the copy does.
        XCTAssertEqual(try stored(#"{"macAudioRoute": "mirror"}"#).label, alsoCopy)
        // Never chosen: the default is to follow the Mac.
        XCTAssertEqual(try stored(#"{"fps": 30}"#).label, follow)
        XCTAssertEqual(SenderSettings().macAudioRoute.label, follow)
        // Saved again, the old name is gone.
        let reloaded = try JSONDecoder().decode(
            SenderSettings.self, from: Data(#"{"macAudioRoute": "displaysOnly"}"#.utf8))
        let written = String(data: try JSONEncoder().encode(reloaded), encoding: .utf8) ?? ""
        XCTAssertFalse(written.contains("displaysOnly"), written)
    }

    // MARK: - Following the Mac's Sound setting

    /// Following the Sound setting, the app makes each ESP device's output
    /// and leaves the choosing to the human: the router can read the Mac's
    /// devices but has nothing that could change its output. Quitting
    /// withdraws the outputs.
    func testFollowingMakesTheOutputsAndQuittingWithdrawsThem() throws {
        let route = try stored(#"{"macAudioRoute": "displaysOnly"}"#)
        let driver = FakeDisplayAudioDriver()
        let system = FakeMacOutputSystem(devices: [speakers])
        system.show([desk])
        let router = MacAudioRouter(bridge: driver, system: system)
        for _ in 0..<3 { router.update(route: route, displays: [desk]) }
        XCTAssertEqual(driver.lastRegistration, [desk], "the device's output is made")
        XCTAssertEqual(driver.registrationCount, 3, "every pass is a heartbeat")
        router.shutdown()
        XCTAssertEqual(driver.lastRegistration, [], "the outputs are withdrawn")
    }

    /// Following the Mac never taps or copies its sound, even when the driver
    /// it needs is missing: the displays are quiet, and the note says why and
    /// where the Install button is.
    func testFollowingWithoutTheDriverIsQuietAndSaysHowToInstall() throws {
        let route = try stored(#"{"macAudioRoute": "displaysOnly"}"#)
        let driver = FakeDisplayAudioDriver()
        driver.state = .absent
        let system = FakeMacOutputSystem(devices: [speakers])
        let router = MacAudioRouter(bridge: driver, system: system)
        let plan = router.update(route: route, displays: [desk])
        XCTAssertTrue(plan.note?.contains("Install Audio Driver") == true, plan.note ?? "")
        let downlinks = PanelAudioDownlinks(bridge: driver)
        downlinks.update(effective: plan.effective, identities: ["espdisp-desk": desk])
        let source = downlinks.source(for: "espdisp-desk")
        XCTAssertFalse(source.key.hasPrefix("tap"), "the Mac's sound is not copied: \(source.key)")
    }

    /// With no frames from the driver, as for an output that is not the
    /// Mac's (the driver's own test shows it hands over none), the device's
    /// speaker gets only the silence that keeps its microphone link alive,
    /// and frames that do arrive are what it plays.
    func testNoFramesFromTheDriverMeansOnlySilence() throws {
        let route = try stored(#"{"macAudioRoute": "displaysOnly"}"#)
        let driver = FakeDisplayAudioDriver()
        driver.addDevice(uid: desk.uid, id: 7)
        // Nothing is ever queued: no app plays to the device.
        let panel = try LoopbackPanel()
        defer { panel.close() }
        let address = PanelPeerAddress()
        address.publish("127.0.0.1")
        let snapshots = SnapshotLog()
        let session = PanelAudioSession(
            descriptor: AudioStreamDescriptor(
                port: panel.port, version: AudioProtocol.version, sampleRateHz: 16_000,
                playbackChannels: 2, captureChannels: 2),
            tuning: AudioRuntimeTuning(responseTimeoutMilliseconds: 30_000),
            peerAddress: address,
            radioBudget: PanelRadioBudget(),
            systemAudioAccess: SystemAudioAccess(status: { .denied }, request: nil),
            systemAudioSource: SystemAudioCaptureSource(open: {
                XCTFail("the tap is never opened")
                throw POSIXError(.EPERM)
            }),
            downlink: .displayDevice(
                name: "Desk", route: route,
                capture: .displayDevice(uid: desk.uid, bridge: driver),
                identity: desk.uid + "#7"),
            onUpdate: { snapshots.append($0) })
        session.setEnabled(true)
        session.start()
        defer { session.stop() }
        let packets = panel.receiveDownlink(timeoutSeconds: 3) { $0.count >= 20 }
        XCTAssertGreaterThanOrEqual(packets.count, 20, "the downlink keeps flowing")
        XCTAssertTrue(
            packets.allSatisfy { pcm16Samples($0.samples).allSatisfy { $0 == 0 } },
            "every packet is silence")
        // Once something plays to the device, it is what the display gets.
        driver.queue([Float](repeating: 0.5, count: 4_800), for: 7)
        let after = panel.receiveDownlink(timeoutSeconds: 3) { packets in
            packets.contains { pcm16Samples($0.samples).contains { $0 != 0 } }
        }
        XCTAssertTrue(after.contains { pcm16Samples($0.samples).contains { $0 != 0 } })
    }

    /// Before the first route pass, or with routing never started, a session
    /// built now follows the Mac: it never opens the tap or its prompt.
    func testAFreshDownlinkNeverTaps() {
        let downlinks = PanelAudioDownlinks(bridge: FakeDisplayAudioDriver())
        XCTAssertNotEqual(downlinks.source(for: "espdisp-desk").key, "tap")
    }

    // MARK: - Also copying the Mac's sound

    func testCopyingTapsTheMacsSoundAndLeavesItsOutputAlone() throws {
        let route = try stored(#"{"macAudioRoute": "copy"}"#)
        let driver = FakeDisplayAudioDriver()
        let system = FakeMacOutputSystem(devices: [speakers])
        let router = MacAudioRouter(bridge: driver, system: system)
        let plan = router.update(route: route, displays: [desk])
        let downlinks = PanelAudioDownlinks(bridge: driver)
        downlinks.update(effective: plan.effective, identities: ["espdisp-desk": desk])
        XCTAssertEqual(downlinks.source(for: "espdisp-desk").key, "tap")
        XCTAssertTrue(driver.registrations.allSatisfy(\.isEmpty), "no display device is made")
    }
}
