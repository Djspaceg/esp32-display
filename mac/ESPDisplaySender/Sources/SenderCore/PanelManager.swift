import AppKit
import Foundation
import Network
import ScreenCaptureKit
import SenderProtocol

/// The live view of a panel: persisted identity merged with whatever the
/// device has reported during this run. Intentionally not `Codable` — see
/// `PersistedPanel` for the subset that reaches disk.
struct PanelSnapshot: Identifiable, Equatable {
    var id: String { serviceName }

    var serviceName: String
    var displayName: String
    var hardwareID: String?
    var address: String?
    var usbPort: String?
    var discovered = false
    var lastSeen: Date?
    var lastHeartbeatAt: Date?
    var rssi: Int?
    var displayFPS = 0.0
    var framesSent: UInt64 = 0
    var sendErrors: UInt64 = 0
    var diffPercent = 0.0
    var framesShown: UInt32 = 0
    var framesDropped: UInt32 = 0
    var freeHeap: UInt32 = 0
    var spacingMicros: UInt32 = 0
    var firmwareVersion: String?
    var frameProtocolVersion: Int?
    var controlProtocolVersion: Int?
    var capabilitiesRaw: UInt32 = 0
    var uptimeSeconds: UInt32 = 0
    var brightness: Int = 0
    var brightnessHigh = true
    var flipped = false
    var sleeping = false
    var idle = false
    var paused = false
    var sourceDescription = "Automatic"
    /// Why this panel is not usable, when the reason is something the user
    /// would otherwise only find in the log. Cleared as soon as the device
    /// reports in again.
    var lastError: String?

    var capabilities: DeviceProtocol.Capabilities {
        DeviceProtocol.Capabilities(rawValue: capabilitiesRaw)
    }

    var isOnline: Bool {
        guard let lastHeartbeatAt else { return false }
        return Date().timeIntervalSince(lastHeartbeatAt) < 10
    }

    var statusText: String {
        if isOnline { return paused ? "Paused" : "Online" }
        if discovered { return "Connecting"
        }
        return "Offline"
    }

    var signalDescription: String {
        guard let rssi else { return "—" }
        if rssi >= -55 { return "Excellent (\(rssi) dBm)" }
        if rssi >= -65 { return "Good (\(rssi) dBm)" }
        if rssi >= -75 { return "Fair (\(rssi) dBm)" }
        return "Weak (\(rssi) dBm)"
    }

