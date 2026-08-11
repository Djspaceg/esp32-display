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
        var landscape: Bool
        /// The application that owns it, used to find the replacement when a
        /// resize or full-screen transition destroys and recreates the window.
        var owner: String?
    }

    let name: String
    private let sender: FrameSender
    private let source: Source
    private let picker: PickerSource?
    private let onStatus: ((Status) -> Void)?
    private let onPreview: ((CGImage, Bool) -> Void)?
    private let stateLock = NSLock()
    private var pickedFilter: SCContentFilter?
    private var pickedGeneration: UInt64 = 0
    private var _captureStatus: CaptureStatus = .waiting("Starting up…")
    private var _previewEnabled = false
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

    /// How often a parked session re-resolves the device while waiting.
    private static let parkedRetryInterval: TimeInterval = 15

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

    init(name: String, sender: FrameSender, source: Source, picker: PickerSource?, fps: Int,
         onStatus: ((Status) -> Void)? = nil,
         onPreview: ((CGImage, Bool) -> Void)? = nil) {
        self.name = name
        self.sender = sender
        self.source = source
        self.picker = picker
        self._fps = fps
        self.onStatus = onStatus
        self.onPreview = onPreview
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

    private var currentSettingsGeneration: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return settingsGeneration
    }

    func sendDisplaySleep() { sender.sendDisplaySleep() }
    func sendDisplayWake() { sender.sendDisplayWake() }
    func forceKeyframe() { sender.forceKeyframe() }
    func setPaused(_ paused: Bool) { sender.setPaused(paused) }
    func setBrightness(high: Bool) { sender.setBrightness(high: high) }
    func setBrightnessLevel(_ level: Int) { sender.setBrightnessLevel(level) }
    func setFlip(_ flipped: Bool) {
        sender.setFlip(flipped)
        sender.forceKeyframe()
    }
    func identify(seconds: Int = 8) { sender.identify(seconds: seconds) }

    /// Apply pacing settings. Self-tuning is switched off first so an explicit
    /// value is not immediately overwritten by the next climb step.
    func applyPacing(spacingMicros: UInt32, adaptive: Bool) {
        sender.setAdaptivePacing(adaptive)
        if !adaptive { sender.setSpacingMicros(spacingMicros) }
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

    private func noteRegionApplied(_ spec: RegionSpec) {
        stateLock.withLock {
            _region = spec
            _appliedRegion = spec
        }
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
        var attempts = 0
        let maxAttempts = 5
        while true {
            do {
                try await sender.start()
                break
            } catch {
                attempts += 1
                if attempts >= maxAttempts {
                    print("[\(name)] unreachable after \(maxAttempts) attempts - "
                        + "retiring (will retry if it reappears)")
                    return false
                }
                print("[\(name)] connect failed (\(error.localizedDescription)) - retrying in 5s")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }

        let uuidCachePath = "/tmp/espdisplaysender-uuid-\(name)"
        var knownUUID = try? String(
            contentsOfFile: uuidCachePath, encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        var announced = false
        var lastReconnectAt = Date.distantPast
        var pickerFailures = 0
        var parkRequested = false

        while true {
            let capture = DisplayCapture(
                // The sender's geometry, not a constant: the capture has to
                // produce frames of exactly the size the sender will send, and
                // the sender's came from the panel's `res` TXT record.
                geometry: sender.geometry,
                onPreview: { [weak self] image, landscape in
                    self?.onPreview?(image, landscape)
                },
                onFrame: { [sender] rgb565, landscape in
                    sender.submit(frame: rgb565, landscape: landscape)
                })
            adopt(capture)
            let baselineSourceGeneration = sourceGeneration
            let baselineSettingsGeneration = currentSettingsGeneration
            let fps = self.fps
            var displayShape: (CGDirectDisplayID, Int, Int, Bool)?
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
                    setCaptureStatus(.waiting(
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
                    noteRegionApplied(region)
                    announced = false
                    setCaptureStatus(.streaming)
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
                switch resolution {
                case .resolved(let target):
                    filter = target.filter
                    rememberPickerFilter(target.filter)
                    if let windowID = target.windowID {
                        tracked = TrackedWindow(
                            id: windowID,
                            landscape: target.size.width > target.size.height,
                            owner: target.owner)
                    }
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
                    setCaptureStatus(.streaming)
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
                    setCaptureStatus(.waiting(
                        "Waiting for the display \"\(stored.display)\", where this "
                            + "region was drawn."))
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                // Clamped every time: a region outlives the display geometry it
                // was drawn against, and ScreenCaptureKit yields nothing useful
                // for a rectangle that falls outside the display.
                let region = effectiveRegion(stored).clamped(to: found.points)
                let display = found.display
                displayShape = (display.displayID, display.width, display.height, false)
                do {
                    try await capture.start(
                        display: display, sourceRect: region.rect, fps: fps)
                    noteRegionApplied(region)
                    announced = false
                    setCaptureStatus(.streaming)
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
                    setCaptureStatus(.waiting(
                        "Waiting for a window matching \"\(winName)\"."))
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                let app = window.owningApplication?.applicationName ?? "?"
                tracked = TrackedWindow(
                    id: window.windowID,
                    landscape: window.frame.width > window.frame.height,
                    owner: app)
                do {
                    try await capture.start(window: window, fps: fps)
                    announced = false
                    setCaptureStatus(.streaming)
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
                    setCaptureStatus(.waiting(
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
                    setCaptureStatus(.streaming)
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

            // Capture has just (re)started, so publish the new source now.
            // reportProgress throttles itself to one report every five seconds,
            // which left the window describing the previous source for seconds
            // after a pick had already taken effect.
            reportProgress(force: true)

            // ---- Watchdog: poll for death, reconfiguration, silent stalls,
            // source changes, and a blackholed network path.
            while true {
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
                // Sleep/wake can kill the stream without firing the
                // delegate, so silence is our only signal for that. It is a
                // coarse one: ScreenCaptureKit delivers nothing at all for a
                // truly static screen (measured - a 30s threshold restarted
                // capture every 30s on an idle display), so the timeout is
                // long enough to avoid churning on idle content. A restart
                // is harmless either way, just noisy.
                if Date().timeIntervalSince(capture.lastSampleAt) > 120 {
                    print("[\(name)] no capture samples for 120s - restarting capture")
                    setCaptureStatus(.recovering(
                        "No frames from the source for two minutes. Reconnecting…"))
                    break
                }
                if let shape = displayShape {
                    let current = await DisplayCapture.resolve(
                        named: trackedDisplayName(), knownUUID: knownUUID)
                    if current == nil
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
                }
                // Device heartbeats stop when it rebooted onto a new address
                // or dropped off WiFi; reconnecting re-resolves the service.
                if let age = sender.heartbeatAge, age > 10,
                    Date().timeIntervalSince(lastReconnectAt) > 15
                {
                    print(String(format: "[%@] no device heartbeat for %.0fs", name, age))
                    lastReconnectAt = Date()
                    await sender.reconnect()
                }
                // Reconnecting has not helped for long enough that the device
                // is gone rather than flapping. Stop capturing for it.
                if Self.shouldPark(silentFor: sender.heartbeatAge) {
                    parkRequested = true
                    break
                }
            }
            await capture.stop()
            if parkRequested {
                parkRequested = false
                await waitForDeviceToReturn()
                announced = false
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
    /// Now the window is re-found by ID, orientation changes are applied to the
    /// live stream, and a recreated window is retargeted rather than chased
    /// with a rebuild.
    ///
    /// - Returns: false when the stream genuinely has to be rebuilt.
    private func followWindow(
        _ tracked: inout TrackedWindow, capture: DisplayCapture, isPicked: Bool
    ) async -> Bool {
        var window = await DisplayCapture.findWindow(id: tracked.id)

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

        let nowLandscape = window.frame.width > window.frame.height
        if nowLandscape != tracked.landscape {
            guard await capture.reorient(landscape: nowLandscape) else {
                print("[\(name)] window aspect flipped - restarting capture")
                return false
            }
            tracked.landscape = nowLandscape
            // The panel's buffer still holds the previous orientation, and the
            // band diff would otherwise skip everything that happens to match.
            sender.forceKeyframe()
            print("[\(name)] window resized to "
                + "\(Int(window.frame.width))x\(Int(window.frame.height)) - "
                + "re-oriented in place")
        }
        setCaptureStatus(.streaming)
        return true
    }

    /// Hold capture and sending down until the device answers again.
    ///
    /// Waits on a reply counter rather than `heartbeatAge`, because a reconnect
    /// refreshes the heartbeat grace period: using the age here would unpark on
    /// every retry and thrash capture up and down against a dead panel.
    private func waitForDeviceToReturn() async {
        let repliesBeforeParking = sender.deviceRepliesReceived
        sender.setParked(true)
        print("[\(name)] no reply for \(Int(Self.parkAfterSilence))s - capture stopped, "
            + "waiting for the display to come back")
        reportProgress(force: true)

        setCaptureStatus(.suspended(
            "The panel stopped answering, so mirroring is paused. It resumes by "
                + "itself as soon as the panel is back."))

        var lastAttemptAt = Date()
        while !Self.hasDeviceReturned(
            repliesNow: sender.deviceRepliesReceived,
            repliesWhenParked: repliesBeforeParking)
        {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Date().timeIntervalSince(lastAttemptAt) > Self.parkedRetryInterval {
                lastAttemptAt = Date()
                await sender.reconnect()
            }
        }

        sender.setParked(false)
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
            try? await Task.sleep(nanoseconds: slice)
            if sourceGeneration != baselineSource { return }
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
            updatedAt: now))
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
    private static let retryCooldown: TimeInterval = 120

    private let lock = NSLock()
    private var sessions: [String: DeviceSession] = [:]
    private var retiredAt: [String: Date] = [:]

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
        if sessions[name] != nil { return true }
        if let failed = retiredAt[name],
            Date().timeIntervalSince(failed) < Self.retryCooldown
        {
            return true
        }
        return false
    }

    func retire(_ name: String) {
        lock.lock()
        sessions[name] = nil
        retiredAt[name] = Date()
        lock.unlock()
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
