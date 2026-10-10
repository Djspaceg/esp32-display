import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import SenderProtocol

/// One streaming session: a device plus a supervised capture source. Runs
/// forever and heals itself through every observed failure mode (stream
/// deaths, display reconfiguration, device reboots, WiFi rot). With
/// discovery, one of these runs per panel on the network.
final class DeviceSession {
    struct Status {
        let serviceName: String
        let displayFPS: Double
        let framesSent: UInt64
        let sendErrors: UInt64
        let diffPercent: Double
        let heartbeatAge: TimeInterval?
        let stats: BandProtocol.DeviceStats
        let info: DeviceProtocol.DeviceInfo?
        let resolvedAddress: String?
        let spacingMicros: UInt32
        let paused: Bool
        /// Capture and sending are suspended because the device stopped
        /// answering. Distinct from `paused`, which is the user's choice.
        let parked: Bool
        let sourceDescription: String
        /// Orientation of the last frame sent, i.e. what the panel has on screen.
        /// Carried so the settings window can describe gestures against the axis
        /// the panel is actually using.
        let landscape: Bool
        /// What capture is doing, so a broken mirror is visible in the window
        /// rather than only in stderr.
        let captureStatus: CaptureStatus
        /// When a frame was last captured and sent, or nil if none ever has
        /// been. The UI reports the gap, which is the one number that
        /// distinguishes "mirroring stopped" from "nothing is changing
        /// on screen".
        let lastFrameAt: Date?
        let updatedAt: Date
        /// Seconds since the device last really answered (`FrameSender.replyAge`).
        var replyAge: TimeInterval? = nil
    }

    /// What this device should show, from the per-device config file:
    /// - auto: the user's picker selection if any, else display tracking
    /// - display: track a named virtual display (mirror-aware)
    /// - window: follow a named app window
    enum Source {
        case auto(defaultDisplay: String)
        case display(String)
        case window(String)
        /// A rectangle of one named display, drawn with the region selector.
        case region(RegionSpec)
    }

    /// What the supervisor knows about the window it is following, so a resize
    /// can be absorbed in place instead of by rebuilding the stream.
    private struct TrackedWindow {
        var id: CGWindowID
        /// The application that owns it, used to find the replacement when a
        /// resize or full-screen transition destroys and recreates the window.
        var owner: String?
        /// Whether the window was on screen at the last check. A minimised or
        /// hidden window legitimately delivers no frames.
        var onScreen = true
    }

    let id: UUID
    let name: String
    /// The panel's IP as this session's socket resolved it, or nil before the
    /// connection is ready.
    ///
    /// Exposed for the firmware push, which sends its invitation straight to the
    /// panel rather than through this session: an update needs an address, and
    /// this is the one the panel's own datagrams are arriving from. Reading it
    /// here rather than adding a second discovery path is the point - a
    /// mDNS lookup done again at push time could resolve to something else.
    var resolvedAddress: String? { sender.resolvedAddress }
    private let sender: FrameSender
    private var audioSession: PanelAudioSession?
    private var audioDescriptor: AudioStreamDescriptor?
    private let audioSessionFactory: ((AudioStreamDescriptor) -> PanelAudioSession)?
    private var speakerVolume = PanelSpeakerVolume.default
    private var audioTuning = AudioRuntimeTuning()
    private var audioRunStarted = false
    private var audioEnabled = true
    private let source: Source
    private let picker: PickerSource?
    private let onStatus: ((Status) -> Void)?
    private let onPreview: ((CGImage, Bool) -> Void)?
    private let stateLock = NSLock()
    private var pickedFilter: SCContentFilter?
    private var pickedGeneration: UInt64 = 0
    private var _captureStatus: CaptureStatus = .waiting("Starting up…")
    private var _previewEnabled = false
    private var _stopped = false
    private weak var activeCapture: DisplayCapture?
    /// The rectangle the user wants captured, and the one the running stream has
    /// actually been given, so the drain loop knows when it has caught up.
    private var _region: RegionSpec?
    private var _appliedRegion: RegionSpec?
    private var _regionOverride: RegionSpec?
    private var regionUpdateInFlight = false
    /// Last frame time carried across capture restarts.
    ///
    /// Read from the live capture it would reset to nil every time a stream was
    /// replaced, so the window would claim "No frames yet" for a moment during
    /// each restart - the opposite of the reassurance this row is for.
    private var _lastFrameAt: Date?
    private var _fps: Int
    /// The panel's mounting rotation in quarter turns, as the manager records it.
    private var _panelRotation = 0
    /// Bumped when a setting that capture was started with changes, so the
    /// watchdog restarts the stream rather than leaving the old rate running.
    private var settingsGeneration: UInt64 = 0

    /// How long the device may stay silent before capture is torn down.
    ///
    /// Comfortably longer than the 10s reconnect trigger, so a brief WiFi
    /// stumble is healed by re-resolving rather than by stopping capture. Past
    /// this point the device is genuinely gone, and continuing to capture the
    /// screen and push frames at it only burns CPU and counts send errors
    /// (observed: 213,000 of them against one panel that was switched off).
    private static let parkAfterSilence: TimeInterval = 30

    /// Whether capture should be torn down, given how long the device has been
    /// silent. A nil age means nothing has ever been heard from it, which the
    /// connect retries in `run()` already handle, so it never parks here.
    static func shouldPark(silentFor age: TimeInterval?) -> Bool {
        guard let age else { return false }
        return age > parkAfterSilence
    }

    /// Whether a parked session should resume, judged by a genuine new reply
    /// rather than by heartbeat age, which a reconnect resets. Compared for
    /// inequality so the counter wrapping around cannot wedge a session parked
    /// forever.
    static func hasDeviceReturned(
        repliesNow: UInt64, repliesWhenParked: UInt64
    ) -> Bool {
        repliesNow != repliesWhenParked
    }

    private var lastReport = Date()
    private var lastCount: UInt64 = 0

    private let linkTiming: LinkSupervisor.Timing

    /// Judges whether the running stream is still delivering frames. Touched
    /// only by the `run()` task, which is sequential, so it takes no lock.
    private var stallMonitor = CaptureStallMonitor()

    init(
        id: UUID = UUID(), name: String, sender: FrameSender,
        audioSession: PanelAudioSession? = nil,
        audioDescriptor: AudioStreamDescriptor? = nil,
        audioSessionFactory: ((AudioStreamDescriptor) -> PanelAudioSession)? = nil,
        source: Source, picker: PickerSource?, fps: Int,
        linkTiming: LinkSupervisor.Timing = .standard,
        onStatus: ((Status) -> Void)? = nil,
        onPreview: ((CGImage, Bool) -> Void)? = nil
    ) {
        self.id = id
        self.linkTiming = linkTiming
        self.name = name
        self.sender = sender
        self.audioSession = audioSession
        self.audioDescriptor = audioDescriptor
        self.audioSessionFactory = audioSessionFactory
        self.source = source
        self.picker = picker
        self._fps = fps
        self.onStatus = onStatus
        self.onPreview = onPreview
    }

