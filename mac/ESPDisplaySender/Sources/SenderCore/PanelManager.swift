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
    /// What the user chose this panel should show. Persisted, so a source picked
    /// once is still in effect after a restart.
    var source: PanelSource = .automatic
    /// What the session is actually capturing right now, which can differ from
    /// `source` while a display is being resolved or a window is missing.
    var sourceDescription = "Automatic"
    /// Lines to show on the panel's own status card while no sender is driving
    /// it. Persisted, and pushed to the device whenever it reports in.
    var idleText = ""
    /// Why this panel is not usable, when the reason is something the user
    /// would otherwise only find in the log. Cleared as soon as the device
    /// reports in again.
    var lastError: String?
    /// What the capture side is doing. Held separately from `lastError`, which
    /// every device heartbeat clears - a capture problem outlives the
    /// heartbeats, because the panel keeps answering perfectly well while
    /// receiving nothing.
    var captureStatus: CaptureStatus = .waiting("Starting up…")
    /// When a frame was last captured and sent for this panel.
    var lastFrameAt: Date?

    var capabilities: DeviceProtocol.Capabilities {
        DeviceProtocol.Capabilities(rawValue: capabilitiesRaw)
    }

    /// How long since a frame was last captured and sent, or nil if none ever
    /// has been.
    ///
    /// Deliberately not treated as an error signal on its own:
    /// ScreenCaptureKit delivers nothing at all while the source is static, so
    /// a large age is normal for an unchanging window. `captureStatus` is the
    /// authority on whether something is wrong; this is the supporting detail.
    var frameAge: TimeInterval? {
        lastFrameAt.map { Date().timeIntervalSince($0) }
    }

    /// The frame age as it reads in the preview row.
    var frameAgeDescription: String {
        guard let age = frameAge else { return "No frames yet" }
        if age < 1 { return "Live" }
        if age < 60 { return "Last frame \(Int(age))s ago" }
        let minutes = Int(age / 60)
        return "Last frame \(minutes)m ago"
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
        return "\(signalWord) (\(rssi) dBm)"
    }

    /// Signal strength as a single word, for the `{signal}` screensaver token
    /// and as the basis of `signalDescription`, so the two cannot disagree.
    var signalWord: String {
        guard let rssi else { return "" }
        if rssi >= -55 { return "Excellent" }
        if rssi >= -65 { return "Good" }
        if rssi >= -75 { return "Fair" }
        return "Weak"
    }

    /// What this panel's screensaver tokens currently stand for.
    ///
    /// Unknown values are left empty rather than filled with a placeholder: an
    /// empty token drops its line, which is better than a panel reading
    /// "wifi —" across the room.
    var screensaverValues: ScreensaverTemplate.Values {
        ScreensaverTemplate.Values(
            name: displayName,
            address: address ?? "",
            signal: signalWord,
            rssi: rssi.map { "\($0) dBm" } ?? "",
            version: firmwareVersion ?? "",
            uptime: uptimeSeconds > 0 ? uptimeDescription : "")
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
    @Published var selectedServiceName: String? {
        didSet { updatePreviewFocus() }
    }
    /// The outcome of the most recent user-initiated action, cleared when read.
    @Published private(set) var operationOutcome: OperationOutcome?
    /// Standing problems, at most one per kind, in the order first reported.
    @Published private(set) var issues: [ReportedIssue] = []
    /// Streaming settings shared by every panel.
    @Published private(set) var settings = SenderSettings()
    /// Live image of what the selected panel is being sent. Its own observable
    /// object so ten frames a second redraw one small view instead of the
    /// whole window.
    let preview = FramePreview()

    private var sessions: [String: DeviceSession] = [:]
    /// Which session is currently feeding `preview`, and whether anyone is
    /// looking. Tracked separately from `selectedServiceName` so the session
    /// being switched off can be told before the new one is switched on.
    private var previewFocus: String?
    private var previewVisible = false
    private var supersededServiceNames: Set<String> = []
    private weak var picker: PickerSource?
    private var pickerTarget: String?
    private var refreshTimer: Timer?
    private var lastPersistedAt = Date.distantPast
    /// Where the durable records live, or nil to disable persistence entirely.
    /// Previews and tests run without a file so they cannot overwrite the
    /// records belonging to the installed app.
    private let persistenceURL: URL?
    /// Where the shared settings live, or nil to disable persistence.
    private let settingsURL: URL?
    /// The brightness each panel was last asked for, and when. Used to hold off
    /// the device's own reports while a drag is in flight; see
    /// `ignoreReportedBrightness`.
    private var commandedBrightness: [String: (level: Int, at: Date)] = [:]
    /// How long to keep preferring the commanded level over the device's
    /// reports. Long enough to cover a coalesced drag plus a round trip, short
    /// enough that a lost command self-corrects while the user is still there.
    private static let brightnessEchoGrace: TimeInterval = 1.5

    init(settings: SenderSettings? = nil) {
        let url = PanelStore.defaultURL
        persistenceURL = url
        settingsURL = SettingsStore.defaultURL
        let loaded = PanelStore.load(from: url)
        let loadedSettings = SettingsStore.load(from: SettingsStore.defaultURL)
        // An explicit value from the command line wins for this run without
        // being written back, so a one-off invocation cannot silently rewrite
        // what the UI saved.
        self.settings = (settings ?? loadedSettings.settings).validated
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
        if let failure = loadedSettings.failure {
            report(.persistence, detail: "Streaming settings could not be read, so "
                + "the defaults are in use: \(failure)")
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
        settingsURL = nil
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

    // MARK: live preview

    /// Whether the manager window is on screen. Converting frames for a window
    /// nobody can see would be pure waste, so the preview is switched off with
    /// the window rather than left running for the life of the process.
    func setPreviewVisible(_ visible: Bool) {
        guard previewVisible != visible else { return }
        previewVisible = visible
        updatePreviewFocus()
    }

    /// Route preview frames from the selected panel's session only, and tell
    /// every other session to stop producing them.
    private func updatePreviewFocus() {
        let target = previewVisible ? selectedServiceName : nil
        guard target != previewFocus else { return }
        if let previous = previewFocus {
            sessions[previous]?.setPreviewEnabled(false)
        }
        previewFocus = target
        preview.focus(on: target)
        if let target {
            sessions[target]?.setPreviewEnabled(true)
        }
    }

    /// Accept a frame from a session. Frames from a panel that is no longer
    /// selected are dropped by `FramePreview` itself, since a callback already
    /// in flight can outlive a selection change.
    func acceptPreview(image: CGImage, landscape: Bool, from serviceName: String) {
        preview.accept(image: image, landscape: landscape, from: serviceName)
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

    /// Apply new streaming settings to every live session and remember them.
    ///
    /// Pacing and identify duration take effect immediately. Frame rate is
    /// handed to ScreenCaptureKit when a stream starts, so each session
    /// restarts its capture to pick it up.
    func updateSettings(_ new: SenderSettings) {
        let validated = new.validated
        guard validated != settings else { return }
        settings = validated
        for session in sessions.values {
            session.setFPS(validated.fps)
            session.applyPacing(
                spacingMicros: validated.spacingMicros,
                adaptive: validated.adaptivePacing)
        }
        guard let settingsURL else { return }
        do {
            try SettingsStore.save(validated, to: settingsURL)
            resolve(.persistence)
        } catch {
            report(.persistence, detail: "Streaming settings could not be saved to "
                + "\(settingsURL.path): \(error.localizedDescription)")
        }
    }

    func register(_ session: DeviceSession) {
        guard !supersededServiceNames.contains(session.name) else { return }
        sessions[session.name] = session
        // Bring the session up to the current settings whatever it was built
        // with. A session created after the user changed something would
        // otherwise keep the old rate; a frame-rate difference restarts its
        // capture within a couple of seconds, so this self-heals.
        session.setFPS(settings.fps)
        session.applyPacing(
            spacingMicros: settings.spacingMicros, adaptive: settings.adaptivePacing)
        // A session that appears while its panel is already selected has to be
        // told to produce previews; `updatePreviewFocus` would see no change in
        // focus and do nothing.
        if session.name == previewFocus {
            session.setPreviewEnabled(true)
        }
        if !panels.contains(where: { $0.serviceName == session.name }) {
            panels.append(PanelSnapshot(serviceName: session.name, displayName: session.name,
                                        discovered: true, lastSeen: Date()))
            sortPanels()
        }
    }

    func retire(_ serviceName: String) {
        sessions[serviceName] = nil
        if previewFocus == serviceName { preview.clearFrame() }
        guard !supersededServiceNames.contains(serviceName) else { return }
        updatePanel(serviceName) { panel in
            panel.discovered = false
            panel.displayFPS = 0
            panel.captureStatus = .failed(
                "No session is running for this display, so nothing is being sent.")
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
            panel.captureStatus = status.captureStatus
            panel.lastFrameAt = status.lastFrameAt
            // A parked session is alive but deliberately not capturing, which
            // otherwise looks identical to a panel that is simply idle.
            panel.lastError = status.parked
                ? "Not reachable, so capture is stopped for this display. It resumes "
                    + "automatically as soon as the panel answers again."
                : nil
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
            let keepBrightness = ignoreReportedBrightness(
                Int(info.brightness), for: serviceName)
            updatePanel(serviceName) { panel in
                panel.lastSeen = now
                panel.lastHeartbeatAt = now
                panel.lastError = nil
                Self.apply(info, to: &panel, keepBrightness: keepBrightness)
            }
            // EINF means the device just connected or rebooted, so anything it
            // was told before is gone. This is the only moment the sender knows
            // to push it again.
            pushIdleText(to: serviceName)
        case .acknowledgement(let acknowledgement):
            let keepBrightness = ignoreReportedBrightness(
                Int(acknowledgement.brightness), for: serviceName)
            updatePanel(serviceName) { panel in
                panel.lastSeen = now
                panel.lastHeartbeatAt = now
                if !keepBrightness {
                    panel.brightness = Int(acknowledgement.brightness)
                }
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

    /// Open the system content picker for a panel.
    ///
    /// `style` opens the picker directly in display, window, or application
    /// mode, so the user lands where they meant to go instead of hunting for
    /// the right tab.
    func chooseSource(
        for serviceName: String, style: SCShareableContentStyle? = nil
    ) {
        guard sessions[serviceName] != nil, let picker else { return }
        pickerTarget = serviceName
        selectedServiceName = serviceName
        picker.present(style: style)
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
        case .brightnessLevel: return "brightness levels"
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

    /// Set an exact backlight level on firmware that accepts one.
    ///
    /// The panel value is updated straight away so a slider tracks the finger
    /// rather than waiting a round trip. The device's own reports are then
    /// suppressed until it catches up, because they lag the drag and would
    /// otherwise fight the thumb.
    func setBrightnessLevel(_ level: Int, for serviceName: String) {
        control(serviceName, capability: .brightnessLevel) { session in
            let clamped = min(
                max(level, DeviceProtocol.brightnessLevelRange.lowerBound),
                DeviceProtocol.brightnessLevelRange.upperBound)
            updatePanel(serviceName) { $0.brightness = clamped }
            commandedBrightness[serviceName] = (level: clamped, at: Date())
            session.setBrightnessLevel(clamped)
        }
    }

    /// Whether a level the device reported should be ignored in favour of what
    /// the user just asked for.
    ///
    /// Reports are ignored until the device converges on the commanded value,
    /// or until the grace period lapses. The timeout is what makes this safe:
    /// without it a dropped command would leave the UI permanently disagreeing
    /// with the panel.
    private func ignoreReportedBrightness(
        _ reported: Int, for serviceName: String
    ) -> Bool {
        guard let commanded = commandedBrightness[serviceName] else { return false }
        guard reported != commanded.level else {
            commandedBrightness[serviceName] = nil
            return false
        }
        guard Date().timeIntervalSince(commanded.at) < Self.brightnessEchoGrace else {
            commandedBrightness[serviceName] = nil
            return false
        }
        return true
    }

    func setFlip(_ flipped: Bool, for serviceName: String) {
        control(serviceName, capability: .flip) { session in
            updatePanel(serviceName) { $0.flipped = flipped }
            session.setFlip(flipped)
        }
    }

    func identify(_ serviceName: String) {
        let seconds = settings.identifySeconds
        control(serviceName, capability: .identify) { $0.identify(seconds: seconds) }
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
        // Record what was picked, not just how it reads: the filter itself
        // cannot be stored, but the display or application it names can be
        // resolved again on the next launch.
        //
        // A pick that cannot be identified leaves the saved choice alone. It
        // still applies to the running session via the filter; what it must not
        // do is replace a good stored choice with "Automatic", which is how a
        // deliberate selection used to appear to revert on its own.
        let identified = PanelSource.from(filter)
        updatePanel(target) { panel in
            if let identified { panel.source = identified }
            panel.sourceDescription = picker?.describe(filter) ?? "Selected content"
        }
        persistIfNeeded(force: true)
    }

    /// Return this panel to automatic display tracking.
    func useAutomaticSource(for serviceName: String) {
        updatePanel(serviceName) { panel in
            panel.source = .automatic
            panel.sourceDescription = "Automatic"
        }
        picker?.clearSelection()
        persistIfNeeded(force: true)
    }

    /// The stored source for every panel, keyed by service name. Read once at
    /// startup to decide what each session should capture.
    func persistedSources() -> [String: PanelSource] {
        Dictionary(
            panels.map { ($0.serviceName, $0.source) },
            uniquingKeysWith: { first, _ in first })
    }

    /// Set the screensaver template the panel shows while nothing is driving it.
    ///
    /// Stored as the user typed it, tokens and all, so the editor round-trips and
    /// the values are re-substituted with fresh ones every time the panel is
    /// pushed to. Expansion and sanitizing happen on the way to the device,
    /// whose font is a 5x7 ASCII bitmap.
    func setIdleText(_ text: String, for serviceName: String) {
        guard panels.contains(where: { $0.serviceName == serviceName }) else { return }
        updatePanel(serviceName) { $0.idleText = text }
        persistIfNeeded(force: true)
        pushIdleText(to: serviceName)
    }

    /// How a template will actually appear on the panel, so the UI can show what
    /// was substituted and what was dropped rather than leaving the user to
    /// guess. Pass `template` to preview unsaved edits; omit it for the saved one.
    func screensaverPreview(
        for serviceName: String, template: String? = nil
    ) -> ScreensaverTemplate.Expansion {
        guard let panel = panels.first(where: { $0.serviceName == serviceName })
        else {
            return ScreensaverTemplate.Expansion(lines: [], unknownTokens: [])
        }
        return ScreensaverTemplate.expand(
            template ?? panel.idleText, values: panel.screensaverValues)
    }

    private func pushIdleText(to serviceName: String) {
        guard let session = sessions[serviceName],
              let panel = panels.first(where: { $0.serviceName == serviceName }),
              panel.capabilities.contains(.idleText)
        else { return }
        // An empty template sends an empty packet, which clears the card and
        // lets the panel fall back to drawing its own.
        session.sendIdleText(
            ScreensaverTemplate.expand(
                panel.idleText, values: panel.screensaverValues).lines)
    }

    private static func apply(
        _ info: DeviceProtocol.DeviceInfo, to panel: inout PanelSnapshot,
        keepBrightness: Bool = false
    ) {
        panel.displayName = info.name
        panel.hardwareID = info.deviceID
        panel.rssi = Int(info.rssi)
        panel.firmwareVersion = info.firmwareVersion
        panel.frameProtocolVersion = Int(info.frameProtocolVersion)
        panel.controlProtocolVersion = Int(info.controlProtocolVersion)
        panel.capabilitiesRaw = info.capabilities.rawValue
        panel.uptimeSeconds = info.uptimeSeconds
        // Only the level is held back. The high/low flag is derived on the
        // device from a PWM threshold the Mac does not know, so guessing at it
        // locally would be inventing state; the device stays authoritative.
        if !keepBrightness {
            panel.brightness = Int(info.brightness)
        }
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
            .union(.brightnessLevel)
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
                    source: .display("Tiny Monitor"),
                    sourceDescription: "Tiny Monitor",
                    captureStatus: .streaming,
                    lastFrameAt: now),
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
                        + "automatically once it reappears on the network.",
                    captureStatus: .failed(
                        "The content being mirrored is no longer available. Choose "
                            + "a source again, or switch to Automatic.")),
            ],
            savedNetworkNames: ["Studio WiFi", "Phone Hotspot"],
            usbSerialPorts: [
                "/dev/cu.usbserial-A1B2C3D4",
                "/dev/cu.usbmodem-E5F60718",
            ])
    }
}
#endif

