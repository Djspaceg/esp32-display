import CoreAudio
import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// A Mac whose outputs and default output are just values, so no test moves
/// the default output of the Mac running it.
@MainActor
class FakeMacOutputSystem: MacOutputSystem {
    var devices: [MacOutputDevice]
    var defaultUID: String?
    private(set) var created: [(uid: String, main: String, members: [String])] = []
    private(set) var destroyed: [String] = []
    /// Destroying the default hands the choice of output to the HAL.
    private(set) var destroyedWhileDefault: [String] = []
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
        if defaultUID == uid {
            destroyedWhileDefault.append(uid)
            defaultUID = "picked-by-the-HAL"
        }
    }

    /// The driver's devices, as they appear once registered.
    func show(_ specs: [DisplayAudioDeviceSpec]) {
        for spec in specs where !devices.contains(where: { $0.uid == spec.uid }) {
            devices.append(MacOutputDevice(uid: spec.uid, name: spec.name, isBuiltIn: false))
        }
    }
}

/// Refuses to make one UID the default, as the HAL can for a device it has
/// not listed yet.
@MainActor
final class RefusingDefault: FakeMacOutputSystem {
    var refuse: String?
    override func setDefaultOutput(uid: String) -> Bool {
        uid == refuse ? false : super.setDefaultOutput(uid: uid)
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
                plan.note?.contains("Install Audio Driver") == true, plan.note ?? "")
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

    /// Picking another output in Sound settings while mirroring stands: the
    /// Multi-Output device is not rebuilt around it and made default again.
    func testMirrorLeavesAUsersOwnPickAlone() {
        let driver = FakeDisplayAudioDriver()
        let system = FakeMacOutputSystem(
            devices: [speakers, headphones], defaultUID: speakers.uid)
        system.show([desk])
        let router = MacAudioRouter(bridge: driver, system: system)
        router.update(route: .mirror, displays: [desk])
        XCTAssertEqual(system.defaultUID, MacAudioRoutePlan.mirrorUID)
        system.defaultUID = headphones.uid
        for _ in 0..<3 { router.update(route: .mirror, displays: [desk]) }
        XCTAssertEqual(system.defaultUID, headphones.uid)
        XCTAssertEqual(system.created.count, 1)
        // Going back to the copy afterwards keeps the user's pick too.
        router.update(route: .copy, displays: [desk])
        XCTAssertEqual(system.defaultUID, headphones.uid)
    }

    /// From the displays' Multi-Output device to mirror and back: the default
    /// is never the device being destroyed.
    func testSwitchingMultiOutputsNeverDestroysTheDefault() {
        let driver = FakeDisplayAudioDriver()
        let system = FakeMacOutputSystem(devices: [speakers], defaultUID: speakers.uid)
        system.show([desk, shelf])
        let router = MacAudioRouter(bridge: driver, system: system)
        router.update(route: .displaysOnly, displays: [desk, shelf])
        XCTAssertEqual(system.defaultUID, MacAudioRoutePlan.displaysUID)
        router.update(route: .mirror, displays: [desk, shelf])
        XCTAssertEqual(system.defaultUID, MacAudioRoutePlan.mirrorUID)
        router.update(route: .displaysOnly, displays: [desk, shelf])
        XCTAssertEqual(system.defaultUID, MacAudioRoutePlan.displaysUID)
        router.update(route: .copy, displays: [desk, shelf])
        XCTAssertEqual(system.defaultUID, speakers.uid)
        XCTAssertEqual(system.destroyedWhileDefault, [])
        // Each switch parks on the new device's own clock first: the Mac's
        // output for mirror, a display (never the speakers) for the displays.
        XCTAssertEqual(system.defaultChanges, [
            MacAudioRoutePlan.displaysUID,
            speakers.uid, MacAudioRoutePlan.mirrorUID,
            desk.uid, MacAudioRoutePlan.displaysUID,
            speakers.uid,
        ])
    }

