import AppKit
import Foundation
import Network
import ScreenCaptureKit
import SenderProtocol

/// Main-actor model exposed to SwiftUI. Networking and capture continue in
/// DeviceSession; this registry only publishes immutable snapshots and routes
/// user actions to the live session for the selected panel.
@MainActor
final class PanelManager: ObservableObject {
    @Published internal(set) var panels: [PanelSnapshot] = []
    @Published internal(set) var savedNetworkNames: [String] = []
    @Published internal(set) var usbDevices: [WifiConfigUI.USBDeviceOption] = []
    /// Current transport paths. Kept as a projection for flashing/configuration
    /// code that needs a path rather than a display label.
    var usbSerialPorts: [String] { usbDevices.map(\.path) }
    /// Displays the user can pick from, by name.
    ///
    /// Listed in the window rather than reached through the macOS picker, so
    /// switching from one monitor to another is a single click instead of a trip
    /// through system UI to choose from a list this app can show itself.
    @Published internal(set) var displayNames: [String] = []
    @Published var selectedServiceName: String? {
        didSet { updatePreviewFocus() }
    }
    /// The outcome of the most recent user-initiated action, cleared when read.
    @Published internal(set) var operationOutcome: OperationOutcome?
    /// Standing problems, at most one per kind, in the order first reported.
    @Published private(set) var issues: [ReportedIssue] = []
    /// Persisted app settings, including streaming policy and sidebar ordering.
    @Published private(set) var settings = SenderSettings()
    /// Live image of what the selected panel is being sent. Its own observable
    /// object so ten frames a second redraw one small view instead of the
    /// whole window.
    let preview = FramePreview()

    var sessions: [String: DeviceSession] = [:]
    /// Which session is currently feeding `preview`, and whether anyone is
    /// looking. Tracked separately from `selectedServiceName` so the session
    /// being switched off can be told before the new one is switched on.
    var previewFocus: String?
    var previewVisible = false
    /// The marquee, and which panel it is currently drawing a region for.
    let regionSelector = RegionSelector()
    var regionTarget: String?
    /// What the panel was showing before the marquee opened, so Escape can put it
    /// back.
    var sourceBeforeRegion: PanelSource?
    /// Fills the preview for a panel that has no session of its own, so a source
    /// can be chosen and judged with the hardware switched off.
    let previewDriver = PreviewDriver()
    /// The display an Automatic source tracks, as a session would resolve it.
    let defaultDisplayName: String
    private var screenChangeObserver: NSObjectProtocol?
    var supersededServiceNames: Set<String> = []
    /// Unknown services that completed one provisional EINF probe and matched no
    /// owned hardware record. Retained only while that advertisement stays
    /// visible so discovery does not relaunch the same unowned board in a loop.
    var unownedServiceNames: Set<String> = []
    weak var picker: PickerSource?
    var pickerTarget: String?
    private var refreshTimer: Timer?
    /// Identity probes are blocking serial reads. Store the detached task itself
    /// so setup inspection and background refresh share one read per path rather
    /// than racing two readers on the same tty. The generation prevents a result
    /// from an unplugged device being applied after macOS reuses its path.
    var usbProbeTasks: [
        String: (generation: Int, task: Task<WifiConfigUI.PortProbe, Never>)
    ] = [:]
    var usbPathGenerations: [String: Int] = [:]
    /// A path-only USB choice made during this app run. Legacy firmware cannot
    /// report CFGSHOW id=, so this is the narrow bridge that lets the user choose
    /// among several name-only devices. It is never persisted and expires when
    /// the macOS path generation changes; esptool still has to read the panel's
    /// exact EINF MAC before any write.
    var explicitLegacyUSBSelections: [
        String: (path: String, generation: Int)
    ] = [:]
    private var lastPersistedAt = Date.distantPast
    /// Where per-panel OTA passwords are kept. Injected rather than reached for
    /// directly so that previews and tests, which run unsigned, cannot touch the
    /// login keychain - see `OTAPasswordStoring`.
    let otaPasswords: OTAPasswordStoring
    /// Where the durable records live, or nil to disable persistence entirely.
    /// Previews and tests run without a file so they cannot overwrite the
    /// records belonging to the installed app.
    private let persistenceURL: URL?
    /// Where the shared settings live, or nil to disable persistence.
    private let settingsURL: URL?
    /// The brightness each panel was last asked for, and when. Used to hold off
    /// the device's own reports while a drag is in flight; see
    /// `ignoreReportedBrightness`.
    var commandedBrightness: [String: (level: Int, at: Date)] = [:]

