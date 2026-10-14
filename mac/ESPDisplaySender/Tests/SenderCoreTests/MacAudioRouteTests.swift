import CoreAudio
import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// A Mac whose outputs and default output are just values, so no test moves
/// the default output of the Mac running it.
@MainActor
final class FakeMacOutputSystem: MacOutputSystem {
    var devices: [MacOutputDevice]
    var defaultUID: String?
    private(set) var created: [(uid: String, main: String, members: [String])] = []
    private(set) var destroyed: [String] = []
    private(set) var defaultChanges: [String] = []

    init(devices: [MacOutputDevice], defaultUID: String?) {
        self.devices = devices
        self.defaultUID = defaultUID
    }

    func outputDevices() -> [MacOutputDevice] { devices }
    func defaultOutputUID() -> String? { defaultUID }

    func setDefaultOutput(uid: String) -> Bool {
        guard devices.contains(where: { $0.uid == uid }) else { return false }
        defaultUID = uid
        defaultChanges.append(uid)
        return true
    }

    func createMultiOutput(uid: String, name: String, mainUID: String, members: [String]) -> Bool {
        devices.removeAll { $0.uid == uid }
        devices.append(MacOutputDevice(uid: uid, name: name, isBuiltIn: false))
        created.append((uid, mainUID, members))
        return true
    }

    func destroyAggregate(uid: String) {
        devices.removeAll { $0.uid == uid }
        destroyed.append(uid)
        if defaultUID == uid { defaultUID = devices.first?.uid }
    }

    /// The driver's devices, as they appear once registered.
    func show(_ specs: [DisplayAudioDeviceSpec]) {
        for spec in specs where !devices.contains(where: { $0.uid == spec.uid }) {
            devices.append(MacOutputDevice(uid: spec.uid, name: spec.name, isBuiltIn: false))
        }
    }
}