    /// The driver dropped the devices (a stalled heartbeat) and made them
    /// again: the same route is applied again to the new devices.
    func testDevicesThatComeBackAsNewOnesAreRoutedAgain() {
        let driver = FakeDisplayAudioDriver()
        let system = FakeMacOutputSystem(devices: [speakers], defaultUID: speakers.uid)
        system.show([desk])
        let router = MacAudioRouter(bridge: driver, system: system)
        router.update(route: .displaysOnly, displays: [desk])
        XCTAssertEqual(system.defaultUID, desk.uid)
        // The HAL moved the default when the device went away.
        system.defaultUID = speakers.uid
        driver.idBase = 200
        router.update(route: .displaysOnly, displays: [desk])
        XCTAssertEqual(system.defaultUID, desk.uid)
    }

    /// A pass that could not make the device default tries again without
    /// rebuilding a Multi-Output device that is already right.
    func testARetryReusesAMatchingMultiOutputDevice() {
        let driver = FakeDisplayAudioDriver()
        let system = RefusingDefault(devices: [speakers], defaultUID: speakers.uid)
        system.show([desk, shelf])
        let router = MacAudioRouter(bridge: driver, system: system)
        system.refuse = MacAudioRoutePlan.displaysUID
        router.update(route: .displaysOnly, displays: [desk, shelf])
        router.update(route: .displaysOnly, displays: [desk, shelf])
        XCTAssertEqual(system.created.count, 1)
        system.refuse = nil
        router.update(route: .displaysOnly, displays: [desk, shelf])
        XCTAssertEqual(system.created.count, 1)
        XCTAssertEqual(system.defaultUID, MacAudioRoutePlan.displaysUID)
    }

    /// Headphones unplugged while mirroring through them: the Multi-Output
    /// device is rebuilt on the Mac's own output rather than left clocked by
    /// a device that is gone.
    func testMirrorIsRebuiltWhenItsMacOutputGoesAway() {
        let driver = FakeDisplayAudioDriver()
        let system = FakeMacOutputSystem(
            devices: [speakers, headphones], defaultUID: headphones.uid)
        system.show([desk])
        let router = MacAudioRouter(bridge: driver, system: system)
        router.update(route: .mirror, displays: [desk])
        XCTAssertEqual(system.created.last?.main, headphones.uid)
        system.devices.removeAll { $0.uid == headphones.uid }
        router.update(route: .mirror, displays: [desk])
        XCTAssertEqual(system.created.count, 2)
        XCTAssertEqual(system.created.last?.main, speakers.uid)
        XCTAssertEqual(system.created.last?.members, [speakers.uid, desk.uid])
        XCTAssertEqual(system.defaultUID, MacAudioRoutePlan.mirrorUID)
    }

    /// An output picked outside the app is left alone, and the route says
    /// where the sound went and how to send it back.
    func testAnOutputPickedElsewhereIsNotedNotOverruled() {
        let driver = FakeDisplayAudioDriver()
        let system = FakeMacOutputSystem(
            devices: [speakers, headphones], defaultUID: speakers.uid)
        system.show([desk])
        let router = MacAudioRouter(bridge: driver, system: system)
        XCTAssertNil(router.update(route: .displaysOnly, displays: [desk]).note)
        system.defaultUID = headphones.uid
        let plan = router.update(route: .displaysOnly, displays: [desk])
        XCTAssertEqual(system.defaultUID, headphones.uid)
        XCTAssertTrue(plan.note?.contains("\"Headphones\"") == true, plan.note ?? "")
        XCTAssertTrue(plan.note?.contains("\"Desk\"") == true, plan.note ?? "")
        system.defaultUID = desk.uid
        XCTAssertNil(router.update(route: .displaysOnly, displays: [desk]).note)
    }

    /// A Mac with no output of its own while one of ours is the default: the
    /// copy waits quietly, and moves the Mac back once an output appears.
    func testRestoreWaitsForAMacOutputAndThenUsesIt() {
        let driver = FakeDisplayAudioDriver()
        let system = FakeMacOutputSystem(devices: [], defaultUID: desk.uid)
        system.show([desk])
        let router = MacAudioRouter(bridge: driver, system: system)
        router.update(route: .copy, displays: [])
        router.update(route: .copy, displays: [])
        XCTAssertNil(router.macOutputUID)
        XCTAssertEqual(system.defaultChanges, [])
        system.devices.append(speakers)
        router.update(route: .copy, displays: [])
        XCTAssertEqual(system.defaultUID, speakers.uid)
    }