    var uptimeDescription: String {
        guard uptimeSeconds > 0 else { return "—" }
        let days = uptimeSeconds / 86_400
        let hours = (uptimeSeconds % 86_400) / 3_600
        let minutes = (uptimeSeconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

private extension String {
    /// Sentence-cases a phrase for use at the start of a title, without
    /// touching the rest of the words.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// The result of something the user just asked for, success or failure, shown
/// in one place. Previously failures arrived either here or as an NSAlert put
/// up by the serial layer, depending on which code path produced them.
struct OperationOutcome: Equatable {
    enum Kind: Equatable {
        case success
        case failure
    }

    var kind: Kind
    var title: String
    var message: String

    static func failure(_ failure: WifiConfigUI.ConfigFailure) -> OperationOutcome {
        OperationOutcome(kind: .failure, title: failure.title, message: failure.message)
    }

    static func failure(_ title: String, _ message: String) -> OperationOutcome {
        OperationOutcome(kind: .failure, title: title, message: message)
    }

    static func success(_ title: String, _ message: String) -> OperationOutcome {
        OperationOutcome(kind: .success, title: title, message: message)
    }
}

/// A process-wide problem the app cannot resolve on its own, so the user has
/// to be told rather than having it recorded in a log they will never read.
enum AppIssue: String, CaseIterable, Sendable {
    case screenRecording
    case deviceConfig
    case persistence

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording permission needed"
        case .deviceConfig: return "Per-display source file ignored"
        case .persistence: return "Display settings could not be saved"
        }
    }
}

/// An `AppIssue` together with the specific detail behind it.
struct ReportedIssue: Identifiable, Equatable {
    let issue: AppIssue
    let detail: String

    var id: String { issue.rawValue }
    var title: String { issue.title }
}

/// Main-actor model exposed to SwiftUI. Networking and capture continue in
/// DeviceSession; this registry only publishes immutable snapshots and routes
/// user actions to the live session for the selected panel.
@MainActor
final class PanelManager: ObservableObject {
    @Published private(set) var panels: [PanelSnapshot] = []
    @Published private(set) var savedNetworkNames: [String] = []
    @Published private(set) var usbSerialPorts: [String] = []
    @Published var selectedServiceName: String?
    /// The outcome of the most recent user-initiated action, cleared when read.
    @Published private(set) var operationOutcome: OperationOutcome?
    /// Standing problems, at most one per kind, in the order first reported.
    @Published private(set) var issues: [ReportedIssue] = []

    private var sessions: [String: DeviceSession] = [:]
    private var supersededServiceNames: Set<String> = []
    private weak var picker: PickerSource?
    private var pickerTarget: String?
    private var refreshTimer: Timer?
    private var lastPersistedAt = Date.distantPast
    /// Where the durable records live, or nil to disable persistence entirely.
    /// Previews and tests run without a file so they cannot overwrite the
    /// records belonging to the installed app.
    private let persistenceURL: URL?

    init() {
        let url = PanelStore.defaultURL
        persistenceURL = url
        let loaded = PanelStore.load(from: url)
        panels = loaded.records
            .map(\.snapshot)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        selectedServiceName = panels.first?.serviceName
        savedNetworkNames = WifiCredentialStore.savedNetworkNames()
        usbSerialPorts = WifiConfigUI.candidatePorts()
        if let failure = loaded.failure {
            report(.persistence, detail: "Saved display settings could not be read "
                + "from \(url?.path ?? "disk"): \(failure)")
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.refreshUSBPorts()
                self?.objectWillChange.send()
            }
        }
    }

#if DEBUG
    /// Preview and test seam: no disk, no timers, no discovery.
    init(
        previewPanels: [PanelSnapshot],
        savedNetworkNames: [String],
        usbSerialPorts: [String]
    ) {
        persistenceURL = nil
        panels = previewPanels
        self.savedNetworkNames = savedNetworkNames
        self.usbSerialPorts = usbSerialPorts
        selectedServiceName = previewPanels.first?.serviceName
    }
#endif

    deinit {
        refreshTimer?.invalidate()
    }

    var selectedPanel: PanelSnapshot? {
        guard let selectedServiceName else { return nil }
        return panels.first { $0.serviceName == selectedServiceName }
    }

    func attachPicker(_ picker: PickerSource) {
        self.picker = picker
        picker.onSelection = { [weak self] filter in
            Task { @MainActor in
                self?.applyPickerSelection(filter)
            }
        }
        picker.onCancellation = { [weak self] in
            Task { @MainActor in
                self?.pickerTarget = nil
            }
        }
    }

    func noteDiscovery(_ devices: [DeviceBrowser.Device]) {
        let visible = Set(devices.map(\.name))
        for index in panels.indices {
            panels[index].discovered = visible.contains(panels[index].serviceName)
        }
        for device in devices
            where !supersededServiceNames.contains(device.name)
                && !panels.contains(where: { $0.serviceName == device.name })
        {
            panels.append(PanelSnapshot(serviceName: device.name, displayName: device.name,
                                        discovered: true, lastSeen: Date()))
        }
        sortPanels()
        if selectedServiceName == nil {
            selectedServiceName = panels.first?.serviceName
        }
        persistIfNeeded(force: true)
    }

    func register(_ session: DeviceSession) {
        guard !supersededServiceNames.contains(session.name) else { return }
        sessions[session.name] = session
        if !panels.contains(where: { $0.serviceName == session.name }) {
            panels.append(PanelSnapshot(serviceName: session.name, displayName: session.name,
                                        discovered: true, lastSeen: Date()))
            sortPanels()
        }
    }

    func retire(_ serviceName: String) {
        sessions[serviceName] = nil
        guard !supersededServiceNames.contains(serviceName) else { return }
        updatePanel(serviceName) { panel in
            panel.discovered = false
            panel.displayFPS = 0
            panel.lastError = "Gave up trying to reach this display. It is retried "
                + "automatically once it reappears on the network."
        }
    }

    // MARK: problem reporting

    /// Record a standing problem, replacing any earlier report of the same kind
    /// so a repeating failure does not stack up.
    func report(_ issue: AppIssue, detail: String) {
        let reported = ReportedIssue(issue: issue, detail: detail)
        if let index = issues.firstIndex(where: { $0.issue == issue }) {
            guard issues[index] != reported else { return }
            issues[index] = reported
        } else {
            issues.append(reported)
        }
    }

    /// Withdraw a problem because it no longer applies.
    func resolve(_ issue: AppIssue) {
        issues.removeAll { $0.issue == issue }
    }

    /// Dismiss a problem the user has read. Identical to `resolve`, but named
    /// for the UI so the intent at each call site is obvious.
    func dismissIssue(_ issue: AppIssue) {
        resolve(issue)
    }

    func update(_ status: DeviceSession.Status) {
        guard !supersededServiceNames.contains(status.serviceName) else { return }
        let reconciledIdentity: Bool
        if let hardwareID = status.info?.deviceID {
            reconciledIdentity = reconcilePanelIdentity(
                hardwareID: hardwareID, serviceName: status.serviceName)
        } else {
            reconciledIdentity = false
        }
        updatePanel(status.serviceName) { panel in
            panel.lastSeen = status.updatedAt
            panel.lastHeartbeatAt = status.heartbeatAge.map {
                status.updatedAt.addingTimeInterval(-$0)
            }
            panel.displayFPS = status.displayFPS
            panel.framesSent = status.framesSent
            panel.sendErrors = status.sendErrors
            panel.diffPercent = status.diffPercent
            panel.framesShown = status.stats.shown
            panel.framesDropped = status.stats.dropped
            panel.freeHeap = status.stats.heap
            panel.spacingMicros = status.spacingMicros
            panel.paused = status.paused
            panel.sourceDescription = status.sourceDescription
            if let address = status.resolvedAddress { panel.address = address }
            if let info = status.info {
                Self.apply(info, to: &panel)
            }
        }
        persistIfNeeded(force: reconciledIdentity)
    }

    /// Publish network events immediately, independently of capture startup.
    /// This keeps the manager online and its controls usable while
    /// ScreenCaptureKit is waiting for a source or permission.
    func update(_ event: FrameSender.DeviceEvent, for serviceName: String) {
        guard !supersededServiceNames.contains(serviceName) else { return }
        let now = Date()
        var reconciledIdentity = false
        switch event {
        case .heartbeat(let stats):
            updatePanel(serviceName) { panel in
                panel.lastSeen = now
                panel.lastHeartbeatAt = now
                panel.lastError = nil
                panel.framesShown = stats.shown
                panel.framesDropped = stats.dropped
                panel.freeHeap = stats.heap
            }
        case .info(let info):
            reconciledIdentity = reconcilePanelIdentity(
                hardwareID: info.deviceID, serviceName: serviceName)
            updatePanel(serviceName) { panel in
                panel.lastSeen = now
                panel.lastHeartbeatAt = now
                panel.lastError = nil
                Self.apply(info, to: &panel)
            }
        case .acknowledgement(let acknowledgement):
            updatePanel(serviceName) { panel in
                panel.lastSeen = now
                panel.lastHeartbeatAt = now
                panel.brightness = Int(acknowledgement.brightness)
                panel.brightnessHigh = acknowledgement.brightnessHigh
                panel.flipped = acknowledgement.flipped
                panel.sleeping = acknowledgement.sleeping
            }
            if !acknowledgement.succeeded {
                operationOutcome = .failure(
                    "Display command failed",
                    "The display rejected the \(acknowledgement.opcode) "
                        + "command (status \(acknowledgement.status)).")
            }
        }
        persistIfNeeded(force: reconciledIdentity)
    }

    func chooseSource(for serviceName: String) {
        guard sessions[serviceName] != nil, let picker else { return }
        pickerTarget = serviceName
        selectedServiceName = serviceName
        picker.present()
    }

    func setPaused(_ paused: Bool, for serviceName: String) {
        sessions[serviceName]?.setPaused(paused)
        updatePanel(serviceName) { $0.paused = paused }
    }

    /// Why a control cannot be used right now, or nil when it can.
    ///
    /// The single source of truth for both the disabled state and the refusal
    /// message, so the two can never disagree, and specific enough to show as a
    /// tooltip on the disabled control rather than only as a message the user
    /// can never actually trigger.
    func controlUnavailableReason(
        _ serviceName: String, capability: DeviceProtocol.Capabilities
    ) -> String? {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }) else {
            return "This display is not known yet."
        }
        guard sessions[serviceName] != nil else {
            return "No streaming session is connected to this display."
        }
        guard panel.isOnline else {
            return "This display is offline."
        }
        guard panel.controlProtocolVersion
            == Int(DeviceProtocol.controlProtocolVersion)
        else {
            return "Flash the current firmware to enable remote controls."
        }
        guard panel.capabilities.contains(capability) else {
            return "This display does not report support for "
                + "\(Self.describe(capability))."
        }
        return nil
    }

    func canControl(
        _ serviceName: String, capability: DeviceProtocol.Capabilities
    ) -> Bool {
        controlUnavailableReason(serviceName, capability: capability) == nil
    }

    private static func describe(_ capability: DeviceProtocol.Capabilities) -> String {
        switch capability {
        case .brightness: return "brightness control"
        case .flip: return "rotation"
        case .identify: return "identify"
        case .restart: return "remote restart"
        default: return "this control"
        }
    }

    /// Run a control action, refusing with an accurate reason if the display
    /// cannot honour it. The UI disables these controls using the same check,
    /// so the refusal is a backstop for a panel that went offline mid-click.
    private func control(
        _ serviceName: String,
        capability: DeviceProtocol.Capabilities,
        action: (DeviceSession) -> Void
    ) {
        if let reason = controlUnavailableReason(serviceName, capability: capability) {
            operationOutcome = .failure(
                "\(Self.describe(capability).capitalizedFirst) unavailable", reason)
            return
        }
        guard let session = sessions[serviceName] else { return }
        action(session)
    }

    func setBrightness(high: Bool, for serviceName: String) {
        control(serviceName, capability: .brightness) { session in
            updatePanel(serviceName) { $0.brightnessHigh = high }
            session.setBrightness(high: high)
        }
    }

    func setFlip(_ flipped: Bool, for serviceName: String) {
        control(serviceName, capability: .flip) { session in
            updatePanel(serviceName) { $0.flipped = flipped }
            session.setFlip(flipped)
        }
    }

    func identify(_ serviceName: String) {
        control(serviceName, capability: .identify) { $0.identify() }
    }

    func restart(_ serviceName: String) {
        control(serviceName, capability: .restart) { $0.restartDevice() }
    }

    func rename(_ newName: String, for serviceName: String) {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }) else { return }
        switch WifiConfigUI.renameDevice(
            currentName: panel.displayName,
            newName: newName,
            preferredPort: panel.usbPort)
        {
        case .success(let appliedName):
            updatePanel(serviceName) { $0.displayName = appliedName }
            persistIfNeeded(force: true)
            operationOutcome = .success(
                "Name saved",
                "The display is restarting as \"\(appliedName)\". Streaming "
                    + "reconnects automatically.")
        case .failure(let failure):
            operationOutcome = .failure(failure)
        }
    }

    func applySavedNetwork(_ ssid: String, to serviceName: String) {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }) else { return }
        guard !ssid.isEmpty else {
            operationOutcome = .failure(
                "No network selected", "Select a saved WiFi network first.")
            return
        }
        switch WifiConfigUI.applySavedNetwork(
            ssid,
            currentName: panel.displayName,
            preferredPort: panel.usbPort)
        {
        case .success:
            operationOutcome = .success(
                "WiFi saved",
                "The display is restarting and joining \"\(ssid)\". Streaming "
                    + "reconnects automatically.")
        case .failure(let failure):
            operationOutcome = .failure(failure)
        }
    }

    func configureUSB(preferredSSID: String? = nil) {
        guard let panel = selectedPanel else {
            operationOutcome = .failure(
                "No display selected", "Select a display before configuring WiFi.")
            return
        }
        let result = WifiConfigUI.run(
            currentName: panel.displayName,
            preferredPort: panel.usbPort,
            preferredSSID: preferredSSID)
        refreshSavedNetworks()
        refreshUSBPorts()
        switch result {
        case .success(let confirmation):
            // nil means the user cancelled, which needs no announcement.
            if let confirmation {
                operationOutcome = .success(confirmation.title, confirmation.message)
            }
        case .failure(let failure):
            operationOutcome = .failure(failure)
        }
    }

    func usbPortOptions(for serviceName: String) -> [String] {
        guard let assigned = panels.first(where: { $0.serviceName == serviceName })?.usbPort,
              !assigned.isEmpty,
              !usbSerialPorts.contains(assigned)
        else { return usbSerialPorts }
        return [assigned] + usbSerialPorts
    }

    func setUSBPort(_ port: String?, for serviceName: String) {
        let normalized = port?.trimmingCharacters(in: .whitespacesAndNewlines)
        updatePanel(serviceName) { panel in
            panel.usbPort = normalized?.isEmpty == false ? normalized : nil
        }
        persistIfNeeded(force: true)
    }

    func refreshUSBPorts() {
        let current = WifiConfigUI.candidatePorts()
        if current != usbSerialPorts {
            usbSerialPorts = current
        }
    }

    func refreshSavedNetworks() {
        savedNetworkNames = WifiCredentialStore.savedNetworkNames()
    }

    func clearOperationOutcome() {
        operationOutcome = nil
    }

    func canForget(_ serviceName: String) -> Bool {
        sessions[serviceName] == nil
    }

    func forget(_ serviceName: String) {
        guard canForget(serviceName) else { return }
        panels.removeAll { $0.serviceName == serviceName }
        if selectedServiceName == serviceName {
            selectedServiceName = panels.first?.serviceName
        }
        persistIfNeeded(force: true)
    }

    func flushPersistence() {
        persistIfNeeded(force: true)
    }

    private func applyPickerSelection(_ filter: SCContentFilter) {
        let target = pickerTarget ?? selectedServiceName
            ?? panels.first(where: { $0.isOnline })?.serviceName
        pickerTarget = nil
        guard let target, let session = sessions[target] else { return }
        session.usePickerFilter(filter)
        updatePanel(target) { panel in
            panel.sourceDescription = picker?.describe(filter) ?? "Selected content"
        }
    }

    private static func apply(
        _ info: DeviceProtocol.DeviceInfo, to panel: inout PanelSnapshot
    ) {
        panel.displayName = info.name
        panel.hardwareID = info.deviceID
        panel.rssi = Int(info.rssi)
        panel.firmwareVersion = info.firmwareVersion
        panel.frameProtocolVersion = Int(info.frameProtocolVersion)
        panel.controlProtocolVersion = Int(info.controlProtocolVersion)
        panel.capabilitiesRaw = info.capabilities.rawValue
        panel.uptimeSeconds = info.uptimeSeconds
        panel.brightness = Int(info.brightness)
        panel.brightnessHigh = info.brightnessHigh
        panel.flipped = info.flipped
        panel.sleeping = info.sleeping
        panel.idle = info.idle
    }

    /// Migrate a persisted record when the same hardware reappears under a
    /// different Bonjour name. The service name remains the live routing key,
    /// while EINF's hardware ID preserves identity across USB renames.
    private func reconcilePanelIdentity(
        hardwareID: String, serviceName: String
    ) -> Bool {
        guard let oldIndex = panels.firstIndex(where: {
            $0.hardwareID == hardwareID && $0.serviceName != serviceName
        }) else { return false }

        let oldServiceName = panels[oldIndex].serviceName
        supersededServiceNames.remove(serviceName)
        supersededServiceNames.insert(oldServiceName)
        sessions[oldServiceName] = nil
        var migrated = panels.remove(at: oldIndex)
        migrated.serviceName = serviceName
        if let currentIndex = panels.firstIndex(where: { $0.serviceName == serviceName }) {
            let current = panels[currentIndex]
            migrated.discovered = current.discovered
            migrated.lastSeen = [migrated.lastSeen, current.lastSeen]
                .compactMap { $0 }
                .max()
            panels[currentIndex] = migrated
        } else {
            panels.append(migrated)
        }
        if selectedServiceName == oldServiceName {
            selectedServiceName = serviceName
        }
        sortPanels()
        return true
    }

    private func updatePanel(
        _ serviceName: String, change: (inout PanelSnapshot) -> Void
    ) {
        if let index = panels.firstIndex(where: { $0.serviceName == serviceName }) {
            change(&panels[index])
        } else {
            var panel = PanelSnapshot(serviceName: serviceName, displayName: serviceName)
            change(&panel)
            panels.append(panel)
            sortPanels()
        }
    }

    private func sortPanels() {
        panels.sort {
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func persistIfNeeded(force: Bool = false) {
        guard let url = persistenceURL else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastPersistedAt) >= 30 else { return }
        lastPersistedAt = now
        do {
            try PanelStore.save(panels.map(PersistedPanel.init(snapshot:)), to: url)
            resolve(.persistence)
        } catch {
            report(.persistence, detail: "Display names and USB assignments could not "
                + "be written to \(url.path): \(error.localizedDescription)")
        }
    }
}

