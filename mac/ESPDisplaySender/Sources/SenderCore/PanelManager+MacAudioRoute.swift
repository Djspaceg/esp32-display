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
                                "the display is not known to this Mac yet."])
                    }),
                    identity: "pending")
            }
            let bridge = bridge
            let uid = device.uid
            let id = deviceIDs[uid].map(String.init) ?? "absent"
            return .displayDevice(
                name: device.name, route: effective,
                capture: .displayDevice(uid: uid, bridge: bridge),
                identity: uid + "#" + id,
                deviceProbe: { bridge.deviceID(uid: uid).map(String.init) })
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
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        router?.shutdown()
        router = nil
    }

    /// Lets an offscreen render show a route's note without CoreAudio.
    func showForTesting(_ plan: MacAudioRoutePlan) { self.plan = plan }

    func update(
        route: MacAudioRoute,
        devices: [String: DisplayAudioDeviceSpec],
        identities: [String: DisplayAudioDeviceSpec]
    ) {
        guard let router else { return }
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
}