    /// Permanent local teardown used when the owning hardware record is deleted.
    var isStopped: Bool {
        stateLock.withLock { _stopped }
    }

    func stop() {
        let capture: DisplayCapture? = stateLock.withLock {
            guard !_stopped else { return nil }
            _stopped = true
            _previewEnabled = false
            pickedGeneration &+= 1
            settingsGeneration &+= 1
            return activeCapture
        }
        sender.stop()
        currentAudioSession?.stop()
        if let capture {
            Task { await capture.stop() }
        }
    }

    /// What capture is doing right now.
    var captureStatus: CaptureStatus {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _captureStatus
    }

    /// Record a capture state and publish it immediately.
    ///
    /// Published straight away rather than waiting for the next five-second
    /// status tick: the whole point of these states is that the user is
    /// watching the window wondering why nothing is happening.
    private func setCaptureStatus(_ status: CaptureStatus) {
        stateLock.lock()
        let changed = _captureStatus != status
        _captureStatus = status
        stateLock.unlock()
        guard changed else { return }
        reportProgress(force: true)
    }

    /// The status for a source that could not be found: a calm Waiting, unless
    /// the lookup failed because ScreenCaptureKit stopped answering, which is a
    /// fault the user should see rather than a display that is simply absent.
    private func sourceMissing(_ waiting: String) -> CaptureStatus {
        DisplayCapture.isUnresponsive
            ? .failed(Self.unresponsiveMessage)
            : .waiting(waiting)
    }

    private static let unresponsiveMessage =
        "Screen capture is not responding, so the source cannot be found. "
        + "Retrying automatically."