#if DEBUG
extension PanelManager {
    static var preview: PanelManager {
        let now = Date()
        let controls = DeviceProtocol.Capabilities.brightness
            .union(.flip)
            .union(.identify)
            .union(.restart)
        return PanelManager(
            previewPanels: [
                PanelSnapshot(
                    serviceName: "studio-display",
                    displayName: "studio-display",
                    hardwareID: "esp32c6-a1b2c3d4",
                    address: "192.168.1.42",
                    usbPort: "/dev/cu.usbserial-A1B2C3D4",
                    discovered: true,
                    lastSeen: now,
                    lastHeartbeatAt: now,
                    rssi: -52,
                    displayFPS: 39.8,
                    framesSent: 128_440,
                    sendErrors: 0,
                    diffPercent: 18,
                    framesShown: 128_397,
                    framesDropped: 43,
                    freeHeap: 186_624,
                    spacingMicros: 200,
                    firmwareVersion: "1.1.0",
                    frameProtocolVersion: 2,
                    controlProtocolVersion: Int(DeviceProtocol.controlProtocolVersion),
                    capabilitiesRaw: controls.rawValue,
                    uptimeSeconds: 93_840,
                    brightness: 255,
                    brightnessHigh: true,
                    flipped: false,
                    sleeping: false,
                    idle: false,
                    paused: false,
                    sourceDescription: "Tiny Monitor"),
                PanelSnapshot(
                    serviceName: "travel-display",
                    displayName: "travel-display",
                    hardwareID: "esp32c6-e5f60718",
                    address: "192.168.1.87",
                    discovered: false,
                    lastSeen: now.addingTimeInterval(-3_600),
                    firmwareVersion: "1.1.0",
                    frameProtocolVersion: 2,
                    controlProtocolVersion: Int(DeviceProtocol.controlProtocolVersion),
                    capabilitiesRaw: controls.rawValue,
                    brightness: 255,
                    sourceDescription: "Automatic",
                    lastError: "Gave up trying to reach this display. It is retried "
                        + "automatically once it reappears on the network."),
            ],
            savedNetworkNames: ["Studio WiFi", "Phone Hotspot"],
            usbSerialPorts: [
                "/dev/cu.usbserial-A1B2C3D4",
                "/dev/cu.usbmodem-E5F60718",
            ])
    }
}
#endif