    /// Last gesture sequence number seen from each panel, so a redelivered UDP
    /// datagram is not acted on twice. Compared for inequality rather than
    /// ordering: the counter wraps at 16 bits and restarts at a random value
    /// when the device reboots, so "newer" is not something it can express.
    var lastTouchSequence: [String: UInt16] = [:]
    /// Where each panel is in the window cycle. Deliberately not persisted:
    /// window IDs are reissued, so a stored one would point at whatever window
    /// inherited the number rather than at the one the user was looking at.
    var lastCycledWindow: [String: CGWindowID] = [:]
    /// How long to keep preferring the commanded level over the device's
    /// reports. Long enough to cover a coalesced drag plus a round trip, short
    /// enough that a lost command self-corrects while the user is still there.
    static let brightnessEchoGrace: TimeInterval = 1.5
    /// Debounced USB brightness writes. A slider drag may produce dozens of
    /// values; only the latest one should open a serial transaction.
    var usbBrightnessTasks: [String: Task<Void, Never>] = [:]
    var pendingUSBBrightness: [String: (command: String, path: String)] = [:]
    var usbControlSender: @Sendable (
        _ command: String, _ path: String, _ timeout: TimeInterval
    ) -> WifiConfigUI.CommandResult = { command, path, timeout in
        WifiConfigUI.sendCommand(command, port: path, timeout: timeout)
    }
    var usbControlReprobe: (@MainActor (
        _ path: String, _ timeout: TimeInterval
    ) async -> Void)?
    /// Configuration setters restart the panel. Keep controls closed until a
    /// fresh CFGSHOW response proves the serial endpoint is back.
    var usbRestartingServices: Set<String> = []

