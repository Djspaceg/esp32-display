import CoreAudio
import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// A Mac whose outputs and default output are just values, so no test moves
/// the default output of the Mac running it.
@MainActor
class FakeMacOutputSystem: MacOutputSystem {
    var devices: [MacOutputDevice]

    init(devices: [MacOutputDevice]) {
        self.devices = devices
    }

    func outputDevices() -> [MacOutputDevice] { devices }

    /// The driver's devices, as they appear once registered.
    func show(_ specs: [DisplayAudioDeviceSpec]) {
        for spec in specs where !devices.contains(where: { $0.uid == spec.uid }) {
            devices.append(MacOutputDevice(uid: spec.uid, name: spec.name))
        }
    }
}

@MainActor
final class MacAudioRouteTests: XCTestCase {
    private let speakers = MacOutputDevice(
        uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")
    private let headphones = MacOutputDevice(
        uid: "USBHeadphones", name: "Headphones")
    private let desk = DisplayAudioDeviceSpec(
        uid: "com.resourcefork.espdisplay.display.AAAA", name: "Desk", latencyFrames: 7_200)
    private let shelf = DisplayAudioDeviceSpec(
        uid: "com.resourcefork.espdisplay.display.BBBB", name: "Shelf", latencyFrames: 7_200)

    // MARK: - The plan

    func testCopyNeedsNoDriver() {
        let plan = MacAudioRoutePlan.make(
            chosen: .copy, driver: .absent, presentDisplayUIDs: [])
        XCTAssertEqual(plan.effective, .copy)
        XCTAssertNil(plan.note)
    }

    /// Following the Mac without the driver never falls back to copying the
    /// Mac's sound: the devices stay quiet, and the note says how to install.
    func testAMissingDriverLeavesTheDevicesQuietAndSaysHowToInstall() {
        for route in [MacAudioRoute.followMac] {
            let plan = MacAudioRoutePlan.make(
                chosen: route, driver: .absent, presentDisplayUIDs: [])
            XCTAssertEqual(plan.chosen, route)
            XCTAssertEqual(plan.effective, .followMac)
            XCTAssertTrue(plan.note?.contains("stay quiet") == true, plan.note ?? "")
            XCTAssertTrue(plan.note?.contains("not installed") == true, plan.note ?? "")
            XCTAssertTrue(
                plan.note?.contains("Install Audio Driver") == true, plan.note ?? "")
        }
    }

    func testADriverFromAnotherBuildIsNotUsed() {
        let plan = MacAudioRoutePlan.make(
            chosen: .followMac, driver: .incompatible(version: 2),
            presentDisplayUIDs: ["d"])
        XCTAssertEqual(plan.effective, .followMac)
        XCTAssertTrue(plan.note?.contains("stay quiet") == true, plan.note ?? "")
        XCTAssertTrue(plan.note?.contains("version 2") == true, plan.note ?? "")
    }

    func testNoDeviceOutputYetIsAWait() {
        let plan = MacAudioRoutePlan.make(
            chosen: .followMac, driver: .ready, presentDisplayUIDs: [])
        XCTAssertEqual(plan.effective, .followMac)
        XCTAssertEqual(plan.note, MacAudioRoutePlan.waitingNote)
    }

    // MARK: - The router

    /// A display device another process registered first is never made the
    /// Mac's output: that process would get the Mac's sound.
    func testADeviceClaimedElsewhereIsNotRoutedTo() {
        let driver = FakeDisplayAudioDriver()
        driver.claimedElsewhere = [desk.uid]
        let system = FakeMacOutputSystem(devices: [speakers])
        // macOS lists the other owner's device under that owner's suffix.
        system.devices.append(MacOutputDevice(
            uid: desk.uid + ".0123456789abcdef", name: "Desk"))
        let router = MacAudioRouter(bridge: driver, system: system)
        let plan = router.update(route: .followMac, displays: [desk])
        XCTAssertTrue(plan.note?.contains("claimed") == true, plan.note ?? "")
        XCTAssertTrue(plan.note?.contains("\"Desk\"") == true, plan.note ?? "")
    }

    /// Claims are found in the device list the pass has already read, not by
    /// reading it again on the main thread for every missing display.
    func testAClaimIsFoundWithoutReadingTheDeviceListAgain() {
        let driver = FakeDisplayAudioDriver()
        driver.devicesAppearOnRegister = false
        let system = FakeMacOutputSystem(devices: [speakers])
        system.devices.append(MacOutputDevice(
            uid: desk.uid + ".ffffffffffffffff", name: "Desk"))
        let router = MacAudioRouter(bridge: driver, system: system)
        var plan = router.update(route: .followMac, displays: [desk, shelf])
        plan = router.update(route: .followMac, displays: [desk, shelf])
        XCTAssertEqual(driver.claimScans, 0)
        XCTAssertTrue(plan.note?.contains("claimed") == true, plan.note ?? "")
        XCTAssertTrue(plan.note?.contains("\"Desk\"") == true, plan.note ?? "")
        XCTAssertFalse(plan.note?.contains("Shelf") == true, "only the claimed one")
    }

    /// The driver lists a device under this app's UID that this app does not
    /// own: noted, and never made the Mac's output.
    func testAListedDeviceThisAppDoesNotOwnIsNotRoutedTo() {
        let driver = FakeDisplayAudioDriver()
        driver.listedButNotOwned = [desk.uid]
        let system = FakeMacOutputSystem(devices: [speakers])
        system.show([desk])
        let router = MacAudioRouter(bridge: driver, system: system)
        let plan = router.update(route: .followMac, displays: [desk])
        XCTAssertTrue(plan.note?.contains("claimed") == true, plan.note ?? "")
    }

    /// Registered, but every one of the driver's devices is held by other
    /// apps: the route says so instead of waiting for a device that cannot come.
    func testAFullDriverSaysSo() {
        let driver = FakeDisplayAudioDriver()
        driver.devicesAppearOnRegister = false
        driver.heldDevices = DisplayAudioDriverProtocol.maxDevices
        let system = FakeMacOutputSystem(devices: [speakers])
        let router = MacAudioRouter(bridge: driver, system: system)
        let first = router.update(route: .followMac, displays: [desk])
        XCTAssertFalse(
            first.note?.contains("no room") == true,
            "one pass is not enough: the driver may not have caught up")
        let plan = router.update(route: .followMac, displays: [desk])
        XCTAssertTrue(plan.note?.contains("no room") == true, plan.note ?? "")
        XCTAssertTrue(plan.note?.contains("\"Desk\"") == true, plan.note ?? "")
        XCTAssertTrue(plan.note?.contains("8 of its 8 outputs are in use by other apps") == true,
                      plan.note ?? "")
        driver.heldDevices = 3
        let waiting = router.update(route: .followMac, displays: [desk])
        XCTAssertFalse(waiting.note?.contains("no room") == true, waiting.note ?? "")
    }

    /// A change of displays, or a refused registration, starts the count
    /// again: the next pass may read the driver before it caught up.
    func testAFullCountStartsAgainAfterAChange() {
        let driver = FakeDisplayAudioDriver()
        driver.devicesAppearOnRegister = false
        driver.heldDevices = DisplayAudioDriverProtocol.maxDevices
        let system = FakeMacOutputSystem(devices: [speakers])
        let router = MacAudioRouter(bridge: driver, system: system)
        router.update(route: .followMac, displays: [desk, shelf])
        XCTAssertTrue(router.update(route: .followMac, displays: [desk, shelf])
            .note?.contains("no room") == true)
        let changed = router.update(route: .followMac, displays: [desk])
        XCTAssertFalse(changed.note?.contains("no room") == true, changed.note ?? "")
        XCTAssertTrue(router.update(route: .followMac, displays: [desk])
            .note?.contains("no room") == true)
        driver.refuseRegistrations = true
        XCTAssertTrue(router.update(route: .followMac, displays: [desk])
            .note?.contains("refused") == true)
        driver.refuseRegistrations = false
        let back = router.update(route: .followMac, displays: [desk])
        XCTAssertFalse(back.note?.contains("no room") == true, back.note ?? "")
    }

    /// A full driver and a claimed display are both said.
    func testAFullDriverAndAClaimedDisplayAreBothNoted() {
        let driver = FakeDisplayAudioDriver()
        driver.devicesAppearOnRegister = false
        driver.heldDevices = DisplayAudioDriverProtocol.maxDevices
        let system = FakeMacOutputSystem(devices: [speakers])
        system.devices.append(MacOutputDevice(
            uid: desk.uid + ".0123456789abcdef", name: "Desk"))
        let router = MacAudioRouter(bridge: driver, system: system)
        router.update(route: .followMac, displays: [desk, shelf])
        let plan = router.update(route: .followMac, displays: [desk, shelf])
        XCTAssertTrue(plan.note?.contains("no room for \"Shelf\"") == true, plan.note ?? "")
        XCTAssertTrue(plan.note?.contains("claimed the output for \"Desk\"") == true,
                      plan.note ?? "")
    }

    /// Every display claimed: no "waiting for the device to appear", since
    /// it has appeared, only not for this app.
    func testAClaimIsNotAlsoCalledWaiting() {
        let driver = FakeDisplayAudioDriver()
        driver.claimedElsewhere = [desk.uid]
        let system = FakeMacOutputSystem(devices: [speakers])
        system.devices.append(MacOutputDevice(
            uid: desk.uid + ".0123456789abcdef", name: "Desk"))
        let router = MacAudioRouter(bridge: driver, system: system)
        let plan = router.update(route: .followMac, displays: [desk])
        XCTAssertFalse(plan.note?.contains("Waiting") == true, plan.note ?? "")
        XCTAssertTrue(plan.note?.contains("claimed") == true, plan.note ?? "")
    }

    /// A refusal is said on its own: with nothing registered no device can
    /// be present, so the plan's only note is the generic "waiting".
    func testARefusalIsNotAlsoCalledWaiting() {
        let driver = FakeDisplayAudioDriver()
        driver.refuseRegistrations = true
        let router = MacAudioRouter(
            bridge: driver, system: FakeMacOutputSystem(devices: []))
        let plan = router.update(route: .followMac, displays: [desk])
        XCTAssertTrue(plan.note?.contains("refused") == true, plan.note ?? "")
        XCTAssertFalse(plan.note?.contains("Waiting") == true, plan.note ?? "")
    }

    /// Some of the full driver's devices are this app's own: the note counts
    /// only the others, and says so when this app itself has every one.
    func testAFullDriverCountsOnlyOtherAppsDevices() {
        let driver = FakeDisplayAudioDriver()
        driver.devicesAppearOnRegister = false
        driver.heldDevices = DisplayAudioDriverProtocol.maxDevices
        let system = FakeMacOutputSystem(devices: [speakers])
        system.show([desk])
        driver.addDevice(uid: desk.uid, id: 300)
        let router = MacAudioRouter(bridge: driver, system: system)
        router.update(route: .followMac, displays: [desk, shelf])
        let some = router.update(route: .followMac, displays: [desk, shelf])
        XCTAssertTrue(some.note?.contains("7 of its 8 outputs are in use by other apps") == true,
                      some.note ?? "")
        XCTAssertTrue(some.note?.contains("\"Shelf\"") == true, some.note ?? "")

        // Nine displays: this app holds all eight devices itself.
        let many = (0..<9).map {
            DisplayAudioDeviceSpec(
                uid: "com.resourcefork.espdisplay.display.\($0)", name: "D\($0)", latencyFrames: 0)
        }
        let busy = FakeDisplayAudioDriver()
        busy.devicesAppearOnRegister = false
        busy.heldDevices = DisplayAudioDriverProtocol.maxDevices
        for (index, spec) in many.prefix(8).enumerated() {
            busy.addDevice(uid: spec.uid, id: AudioObjectID(400 + index))
        }
        let crowded = FakeMacOutputSystem(devices: [speakers])
        crowded.show(Array(many.prefix(8)))
        let own = MacAudioRouter(bridge: busy, system: crowded)
        own.update(route: .followMac, displays: many)
        let all = own.update(route: .followMac, displays: many)
        XCTAssertTrue(all.note?.contains("already uses all 8") == true, all.note ?? "")
        XCTAssertTrue(all.note?.contains("\"D8\"") == true, all.note ?? "")
    }

    /// A driver with no room left for this app says so rather than leaving
    /// the route waiting for devices that will never come.
    func testARefusedRegistrationIsNoted() {
        let driver = FakeDisplayAudioDriver()
        driver.refuseRegistrations = true
        let system = FakeMacOutputSystem(devices: [speakers])
        let router = MacAudioRouter(bridge: driver, system: system)
        let plan = router.update(route: .followMac, displays: [desk])
        XCTAssertTrue(plan.note?.contains("refused") == true, plan.note ?? "")
    }

    /// Switching to the copy withdraws the devices' outputs and leaves the
    /// Mac's output where it is, ours included: macOS moves it off an output
    /// that goes away.
    func testSwitchingToTheCopyWithdrawsTheDevicesAndTouchesNoOutput() {
        let driver = FakeDisplayAudioDriver()
        let system = FakeMacOutputSystem(devices: [speakers])
        system.show([desk, shelf])
        let router = MacAudioRouter(bridge: driver, system: system)
        router.update(route: .followMac, displays: [desk, shelf])
        XCTAssertEqual(driver.lastRegistration, [desk, shelf])
        let plan = router.update(route: .copy, displays: [desk, shelf])
        XCTAssertEqual(plan.effective, .copy)
        XCTAssertEqual(driver.lastRegistration, [], "the devices are withdrawn")
    }

    func testAMissingDriverRegistersNothingAndTouchesNoOutput() {
        let driver = FakeDisplayAudioDriver()
        driver.state = .absent
        let system = FakeMacOutputSystem(devices: [speakers])
        let router = MacAudioRouter(bridge: driver, system: system)
        let plan = router.update(route: .followMac, displays: [desk])
        XCTAssertEqual(plan.effective, .followMac)
        XCTAssertTrue(driver.registrations.allSatisfy(\.isEmpty))
    }

    // MARK: - What each session is given

    func testSessionsGetTheirDisplayDeviceOrTheTapWithTheNote() throws {
        let driver = FakeDisplayAudioDriver()
        let downlinks = PanelAudioDownlinks(bridge: driver)
        let devices = ["espdisp-desk": desk]
        downlinks.update(effective: .followMac, identities: devices)
        let device = downlinks.source(for: "espdisp-desk")
        XCTAssertTrue(device.key.hasPrefix("device|\(desk.uid)#absent|"), device.key)
        XCTAssertEqual(device.sourceName, "Mac output \"Desk\"")
        // A device the driver made again is a new source, so the session
        // reopens it rather than reading a dead object.
        downlinks.update(
            effective: .followMac, identities: devices, deviceIDs: [desk.uid: 300])
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

    func testTheRouteIsSavedAndAnUnreadableOneFollowsTheMac() throws {
        var settings = SenderSettings()
        XCTAssertEqual(settings.macAudioRoute, .followMac)
        settings.macAudioRoute = .copy
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(SenderSettings.self, from: data).macAudioRoute,
                       .copy)
        XCTAssertEqual(settings.validated.macAudioRoute, .copy)
        let unknown = try JSONDecoder().decode(
            SenderSettings.self, from: Data("{\"macAudioRoute\": \"surround\"}".utf8))
        XCTAssertEqual(unknown.macAudioRoute, .followMac)
        // The route itself maps the old names, not only the file's fallback.
        XCTAssertEqual(
            try JSONDecoder().decode(
                [MacAudioRoute].self, from: Data(#"["displaysOnly", "mirror", "copy"]"#.utf8)),
            [.followMac, .copy, .copy])
        XCTAssertThrowsError(
            try JSONDecoder().decode([MacAudioRoute].self, from: Data(#"["surround"]"#.utf8)))
    }

    func testAManagerNobodyStartedNeverRoutes() {
        let manager = PanelManager(
            previewPanels: [], savedNetworkNames: [], usbSerialPorts: [])
        XCTAssertNil(manager.macAudio.router)
        manager.setMacAudioRoute(.copy)
        XCTAssertNil(manager.macAudioRoutePlan)
        XCTAssertEqual(manager.settings.macAudioRoute, .copy)
    }
}
