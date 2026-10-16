import CoreAudio
import Foundation
import SenderProtocol

/// The source each display's audio session should use, readable from any
/// thread: sessions are built by `DeviceSession` wherever it reconciles audio,
/// and a session built on the wrong source would open the tap, and possibly
/// its permission prompt, before being switched.
final class PanelAudioDownlinks: @unchecked Sendable {
    private let lock = NSLock()
    private let bridge: DisplayAudioDriverBridge
    private var effective = MacAudioRoute.copy
    /// Every display record, not only the ones with a device yet, so a
    /// session built before the next pass still gets its own device.
    private var identities: [String: DisplayAudioDeviceSpec] = [:]
    /// Each display device's current object ID. Part of a source's key, so a
    /// device the driver made again reopens the session on the new one.
    private var deviceIDs: [String: AudioObjectID] = [:]

    init(bridge: DisplayAudioDriverBridge) {
        self.bridge = bridge
    }

    func update(
        effective: MacAudioRoute,
        identities: [String: DisplayAudioDeviceSpec],
        deviceIDs: [String: AudioObjectID] = [:]
    ) {
        lock.withLock {
            self.effective = effective
            self.identities = identities
            self.deviceIDs = deviceIDs
        }
    }

    func source(for serviceName: String) -> PanelDownlinkSource {
        lock.withLock {
            // Only the copy taps the Mac's sound; following the Mac plays a
            // device's own output, or nothing.
            guard effective.usesDriver else { return .systemTap() }
            guard let device = identities[serviceName] else {
                // Not a display this app knows yet (a probe of a new board):
                // silence until it is, never the tap and its prompt.
                return .displayDevice(
                    name: serviceName, route: effective,
                    capture: SystemAudioCaptureSource(open: {
                        throw NSError(
                            domain: "ESPDisplaySender.Audio", code: 5,
                            userInfo: [NSLocalizedDescriptionKey:
                                "the device is not known to this Mac yet."])
                    }),
                    identity: "pending")
            }
            let bridge = bridge
            let uid = device.uid
            let id = deviceIDs[uid].map(String.init) ?? "absent"
            return .displayDevice(
                name: device.name, route: effective,
                capture: .displayDevice(uid: uid, bridge: bridge),
                identity: uid + "#" + id)
        }
    }
}

/// The app's whole Mac-audio routing state. The router exists only once the
/// app starts it, so a test that builds a `PanelManager` never registers
/// devices or moves the default output of the Mac running it.
@MainActor
final class MacAudioRouting {
    let bridge: DisplayAudioDriverBridge
    let downlinks: PanelAudioDownlinks
    private(set) var router: MacAudioRouter?
    private(set) var plan: MacAudioRoutePlan?
    /// Whether the driver is installed, looked for on every pass whatever the
    /// route, so the Install button shows only while it is missing.
    private(set) var driverAvailability: DisplayAudioDriverAvailability?
    /// The Install / Remove Audio Driver row.
    var setup = DisplayAudioDriverSetup(bundledDriver: false, signingTeam: nil)
    var runner = PrivilegedRunner.system
    private var timer: Timer?

    /// Seconds between passes. Each pass is the driver's heartbeat, well
    /// inside its ten-second timeout.
    static let interval: TimeInterval = 2

    init(bridge: DisplayAudioDriverBridge = CoreAudioDisplayAudioDriver.shared) {
        self.bridge = bridge
        downlinks = PanelAudioDownlinks(bridge: bridge)
    }

    /// `tick` runs every `interval`, in the run loop's common modes: a modal
    /// panel or an open menu must not stop the heartbeat, or the driver drops
    /// the displays' devices and the Mac's output moves.
    func start(system: MacOutputSystem, tick: @escaping @MainActor () -> Void) {
        guard router == nil else { return }
        router = MacAudioRouter(bridge: bridge, system: system)
        setup = DisplayAudioDriverSetup(
            bundledDriver: DisplayAudioDriverInstaller.bundledDriver() != nil,
            signingTeam: DisplayAudioDriverInstaller.signingTeam())
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        // A password dialog still up when the app quits must not install or
        // remove anything once it is answered.
        PrivilegedRunner.terminateRunning()
        timer?.invalidate()
        timer = nil
        router?.shutdown()
        router = nil
    }

    /// Lets an offscreen render show a route's note without CoreAudio.
    func showForTesting(_ plan: MacAudioRoutePlan) { self.plan = plan }

    /// Lets an offscreen render show the driver row without CoreAudio.
    func showForTesting(
        driver availability: DisplayAudioDriverAvailability?, setup: DisplayAudioDriverSetup
    ) {
        driverAvailability = availability
        self.setup = setup
    }

