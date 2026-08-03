import AppKit
import Foundation
import Network
import ScreenCaptureKit
import SenderProtocol

struct PanelSnapshot: Identifiable, Codable, Equatable {
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

/// Main-actor model exposed to SwiftUI. Networking and capture continue in
/// DeviceSession; this registry only publishes immutable snapshots and routes
/// user actions to the live session for the selected panel.
@MainActor
final class PanelManager: ObservableObject {
    @Published private(set) var panels: [PanelSnapshot] = []
    @Published private(set) var savedNetworkNames: [String] = []
    @Published private(set) var usbSerialPorts: [String] = []
    @Published var selectedServiceName: String?
    @Published private(set) var operationError: String?

    private var sessions: [String: DeviceSession] = [:]
    private var supersededServiceNames: Set<String> = []
    private weak var picker: PickerSource?
    private var pickerTarget: String?
    private var refreshTimer: Timer?
    private var lastPersistedAt = Date.distantPast

    init() {
        panels = Self.loadPersistedPanels()
            .map { panel in
                var offline = panel
                offline.discovered = false
                offline.lastHeartbeatAt = nil
                offline.displayFPS = 0
                return offline
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        selectedServiceName = panels.first?.serviceName
        savedNetworkNames = WifiCredentialStore.savedNetworkNames()
        usbSerialPorts = WifiConfigUI.candidatePorts()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.refreshUSBPorts()
                self?.objectWillChange.send()
            }
        }
    }

#if DEBUG
    init(
        previewPanels: [PanelSnapshot],
        savedNetworkNames: [String],
        usbSerialPorts: [String]
    ) {
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
        }
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
                operationError = "The display rejected the \(acknowledgement.opcode) "
                    + "command (status \(acknowledgement.status))."
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

    func canControl(
        _ serviceName: String, capability: DeviceProtocol.Capabilities
    ) -> Bool {
        guard sessions[serviceName] != nil,
              let panel = panels.first(where: { $0.serviceName == serviceName })
        else { return false }
        return panel.isOnline
            && panel.controlProtocolVersion == Int(DeviceProtocol.controlProtocolVersion)
            && panel.capabilities.contains(capability)
    }

    func setBrightness(high: Bool, for serviceName: String) {
        guard canControl(serviceName, capability: .brightness),
              let session = sessions[serviceName]
        else {
            operationError = "Brightness control is not available for this display."
            return
        }
        updatePanel(serviceName) { $0.brightnessHigh = high }
        session.setBrightness(high: high)
    }

    func setFlip(_ flipped: Bool, for serviceName: String) {
        guard canControl(serviceName, capability: .flip),
              let session = sessions[serviceName]
        else {
            operationError = "Rotation control is not available for this display."
            return
        }
        updatePanel(serviceName) { $0.flipped = flipped }
        session.setFlip(flipped)
    }

    func identify(_ serviceName: String) {
        guard canControl(serviceName, capability: .identify) else {
            operationError = "Identify is not available for this display."
            return
        }
        sessions[serviceName]?.identify()
    }

    func restart(_ serviceName: String) {
        guard canControl(serviceName, capability: .restart) else {
            operationError = "Restart is not available for this display."
            return
        }
        sessions[serviceName]?.restartDevice()
    }

    func rename(_ newName: String, for serviceName: String) {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }) else { return }
        guard let appliedName = WifiConfigUI.renameDevice(
            currentName: panel.displayName,
            newName: newName,
            preferredPort: panel.usbPort)
        else { return }
        updatePanel(serviceName) { $0.displayName = appliedName }
        persistIfNeeded(force: true)
    }

    func applySavedNetwork(_ ssid: String, to serviceName: String) {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }) else { return }
        guard !ssid.isEmpty else {
            operationError = "Select a saved WiFi network first."
            return
        }
        _ = WifiConfigUI.applySavedNetwork(
            ssid,
            currentName: panel.displayName,
            preferredPort: panel.usbPort)
    }

    func configureUSB(preferredSSID: String? = nil) {
        guard let panel = selectedPanel else {
            operationError = "Select a display before configuring WiFi."
            return
        }
        WifiConfigUI.run(
            currentName: panel.displayName,
            preferredPort: panel.usbPort,
            preferredSSID: preferredSSID)
        refreshSavedNetworks()
        refreshUSBPorts()
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

    func clearOperationError() {
        operationError = nil
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
        let now = Date()
        guard force || now.timeIntervalSince(lastPersistedAt) >= 30 else { return }
        lastPersistedAt = now
        guard let url = Self.persistenceURL,
              let data = try? JSONEncoder.espDisplay.encode(panels)
        else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static var persistenceURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ESPDisplaySender", isDirectory: true)
            .appendingPathComponent("panels.json")
    }

    private static func loadPersistedPanels() -> [PanelSnapshot] {
        guard let url = persistenceURL,
              let data = try? Data(contentsOf: url),
              let panels = try? JSONDecoder.espDisplay.decode([PanelSnapshot].self, from: data)
        else { return [] }
        return panels
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
                    sourceDescription: "Automatic"),
            ],
            savedNetworkNames: ["Studio WiFi", "Phone Hotspot"],
            usbSerialPorts: [
                "/dev/cu.usbserial-A1B2C3D4",
                "/dev/cu.usbmodem-E5F60718",
            ])
    }
}
#endif

private extension JSONEncoder {
    static var espDisplay: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var espDisplay: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