@MainActor
final class MacAudioRouteTests: XCTestCase {
    private let speakers = MacOutputDevice(
        uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", isBuiltIn: true)
    private let headphones = MacOutputDevice(
        uid: "USBHeadphones", name: "Headphones", isBuiltIn: false)
    private let desk = DisplayAudioDeviceSpec(
        uid: "com.espdisplay.display.AAAA", name: "Desk", latencyFrames: 7_200)
    private let shelf = DisplayAudioDeviceSpec(
        uid: "com.espdisplay.display.BBBB", name: "Shelf", latencyFrames: 7_200)

    // MARK: - The plan

    func testCopyIsTodaysRouteAndNeedsNoDriver() {
        let plan = MacAudioRoutePlan.make(
            chosen: .copy, driver: .absent, presentDisplayUIDs: [], macOutputUID: "spk")
        XCTAssertEqual(plan.effective, .copy)
        XCTAssertEqual(plan.target, .restore)
        XCTAssertNil(plan.note)
    }

    func testAMissingDriverFallsBackToTheCopyAndSaysHowToInstall() {
        for route in [MacAudioRoute.mirror, .displaysOnly] {
            let plan = MacAudioRoutePlan.make(
                chosen: route, driver: .absent, presentDisplayUIDs: [], macOutputUID: "spk")
            XCTAssertEqual(plan.chosen, route)
            XCTAssertEqual(plan.effective, .copy)
            XCTAssertEqual(plan.target, .restore)
            XCTAssertTrue(plan.note?.contains("not installed") == true, plan.note ?? "")
            XCTAssertTrue(
                plan.note?.contains("sudo mac/AudioDriver/install-driver.sh") == true,
                plan.note ?? "")
        }
    }

    func testADriverFromAnotherBuildIsNotUsed() {
        let plan = MacAudioRoutePlan.make(
            chosen: .mirror, driver: .incompatible(version: 2),
            presentDisplayUIDs: ["d"], macOutputUID: "spk")
        XCTAssertEqual(plan.effective, .copy)
        XCTAssertTrue(plan.note?.contains("version 2") == true, plan.note ?? "")
    }

    func testDisplaysOnlyWithOneDisplayMakesItTheDefaultOutput() {
        let plan = MacAudioRoutePlan.make(
            chosen: .displaysOnly, driver: .ready, presentDisplayUIDs: ["d1"],
            macOutputUID: "spk")
        XCTAssertEqual(plan.effective, .displaysOnly)
        XCTAssertEqual(plan.target, .device(uid: "d1"))
        XCTAssertNil(plan.note)
    }

    func testDisplaysOnlyWithSeveralDisplaysPlaysThemTogether() {
        let plan = MacAudioRoutePlan.make(
            chosen: .displaysOnly, driver: .ready, presentDisplayUIDs: ["d1", "d2"],
            macOutputUID: "spk")
        XCTAssertEqual(plan.target, .multiOutput(
            uid: MacAudioRoutePlan.displaysUID, name: "ESPDisplay Displays",
            mainUID: "d1", members: ["d1", "d2"]))
    }

    func testMirrorClocksOnTheMacsOwnOutput() {
        let plan = MacAudioRoutePlan.make(
            chosen: .mirror, driver: .ready, presentDisplayUIDs: ["d1"], macOutputUID: "spk")
        XCTAssertEqual(plan.target, .multiOutput(
            uid: MacAudioRoutePlan.mirrorUID, name: "Mac and ESPDisplay Displays",
            mainUID: "spk", members: ["spk", "d1"]))
    }

    func testNoDisplayDeviceYetLeavesTheMacOnItsOwnOutput() {
        let plan = MacAudioRoutePlan.make(
            chosen: .displaysOnly, driver: .ready, presentDisplayUIDs: [], macOutputUID: "spk")
        XCTAssertEqual(plan.effective, .displaysOnly)
        XCTAssertEqual(plan.target, .restore)
        XCTAssertNotNil(plan.note)
    }

    func testOurDevicesAreNeverTheMacsOwnOutput() {
        XCTAssertTrue(MacAudioRoutePlan.isOurs(uid: desk.uid))
        XCTAssertTrue(MacAudioRoutePlan.isOurs(uid: MacAudioRoutePlan.mirrorUID))
        XCTAssertTrue(MacAudioRoutePlan.isOurs(uid: MacAudioRoutePlan.displaysUID))
        XCTAssertFalse(MacAudioRoutePlan.isOurs(uid: speakers.uid))
    }

    // MARK: - The router

    func testDisplaysOnlyRegistersTheDevicesAndMakesTheDisplayTheOutput() {
        let driver = FakeDisplayAudioDriver()
        let system = FakeMacOutputSystem(devices: [speakers], defaultUID: speakers.uid)
        let router = MacAudioRouter(bridge: driver, system: system)
        let first = router.update(route: .displaysOnly, displays: [desk])
        XCTAssertEqual(driver.lastRegistration, [desk])
        // The fake driver's device exists at once, but CoreAudio lists it a
        // moment later: the first pass can already route to it.
        XCTAssertEqual(first.target, .device(uid: desk.uid))
        system.show([desk])
        let plan = router.update(route: .displaysOnly, displays: [desk])
        XCTAssertEqual(plan.target, .device(uid: desk.uid))
        XCTAssertEqual(system.defaultUID, desk.uid)
        XCTAssertEqual(router.macOutputUID, speakers.uid, "the speakers are remembered")
    }

    func testTheDefaultIsChangedOnceNotOnEveryHeartbeat() {
        let driver = FakeDisplayAudioDriver()
        let system = FakeMacOutputSystem(devices: [speakers], defaultUID: speakers.uid)
        system.show([desk])
        let router = MacAudioRouter(bridge: driver, system: system)
        router.update(route: .displaysOnly, displays: [desk])
        XCTAssertEqual(system.defaultChanges, [desk.uid])
        // The user picks the speakers in Sound settings afterwards.
        system.defaultUID = speakers.uid
        router.update(route: .displaysOnly, displays: [desk])
        router.update(route: .displaysOnly, displays: [desk])
        XCTAssertEqual(system.defaultUID, speakers.uid, "the user's pick stands")
        XCTAssertEqual(driver.registrationCount, 3, "every pass is a heartbeat")
    }

    func testMirrorBuildsAMultiOutputDeviceAndMakesItTheOutput() {
        let driver = FakeDisplayAudioDriver()
        let system = FakeMacOutputSystem(
            devices: [speakers, headphones], defaultUID: headphones.uid)
        system.show([desk, shelf])
        let router = MacAudioRouter(bridge: driver, system: system)
        router.update(route: .mirror, displays: [desk, shelf])
        XCTAssertEqual(system.created.count, 1)
        XCTAssertEqual(system.created.first?.main, headphones.uid)
        XCTAssertEqual(system.created.first?.members, [headphones.uid, desk.uid, shelf.uid])
        XCTAssertEqual(system.defaultUID, MacAudioRoutePlan.mirrorUID)
        XCTAssertEqual(router.macOutputUID, headphones.uid)
    }

    func testGoingBackToTheCopyRestoresTheMacsOutputAndRemovesOurDevices() {
        let driver = FakeDisplayAudioDriver()
        let system = FakeMacOutputSystem(devices: [speakers], defaultUID: speakers.uid)
        system.show([desk])
        let router = MacAudioRouter(bridge: driver, system: system)
        router.update(route: .mirror, displays: [desk])
        XCTAssertEqual(system.defaultUID, MacAudioRoutePlan.mirrorUID)
        let plan = router.update(route: .copy, displays: [desk])
        XCTAssertEqual(plan.effective, .copy)
        XCTAssertEqual(system.defaultUID, speakers.uid)
        XCTAssertTrue(system.destroyed.contains(MacAudioRoutePlan.mirrorUID))
        XCTAssertEqual(driver.lastRegistration, [], "the devices are withdrawn")
    }

    func testQuittingPutsTheMacsOutputBack() {
        let driver = FakeDisplayAudioDriver()
        let system = FakeMacOutputSystem(devices: [speakers], defaultUID: speakers.uid)
        system.show([desk])
        let router = MacAudioRouter(bridge: driver, system: system)
        router.update(route: .displaysOnly, displays: [desk])
        XCTAssertEqual(system.defaultUID, desk.uid)
        router.shutdown()
        XCTAssertEqual(system.defaultUID, speakers.uid)
        XCTAssertEqual(driver.lastRegistration, [])
    }

    /// Started while a display was still the default, as after a crash: the
    /// built-in output is the one to go back to.
    func testAStartOnOneOfOurDevicesFindsTheBuiltInOutput() {
        let driver = FakeDisplayAudioDriver()
        let system = FakeMacOutputSystem(
            devices: [headphones, speakers], defaultUID: MacAudioRoutePlan.mirrorUID)
        system.devices.append(MacOutputDevice(
            uid: MacAudioRoutePlan.mirrorUID, name: "stale", isBuiltIn: false))
        let router = MacAudioRouter(bridge: driver, system: system)
        router.update(route: .copy, displays: [])
        XCTAssertEqual(router.macOutputUID, speakers.uid)
        XCTAssertEqual(system.defaultUID, speakers.uid)
        XCTAssertTrue(system.destroyed.contains(MacAudioRoutePlan.mirrorUID))
    }

    func testAMissingDriverRegistersNothingAndTouchesNoOutput() {
        let driver = FakeDisplayAudioDriver()
        driver.state = .absent
        let system = FakeMacOutputSystem(devices: [speakers], defaultUID: speakers.uid)
        let router = MacAudioRouter(bridge: driver, system: system)
        let plan = router.update(route: .displaysOnly, displays: [desk])
        XCTAssertEqual(plan.effective, .copy)
        XCTAssertTrue(driver.registrations.allSatisfy(\.isEmpty))
        XCTAssertTrue(system.defaultChanges.isEmpty)
    }

    // MARK: - What each session is given

    func testSessionsGetTheirDisplayDeviceOrTheTapWithTheNote() throws {
        let driver = FakeDisplayAudioDriver()
        let downlinks = PanelAudioDownlinks(bridge: driver)
        let devices = ["espdisp-desk": desk]
        downlinks.update(
            plan: MacAudioRoutePlan.make(
                chosen: .displaysOnly, driver: .ready,
                presentDisplayUIDs: [desk.uid], macOutputUID: "spk"),
            devices: devices)
        let device = downlinks.source(for: "espdisp-desk")
        XCTAssertTrue(device.key.hasPrefix("device|\(desk.uid)|"))
        XCTAssertEqual(device.sourceName, "Mac output \"Desk\"")
        XCTAssertTrue(downlinks.source(for: "unknown").key.hasPrefix("tap|"))

        let absent = MacAudioRoutePlan.make(
            chosen: .displaysOnly, driver: .absent, presentDisplayUIDs: [], macOutputUID: nil)
        downlinks.update(plan: absent, devices: devices)
        let fallback = downlinks.source(for: "espdisp-desk")
        XCTAssertTrue(fallback.key.hasPrefix("tap|"))
        XCTAssertEqual(fallback.note, absent.note)
    }

    // MARK: - The setting

    func testTheRouteIsSavedAndAnOldFileReadsAsTheCopy() throws {
        var settings = SenderSettings()
        XCTAssertEqual(settings.macAudioRoute, .copy)
        settings.macAudioRoute = .displaysOnly
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(SenderSettings.self, from: data).macAudioRoute,
                       .displaysOnly)
        XCTAssertEqual(settings.validated.macAudioRoute, .displaysOnly)
        let old = try JSONDecoder().decode(SenderSettings.self, from: Data("{\"fps\": 30}".utf8))
        XCTAssertEqual(old.macAudioRoute, .copy)
        let unknown = try JSONDecoder().decode(
            SenderSettings.self, from: Data("{\"macAudioRoute\": \"surround\"}".utf8))
        XCTAssertEqual(unknown.macAudioRoute, .copy)
    }

    func testAManagerNobodyStartedNeverRoutes() {
        let manager = PanelManager(
            previewPanels: [], savedNetworkNames: [], usbSerialPorts: [])
        XCTAssertNil(manager.macAudio.router)
        manager.setMacAudioRoute(.displaysOnly)
        XCTAssertNil(manager.macAudioRoutePlan)
        XCTAssertEqual(manager.settings.macAudioRoute, .displaysOnly)
    }
}