    func update(
        route: MacAudioRoute,
        devices: [String: DisplayAudioDeviceSpec],
        identities: [String: DisplayAudioDeviceSpec]
    ) {
        guard let router else { return }
        driverAvailability = bridge.availability()
        setup.observe(driverAvailability, now: Date())
        let plan = router.update(
            route: route,
            displays: devices.keys.sorted().compactMap { devices[$0] })
        self.plan = plan
        downlinks.update(
            effective: plan.effective, identities: identities,
            deviceIDs: router.presentDevices)
    }
}

extension PanelManager {
    /// Begin routing; called once by the app, never by tests.
    func startMacAudioRouting(system: MacOutputSystem? = nil) {
        macAudio.start(system: system ?? CoreAudioMacOutputSystem()) { [weak self] in
            self?.applyMacAudioRoute()
        }
        applyMacAudioRoute()
    }

    /// Put the Mac's own output back and remove the displays' devices.
    func stopMacAudioRouting() {
        macAudio.stop()
    }

    func setMacAudioRoute(_ route: MacAudioRoute) {
        guard settings.macAudioRoute != route else { return }
        var updated = settings
        updated.macAudioRoute = route
        updateSettings(updated)
        applyMacAudioRoute()
    }

    /// Each display record's device, by service name.
    func displayAudioIdentities() -> [String: DisplayAudioDeviceSpec] {
        let latency = DisplayAudioDeviceSpec.latencyFrames(tuning: settings.audioTuning)
        var identities: [String: DisplayAudioDeviceSpec] = [:]
        for panel in panels {
            identities[panel.serviceName] = DisplayAudioDeviceSpec(
                uid: DisplayAudioDeviceSpec.uid(
                    hardwareID: panel.hardwareID, serviceName: panel.serviceName),
                name: panel.displayName,
                latencyFrames: latency)
        }
        return identities
    }

    /// The display devices wanted now: every display with a running session
    /// that has, or advertises, audio.
    func displayAudioDevices(
        identities: [String: DisplayAudioDeviceSpec]
    ) -> [String: DisplayAudioDeviceSpec] {
        identities.filter { name, _ in
            guard sessions[name] != nil,
                  let panel = panels.first(where: { $0.serviceName == name })
            else { return false }
            return panel.audioStatus != nil || panel.capabilities.contains(.audioDownlink)
        }
    }

    /// Re-plan the route and hand every session its source. Runs every two
    /// seconds, which is also the driver's heartbeat.
    func applyMacAudioRoute() {
        guard macAudio.router != nil else { return }
        let rowBefore = displayAudioDriverRow
        defer {
            if displayAudioDriverRow != rowBefore { objectWillChange.send() }
        }
        let identities = displayAudioIdentities()
        macAudio.update(
            route: settings.macAudioRoute,
            devices: displayAudioDevices(identities: identities),
            identities: identities)
        for (name, session) in sessions {
            session.setAudioDownlink(macAudio.downlinks.source(for: name))
        }
    }

    var macAudioRoutePlan: MacAudioRoutePlan? { macAudio.plan }

    /// The Audio section's driver row; nil until the driver has been looked
    /// for.
    var displayAudioDriverRow: DisplayAudioDriverSetup.Presentation? {
        guard macAudio.driverAvailability != nil || macAudio.setup.phase != .idle else {
            return nil
        }
        return macAudio.setup.presentation(availability: macAudio.driverAvailability)
    }

    /// The Install or Remove Audio Driver button. macOS asks for the password;
    /// the row follows the driver appearing or going on the two-second pass.
    func runDisplayAudioDriverAction(_ action: DisplayAudioDriverAction) {
        guard macAudio.setup.begin(action, now: Date()) else { return }
        objectWillChange.send()
        let command: String
        switch action {
        case .install:
            guard let source = DisplayAudioDriverInstaller.bundledDriver(),
                  let team = macAudio.setup.signingTeam
            else {
                macAudio.setup.finished(
                    action, .failed("this build carries no signed driver."), now: Date())
                return
            }
            command = DisplayAudioDriverInstaller.installCommand(source: source, team: team)
        case .remove:
            command = DisplayAudioDriverInstaller.removeCommand()
        }
        let runner = macAudio.runner
        let prompt = DisplayAudioDriverInstaller.prompt(for: action)
        // The runner waits on the password dialog off the main thread, so the
        // window and the two-second pass carry on; the outcome lands here.
        Task { @MainActor [weak self] in
            let result = await runner.run(command, prompt)
            guard let self else { return }
            self.macAudio.setup.finished(action, result, now: Date())
            self.objectWillChange.send()
            self.applyMacAudioRoute()
        }
    }
}