    /// A display device another process registered first is never made the
    /// Mac's output: that process would get the Mac's sound.
    func testADeviceClaimedElsewhereIsNotRoutedTo() {
        let driver = FakeDisplayAudioDriver()
        driver.claimedElsewhere = [desk.uid]
        let system = FakeMacOutputSystem(devices: [speakers], defaultUID: speakers.uid)
        // macOS lists the other owner's device under that owner's suffix.
        system.devices.append(MacOutputDevice(
            uid: desk.uid + ".0123456789abcdef", name: "Desk", isBuiltIn: false))
        let router = MacAudioRouter(bridge: driver, system: system)
        let plan = router.update(route: .displaysOnly, displays: [desk])
        XCTAssertEqual(system.defaultUID, speakers.uid)
        XCTAssertEqual(plan.target, .restore)
        XCTAssertTrue(plan.note?.contains("claimed") == true, plan.note ?? "")
        XCTAssertTrue(plan.note?.contains("\"Desk\"") == true, plan.note ?? "")
    }

    /// The default output and Multi-Output members are named by the UIDs
    /// macOS lists, which carry this app's suffix, not as registered.
    func testRoutesByTheDevicesMacOSUIDs() {
        let driver = FakeDisplayAudioDriver()
        driver.suffix = ".0123456789abcdef"
        let listed = DisplayAudioDeviceSpec(
            uid: desk.uid + driver.suffix, name: desk.name, latencyFrames: desk.latencyFrames)
        let system = FakeMacOutputSystem(devices: [speakers], defaultUID: speakers.uid)
        system.show([listed])
        let router = MacAudioRouter(bridge: driver, system: system)
        let plan = router.update(route: .displaysOnly, displays: [desk])
        XCTAssertEqual(plan.target, .device(uid: listed.uid))
        XCTAssertEqual(system.defaultUID, listed.uid)
        XCTAssertEqual(driver.lastRegistration, [desk], "registered as the display's own UID")
    }

    /// Claims are found in the device list the pass has already read, not by
    /// reading it again on the main thread for every missing display.
    func testAClaimIsFoundWithoutReadingTheDeviceListAgain() {
        let driver = FakeDisplayAudioDriver()
        driver.devicesAppearOnRegister = false
        let system = FakeMacOutputSystem(devices: [speakers], defaultUID: speakers.uid)
        system.devices.append(MacOutputDevice(
            uid: desk.uid + ".ffffffffffffffff", name: "Desk", isBuiltIn: false))
        let router = MacAudioRouter(bridge: driver, system: system)
        var plan = router.update(route: .displaysOnly, displays: [desk, shelf])
        plan = router.update(route: .displaysOnly, displays: [desk, shelf])
        XCTAssertEqual(driver.claimScans, 0)
        XCTAssertTrue(plan.note?.contains("claimed") == true, plan.note ?? "")
        XCTAssertTrue(plan.note?.contains("\"Desk\"") == true, plan.note ?? "")
        XCTAssertFalse(plan.note?.contains("Shelf") == true, "only the claimed one")
        XCTAssertEqual(system.defaultUID, speakers.uid)
    }

    /// The driver lists a device under this app's UID that this app does not
    /// own: noted, and never made the Mac's output.
    func testAListedDeviceThisAppDoesNotOwnIsNotRoutedTo() {
        let driver = FakeDisplayAudioDriver()
        driver.listedButNotOwned = [desk.uid]
        let system = FakeMacOutputSystem(devices: [speakers], defaultUID: speakers.uid)
        system.show([desk])
        let router = MacAudioRouter(bridge: driver, system: system)
        let plan = router.update(route: .displaysOnly, displays: [desk])
        XCTAssertEqual(system.defaultUID, speakers.uid)
        XCTAssertEqual(plan.target, .restore)
        XCTAssertTrue(plan.note?.contains("claimed") == true, plan.note ?? "")
    }

