import AppKit
import CoreGraphics
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
    var audioRouteSnapshot = CoreAudioRouteSnapshot.empty
    /// The Mac-audio route and the displays' driver devices; see
    /// PanelManager+MacAudioRoute.swift.
    let macAudio = MacAudioRouting()
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
    /// The app's bundled firmware once read; see `bundledFirmware`. Not
    /// published: it is filled in on first use and never changes after.
    var bundledFirmwareCache: BundledFirmware.Availability?
    /// Set by offscreen captures, which render the detail pane: its appearance
    /// asks CFGSHOW for the current SSID, and a capture must never open a real
    /// serial port another process may be using.
    var serialIODisabled = false
    /// The media-key path a gesture goes through: whether this process may
    /// post keys, the one-time Accessibility prompt, and the sender itself.
    /// Replaced by tests, which must not prompt or change the volume of
    /// whoever runs them.
    var mediaKeysAuthorized: () -> Bool = { MediaControl.isAuthorized }
    var requestMediaKeyAuthorization: () -> Void = {
        MediaControl.requestAuthorizationOnce()
    }
    /// Re-starts the Bonjour permission probe. Installed by the app bootstrap;
    /// tests and previews leave it inert.
    var requestLocalNetworkAuthorization: () -> Void = {}
    /// Rechecks the Local Network probe after its small interval, or
    /// immediately after the foreground app becomes active.
    var refreshLocalNetworkAuthorization: (_ immediately: Bool) -> Void = { _ in }
    /// The bootstrap uses this to recheck an existing Local Network decision
    /// without starting a first-use request before the launch sheet explains it.
    var hasRequestedLocalNetworkPermission: Bool {
        permissionPromptHistory.wasRequested(.localNetwork)
    }
    var mediaKeySender: (MediaControl.Key) -> String? = { MediaControl.send($0) }
    /// Posts a recorded key combination; replaced by tests, like the media key.
    var keyPressSender: (KeyCombo) -> String? = { MediaControl.press($0) }
    /// Called when a notice the user must act on first appears. The sender
    /// usually runs with its window closed, so the window controller uses this
    /// to bring the window forward without taking focus.
    var onAttentionNeeded: (() -> Void)?
    /// The Accessibility notice was dismissed; it stays down until the grant
    /// is next seen rather than coming back on the next detent of the turn.
    var accessibilityNoticeDismissed = false
    /// The status of screen capture after its most recent real attempt.
    private var screenRecordingPermissionState = ScreenRecordingPermissionState.ready
    /// The live rows in Settings and the first-launch checklist. They are
    /// rebuilt from the real permission probes every time the manager refreshes.
    @Published private(set) var permissionChecklist: [PermissionChecklistItem] = []
    /// A foreground launch presents this automatically while any capability is
    /// unavailable. Background launches leave it queued until a window exists.
    @Published var permissionChecklistPresented = false
    @Published private(set) var activePermissionRequest: MacPermission?
    private let permissionPromptHistory = PermissionPromptHistory()
    /// Local Network has no preflight API. Delay the initial first-run
    /// "not yet asked" result briefly; a pending probe is never treated as
    /// missing access.
    private static let localNetworkInitialGracePeriod: TimeInterval = 1.5
    private var localNetworkInitialCheckStartedAt = Date()
    private var localNetworkInitialCheckTask: Task<Void, Never>?
    private var localNetworkChecklistStatus: PermissionChecklistStatus?
    private var localNetworkTechnicalDetail: String?
    private var systemAudioChecklistStatus: PermissionChecklistStatus?
    private var cameraExtensionNeedsApproval = false
    private var cameraExtensionActivated = false
    private var cameraExtensionNeedsRestart = false
    private var cameraExtensionTechnicalDetail: String?
    private var automaticPermissionSequence = false
    private var permissionChecklistDismissedThisLaunch = false
    private var foregroundStartupUnblocked = false
    private var foregroundStartupContinuation: CheckedContinuation<Void, Never>?
    private var screenRecordingTechnicalDetail: String?
    /// Standing problems, at most one per kind, in the order first reported.
    @Published private(set) var issues: [ReportedIssue] = []
    /// What each source currently reports under an issue kind, in report order.
    /// `issues` is derived from this.
    private var issueSources: [AppIssue: [(
        source: String,
        detail: String,
        technicalDetail: String?,
        permissionState: PermissionIssueState?
    )]] = [:]
    /// The two files behind `.persistence`. Each one's save withdraws only its
    /// own failure: saving the app settings says nothing about the display
    /// records, and the reverse.
    static let panelRecordsIssueSource = "display records"
    static let settingsIssueSource = "app settings"
    /// A file that could not be read at launch. Saving over it later does not
    /// bring back what it held, so only Dismiss clears these.
    static let panelRecordsReadIssueSource = "display records (read)"
    static let settingsReadIssueSource = "app settings (read)"
    /// Persisted app settings, including streaming policy and sidebar ordering.
    @Published private(set) var settings = SenderSettings()
    /// Live image of what the selected panel is being sent. Its own observable
    /// object so ten frames a second redraw one small view instead of the
    /// whole window.
    let preview = FramePreview()
    let cameraPreview = CameraPreview()

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
    /// Mac screens used as devices, listed beside the boards.
    let screenDevices: ScreenDeviceController
    /// Screens those devices cover. A board is not offered one as a source,
    /// and no region is dragged onto one.
    var coveredDisplayNames: Set<String> = []
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
    /// Clock and scheduler for coalescing per-panel telemetry, injectable so a
    /// test can drive a burst without waiting on the main run loop.
    var telemetryNow: () -> Date = { Date() }
    var telemetryThrottle = PanelUpdateThrottle()
    /// Telemetry held for a panel until its next coalesced write.
    struct PendingTelemetry {
        var audio: PanelAudioSnapshot?
        var heartbeat: (stats: FrameSender.DeviceStats, at: Date)?
        /// The session the held data came from; a write after it is replaced
        /// or retired is dropped.
        var sessionID: UUID?
    }
    var pendingTelemetry: [String: PendingTelemetry] = [:]
    var cameraAssemblers: [String: CameraFrameAssembler] = [:]
    var scheduleTelemetryFlush: (TimeInterval, @escaping @MainActor () -> Void) -> Void = {
        delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { work() }
        }
    }
    /// Identity probes are blocking serial reads. Store the detached task itself
    /// so setup inspection and background refresh share one read per path rather
    /// than racing two readers on the same tty. The generation prevents a result
    /// from an unplugged device being applied after macOS reuses its path.
    var usbProbeTasks: [
        String: (generation: Int, task: Task<WifiConfigUI.PortProbe, Never>)
    ] = [:]
    var usbPathGenerations: [String: Int] = [:]
    /// While above zero, newly attached ports are not asked CFGSHOW in the
    /// background. A repair holds this: the board it is catching must be
    /// opened by esptool alone, in the moment it is on USB.
    var usbProbeHolds = 0
    /// Where a USB recovery is kept between launches; nil keeps none (previews
    /// and tests that do not give one).
    let recoveryStore: UsbRecoveryStore?
    /// Whether an interrupted recovery has been offered since launch, so it is
    /// offered once rather than each time the window is shown.
    var recoveryOffered = false
    /// Ports whose last CFGSHOW at this path generation went unanswered, and
    /// when to ask again. A board still booting misses its first probe; without
    /// this it stayed unverified until a manual refresh or a replug.
    /// `nextAt` is system uptime, so a clock change does not stall it.
    var usbIdentifyRetries: [
        String: (generation: Int, attempts: Int, nextAt: TimeInterval)
    ] = [:]
    /// Wait before each retry; the last value repeats until the board answers
    /// or is unplugged.
    var usbIdentifyRetryDelays: [TimeInterval] = [2, 4, 8, 16, 30]
    /// Unanswered asks after which a port no display record points at is let
    /// go: seven is about two minutes on the delays above.
    var usbUnknownPortRetryAttempts = 7
    /// CFGSHOW answers without id= at each port, at its current connection.
    /// Such an answer pairs nothing, so it is asked again, up to
    /// `usbIDlessAnswerLimit`, and then the port is left until it is plugged
    /// in again.
    var usbIDlessAnswers: [String: (generation: Int, count: Int)] = [:]
    static let usbIDlessAnswerLimit = 5
    /// While above zero, unanswered ports are not asked again: something in the
    /// app (the Add sheet's esptool read) has the port.
    var usbIdentifyRetryHolds = 0
    /// USB control writes (flip, rotate, power, brightness) being sent now,
    /// with the reprobe that follows each.
    var usbControlsInFlight = 0
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
    /// When this app last asked each panel for a rotation. A report inside
    /// `rotationEchoGrace` of it may still carry the old value, so it does not
    /// turn the region back; see `followReportedRotation`.
    var commandedRotationAt: [String: Date] = [:]
    /// The rotation a panel was at before a reported change that arrived while
    /// its geometry was still unknown, so the change can still be followed
    /// once the geometry says whether the glass is rectangular.
    var rotationAwaitingGeometry: [String: Int] = [:]

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
    /// Longer than the panel's 2 s EINF period, so the last report sent before
    /// a rotation command landed has been superseded.
    static let rotationEchoGrace: TimeInterval = 3
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
    /// Keychain lookup for the automatic preset sync, injectable because the
    /// tests and previews run unsigned and have no Keychain to read.
    var wifiCredentialLookup: @Sendable (String) -> SavedWiFiCredential? = { ssid in
        WifiCredentialStore.credential(for: ssid)
    }
    /// The Keychain's saved network names, and writing and removing one, for
    /// the Settings list. Injectable for the same reason as the lookup.
    /// The USB serial number behind a port, from the IORegistry; injectable so
    /// tests need no USB devices.
    var usbSerialReader: @Sendable (String) -> String? = { port in
        UsbRescuer.usbDevice(forPort: port).flatMap { $0.serial.isEmpty ? nil : $0.serial }
    }
    var wifiNetworkNamesReader: @Sendable () -> [String] = {
        WifiCredentialStore.savedNetworkNames()
    }
    var wifiCredentialWriter: @Sendable (SavedWiFiCredential) -> Bool = { credential in
        WifiCredentialStore.save(
            ssid: credential.ssid, password: credential.password)
    }
    var wifiCredentialRemover: @Sendable (String) -> Bool = { ssid in
        WifiCredentialStore.remove(ssid: ssid)
    }
    /// One automatic preset sync in flight per board, keyed by hardware ID
    /// rather than by service name: the sync writes to a physical board.
    var wifiPresetSyncTasks: [String: Task<Void, Never>] = [:]
    /// What was last successfully copied to each board. A reprobe after any USB
    /// control re-enters the sync path, so without this a brightness change
    /// would rewrite ten slots.
    var syncedWifiPresetSignatures: [String: String] = [:]
    /// Bumped when a saved network's password changes in Settings. Part of the
    /// sync signature, because a new password under an unchanged list of names
    /// is still a collection every board has to receive.
    var wifiCredentialRevision = 0
    /// The last completed sync per board, less any network saved again since,
    /// so the UI can say what did not fit or could not be copied without
    /// re-reading the display.
    var wifiPresetSyncReports: [String: WifiPresetSyncReport] = [:]
    /// A switch to a saved network from a board's page, in flight or failed,
    /// by service name (`PanelManager+WifiSwitch`).
    var wifiSwitchStates: [String: WifiSwitchState] = [:]
    /// How long to wait before each retry of an automatic preset sync the
    /// board went silent on. A board can answer CFGSHOW and then go quiet for
    /// several seconds - still booting after the port opened, or restarted once
    /// early on - so silence is only reported once every retry is silent too:
    /// 45 s of waiting, about a minute with each attempt's 3 s timeout.
    var wifiPresetSyncRetryDelays: [TimeInterval] = [3, 6, 12, 24]
    /// How often a board whose silence was reported is tried again while it
    /// stays attached, so the banner clears when it comes good.
    var wifiPresetSyncRecheckInterval: TimeInterval = 60
    var wifiPresetSyncRechecks: [String: Task<Void, Never>] = [:]
    /// Boards (by hardware ID) a USB flash or onboarding run currently owns.
    /// Between esptool's reset and the run's last line the board answers
    /// CFGSHOW before it is safe to hand preset commands, so the automatic
    /// sync waits for the run to finish.
    /// A count, not a set: a second run on the same board (the update sheet can
    /// be closed while its wait runs, and reopened) must not have its hold
    /// released by the first one finishing.
    var usbFlashesInFlight: [String: Int] = [:]
    /// Bumped each time a run starts on a board. A sync that started before a
    /// run and finishes after it has seen a board that was reset under it.
    var usbFlashEpochs: [String: Int] = [:]

    init(
        settings: SenderSettings? = nil,
        defaultDisplayName: String = "",
        otaPasswords: OTAPasswordStoring = KeychainOTAPasswordStore(),
        coversScreenDevices: Bool = true
    ) {
        self.defaultDisplayName = defaultDisplayName
        self.otaPasswords = otaPasswords
        // The listing modes print and leave, and must not cover a screen.
        screenDevices = ScreenDeviceController(
            storeURL: ScreenDeviceStore.defaultURL, live: coversScreenDevices)
        let url = PanelStore.defaultURL
        persistenceURL = url
        settingsURL = SettingsStore.defaultURL
        recoveryStore = UsbRecoveryStore.defaultURL.map(UsbRecoveryStore.init(url:))
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
        applySavedNetworkNames(WifiCredentialStore.savedNetworkNames())
        usbDevices = WifiConfigUI.candidatePorts().map {
            WifiConfigUI.USBDeviceOption(path: $0)
        }
        refreshAudioDevices()
        if let failure = loaded.failure {
            report(.persistence, source: Self.panelRecordsReadIssueSource,
                   detail: "Saved device settings could not be read "
                + "from \(url?.path ?? "disk"): \(failure)")
        }
        if let failure = loadedSettings.failure {
            report(.persistence, source: Self.settingsReadIssueSource,
                   detail: "App settings could not be read, so "
                + "the defaults are in use: \(failure)")
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.refreshUSBPorts()
                self?.refreshAudioDevices()
                self?.refreshMacPermissionGuidance()
                self?.sortPanels()
                self?.objectWillChange.send()
            }
        }
        refreshMacPermissionGuidance()
        scheduleInitialLocalNetworkCheck()
        // Dragging the marquee streams straight through to whichever panel it
        // was opened for.
        regionSelector.onChange = { [weak self] region in
            guard let self, let target = self.regionTarget else { return }
            self.apply(region, to: target)
            // A hand-dragged size usually matches no preset; the highlight has
            // to follow the rectangle or it lies within one drag.
            self.regionSelector.activeScale = self.geometry(of: target).flatMap {
                region.matchingScale(geometry: $0)
            }
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
            guard let self, let target = self.regionTarget,
                  self.geometry(of: target).map({ $0.width == $0.height }) ?? true
            else { return }
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
        wireScreenDevices()
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
        settingsPersistenceURL: URL? = nil,
        recoveryStore: UsbRecoveryStore? = nil
    ) {
        defaultDisplayName = ""
        self.recoveryStore = recoveryStore
        // Never live here: a preview or a test must not cover a screen.
        screenDevices = ScreenDeviceController(storeURL: nil, live: false)
        // In memory by default, never the keychain: this initialiser is what the
        // SwiftUI previews and the tests use, and both run unsigned.
        self.otaPasswords = otaPasswords
        persistenceURL = nil
        settingsURL = settingsPersistenceURL
        self.settings = settings.validated
        panels = previewPanels
        sortPanels()
        // Never the Keychain from here, for the same reason as the OTA store:
        // every saved-network read and write in a preview or test stays in
        // memory. The sync tests replace the lookup with their own.
        useWifiCredentials(InMemoryWifiCredentials(savedNetworkNames.map {
            SavedWiFiCredential(ssid: $0, password: "preview")
        }))
        // Treated as what the Keychain holds, so the preset order is migrated
        // here exactly as it is at launch.
        applySavedNetworkNames(savedNetworkNames)
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
        var validated = new.validated
        // The preset order is edited from the WiFi Networks pane, not through
        // here, so a copy of the settings taken before an edit - or the
        // AppleScript setter's - must not put the old order back.
        validated.wifiPresetOrder = settings.wifiPresetOrder
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
            session.applyAudio(tuning: validated.audioTuning)
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

    /// Bring the saved networks up to date with what the Keychain holds: the
    /// first-launch migration of the preset order, and every refresh after.
    /// Returns whether the published list changed, which is what the attached
    /// boards have to be told about.
    ///
    /// The order is written back only when reconciling actually added a name,
    /// so a launch that finds nothing new leaves settings.json untouched and
    /// running this twice writes at most once.
    @discardableResult
    func applySavedNetworkNames(_ keychainNames: [String]) -> Bool {
        let order = WifiPresetOrder.reconciled(
            stored: settings.wifiPresetOrder, keychainNames: keychainNames)
        // Nothing saved and nothing stored stays nil rather than writing an
        // empty list, so a first run with no networks creates no file.
        if order != (settings.wifiPresetOrder ?? []) {
            settings.wifiPresetOrder = order
            saveWifiPresetOrder()
        }
        return publishSavedNetworks(order: order, keychainNames: keychainNames)
    }

    /// Replace the preset order with one the user chose in Settings. Names the
    /// order no longer mentions keep their Keychain items; see
    /// `removeSavedNetwork` for the one path that deletes.
    func setWifiPresetOrder(_ order: [String], keychainNames: [String]) {
        let cleaned = WifiPresetOrder.reconciled(
            stored: order, keychainNames: keychainNames)
        if cleaned != settings.wifiPresetOrder {
            settings.wifiPresetOrder = cleaned
            saveWifiPresetOrder()
        }
        if publishSavedNetworks(order: cleaned, keychainNames: keychainNames) {
            syncWifiPresetsToAttachedDevices()
        }
    }

    /// Write the preset order and nothing else. The file on disk is read back
    /// and only its order replaced, because what is in memory can differ from
    /// it on purpose: `--fps` and the other command-line overrides apply for
    /// one run without being written back. A file that cannot be read is left
    /// alone - the launch has already said the defaults are in use, and
    /// writing over it would turn that warning into the loss it warns of. The
    /// order stays in memory and is seeded again next launch.
    private func saveWifiPresetOrder() {
        guard let settingsURL else { return }
        let onDisk = SettingsStore.load(from: settingsURL)
        guard onDisk.failure == nil else {
            report(.persistence, source: Self.settingsIssueSource,
                   detail: "The WiFi preset order was not saved, because "
                + "\(settingsURL.path) could not be read: \(onDisk.failure ?? "")")
            return
        }
        var updated = onDisk.settings
        updated.wifiPresetOrder = settings.wifiPresetOrder
        do {
            try SettingsStore.save(updated, to: settingsURL)
            resolve(.persistence, source: Self.settingsIssueSource)
        } catch {
            report(.persistence, source: Self.settingsIssueSource,
                   detail: "App settings could not be saved to "
                + "\(settingsURL.path): \(error.localizedDescription)")
        }
    }

    private func publishSavedNetworks(order: [String], keychainNames: [String]) -> Bool {
        let present = WifiPresetOrder.present(order, keychainNames: keychainNames)
        guard present != savedNetworkNames else { return false }
        savedNetworkNames = present
        return true
    }

    private func saveSettings() {
        guard let settingsURL else { return }
        do {
            try SettingsStore.save(settings, to: settingsURL)
            resolve(.persistence, source: Self.settingsIssueSource)
        } catch {
            report(.persistence, source: Self.settingsIssueSource,
                   detail: "App settings could not be saved to "
                + "\(settingsURL.path): \(error.localizedDescription)")
        }
    }


    // MARK: problem reporting

    /// Record a standing problem, replacing any earlier report of the same kind
    /// so a repeating failure does not stack up.
    func report(
        _ issue: AppIssue,
        detail: String,
        technicalDetail: String? = nil,
        permissionState: PermissionIssueState? = nil
    ) {
        report(
            issue, source: "", detail: detail, technicalDetail: technicalDetail,
            permissionState: permissionState)
    }

    /// Record a problem that one of several independent sources has - one
    /// board, one file - so that source recovering withdraws only its own part.
    /// The banner stays up, showing every remaining source, until the last one
    /// recovers.
    func report(
        _ issue: AppIssue,
        source: String,
        detail: String,
        technicalDetail: String? = nil,
        permissionState: PermissionIssueState? = nil
    ) {
        var sources = issueSources[issue, default: []]
        if let index = sources.firstIndex(where: { $0.source == source }) {
            sources[index] = (source, detail, technicalDetail, permissionState)
        } else {
            sources.append((source, detail, technicalDetail, permissionState))
        }
        issueSources[issue] = sources
        publishIssue(issue)
    }

    /// Withdraw a problem because it no longer applies, whatever reported it.
    func resolve(_ issue: AppIssue) {
        issueSources[issue] = nil
        publishIssue(issue)
    }

    /// Withdraw one source's part of a problem because that source is fine now.
    func resolve(_ issue: AppIssue, source: String) {
        guard var sources = issueSources[issue] else { return }
        sources.removeAll { $0.source == source }
        issueSources[issue] = sources.isEmpty ? nil : sources
        publishIssue(issue)
    }

    private func publishIssue(_ issue: AppIssue) {
        guard let sources = issueSources[issue], !sources.isEmpty else {
            issues.removeAll { $0.issue == issue }
            return
        }
        let technicalDetail = sources.compactMap(\.technicalDetail).joined(separator: "\n")
        let reported = ReportedIssue(
            issue: issue,
            detail: sources.map(\.detail).joined(separator: "\n"),
            technicalDetail: technicalDetail.isEmpty ? nil : technicalDetail,
            permissionState: sources.compactMap(\.permissionState).first)
        if let index = issues.firstIndex(where: { $0.issue == issue }) {
            guard issues[index] != reported else { return }
            issues[index] = reported
        } else {
            issues.append(reported)
        }
    }

    /// Dismiss a problem the user has read. Identical to `resolve`, but named
    /// for the UI so the intent at each call site is obvious.
    func dismissIssue(_ issue: AppIssue) {
        if issue == .accessibility { accessibilityNoticeDismissed = true }
        resolve(issue)
    }

    /// Record the only reliable proof that the current process can capture:
    /// ScreenCaptureKit successfully enumerated content. Permission can be
    /// granted while the existing process still needs a relaunch.
    func recordScreenCaptureAttempt(succeeded: Bool, technicalDetail: String? = nil) {
        screenRecordingPermissionState.observeCaptureResult(
            works: succeeded, authorized: CGPreflightScreenCaptureAccess())
        screenRecordingTechnicalDetail = technicalDetail
        refreshPermissionChecklist()
    }

    /// Re-check grants when the app returns from System Settings and on the
    /// existing two-second housekeeping timer. The screen-capture probe runs
    /// only while there is an unresolved capture issue.
    func refreshMacPermissionGuidance(forceLocalNetworkProbe: Bool = false) {
        if forceLocalNetworkProbe
            || issues.contains(where: { $0.issue == .localNetwork })
            || (localNetworkChecklistStatus == nil
                && permissionPromptHistory.wasRequested(.localNetwork))
        {
            refreshLocalNetworkAuthorization(forceLocalNetworkProbe)
        }
        refreshMediaKeyAuthorization()
        refreshSystemAudioRecordingAuthorization()

        let authorized = CGPreflightScreenCaptureAccess()
        screenRecordingPermissionState.observeAuthorization(authorized)
        guard screenRecordingPermissionState != .ready else {
            screenRecordingTechnicalDetail = nil
            refreshPermissionChecklist()
            return
        }
        refreshPermissionChecklist()
        if authorized {
            Task { [weak self] in
                do {
                    _ = try await SCShareableContent.excludingDesktopWindows(
                        false, onScreenWindowsOnly: false)
                    await MainActor.run {
                        self?.recordScreenCaptureAttempt(succeeded: true)
                    }
                } catch {
                    await MainActor.run {
                        self?.recordScreenCaptureAttempt(
                            succeeded: false, technicalDetail: error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Ask macOS itself for a grant when it still has a prompt to show.
    func requestPermissionAccess(for issue: AppIssue) {
        guard let permission = issue.permission else { return }
        requestPermissionAccess(for: permission)
    }

    /// The checklist's action path. It records the attempt under this exact
    /// signed app identity, so a new signature correctly starts at "Not yet
    /// asked" instead of inheriting a stale denial label.
    func requestPermissionAccess(for permission: MacPermission) {
        guard permission != .cameraExtension || !CameraExtensionInstaller.isActivationPending
        else {
            operationOutcome = .success(
                "Camera extension request is pending",
                "Approve ESPDisplay Camera Extension in System Settings, then return here.")
            return
        }
        activePermissionRequest = permission
        switch permission {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
            permissionPromptHistory.markRequested(permission)
            refreshMacPermissionGuidance()
        case .accessibility:
            requestMediaKeyAuthorization()
            permissionPromptHistory.markRequested(permission)
        case .systemAudioRecording:
            systemAudioChecklistStatus = .checking
            permissionPromptHistory.markRequested(permission)
            let completeTCCRequest: @Sendable (Bool) -> Void = { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.systemAudioChecklistStatus = granted ? .allowed : .blocked
                    self.refreshMacPermissionGuidance()
                }
            }
            if let request = SystemAudioAccess.system.request {
                request(completeTCCRequest)
            } else {
                SystemAudioAccess.requestWithProcessTap { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        // A tap can start and still deliver only silence when
                        // denied. It cannot establish a permission result.
                        self.systemAudioChecklistStatus = .checking
                        self.activePermissionRequest = nil
                        self.refreshMacPermissionGuidance()
                    }
                }
            }
        case .localNetwork:
            permissionPromptHistory.markRequested(permission)
            localNetworkInitialCheckTask?.cancel()
            localNetworkInitialCheckTask = nil
            localNetworkChecklistStatus = nil
            localNetworkTechnicalDetail = nil
            requestLocalNetworkAuthorization()
            unblockForegroundStartup()
            refreshPermissionChecklist()
        case .cameraExtension:
            // The request may wait for approval across the point where the
            // app is closed. Record the real activation attempt immediately,
            // rather than forgetting it until macOS later sends a callback.
            permissionPromptHistory.markRequested(permission)
            cameraExtensionNeedsApproval = false
            cameraExtensionNeedsRestart = false
            cameraExtensionTechnicalDetail = nil
            CameraExtensionInstaller.activate { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .installed:
                        self.cameraExtensionNeedsApproval = false
                        self.cameraExtensionActivated = true
                        self.cameraExtensionNeedsRestart = false
                        self.cameraExtensionTechnicalDetail = nil
                        self.operationOutcome = .success(
                            "Camera extension installed",
                            "ESPDisplay XIAOML Camera is ready in video apps.")
                    case .needsUserApproval:
                        self.cameraExtensionNeedsApproval = true
                        self.cameraExtensionNeedsRestart = false
                        self.operationOutcome = .success(
                            "Camera extension needs approval",
                            "Approve ESPDisplay Camera Extension in System Settings, "
                                + "then return here.")
                    case .needsRestart:
                        self.cameraExtensionNeedsApproval = false
                        self.cameraExtensionActivated = false
                        self.cameraExtensionNeedsRestart = true
                        self.cameraExtensionTechnicalDetail = nil
                        self.operationOutcome = .success(
                            "Camera extension approved",
                            "Restart your Mac before ESPDisplay XIAOML Camera appears in video apps.")
                    case .requestInProgress:
                        self.operationOutcome = .success(
                            "Camera extension request is pending",
                            "Approve ESPDisplay Camera Extension in System Settings, "
                                + "then return here.")
                    case .failed(let error):
                        self.cameraExtensionNeedsApproval = true
                        self.cameraExtensionNeedsRestart = false
                        self.cameraExtensionTechnicalDetail = error.localizedDescription
                        self.operationOutcome = .failure(
                            "Camera extension could not install",
                            error.localizedDescription)
                    }
                    self.refreshPermissionChecklist()
                }
            }
        }
    }

    /// Local Network does not offer a preflight API. Bonjour and multicast
    /// mDNS may be ready while unicast device paths are prohibited, so the
    /// sender's satisfied unicast path is the positive signal.
    func observeLocalNetworkPermission(_ observation: LocalNetworkPermissionProbe.Observation) {
        switch observation {
        case .policyDenied(let technicalDetail):
            localNetworkInitialCheckTask?.cancel()
            localNetworkInitialCheckTask = nil
            permissionPromptHistory.markRequested(.localNetwork)
            localNetworkChecklistStatus = .blocked
            localNetworkTechnicalDetail = technicalDetail
            refreshPermissionChecklist()
        case .browserReady:
            break
        case .unicastPathReady:
            localNetworkInitialCheckTask?.cancel()
            localNetworkInitialCheckTask = nil
            localNetworkChecklistStatus = .allowed
            localNetworkTechnicalDetail = nil
            refreshPermissionChecklist()
        case .deviceAnswered:
            localNetworkInitialCheckTask?.cancel()
            localNetworkInitialCheckTask = nil
            localNetworkChecklistStatus = .allowed
            localNetworkTechnicalDetail = nil
            refreshPermissionChecklist()
        }
    }

    private func refreshSystemAudioRecordingAuthorization() {
        switch SystemAudioAccess.system.status() {
        case .authorized:
            systemAudioChecklistStatus = .allowed
        case .denied:
            systemAudioChecklistStatus = .blocked
        case .notDetermined:
            systemAudioChecklistStatus = .notYetAsked
        case .unknown:
            // An unavailable preflight API is not evidence that this app is
            // denied. Leave it Checking so a configured Mac never sees a
            // false missing-permission sheet.
            break
        }
        refreshPermissionChecklist()
    }

    /// The same source powers the checklist and the in-context banners. A
    /// "not yet asked" row is proactive guidance, not an error banner.
    private func refreshPermissionChecklist() {
        let next = MacPermission.allCases.map(permissionChecklistItem)
        if permissionChecklist != next {
            permissionChecklist = next
        }
        if let activePermissionRequest,
           next.first(where: { $0.permission == activePermissionRequest })?.isReady == true {
            self.activePermissionRequest = nil
        }
        for item in next {
            publishPermissionIssue(for: item)
        }
        let allRequiredReady = next
            .filter { $0.permission.isRequiredAtLaunch }
            .allSatisfy(\.isReady)
        if allRequiredReady {
            permissionChecklistPresented = false
            permissionChecklistDismissedThisLaunch = false
            automaticPermissionSequence = false
            activePermissionRequest = nil
            unblockForegroundStartup()
        } else if PermissionChecklistPresentation.shouldPresent(for: next),
                  !permissionChecklistDismissedThisLaunch
        {
            permissionChecklistPresented = true
        } else if !PermissionChecklistPresentation.shouldPresent(for: next) {
            permissionChecklistPresented = false
            // A previously requested Local Network grant is rechecked in the
            // background, so its unicast probe can prove or disprove it
            // without holding startup or flashing a sheet.
            if permissionPromptHistory.wasRequested(.localNetwork) {
                unblockForegroundStartup()
            }
        }
        advanceAutomaticPermissionSequence()
    }

    private func permissionChecklistItem(
        for permission: MacPermission
    ) -> PermissionChecklistItem {
        let status: PermissionChecklistStatus
        let requiresRelaunch: Bool
        let requiresRestart: Bool
        switch permission {
        case .screenRecording:
            switch screenRecordingPermissionState {
            case .ready:
                status = .allowed
                requiresRelaunch = false
                requiresRestart = false
            case .needsAccess:
                status = permissionPromptHistory.wasRequested(permission)
                    ? .blocked : .notYetAsked
                requiresRelaunch = false
                requiresRestart = false
            case .grantedNeedsRelaunch:
                status = .allowed
                requiresRelaunch = true
                requiresRestart = false
            }
        case .localNetwork:
            status = localNetworkChecklistStatus ?? .checking
            requiresRelaunch = false
            requiresRestart = false
        case .systemAudioRecording:
            status = systemAudioChecklistStatus ?? .checking
            requiresRelaunch = false
            requiresRestart = false
        case .accessibility:
            status = mediaKeysAuthorized()
                ? .allowed
                : (permissionPromptHistory.wasRequested(permission)
                    ? .blocked : .notYetAsked)
            requiresRelaunch = false
            requiresRestart = false
        case .cameraExtension:
            status = (cameraExtensionActivated || CameraExtensionInstaller.isInstalled)
                ? .allowed
                : (cameraExtensionNeedsApproval
                    || permissionPromptHistory.wasRequested(permission)
                    ? .blocked : .notYetAsked)
            requiresRelaunch = false
            requiresRestart = cameraExtensionNeedsRestart
        }
        return PermissionChecklistItem(
            permission: permission, status: status, requiresRelaunch: requiresRelaunch,
            requiresRestart: requiresRestart)
    }

    private func publishPermissionIssue(for item: PermissionChecklistItem) {
        let issue = item.permission.appIssue
        guard item.status == .blocked || item.requiresRelaunch || item.requiresRestart else {
            resolve(issue, source: "permission checklist")
            return
        }
        let state: PermissionIssueState
        if item.requiresRestart {
            state = .grantedNeedsRestart
        } else if item.requiresRelaunch {
            state = .grantedNeedsRelaunch
        } else {
            state = .needsAccess
        }
        let technicalDetail: String?
        switch item.permission {
        case .screenRecording:
            technicalDetail = screenRecordingTechnicalDetail
        case .localNetwork:
            technicalDetail = localNetworkTechnicalDetail
        case .cameraExtension:
            technicalDetail = cameraExtensionTechnicalDetail
        case .systemAudioRecording, .accessibility:
            technicalDetail = nil
        }
        report(
            issue,
            source: "permission checklist",
            detail: item.permission.message(for: state),
            technicalDetail: technicalDetail,
            permissionState: state)
    }

    /// A Local Network request is only known to be missing after this short
    /// initial grace period. A device that reports a usable unicast path first
    /// makes the row Allowed without ever showing the launch sheet.
    private func scheduleInitialLocalNetworkCheck() {
        guard !permissionPromptHistory.wasRequested(.localNetwork) else { return }
        localNetworkInitialCheckTask?.cancel()
        let startedAt = localNetworkInitialCheckStartedAt
        localNetworkInitialCheckTask = Task { [weak self] in
            let nanoseconds = UInt64(Self.localNetworkInitialGracePeriod * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self,
                  self.localNetworkChecklistStatus == nil,
                  self.localNetworkInitialCheckStartedAt == startedAt,
                  !self.permissionPromptHistory.wasRequested(.localNetwork)
            else { return }
            self.localNetworkChecklistStatus = .notYetAsked
            self.refreshPermissionChecklist()
        }
    }

    /// Called once the first interactive window has a checklist on screen.
    /// The next row is requested only after the previous row really becomes
    /// usable, so macOS never receives a stack of simultaneous prompts.
    func beginAutomaticPermissionRequests() {
        permissionChecklistDismissedThisLaunch = false
        automaticPermissionSequence = true
        refreshPermissionChecklist()
    }

    func dismissPermissionChecklist() {
        automaticPermissionSequence = false
        permissionChecklistDismissedThisLaunch = true
        permissionChecklistPresented = false
        unblockForegroundStartup()
    }

    /// Settings > Permissions is the permanent version of the same checklist.
    /// Opening it closes the modal and leaves the user in one place to finish
    /// setup, instead of displaying two copies at once.
    func openPermissionsSettings() {
        dismissPermissionChecklist()
    }

    var cameraExtensionActivationPending: Bool {
        CameraExtensionInstaller.isActivationPending
    }

    /// Foreground capture and discovery wait until the visible checklist has
    /// reached the Local Network row. That keeps their own first-use prompts
    /// from racing ahead of the explained Screen Recording request. A
    /// background LaunchAgent intentionally does not wait because it has no
    /// visible checklist.
    func waitForForegroundStartupPermissionSetup() async {
        guard !foregroundStartupUnblocked else { return }
        await withCheckedContinuation { continuation in
            foregroundStartupContinuation = continuation
        }
    }

    private func unblockForegroundStartup() {
        guard !foregroundStartupUnblocked else { return }
        foregroundStartupUnblocked = true
        foregroundStartupContinuation?.resume()
        foregroundStartupContinuation = nil
    }

    private func advanceAutomaticPermissionSequence() {
        guard automaticPermissionSequence else { return }
        if let activePermissionRequest,
           let active = permissionChecklist.first(where: {
               $0.permission == activePermissionRequest
           })
        {
            if activePermissionRequest == .localNetwork, active.status == .blocked {
                // DNS-SD has delivered a terminal policy denial. Keep the
                // Local Network row and its Settings-only recovery visible,
                // but continue to the independent Camera Extension request.
                self.activePermissionRequest = nil
            } else {
                guard active.isReady else { return }
                self.activePermissionRequest = nil
            }
        }
        let requiredItems = permissionChecklist.filter {
            $0.permission.isRequiredAtLaunch
        }
        guard let permission = PermissionRequestSequence.nextAutomaticRequest(in: requiredItems)
        else { return }
        activePermissionRequest = permission
        if permission == .localNetwork {
            unblockForegroundStartup()
        }
        requestPermissionAccess(for: permission)
    }


    /// The network the board itself reports, for its page in the manager window.
    ///
    /// The name comes from the panel's own mDNS `ssid` record (the network it
    /// has joined) or from CFGSHOW's `ssid=` over USB (the network it is set to
    /// join), whichever arrived last. Firmware from before the record names it
    /// only over USB, so with neither this says the name is not reported rather
    /// than offering the app's saved list. An empty `reportedSSID` is the board
    /// saying over USB that no network is set.
    nonisolated static func boardNetworkDescription(
        reportedSSID: String?, connected: Bool?
    ) -> String {
        guard let reportedSSID else {
            return connected == true
                ? "Connected (name not reported)"
                : "Unknown (not reported yet)"
        }
        guard !reportedSSID.isEmpty else { return "None configured" }
        switch connected {
        case true?: return reportedSSID
        case false?: return "Not connected (set to \"\(reportedSSID)\")"
        case nil: return "\(reportedSSID) (connection not reported)"
        }
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
            // Every orientation write that goes through here - this app's own
            // rotate and flip, EINF and EACK reports - reaches the capture's
            // frame shape too. A no-op unless the shape actually changes.
            sessions[serviceName]?.setPanelRotation(panels[index].rotation)
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

    func statusText(
        for panel: PanelSnapshot,
        asOf now: Date = Date()
    ) -> String {
        panel.statusText(
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
            resolve(.persistence, source: Self.panelRecordsIssueSource)
        } catch {
            report(.persistence, source: Self.panelRecordsIssueSource,
                   detail: "Device names and USB assignments could not "
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
                    lastError: "Gave up trying to reach this device. It is retried "
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
