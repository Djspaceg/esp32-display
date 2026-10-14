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
    private var note: String?
    private var devices: [String: DisplayAudioDeviceSpec] = [:]

    init(bridge: DisplayAudioDriverBridge) {
        self.bridge = bridge
    }

    func update(plan: MacAudioRoutePlan, devices: [String: DisplayAudioDeviceSpec]) {
        lock.withLock {
            effective = plan.effective
            note = plan.note
            self.devices = devices
        }
    }

    func source(for serviceName: String) -> PanelDownlinkSource {
        lock.withLock {
            guard effective.usesDriver, let device = devices[serviceName] else {
                return .systemTap(note: note)
            }
            return .displayDevice(
                name: device.name, route: effective,
                capture: .displayDevice(uid: device.uid, bridge: bridge),
                identity: device.uid)
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

    init(bridge: DisplayAudioDriverBridge = CoreAudioDisplayAudioDriver.shared) {
        self.bridge = bridge
        downlinks = PanelAudioDownlinks(bridge: bridge)
    }

    func start(system: MacOutputSystem) {
        guard router == nil else { return }
        router = MacAudioRouter(bridge: bridge, system: system)
    }

    func stop() {
        router?.shutdown()
        router = nil
    }

    func update(route: MacAudioRoute, devices: [String: DisplayAudioDeviceSpec]) {
        guard let router else { return }
        let plan = router.update(
            route: route,
            displays: devices.keys.sorted().compactMap { devices[$0] })
        self.plan = plan
        downlinks.update(plan: plan, devices: devices)
    }
}

extension PanelManager {
    /// Begin routing; called once by the app, never by tests.
    func startMacAudioRouting(system: MacOutputSystem? = nil) {
        macAudio.start(system: system ?? CoreAudioMacOutputSystem())
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

    /// The display devices wanted now: every display with a running session
    /// that has, or advertises, audio.
    func displayAudioDevices() -> [String: DisplayAudioDeviceSpec] {
        let latency = DisplayAudioDeviceSpec.latencyFrames(tuning: settings.audioTuning)
        var devices: [String: DisplayAudioDeviceSpec] = [:]
        for panel in panels where sessions[panel.serviceName] != nil
            && (panel.audioStatus != nil || panel.capabilities.contains(.audioDownlink)) {
            devices[panel.serviceName] = DisplayAudioDeviceSpec(
                uid: DisplayAudioDeviceSpec.uid(
                    hardwareID: panel.hardwareID, serviceName: panel.serviceName),
                name: panel.displayName,
                latencyFrames: latency)
        }
        return devices
    }

    /// Re-plan the route and hand every session its source. Runs on the
    /// two-second refresh, which is also the driver's heartbeat.
    func applyMacAudioRoute() {
        guard macAudio.router != nil else { return }
        macAudio.update(route: settings.macAudioRoute, devices: displayAudioDevices())
        for (name, session) in sessions {
            session.setAudioDownlink(macAudio.downlinks.source(for: name))
        }
    }

    var macAudioRoutePlan: MacAudioRoutePlan? { macAudio.plan }
}