    /// Registered, but every one of the driver's devices is held by other
    /// apps: the route says so instead of waiting for a device that cannot come.
    func testAFullDriverSaysSo() {
        let driver = FakeDisplayAudioDriver()
        driver.devicesAppearOnRegister = false
        driver.heldDevices = DisplayAudioDriverProtocol.maxDevices
        let system = FakeMacOutputSystem(devices: [speakers], defaultUID: speakers.uid)
        let router = MacAudioRouter(bridge: driver, system: system)
        let first = router.update(route: .displaysOnly, displays: [desk])
        XCTAssertFalse(
            first.note?.contains("no room") == true,
            "one pass is not enough: the driver may not have caught up")
        let plan = router.update(route: .displaysOnly, displays: [desk])
        XCTAssertTrue(plan.note?.contains("no room") == true, plan.note ?? "")
        XCTAssertTrue(plan.note?.contains("\"Desk\"") == true, plan.note ?? "")
        XCTAssertTrue(plan.note?.contains("8 of its 8 devices are in use by other apps") == true,
                      plan.note ?? "")
        driver.heldDevices = 3
        let waiting = router.update(route: .displaysOnly, displays: [desk])
        XCTAssertFalse(waiting.note?.contains("no room") == true, waiting.note ?? "")
    }

    /// A change of displays, or a refused registration, starts the count
    /// again: the next pass may read the driver before it caught up.
    func testAFullCountStartsAgainAfterAChange() {
        let driver = FakeDisplayAudioDriver()
        driver.devicesAppearOnRegister = false
        driver.heldDevices = DisplayAudioDriverProtocol.maxDevices
        let system = FakeMacOutputSystem(devices: [speakers], defaultUID: speakers.uid)
        let router = MacAudioRouter(bridge: driver, system: system)
        router.update(route: .displaysOnly, displays: [desk, shelf])
        XCTAssertTrue(router.update(route: .displaysOnly, displays: [desk, shelf])
            .note?.contains("no room") == true)
        let changed = router.update(route: .displaysOnly, displays: [desk])
        XCTAssertFalse(changed.note?.contains("no room") == true, changed.note ?? "")
        XCTAssertTrue(router.update(route: .displaysOnly, displays: [desk])
            .note?.contains("no room") == true)
        driver.refuseRegistrations = true
        XCTAssertTrue(router.update(route: .displaysOnly, displays: [desk])
            .note?.contains("refused") == true)
        driver.refuseRegistrations = false
        let back = router.update(route: .displaysOnly, displays: [desk])
        XCTAssertFalse(back.note?.contains("no room") == true, back.note ?? "")
    }

    /// A full driver and a claimed display are both said.
    func testAFullDriverAndAClaimedDisplayAreBothNoted() {
        let driver = FakeDisplayAudioDriver()
        driver.devicesAppearOnRegister = false
        driver.heldDevices = DisplayAudioDriverProtocol.maxDevices
        let system = FakeMacOutputSystem(devices: [speakers], defaultUID: speakers.uid)
        system.devices.append(MacOutputDevice(
            uid: desk.uid + ".0123456789abcdef", name: "Desk", isBuiltIn: false))
        let router = MacAudioRouter(bridge: driver, system: system)
        router.update(route: .displaysOnly, displays: [desk, shelf])
        let plan = router.update(route: .displaysOnly, displays: [desk, shelf])
        XCTAssertTrue(plan.note?.contains("no room for \"Shelf\"") == true, plan.note ?? "")
        XCTAssertTrue(plan.note?.contains("claimed the output device for \"Desk\"") == true,
                      plan.note ?? "")
    }

    /// The plan's own note is kept beside a claimed display's: mirroring on
    /// a Mac with no output of its own says both.
    func testThePlansOwnNoteIsKeptBesideAClaim() {
        let driver = FakeDisplayAudioDriver()
        let system = FakeMacOutputSystem(devices: [], defaultUID: nil)
        system.show([shelf])
        system.devices.append(MacOutputDevice(
            uid: desk.uid + ".0123456789abcdef", name: "Desk", isBuiltIn: false))
        driver.claimedElsewhere = [desk.uid]
        let router = MacAudioRouter(bridge: driver, system: system)
        let plan = router.update(route: .mirror, displays: [desk, shelf])
        XCTAssertTrue(plan.note?.contains("no output of its own to mirror") == true,
                      plan.note ?? "")
        XCTAssertTrue(plan.note?.contains("claimed the output device for \"Desk\"") == true,
                      plan.note ?? "")
    }