    init(
        settings: SenderSettings? = nil,
        defaultDisplayName: String = "",
        otaPasswords: OTAPasswordStoring = KeychainOTAPasswordStore()
    ) {
        self.defaultDisplayName = defaultDisplayName
        self.otaPasswords = otaPasswords
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
        sortPanels()
        selectedServiceName = panels.first?.serviceName
        savedNetworkNames = WifiCredentialStore.savedNetworkNames()
        usbDevices = WifiConfigUI.candidatePorts().map {
            WifiConfigUI.USBDeviceOption(path: $0)
        }
        if let failure = loaded.failure {
            report(.persistence, detail: "Saved display settings could not be read "
                + "from \(url?.path ?? "disk"): \(failure)")
        }
        if let failure = loadedSettings.failure {
            report(.persistence, detail: "App settings could not be read, so "
                + "the defaults are in use: \(failure)")
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.refreshUSBPorts()
                self?.sortPanels()
                self?.objectWillChange.send()
            }
        }
        // Dragging the marquee streams straight through to whichever panel it
        // was opened for.
        regionSelector.onChange = { [weak self] region in
            guard let self, let target = self.regionTarget else { return }
            self.apply(region, to: target)
            // A hand-dragged size usually matches no preset; the highlight has
            // to follow the rectangle or it lies within one drag.
            self.regionSelector.activeScale = region.matchingScale(
                geometry: self.geometry(of: target))
        }
        regionSelector.onConfirm = { [weak self] in
            self?.finishChoosingRegion()
        }
        regionSelector.onCancel = { [weak self] in
            self?.cancelChoosingRegion()
        }
        // The scale presets and rotate live on the marquee itself - adjusting a
        // region that is not on screen is meaningless, so these fire only while
        // it is visible, for the panel it was opened for.
        regionSelector.onScale = { [weak self] scale in
            guard let self, let target = self.regionTarget else { return }
            self.setRegionScale(scale, for: target)
        }
        regionSelector.onRotate = { [weak self] in
            guard let self, let target = self.regionTarget else { return }
            self.rotateRegion(for: target)
        }
        previewDriver.onPreview = { [weak self] image, landscape, serviceName in
            self?.preview.accept(
                image: image, landscape: landscape, from: serviceName)
        }
        refreshDisplays()
        // Polled nowhere: querying shareable content is not free, and macOS says
        // when the screen layout changes.
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplays() }
        }
        previewDriver.onUnavailable = { [weak self] serviceName, reason in
            guard let self else { return }
            self.preview.clearFrame()
            self.updatePanel(serviceName) { panel in
                panel.captureStatus = .waiting("Nothing to preview. \(reason)")
            }
        }
        identifyUSBPorts(usbSerialPorts)
    }

    /// Preview and test seam: no timers or discovery, and no disk unless a
    /// settings URL is explicitly injected by a persistence test.
    ///
    /// Deliberately NOT wrapped in `#if DEBUG`, unlike the `#Preview` macros and
    /// `PanelManager.preview` further down. Tests are built in whichever
    /// configuration they are asked for, and `swift test -c release` needs this
    /// initialiser exactly as much as the debug build does. Gating it on DEBUG
    /// broke release-mode testing outright, and the breakage is near
    /// undiagnosable from its symptom: thirty-odd "extra arguments at positions
    /// #1, #2, #3" errors across unrelated test files, none of them pointing
    /// here, because the compiler silently falls back to another initialiser
    /// once this one disappears.
    ///
    /// The cost of leaving it visible is nil in practice: it is `internal`, so
    /// it is not API surface, and it has no release callers to keep it alive
    /// through dead-code stripping.
    init(
        previewPanels: [PanelSnapshot],
        savedNetworkNames: [String],
        usbSerialPorts: [String],
        otaPasswords: OTAPasswordStoring = InMemoryOTAPasswordStore(),
        settings: SenderSettings = SenderSettings(),
        settingsPersistenceURL: URL? = nil
    ) {
        defaultDisplayName = ""
        // In memory by default, never the keychain: this initialiser is what the
        // SwiftUI previews and the tests use, and both run unsigned.
        self.otaPasswords = otaPasswords
        persistenceURL = nil
        settingsURL = settingsPersistenceURL
        self.settings = settings.validated
        panels = previewPanels
        sortPanels()
        self.savedNetworkNames = savedNetworkNames
        usbDevices = usbSerialPorts.map { WifiConfigUI.USBDeviceOption(path: $0) }
        selectedServiceName = panels.first?.serviceName
    }

    deinit {
        refreshTimer?.invalidate()
    }

    var selectedPanel: PanelSnapshot? {
        guard let selectedServiceName else { return nil }
        return panels.first { $0.serviceName == selectedServiceName }
    }


    /// Sessions whose one-time provisional pause has already been lifted.
    var identityBoundSessionIDs: Set<UUID> = []

    /// Apply new streaming settings to every live session and remember them.
    ///
    /// Pacing and identify duration take effect immediately. Frame rate is
    /// handed to ScreenCaptureKit when a stream starts, so each session
    /// restarts its capture to pick it up.
    func updateSettings(_ new: SenderSettings) {
        let validated = new.validated
        guard validated != settings else { return }
        let sortOrderChanged =
            validated.deviceListSortOrder != settings.deviceListSortOrder
        settings = validated
        if sortOrderChanged { sortPanels() }
        for session in sessions.values {
            session.setFPS(validated.fps)
            session.applyPacing(
                spacingMicros: validated.spacingMicros,
                adaptive: validated.adaptivePacing)
            session.applyTileQuality(validated.tileQuality)
        }
        saveSettings()
    }

    /// Change only sidebar ordering. This should not restart live capture the
    /// way a frame-rate or pacing change does.
    func updateDeviceListSortOrder(_ order: DeviceListSortOrder) {
        guard settings.deviceListSortOrder != order else { return }
        settings.deviceListSortOrder = order
        sortPanels()
        saveSettings()
    }

    private func saveSettings() {
        guard let settingsURL else { return }
        do {
            try SettingsStore.save(settings, to: settingsURL)
            resolve(.persistence)
        } catch {
            report(.persistence, detail: "App settings could not be saved to "
                + "\(settingsURL.path): \(error.localizedDescription)")
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


    /// Whether a display has the panel's own 172:320 aspect, in either
    /// orientation. Same tolerances as `DisplayCapture.resolve`'s fallback.
    ///
    /// `nonisolated` because it reads nothing but its arguments; inheriting the
    /// manager's actor would make a pure arithmetic check await the main queue.
    ///
    /// STILL THE COMPILED-IN 172:320, DELIBERATELY, and for the same reason
    /// `DisplayCapture.resolve(named:)` keeps it: this filters the list of Mac
    /// displays a panel could be pointed at, with no panel in scope to ask. A
    /// square panel's ratio is 1:1, so believing an advertised geometry here would
    /// exclude every square Mac display from the list rather than excluding the
    /// panel it was meant to catch. The point is to skip a display that IS a
    /// panel, and the only panels this can see are shaped like the constant.
    /// Which saved network the "Saved WiFi" picker should default to.
    ///
    /// `reportedSSID` is what the device actually said over CFGSHOW
    /// (`PanelSnapshot.currentSSID`). `explicitSelection` is only a value the
    /// user picked; an automatically displayed fallback must remain nil so a
    /// delayed device reply can replace it. An explicit choice wins while it
    /// remains saved, then the device report, then the first saved credential.
    ///
    /// `nonisolated` because it only examines its arguments.
    nonisolated static func preferredSSID(
        explicitSelection: String?, reportedSSID: String?, savedNames: [String]
    ) -> String {
        if let explicitSelection, savedNames.contains(explicitSelection) {
            return explicitSelection
        }
        if let reportedSSID, savedNames.contains(reportedSSID) { return reportedSSID }
        return savedNames.first ?? ""
    }

    nonisolated static func isPanelShaped(_ width: Int, _ height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let target = Double(PixelConvert.width) / Double(PixelConvert.height)
        let aspect = Double(width) / Double(height)
        return abs(aspect - target) < 0.01 || abs(aspect - 1.0 / target) < 0.035
    }


    func presentOperationOutcome(_ outcome: OperationOutcome) {
        operationOutcome = outcome
    }

    func clearOperationOutcome() {
        operationOutcome = nil
    }


    func updatePanel(
        _ serviceName: String, change: (inout PanelSnapshot) -> Void
    ) {
        if let index = panels.firstIndex(where: { $0.serviceName == serviceName }) {
            change(&panels[index])
            sortPanels()
        }
    }

    func sortPanels() {
        let now = Date()
        let sorted = panels.sorted {
            return DeviceListSorter.areInIncreasingOrder(
                deviceListSortValue(for: $0, asOf: now),
                deviceListSortValue(for: $1, asOf: now),
                by: settings.deviceListSortOrder)
        }
        guard sorted.map(\.id) != panels.map(\.id) else { return }
        panels = sorted
    }

    func deviceListStatus(
        for panel: PanelSnapshot,
        asOf now: Date
    ) -> DeviceListStatus {
        panel.deviceListStatus(
            asOf: now,
            connectedViaUSB: verifiedUSBDevice(for: panel.serviceName) != nil)
    }

    func sidebarStatusText(
        for panel: PanelSnapshot,
        asOf now: Date = Date()
    ) -> String {
        panel.sidebarStatusText(
            asOf: now,
            connectedViaUSB: verifiedUSBDevice(for: panel.serviceName) != nil)
    }

    private func deviceListSortValue(
        for panel: PanelSnapshot,
        asOf now: Date
    ) -> DeviceListSortValue {
        panel.deviceListSortValue(
            asOf: now,
            connectedViaUSB: verifiedUSBDevice(for: panel.serviceName) != nil)
    }

    func persistIfNeeded(force: Bool = false) {
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