    /// A clock for the stall monitor that wall-clock changes cannot move.
    private static func monotonicNow() -> Date {
        Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime)
    }

    /// Whether silence from capture would mean something. Not while the user
    /// has paused the panel, the captured display sleeps, the login session is
    /// locked or off the console, or a followed window (or every window of a
    /// picked application) is off screen: each of
    /// those legitimately delivers no frames.
    static func isCaptureLive(
        paused: Bool, displayAsleep: Bool, sessionInactive: Bool, windowOnScreen: Bool
    ) -> Bool {
        !paused && !displayAsleep && !sessionInactive && windowOnScreen
    }

    /// Whether an application-only picker selection has anything to show:
    /// true when one of its applications owns an on-screen window. An empty
    /// application list means the selection is not an application filter.
    static func applicationContentVisible(
        includedApplicationPIDs: [pid_t], onScreenWindowOwnerPIDs: [pid_t]
    ) -> Bool {
        guard !includedApplicationPIDs.isEmpty else { return true }
        let owners = Set(onScreenWindowOwnerPIDs)
        return includedApplicationPIDs.contains { owners.contains($0) }
    }

    static let stallFailureMessage =
        "No new picture from the source. Restarting capture has not brought it "
        + "back yet; still retrying."

    /// What the watchdog does with a stall verdict: the status to publish, if
    /// any, and whether to rebuild the stream. A routine probe restart
    /// publishes nothing, so a static screen never flickers the status.
    static func stallResponse(
        to verdict: CaptureStallMonitor.Verdict
    ) -> (status: CaptureStatus?, restart: Bool) {
        switch verdict {
        case .healthy: return (nil, false)
        case .recovered: return (.streaming, false)
        case .restart(let failing):
            return (failing ? .failed(stallFailureMessage) : nil, true)
        }
    }

    /// Report the stream as healthy, unless the stall monitor is still waiting
    /// for a restarted stream to prove itself. Starting a stream is not proof
    /// it delivers, and clearing a stall failure on start alone would flick it
    /// off and back on at every retry. The monitor clears it on the first frame.
    private func markStreaming() {
        guard !stallMonitor.isFailing else { return }
        setCaptureStatus(.streaming)
    }

    /// Turn the live preview on or off for this session. Off costs nothing:
    /// the capture layer skips the image conversion entirely.
    func setPreviewEnabled(_ enabled: Bool) {
        stateLock.lock()
        _previewEnabled = enabled
        let capture = activeCapture
        stateLock.unlock()
        capture?.setPreviewEnabled(enabled)
    }

    private var previewEnabled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _previewEnabled
    }

    /// Remember the capture currently running, so a preview toggle arriving
    /// between restarts reaches it.
    private func adopt(_ capture: DisplayCapture?) {
        stateLock.lock()
        activeCapture = capture
        let enabled = _previewEnabled
        stateLock.unlock()
        capture?.setPreviewEnabled(enabled)
    }

    /// Capture rate. ScreenCaptureKit takes this when the stream starts, so
    /// changing it makes the watchdog restart capture.
    var fps: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _fps
    }

    func setFPS(_ fps: Int) {
        stateLock.lock()
        let changed = _fps != fps
        _fps = fps
        if changed { settingsGeneration &+= 1 }
        stateLock.unlock()
    }

    /// Tell capture how the panel is mounted. The frame shape follows it for
    /// every kind of source (`DisplayCapture.streamsLandscape`). A change that
    /// alters the shape reshapes the running stream in place; only if that
    /// fails - no stream yet, or ScreenCaptureKit refusing - does the watchdog
    /// restart capture, as for a frame-rate change. A 180 flip keeps the shape
    /// and is left to the panel.
    func setPanelRotation(_ rotation: Int) {
        let geometry = sender.geometry
        let capture: DisplayCapture?? = stateLock.withLock {
            let before = DisplayCapture.streamsLandscape(
                geometry: geometry, rotation: _panelRotation)
            _panelRotation = rotation
            guard DisplayCapture.streamsLandscape(geometry: geometry, rotation: rotation)
                != before
            else { return .none }
            return .some(activeCapture)
        }
        guard case .some(let running) = capture else { return }
        guard let running else {
            // Capture may be being built right now with the old shape.
            stateLock.withLock { settingsGeneration &+= 1 }
            return
        }
        Task { [weak self] in
            // The wanted shape is read when the reshape runs, so a rotation that
            // flaps back before then asks for the shape it ended on.
            guard let self else { return }
            if await running.reshape(landscape: self.streamsLandscape) { return }
            self.stateLock.withLock { self.settingsGeneration &+= 1 }
        }
    }

    /// How many capture restarts have been requested for a changed setting.
    var captureSettingsGenerationForTesting: UInt64 { currentSettingsGeneration }

    /// Whether capture streams landscape frames for the panel's rotation.
    var streamsLandscape: Bool {
        let geometry = sender.geometry
        return stateLock.withLock {
            DisplayCapture.streamsLandscape(geometry: geometry, rotation: _panelRotation)
        }
    }

    private var currentSettingsGeneration: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return settingsGeneration
    }

    /// Test seam for proving provisional sessions cannot send before EINF binds
    /// them to an owned record.
    var senderPausedForTesting: Bool { sender.paused }
    var speakerVolumeForTesting: Double { stateLock.withLock { speakerVolume } }

    func sendDisplaySleep() { sender.sendDisplaySleep() }
    func sendDisplayWake() { sender.sendDisplayWake() }
    func forceKeyframe() { sender.forceKeyframe() }
    func setPaused(_ paused: Bool) {
        sender.setPaused(paused)
        setAudioEnabled(AudioSessionActivationPolicy.isEnabled(
            paused: paused || sender.updateHold, parked: sender.parked))
    }

    /// The link a stream-channel firmware update rides: this session's own
    /// connection to the panel.
    var firmwareUpdateLink: StreamUpdateLink { sender }

    /// Frames and audio stop for an update and come back after it, whatever
    /// the user's own pause says; their pause is left as it was.
    func setFirmwareUpdateHold(_ held: Bool) {
        sender.setUpdateHold(held)
        setAudioEnabled(AudioSessionActivationPolicy.isEnabled(
            paused: held || sender.paused, parked: sender.parked))
    }

    var firmwareUpdateHoldForTesting: Bool { sender.updateHold }
    func applyAudio(tuning: AudioRuntimeTuning) {
        let session = stateLock.withLock {
            audioTuning = tuning.validated
            return audioSession
        }
        sender.radioBudget.update(tuning: tuning)
        session?.update(tuning: tuning)
    }
    /// Kept here as well as on the running audio session, so a session
    /// installed later by `reconcileAudio` starts at the same volume.
    func setSpeakerVolume(_ volume: Double) {
        let session = stateLock.withLock {
            speakerVolume = volume
            return audioSession
        }
        session?.setSpeakerVolume(volume)
    }
    func audioDevicesChanged() {
        currentAudioSession?.devicesChanged()
    }

    private var currentAudioSession: PanelAudioSession? {
        stateLock.withLock { audioSession }
    }

    private func setAudioEnabled(_ enabled: Bool) {
        let session = stateLock.withLock {
            audioEnabled = enabled
            return audioSession
        }
        session?.setEnabled(enabled)
    }

    /// Apply a later browse result without rebuilding video. `.unknown` means
    /// TXT is still absent and must leave an existing adapter untouched.
    func reconcileAudio(_ advertisement: AudioAdvertisement) {
        var oldSession: PanelAudioSession?
        var newSession: PanelAudioSession?
        var shouldStart = false
        var shouldEnable = false
        var volume = PanelSpeakerVolume.default
        var tuning = AudioRuntimeTuning()

        stateLock.lock()
        guard !_stopped else {
            stateLock.unlock()
            return
        }
        switch AudioSessionReconciler.decide(
            current: audioDescriptor,
            advertisement: advertisement)
        {
        case .keep:
            stateLock.unlock()
            return
        case .remove:
            oldSession = audioSession
            audioSession = nil
            audioDescriptor = nil
        case .install(let descriptor):
            oldSession = audioSession
            newSession = audioSessionFactory?(descriptor)
            audioSession = newSession
            audioDescriptor = descriptor
            shouldStart = audioRunStarted
            shouldEnable = audioEnabled
            volume = speakerVolume
            tuning = audioTuning
        }
        stateLock.unlock()

        oldSession?.stop()
        newSession?.update(tuning: tuning)
        newSession?.setSpeakerVolume(volume)
        newSession?.setEnabled(shouldEnable)
        if shouldStart {
            newSession?.start()
        }
    }
    func setBrightness(high: Bool) { sender.setBrightness(high: high) }
    func setBrightnessLevel(_ level: Int) { sender.setBrightnessLevel(level) }
    func setFlip(_ flipped: Bool) {
        sender.setFlip(flipped)
        sender.forceKeyframe()
    }
    /// Like `setFlip`, the keyframe rides along: the panel repaints its cached
    /// frame locally, but a full refresh from here converges even if that
    /// cached frame was stale.
    func setRotation(_ rotation: Int) {
        sender.setRotation(rotation)
        sender.forceKeyframe()
    }
    /// No keyframe here, unlike `setFlip`/`setRotation`: turning the panel
    /// back on should show whatever is already current, not force a resend of
    /// a frame that was never stale in the first place.
    func setPower(_ on: Bool) { sender.setPower(on) }
    func identify(seconds: Int = 8) { sender.identify(seconds: seconds) }

    /// Apply pacing settings. Self-tuning is switched off first so an explicit
    /// value is not immediately overwritten by the next climb step.
    func applyPacing(spacingMicros: UInt32, adaptive: Bool) {
        sender.setAdaptivePacing(adaptive)
        if !adaptive { sender.setSpacingMicros(spacingMicros) }
    }
    /// Apply the tile-stream quality policy. A no-op for band panels.
    func applyTileQuality(_ policy: TileLossyPolicy) {
        sender.setTileLossyPolicy(policy)
    }
    func restartDevice() { sender.restartDevice() }
    func sendIdleText(_ lines: [String]) { sender.sendIdleText(lines) }

    func usePickerFilter(_ filter: SCContentFilter) {
        stateLock.lock()
        pickedFilter = filter
        // Mutually exclusive with a drawn region; see useRegion.
        _regionOverride = nil
        _region = nil
        _appliedRegion = nil
        pickedGeneration &+= 1
        stateLock.unlock()
        forceKeyframe()
    }

    /// Drop a runtime region and fall back to the configured source.
    func clearRegion() {
        clearRegionOverride()
        forceKeyframe()
    }

    /// Replace the stored filter with a freshly resolved equivalent, without
    /// bumping the generation.
    ///
    /// The generation means "the user chose something new", and bumping it here
    /// would make the watchdog treat our own housekeeping as a source change
    /// and restart capture in a loop.
    private func rememberPickerFilter(_ filter: SCContentFilter) {
        stateLock.lock()
        // Only refresh an existing selection. If the user cleared it while we
        // were resolving, do not resurrect it.
        if pickedFilter != nil { pickedFilter = filter }
        stateLock.unlock()
    }

    private func clearPickerFilter() {
        stateLock.lock()
        pickedFilter = nil
        pickedGeneration &+= 1
        stateLock.unlock()
    }

    private var currentPickerSelection: (filter: SCContentFilter, generation: UInt64)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let pickedFilter else { return nil }
        return (pickedFilter, pickedGeneration)
    }

    private var sourceGeneration: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pickedGeneration
    }

    private func trackedDisplayName() -> String {
        switch source {
        case .auto(let d): return d
        case .display(let d): return d
        case .window: return ""
        case .region(let spec): return spec.display
        }
    }

    // MARK: capture region

    /// Move or resize the rectangle being captured, live.
    ///
    /// Called for every step of a marquee drag, so it must not restart the
    /// stream: it reconfigures the running one. Updates are coalesced
    /// newest-wins, the same way frames are, because a drag produces them far
    /// faster than `updateConfiguration` completes and applying every
    /// intermediate rectangle in order would lag behind the pointer.
    func useRegion(_ spec: RegionSpec) {
        var capture: DisplayCapture?
        let switchingSource: Bool = stateLock.withLock {
            let switching = _regionOverride == nil
            _region = spec
            _regionOverride = spec
            if switching {
                // A region and a picker selection are alternative answers to
                // "what should this panel show", so taking one drops the other.
                // The generation bump is what makes the watchdog tear down the
                // old stream and come back through the region branch.
                pickedFilter = nil
                pickedGeneration &+= 1
                return true
            }
            guard !regionUpdateInFlight, let running = activeCapture else { return false }
            regionUpdateInFlight = true
            capture = running
            return false
        }
        // The first region replaces the source outright, so let the run loop
        // restart capture rather than reconfiguring a stream of the wrong kind.
        if switchingSource { return }
        // No capture yet, or one already draining: the value is stored either
        // way and gets picked up by the drain loop or the next capture start.
        guard let capture else { return }
        Task { [weak self] in await self?.drainRegionUpdates(capture) }
    }

    /// The region chosen at runtime, which outranks both the picker and the
    /// configured source.
    private var currentRegionOverride: RegionSpec? {
        stateLock.withLock { _regionOverride }
    }

    private func clearRegionOverride() {
        stateLock.withLock {
            guard _regionOverride != nil else { return }
            _regionOverride = nil
            _region = nil
            _appliedRegion = nil
            pickedGeneration &+= 1
        }
    }

    private func drainRegionUpdates(_ capture: DisplayCapture) async {
        while true {
            let target: RegionSpec? = stateLock.withLock {
                guard let want = _region, want != _appliedRegion else {
                    regionUpdateInFlight = false
                    return nil
                }
                return want
            }
            guard let target else { return }
            let applied = await capture.updateRegion(target.rect)
            let keepGoing = stateLock.withLock { () -> Bool in
                if applied {
                    _appliedRegion = target
                    return true
                }
                // A failed reconfigure means the stream is going away; the
                // watchdog will rebuild it with the stored region.
                regionUpdateInFlight = false
                return false
            }
            if !keepGoing { return }
        }
    }

    /// The region capture should use: the live one if the user has been
    /// dragging, otherwise whatever was stored with the source.
    private func effectiveRegion(_ stored: RegionSpec) -> RegionSpec {
        stateLock.withLock { _region ?? stored }
    }

    /// Record the region a stream was just started with.
    ///
    /// `requested` is the region the start was computed from. If the user
    /// dragged the marquee while the stream was starting, `_region` has moved
    /// on, and overwriting it with the start's value would drop the newest
    /// rectangle; the drain loop is run to catch up to it instead.
    private func noteRegionApplied(_ spec: RegionSpec, requested: RegionSpec) {
        let drain: DisplayCapture? = stateLock.withLock {
            _appliedRegion = spec
            guard let current = _region, current != requested else {
                _region = spec
                return nil
            }
            guard !regionUpdateInFlight, let running = activeCapture else { return nil }
            regionUpdateInFlight = true
            return running
        }
        guard let drain else { return }
        Task { [weak self] in await self?.drainRegionUpdates(drain) }
    }

    /// Runs until the session gives up connecting. Returns false if the
    /// device never became reachable, so the caller can retire it.
    ///
    /// Bounded rather than infinite because mDNS advertises ghosts: a
    /// renamed device leaves its old service name in caches until the TTL
    /// expires, and that name resolves to nothing forever. Retrying it
    /// endlessly is just log noise (observed with a stale "espdisplay"
    /// alongside the live "espdisplay-9050").
    @discardableResult
    func run() async -> Bool {
        // Every way out, retiring included: nothing reuses this sender.
        defer { sender.stop() }
        var attempts = 0
        let maxAttempts = 5
        while !isStopped {
            do {
                try await sender.start()
                break
            } catch {
                if isStopped { return true }
                attempts += 1
                if attempts >= maxAttempts {
                    print("[\(name)] unreachable after \(maxAttempts) attempts - "
                        + "retiring (retried after the cooldown, or when it reappears)")
                    return false
                }
                print("[\(name)] connect failed (\(error.localizedDescription)) - retrying in 5s")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }

        guard !isStopped else { return true }
        let audio = stateLock.withLock {
            audioRunStarted = true
            return audioSession
        }
        audio?.start()

        // The link is watched on its own, for the whole life of the session:
        // capture can sit for as long as it likes waiting for a source, and a
        // board that resets meanwhile must still be reconnected.
        let linkSupervision = Task { [weak self] in await self?.superviseLink() }
        if let override = captureLoopOverrideForTesting {
            await override()
        } else {
            await superviseCapture()
        }
        // Finished before the sender stops, so a reconnect cannot reopen the
        // link after it has been closed for good.
        linkSupervision.cancel()
        await linkSupervision.value
        adopt(nil)
        return true
    }

    /// Reopen the link whenever the panel goes quiet, until the session stops.
    ///
    /// Retries never stop and never give up: a parked session relies on this to
    /// notice the panel coming back, and so does one whose capture has no
    /// source. `LinkSupervisor` paces the attempts.
    private func superviseLink() async {
        var link = LinkSupervisor(timing: linkTiming)
        let tick = UInt64(linkTiming.checkInterval * 1_000_000_000)
        while !isStopped && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: tick)
            guard !isStopped, !Task.isCancelled else { return }
            let age = sender.heartbeatAge
            guard link.shouldReconnect(
                heartbeatAge: age, now: Date().timeIntervalSinceReferenceDate)
            else { continue }
            // A parked session has already said the panel is gone.
            if !sender.parked {
                print(String(format: "[%@] no device heartbeat for %.0fs", name, age ?? 0))
            }
            stateLock.withLock { _reconnectInFlight = true }
            await sender.reconnect()
            stateLock.withLock {
                _reconnectInFlight = false
                _reconnectsFinished &+= 1
            }
        }
    }

    /// Link task progress, read by the watchdog's park decision.
    private var _reconnectInFlight = false
    private var _reconnectsFinished: UInt64 = 0

    /// Whether to park now, and the reconnect count to keep waiting from.
    ///
    /// Silence alone is not enough. A reconnect may be under way on the link
    /// task, and one that succeeds resets the silence - after every Mac wake,
    /// for one. So parking waits until a reconnect that finished after the
    /// silence was judged too long has not helped, which is the order the
    /// watchdog kept when it reconnected inline.
    static func parkDecision(
        silentFor age: TimeInterval?, reconnectInFlight: Bool,
        reconnectsFinished: UInt64, waitingSince: UInt64?
    ) -> (park: Bool, waitingSince: UInt64?) {
        guard shouldPark(silentFor: age) else { return (false, nil) }
        guard let waitingSince else { return (false, reconnectsFinished) }
        return (!reconnectInFlight && reconnectsFinished != waitingSince, waitingSince)
    }

    /// Stands in for `superviseCapture` in tests, which cannot drive
    /// ScreenCaptureKit. Always nil in the app.
    var captureLoopOverrideForTesting: (() async -> Void)?

    /// Start, watch and restart capture until the session stops.
    private func superviseCapture() async {
        let uuidCachePath = "/tmp/espdisplaysender-uuid-\(name)"
        var knownUUID = try? String(
            contentsOfFile: uuidCachePath, encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        var announced = false
        var pickerFailures = 0
        /// Reconnects finished when the silence was first judged long enough
        /// to park; see `parkDecision`.
        var parkWaitingSince: UInt64?
        var parkRequested = false

        while !isStopped {
            // Read before the shape below, so a rotation landing in between
            // restarts capture on the next tick instead of being missed.
            let baselineSettingsGeneration = currentSettingsGeneration
            let capture = DisplayCapture(
                // The sender's geometry, not a constant: the capture has to
                // produce frames of exactly the size the sender will send, and
                // the sender's came from the panel's `res` TXT record.
                geometry: sender.geometry,
                landscape: streamsLandscape,
                onPreview: { [weak self] image, landscape in
                    self?.onPreview?(image, landscape)
                },
                onFrame: { [sender] rgb565, landscape in
                    sender.submit(frame: rgb565, landscape: landscape)
                })
            adopt(capture)
            let baselineSourceGeneration = sourceGeneration
            let fps = self.fps
            var displayShape: (CGDirectDisplayID, Int, Int, Bool)?
            /// The display whose sleep explains silence, when the source is
            /// one display that is not tracked through `displayShape`.
            var pickedDisplayID: CGDirectDisplayID?
            /// The applications an application-only picker selection shows,
            /// so silence while none of them has a window on screen is held.
            var pickedApplicationPIDs: [pid_t] = []
            var tracked: TrackedWindow?

            // ---- Source selection & capture start
            // A manager selection is a runtime override for every configured
            // source type. Clearing a failed picker selection falls back to
            // the original automatic/display/window source.
            let pickerSelection = currentPickerSelection
            // A region drawn at runtime outranks both, and taking one clears the
            // other, so at most one of these is ever set.
            let regionSelection = currentRegionOverride

            if let drawn = regionSelection {
                guard let found = await DisplayCapture.findDisplay(named: drawn.display)
                else {
                    setCaptureStatus(sourceMissing(
                        "Waiting for the display \"\(drawn.display)\", where this "
                            + "region was drawn."))
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                let region = drawn.clamped(to: found.points)
                let display = found.display
                displayShape = (display.displayID, display.width, display.height, false)
                do {
                    try await capture.start(
                        display: display, sourceRect: region.rect, fps: fps)
                    noteRegionApplied(region, requested: drawn)
                    announced = false
                    markStreaming()
                    print("[\(name)] capturing \(region.sizeDescription) at "
                        + "(\(Int(region.x)),\(Int(region.y))) of "
                        + "\"\(drawn.display)\" at \(fps) fps")
                } catch {
                    FileHandle.standardError.write(
                        Data("[\(name)] region capture failed: \(error.localizedDescription)\n".utf8))
                    setCaptureStatus(.failed(
                        "That region could not be captured: "
                            + error.localizedDescription))
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
            } else if let selection = pickerSelection {
                // Re-resolve before starting. An SCContentFilter holds the
                // window and display objects that existed when the user
                // picked them, and a resize or full-screen transition can
                // have macOS replace the window behind them. Starting a
                // stream from those stale references is what left mirroring
                // dead until the menu bar picker handed over a fresh filter.
                let resolution = await DisplayCapture.resolveTarget(of: selection.filter)
                var filter = selection.filter
                pickedDisplayID = selection.filter.includedDisplays.first?.displayID
                if selection.filter.style == .application {
                    pickedApplicationPIDs =
                        selection.filter.includedApplications.map(\.processID)
                }
                switch resolution {
                case .resolved(let target):
                    filter = target.filter
                    rememberPickerFilter(target.filter)
                    if let windowID = target.windowID {
                        tracked = TrackedWindow(
                            id: windowID, owner: target.owner)
                    }
                case .contentGone where DisplayCapture.isUnresponsive:
                    // The lookup timed out, which says nothing about the
                    // selection, so it must not count toward dropping it.
                    setCaptureStatus(.failed(Self.unresponsiveMessage))
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                case .contentGone:
                    // Do not keep restarting against something that is gone.
                    pickerFailures += 1
                    setCaptureStatus(.failed(
                        "The content being mirrored is no longer available. Choose "
                            + "a source again, or switch to Automatic."))
                    if pickerFailures >= 3 {
                        clearPickerFilter()
                        pickerFailures = 0
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                case .notResolvable:
                    break  // e.g. an application filter: use it as-is
                }

                do {
                    try await capture.start(contentFilter: filter, fps: fps)
                    pickerFailures = 0
                    announced = false
                    markStreaming()
                    print("[\(name)] capturing \(picker!.describe(filter)) "
                        + "from picker selection at \(fps) fps")
                } catch {
                    // A picked window that closed would wedge us here; after
                    // a few tries fall back to automatic display tracking.
                    pickerFailures += 1
                    FileHandle.standardError.write(
                        Data("[\(name)] picker source failed: \(error.localizedDescription)\n".utf8))
                    setCaptureStatus(.failed(
                        "The chosen source could not be captured: "
                            + error.localizedDescription))
                    if pickerFailures >= 3 {
                        clearPickerFilter()
                        pickerFailures = 0
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
            } else if case .region(let stored) = source {
                guard let found = await DisplayCapture.findDisplay(named: stored.display)
                else {
                    if !announced {
                        print("[\(name)] waiting for display \"\(stored.display)\" "
                            + "to draw its region on ...")
                        announced = true
                    }
                    setCaptureStatus(sourceMissing(
                        "Waiting for the display \"\(stored.display)\", where this "
                            + "region was drawn."))
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                // Clamped every time: a region outlives the display geometry it
                // was drawn against, and ScreenCaptureKit yields nothing useful
                // for a rectangle that falls outside the display.
                let requested = effectiveRegion(stored)
                let region = requested.clamped(to: found.points)
                let display = found.display
                displayShape = (display.displayID, display.width, display.height, false)
                do {
                    try await capture.start(
                        display: display, sourceRect: region.rect, fps: fps)
                    noteRegionApplied(region, requested: requested)
                    announced = false
                    markStreaming()
                    print("[\(name)] capturing \(region.sizeDescription) at "
                        + "(\(Int(region.x)),\(Int(region.y))) of \"\(stored.display)\" "
                        + "at \(fps) fps")
                } catch {
                    FileHandle.standardError.write(
                        Data("[\(name)] region capture failed: \(error.localizedDescription)\n".utf8))
                    setCaptureStatus(.failed(
                        "That region could not be captured: "
                            + error.localizedDescription))
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
            } else if case .window(let winName) = source {
                guard let window = await DisplayCapture.findWindow(matching: winName) else {
                    if !announced {
                        print("[\(name)] waiting for a window matching \"\(winName)\" ...")
                        announced = true
                    }
                    setCaptureStatus(sourceMissing(
                        "Waiting for a window matching \"\(winName)\"."))
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                let app = window.owningApplication?.applicationName ?? "?"
                tracked = TrackedWindow(id: window.windowID, owner: app)
                do {
                    try await capture.start(window: window, fps: fps)
                    announced = false
                    markStreaming()
                    print("[\(name)] capturing window \(app): \"\(window.title ?? "")\" "
                        + "at \(fps) fps")
                } catch {
                    FileHandle.standardError.write(
                        Data("[\(name)] window capture failed: \(error.localizedDescription)\n".utf8))
                    setCaptureStatus(.failed(
                        "The window \"\(winName)\" could not be captured: "
                            + error.localizedDescription))
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
            } else {
                let displayName = trackedDisplayName()
                guard let resolved = await DisplayCapture.resolve(
                    named: displayName, knownUUID: knownUUID)
                else {
                    if !announced {
                        print("[\(name)] waiting for display \"\(displayName)\" "
                            + "(or a picker selection) ...")
                        announced = true
                    }
                    setCaptureStatus(sourceMissing(
                        displayName.isEmpty
                            ? "No display to mirror yet. Choose a source."
                            : "Waiting for the display \"\(displayName)\"."))
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                if let uuid = resolved.targetUUID, uuid != knownUUID {
                    knownUUID = uuid
                    try? uuid.write(toFile: uuidCachePath, atomically: true, encoding: .utf8)
                }
                let display = resolved.display
                displayShape = (display.displayID, display.width, display.height,
                                resolved.viaMirror)
                do {
                    try await capture.start(display: display, fps: fps)
                    announced = false
                    markStreaming()
                    let dispName = DisplayCapture.name(for: display.displayID) ?? "?"
                    print("[\(name)] capturing \"\(dispName)\" "
                        + "(\(display.width)x\(display.height)) at \(fps) fps"
                        + (resolved.viaMirror ? " [mirror source]" : ""))
                } catch {
                    FileHandle.standardError.write(
                        Data("[\(name)] capture start failed: \(error.localizedDescription)\n".utf8))
                    setCaptureStatus(.failed(
                        "The display could not be captured: "
                            + error.localizedDescription))
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
            }

            stallMonitor.streamStarted(at: Self.monotonicNow())

            // Capture has just (re)started, so publish the new source now.
            // reportProgress throttles itself to one report every five seconds,
            // which left the window describing the previous source for seconds
            // after a pick had already taken effect.
            reportProgress(force: true)

            // ---- Watchdog: poll for death, reconfiguration, silent stalls,
            // source changes, and a blackholed network path.
            watchdog: while !isStopped {
                await waitForWatchdogTick(baselineSource: baselineSourceGeneration)
                reportProgress()

                if sourceGeneration != baselineSourceGeneration {
                    print("[\(name)] source selection changed - switching")
                    break
                }
                if currentSettingsGeneration != baselineSettingsGeneration {
                    print("[\(name)] capture settings changed - restarting capture")
                    break
                }
                if capture.stopped {
                    let reason = capture.stopReason
                    print("[\(name)] capture stream died - restarting"
                        + (reason.map { " (\($0))" } ?? ""))
                    // Say so while the restart is attempted. A restart that
                    // works clears this within a couple of seconds; one that
                    // does not leaves the reason on screen, which is the case
                    // that used to be invisible.
                    setCaptureStatus(.recovering(
                        reason.map { "Mirroring stopped (\($0)). Reconnecting…" }
                            ?? "Mirroring stopped. Reconnecting…"))
                    break
                }
                // A stream can stop delivering without the delegate firing:
                // sleep/wake, a display that slept, or a stream that keeps
                // sending idle or blank status samples with no pixels. Only
                // frames count; see CaptureStallMonitor for why a long silence
                // is probed with a restart rather than trusted.
                // Unknown (the lookup failed) counts as visible: a failing
                // ScreenCaptureKit is a fault to report, not a reason to hold.
                var applicationVisible = true
                if !pickedApplicationPIDs.isEmpty,
                    let owners = await DisplayCapture.onScreenWindowOwnerPIDs()
                {
                    applicationVisible = Self.applicationContentVisible(
                        includedApplicationPIDs: pickedApplicationPIDs,
                        onScreenWindowOwnerPIDs: owners)
                }
                let live = Self.isCaptureLive(
                    paused: sender.paused,
                    displayAsleep: DisplayCapture.isAsleep(displayShape?.0 ?? pickedDisplayID),
                    sessionInactive: DisplayCapture.sessionIsInactive(),
                    windowOnScreen: (tracked?.onScreen ?? true) && applicationVisible)
                let verdict = stallMonitor.check(capture, at: Self.monotonicNow(), live: live)
                let response = Self.stallResponse(to: verdict)
                if case .restart(let failing) = verdict {
                    let sampleAge = Int(Date().timeIntervalSince(capture.lastSampleAt))
                    print("[\(name)] no new frame for "
                        + (failing ? "a restarted stream" : "\(Int(stallMonitor.currentStallAfter))s")
                        + " - restarting capture (last sample \(sampleAge)s ago, "
                        + "status \(capture.lastSampleStatusDescription), "
                        + "\(capture.framesCaptured) frames from this stream)")
                } else if verdict == .recovered {
                    print("[\(name)] capture failure cleared"
                        + (live ? " - frames are arriving again" : " while not live"))
                }
                if let status = response.status { setCaptureStatus(status) }
                if response.restart { break watchdog }
                if let shape = displayShape {
                    let current = await DisplayCapture.resolve(
                        named: trackedDisplayName(), knownUUID: knownUUID)
                    // A timed-out lookup is not a display change; restarting a
                    // working stream into an unresponsive ScreenCaptureKit
                    // would only lose it.
                    if current == nil, DisplayCapture.isUnresponsive {
                        // Fall through to the remaining checks.
                    } else if current == nil
                        || (current!.display.displayID, current!.display.width,
                            current!.display.height, current!.viaMirror) != shape
                    {
                        print("[\(name)] display configuration changed - restarting capture")
                        break
                    }
                }
                if var window = tracked {
                    let healthy = await followWindow(
                        &window, capture: capture, isPicked: pickerSelection != nil)
                    tracked = window
                    if !healthy { break }
                } else if let displayID = Self.pickedDisplayToFollow(
                    pickerSelected: pickerSelection != nil, windowTracked: tracked != nil,
                    displayID: pickedDisplayID)
                {
                    await Self.followPickedDisplay(capture, displayID: displayID) {
                        Self.displayPointSize($0)
                    }
                }
                // Reconnecting (`superviseLink`) has not helped for long enough
                // that the device is gone rather than flapping. Stop capturing.
                let (inFlight, finished) = stateLock.withLock {
                    (_reconnectInFlight, _reconnectsFinished)
                }
                let decision = Self.parkDecision(
                    silentFor: sender.heartbeatAge, reconnectInFlight: inFlight,
                    reconnectsFinished: finished, waitingSince: parkWaitingSince)
                parkWaitingSince = decision.waitingSince
                if decision.park {
                    parkRequested = true
                    break
                }
            }
            await capture.stop()
            if isStopped { break }
            if parkRequested {
                parkRequested = false
                await waitForDeviceToReturn()
                announced = false
                parkWaitingSince = nil
            }
        }
    }

    /// Keep a running stream pointed at the window it is following, absorbing
    /// resizes in place.
    ///
    /// This is the fix for mirroring breaking whenever a window was resized.
    /// Three things used to go wrong here, all of them ending in a stream
    /// rebuild that a picker-selected source does not survive:
    ///
    ///  - the window was re-found *by name*, and `findWindow(matching:)`
    ///    returns the largest match, so resizing one window of an app with
    ///    several handed the session to a sibling window;
    ///  - an aspect flip forced a full restart, because output geometry was
    ///    fixed when the stream was created;
    ///  - a window that macOS destroyed and recreated (which some resize and
    ///    full-screen transitions do) counted as "closed", even though its
    ///    replacement was right there.
    ///
    /// Now the window is re-found by ID, an aspect flip leaves the frame shape
    /// alone (it follows the panel's rotation), and a recreated window is
    /// retargeted rather than chased with a rebuild.
    ///
    /// - Returns: false when the stream genuinely has to be rebuilt.
    private func followWindow(
        _ tracked: inout TrackedWindow, capture: DisplayCapture, isPicked: Bool
    ) async -> Bool {
        var window = await DisplayCapture.findWindow(id: tracked.id)

        // A lookup that timed out says nothing about the window; keep the
        // stream it is already running.
        if window == nil && DisplayCapture.isUnresponsive { return true }

        if window == nil {
            // The ID is gone. Before giving up, look for a replacement from
            // the same application: that is the recreated-window case.
            guard let owner = tracked.owner,
                let replacement = await DisplayCapture.findWindow(matching: owner)
            else {
                print("[\(name)] tracked window closed - restarting capture")
                setCaptureStatus(.recovering(
                    "The window being mirrored has closed. Looking for a source…"))
                return false
            }
            let fresh = SCContentFilter(desktopIndependentWindow: replacement)
            guard await capture.retarget(to: fresh) else {
                print("[\(name)] window was recreated - restarting capture")
                return false
            }
            if isPicked { rememberPickerFilter(fresh) }
            tracked.id = replacement.windowID
            window = replacement
            sender.forceKeyframe()
            print("[\(name)] window was recreated - retargeted in place")
        }

        guard let window else { return false }
        tracked.onScreen = window.isOnScreen
        // A resize that flips the window between portrait and landscape keeps
        // the frame shape, which follows the panel's rotation, not the window.
        // The window's new shape is only re-centred inside it.
        await capture.updateContentSize(window.frame.size)
        markStreaming()
        return true
    }

    /// The display a picker selection is followed by: a picked display or
    /// application share, both shown at their display's size. A picked window
    /// is followed by the window itself (`followWindow`), and without a
    /// selection the display source restarts on a change instead.
    static func pickedDisplayToFollow(
        pickerSelected: Bool, windowTracked: Bool, displayID: CGDirectDisplayID?
    ) -> CGDirectDisplayID? {
        guard pickerSelected, !windowTracked else { return nil }
        return displayID
    }

    /// A display's current size in points, or nil when it is not attached.
    /// Asked of Core Graphics rather than ScreenCaptureKit: it answers at once,
    /// so a watchdog tick never waits on a shareable-content fetch for it.
    static func displayPointSize(_ id: CGDirectDisplayID) -> CGSize? {
        let bounds = CGDisplayBounds(id)
        return bounds.isEmpty ? nil : bounds.size
    }

    /// Re-centre a picked display or application share after its display
    /// changes resolution, in place.
    ///
    /// Both are shown at their display's size, and a picked stream is never
    /// restarted for a display change the way a Screen source is, because a
    /// stream started from a picker selection cannot reliably be recreated
    /// from it. A lookup that fails leaves the stream as it is.
    static func followPickedDisplay(
        _ capture: DisplayCapture, displayID: CGDirectDisplayID,
        displaySize: (CGDirectDisplayID) async -> CGSize?
    ) async {
        guard let size = await displaySize(displayID) else { return }
        await capture.updateContentSize(size)
    }

    /// Hold capture and sending down until the device answers again.
    ///
    /// Waits on a reply counter rather than `heartbeatAge`, because a reconnect
    /// refreshes the heartbeat grace period: using the age here would unpark on
    /// every retry and thrash capture up and down against a dead panel. The
    /// reconnects themselves come from `superviseLink`, which keeps running.
    private func waitForDeviceToReturn() async {
        let repliesBeforeParking = sender.deviceRepliesReceived
        sender.setParked(true)
        setAudioEnabled(false)
        print("[\(name)] no reply for \(Int(Self.parkAfterSilence))s - capture stopped, "
            + "waiting for the display to come back")
        reportProgress(force: true)

        setCaptureStatus(.suspended(
            "The panel stopped answering, so mirroring is paused. It resumes by "
                + "itself as soon as the panel is back."))

        while !isStopped && !Self.hasDeviceReturned(
            repliesNow: sender.deviceRepliesReceived,
            repliesWhenParked: repliesBeforeParking)
        {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        sender.setParked(false)
        setAudioEnabled(AudioSessionActivationPolicy.isEnabled(
            paused: sender.paused || sender.updateHold, parked: false))
        guard !isStopped else { return }
        setCaptureStatus(.waiting("The panel answered again. Restarting mirroring…"))
        print("[\(name)] display answered again - resuming capture")
    }

    /// How long the watchdog waits between checks, and how finely it slices
    /// that wait while watching for a source change.
    private static let watchdogInterval: TimeInterval = 2
    private static let sourcePollInterval: TimeInterval = 0.2

    /// Wait out one watchdog interval, returning early the moment the user
    /// picks a different source.
    ///
    /// A flat two-second sleep made picking a source feel broken: the switch
    /// could not even begin until the current tick elapsed, so a pick appeared
    /// to do nothing and invited a second and third attempt. Every other
    /// condition the watchdog checks tolerates a coarse poll; this one is the
    /// only one a human is sitting and waiting on.
    private func waitForWatchdogTick(baselineSource: UInt64) async {
        let slices = max(1, Int((Self.watchdogInterval / Self.sourcePollInterval).rounded()))
        let slice = UInt64(Self.sourcePollInterval * 1_000_000_000)
        for _ in 0..<slices {
            guard !isStopped else { return }
            try? await Task.sleep(nanoseconds: slice)
            if isStopped || sourceGeneration != baselineSource { return }
        }
    }

    private func reportProgress(force: Bool = false) {
        let now = Date()
        let dt = now.timeIntervalSince(lastReport)
        guard force || dt >= 5 else { return }
        let parked = sender.parked
        let count = sender.framesSent
        // A parked session is sending nothing, so report zero rather than a
        // rate divided by however short the forced interval happened to be.
        let fps = parked || dt <= 0 ? 0 : Double(count - lastCount) / dt
        let stats = sender.deviceStats
        let hb = sender.heartbeatAge.map { String(format: "%.0fs ago", $0) } ?? "never"
        let diffPct = sender.bandsConsidered > 0
            ? Double(sender.bandsSent) * 100 / Double(sender.bandsConsidered) : 0
        let sourceDescription: String
        if let drawn = currentRegionOverride {
            sourceDescription = "\(drawn.sizeDescription) region of \(drawn.display)"
        } else if let selection = currentPickerSelection, let picker {
            sourceDescription = picker.describe(selection.filter)
        } else {
            switch source {
            case .auto(let display):
                sourceDescription = display.isEmpty ? "Automatic" : "Automatic: \(display)"
            case .display(let display): sourceDescription = "Display: \(display)"
            case .window(let window): sourceDescription = "Window: \(window)"
            case .region(let stored):
                let region = effectiveRegion(stored)
                sourceDescription = "\(region.sizeDescription) region of "
                    + "\(region.display)"
            }
        }
        // The user's own pause outranks whatever capture is doing: it explains
        // the absent frames completely, and reporting a stream state underneath
        // it would read as a fault.
        let (status, frameAt) = stateLock.withLock {
            () -> (CaptureStatus, Date?) in
            if let latest = activeCapture?.lastFrameAt,
                latest > (_lastFrameAt ?? .distantPast)
            {
                _lastFrameAt = latest
            }
            return (_captureStatus, _lastFrameAt)
        }
        // The user's own pause outranks whatever capture is doing: it explains
        // the absent frames completely, and reporting a stream state underneath
        // it would read as a fault.
        let reported = sender.paused
            ? CaptureStatus.suspended("Paused. Frames are not being sent.")
            : status
        onStatus?(Status(
            serviceName: name,
            displayFPS: fps,
            framesSent: count,
            sendErrors: sender.sendErrors,
            diffPercent: diffPct,
            heartbeatAge: sender.heartbeatAge,
            stats: stats,
            info: sender.deviceInfo,
            resolvedAddress: sender.resolvedAddress,
            spacingMicros: sender.spacingMicros,
            paused: sender.paused,
            parked: parked,
            sourceDescription: sourceDescription,
            landscape: sender.currentLandscape,
            captureStatus: reported,
            lastFrameAt: frameAt,
            updatedAt: now,
            replyAge: sender.replyAge))
        // A parked session has nothing to report every five seconds; the park
        // and resume lines say all there is to say.
        guard !parked else {
            lastReport = now
            lastCount = count
            return
        }
        print(String(
            format: "[%@] %.1f fps (%llu total, %llu send errors, diff %.0f%%) | device: "
                + "shown=%u dropped=%u heap=%u hb=%@ pacing=%uus",
            name, fps, count, sender.sendErrors, diffPct,
            stats.shown, stats.dropped, stats.heap, hb, sender.spacingMicros))
        lastReport = now
        lastCount = count
    }
}

/// Thread-safe collection of live sessions; the browser adds from its own
/// queue while workspace sleep notifications iterate from the main queue.
final class SessionRegistry: @unchecked Sendable {
    /// How long a retired (unreachable) device is skipped before we try it
    /// again. Long enough that an mDNS ghost's TTL expires in the meantime,
    /// short enough that a device which was merely rebooting comes back.
    static let standardRetryCooldown: TimeInterval = 120

    private let retryCooldown: TimeInterval
    private let lock = NSLock()
    private var sessions: [String: DeviceSession] = [:]
    private var retiredAt: [String: Date] = [:]
    private var _onRetryDue: ((String) -> Void)?

    init(retryCooldown: TimeInterval = SessionRegistry.standardRetryCooldown) {
        self.retryCooldown = retryCooldown
    }

    /// Called, off the main thread, when a retired name's cooldown has run out.
    var onRetryDue: ((String) -> Void)? {
        get { lock.withLock { _onRetryDue } }
        set { lock.withLock { _onRetryDue = newValue } }
    }

    func add(_ session: DeviceSession) {
        lock.lock()
        sessions[session.name] = session
        retiredAt[session.name] = nil
        lock.unlock()
    }

    /// True if a session for this name is live, or it failed so recently
    /// that relaunching would just spin.
    func shouldSkip(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let session = sessions[name] {
            if session.isStopped {
                sessions[name] = nil
            } else {
                return true
            }
        }
        if let failed = retiredAt[name],
            Date().timeIntervalSince(failed) < retryCooldown
        {
            return true
        }
        return false
    }

    func retire(_ name: String, sessionID: UUID? = nil) {
        lock.lock()
        if let sessionID, sessions[name]?.id != sessionID {
            lock.unlock()
            return
        }
        sessions[name] = nil
        let stamp = Date()
        retiredAt[name] = stamp
        lock.unlock()
        scheduleRetry(name, retiredAt: stamp)
    }

    /// Offer a retired name again once its cooldown is over.
    ///
    /// Discovery reports changes only. A name retired while its service stayed
    /// listed, which is what a board that is reset and reflashed in place looks
    /// like, would otherwise wait for a change that never comes.
    private func scheduleRetry(_ name: String, retiredAt stamp: Date) {
        DispatchQueue.global().asyncAfter(deadline: .now() + retryCooldown) { [weak self] in
            guard let self else { return }
            let callback: ((String) -> Void)? = self.lock.withLock {
                // Relaunched in the meantime, or retired again with a cooldown
                // of its own.
                guard self.retiredAt[name] == stamp, self.sessions[name] == nil
                else { return nil }
                self.retiredAt[name] = nil
                return self._onRetryDue
            }
            callback?(name)
        }
    }

    func reconcileAudio(
        _ name: String,
        advertisement: AudioAdvertisement
    ) {
        let session = lock.withLock { sessions[name] }
        session?.reconcileAudio(advertisement)
    }

    var all: [DeviceSession] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sessions.values)
    }
}

/// Browse until the first device appears, or time out.
func discoverFirstDevice(timeoutSeconds: Double) async -> DeviceBrowser.Device? {
    await withCheckedContinuation { cont in
        let lock = NSLock()
        var resumed = false
        var browser: DeviceBrowser?
        func finish(_ device: DeviceBrowser.Device?) {
            lock.lock()
            let first = !resumed
            resumed = true
            lock.unlock()
            guard first else { return }
            browser?.stop()
            cont.resume(returning: device)
        }
        browser = DeviceBrowser { devices in
            if let firstDevice = devices.first {
                finish(firstDevice)
            }
        }
        browser?.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
            finish(nil)
        }
    }
}