    /// Every display claimed: no "waiting for the device to appear", since
    /// it has appeared, only not for this app.
    func testAClaimIsNotAlsoCalledWaiting() {
        let driver = FakeDisplayAudioDriver()
        driver.claimedElsewhere = [desk.uid]
        let system = FakeMacOutputSystem(devices: [speakers], defaultUID: speakers.uid)
        system.devices.append(MacOutputDevice(
            uid: desk.uid + ".0123456789abcdef", name: "Desk", isBuiltIn: false))
        let router = MacAudioRouter(bridge: driver, system: system)
        let plan = router.update(route: .displaysOnly, displays: [desk])
        XCTAssertFalse(plan.note?.contains("Waiting") == true, plan.note ?? "")
        XCTAssertTrue(plan.note?.contains("claimed") == true, plan.note ?? "")
    }

    /// A refusal is said on its own: with nothing registered no device can
    /// be present, so the plan's only note is the generic "waiting".
    func testARefusalIsNotAlsoCalledWaiting() {
        let driver = FakeDisplayAudioDriver()
        driver.refuseRegistrations = true
        let router = MacAudioRouter(
            bridge: driver, system: FakeMacOutputSystem(devices: [], defaultUID: nil))
        let plan = router.update(route: .mirror, displays: [desk])
        XCTAssertTrue(plan.note?.contains("refused") == true, plan.note ?? "")
        XCTAssertFalse(plan.note?.contains("Waiting") == true, plan.note ?? "")
    }

    /// While the driver is full, an output picked elsewhere is still said,
    /// and the generic "waiting" note gives way to the no-room one.
    func testAPickElsewhereIsStillSaidWhileTheDriverIsFull() {
        let driver = FakeDisplayAudioDriver()
        let system = FakeMacOutputSystem(
            devices: [speakers, headphones], defaultUID: speakers.uid)
        system.show([desk])
        let router = MacAudioRouter(bridge: driver, system: system)
        router.update(route: .displaysOnly, displays: [desk])
        system.defaultUID = headphones.uid
        driver.heldDevices = DisplayAudioDriverProtocol.maxDevices
        driver.devicesAppearOnRegister = false
        router.update(route: .displaysOnly, displays: [desk, shelf])
        let plan = router.update(route: .displaysOnly, displays: [desk, shelf])
        XCTAssertTrue(plan.note?.contains("no room for \"Shelf\"") == true, plan.note ?? "")
        XCTAssertTrue(plan.note?.contains("picked outside this app") == true, plan.note ?? "")

        let empty = FakeDisplayAudioDriver()
        empty.devicesAppearOnRegister = false
        empty.heldDevices = DisplayAudioDriverProtocol.maxDevices
        let lone = MacAudioRouter(
            bridge: empty,
            system: FakeMacOutputSystem(devices: [speakers], defaultUID: speakers.uid))
        lone.update(route: .displaysOnly, displays: [desk])
        let full = lone.update(route: .displaysOnly, displays: [desk])
        XCTAssertFalse(full.note?.contains("Waiting") == true, full.note ?? "")
        XCTAssertTrue(full.note?.contains("no room") == true, full.note ?? "")
    }

    /// Some of the full driver's devices are this app's own: the note counts
    /// only the others, and says so when this app itself has every one.
    func testAFullDriverCountsOnlyOtherAppsDevices() {
        let driver = FakeDisplayAudioDriver()
        driver.devicesAppearOnRegister = false
        driver.heldDevices = DisplayAudioDriverProtocol.maxDevices
        let system = FakeMacOutputSystem(devices: [speakers], defaultUID: speakers.uid)
        system.show([desk])
        driver.addDevice(uid: desk.uid, id: 300)
        let router = MacAudioRouter(bridge: driver, system: system)
        router.update(route: .displaysOnly, displays: [desk, shelf])
        let some = router.update(route: .displaysOnly, displays: [desk, shelf])
        XCTAssertTrue(some.note?.contains("7 of its 8 devices are in use by other apps") == true,
                      some.note ?? "")
        XCTAssertTrue(some.note?.contains("\"Shelf\"") == true, some.note ?? "")

        // Nine displays: this app holds all eight devices itself.
        let many = (0..<9).map {
            DisplayAudioDeviceSpec(
                uid: "com.espdisplay.display.\($0)", name: "D\($0)", latencyFrames: 0)
        }
        let busy = FakeDisplayAudioDriver()
        busy.devicesAppearOnRegister = false
        busy.heldDevices = DisplayAudioDriverProtocol.maxDevices
        for (index, spec) in many.prefix(8).enumerated() {
            busy.addDevice(uid: spec.uid, id: AudioObjectID(400 + index))
        }
        let crowded = FakeMacOutputSystem(devices: [speakers], defaultUID: speakers.uid)
        crowded.show(Array(many.prefix(8)))
        let own = MacAudioRouter(bridge: busy, system: crowded)
        own.update(route: .mirror, displays: many)
        let all = own.update(route: .mirror, displays: many)
        XCTAssertTrue(all.note?.contains("already uses all 8") == true, all.note ?? "")
        XCTAssertTrue(all.note?.contains("\"D8\"") == true, all.note ?? "")
    }

    /// A driver with no room left for this app says so rather than leaving
    /// the route waiting for devices that will never come.
    func testARefusedRegistrationIsNoted() {
        let driver = FakeDisplayAudioDriver()
        driver.refuseRegistrations = true
        let system = FakeMacOutputSystem(devices: [speakers], defaultUID: speakers.uid)
        let router = MacAudioRouter(bridge: driver, system: system)
        let plan = router.update(route: .displaysOnly, displays: [desk])
        XCTAssertTrue(plan.note?.contains("refused") == true, plan.note ?? "")
        XCTAssertEqual(system.defaultUID, speakers.uid)
    }

    /// The output changed to AirPods while mirroring and the user then picks
    /// the mirror again, as the note says: it is rebuilt on the AirPods.
    func testPickingTheMirrorAgainRebuildsItOnTheMacsNewOutput() {
        let driver = FakeDisplayAudioDriver()
        let system = FakeMacOutputSystem(
            devices: [speakers, headphones], defaultUID: speakers.uid)
        system.show([desk])
        let router = MacAudioRouter(bridge: driver, system: system)
        router.update(route: .mirror, displays: [desk])
        XCTAssertEqual(system.created.last?.main, speakers.uid)
        system.defaultUID = headphones.uid
        XCTAssertNotNil(router.update(route: .mirror, displays: [desk]).note)
        XCTAssertEqual(system.created.count, 1, "an outside pick is left alone")
        system.defaultUID = MacAudioRoutePlan.mirrorUID
        let plan = router.update(route: .mirror, displays: [desk])
        XCTAssertEqual(system.created.count, 2)
        XCTAssertEqual(system.created.last?.main, headphones.uid)
        XCTAssertEqual(system.defaultUID, MacAudioRoutePlan.mirrorUID)
        XCTAssertEqual(system.destroyedWhileDefault, [])
        XCTAssertNil(plan.note)
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
        downlinks.update(effective: .displaysOnly, identities: devices)
        let device = downlinks.source(for: "espdisp-desk")
        XCTAssertTrue(device.key.hasPrefix("device|\(desk.uid)#absent|"), device.key)
        XCTAssertEqual(device.sourceName, "Mac output \"Desk\"")
        // A device the driver made again is a new source, so the session
        // reopens it rather than reading a dead object.
        downlinks.update(
            effective: .displaysOnly, identities: devices, deviceIDs: [desk.uid: 300])
        let remade = downlinks.source(for: "espdisp-desk")
        XCTAssertNotEqual(remade.key, device.key)
        XCTAssertEqual(remade.key, downlinks.source(for: "espdisp-desk").key)
        // A display not known yet gets silence, never the tap and its prompt.
        let pending = downlinks.source(for: "unknown")
        XCTAssertTrue(pending.key.hasPrefix("device|pending|"), pending.key)
        XCTAssertTrue(pending.access.request == nil)

        downlinks.update(effective: .copy, identities: devices)
        XCTAssertEqual(downlinks.source(for: "espdisp-desk").key, "tap")
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
