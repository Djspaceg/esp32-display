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
        let sourceDescription: String
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
    }

    let name: String
    private let sender: FrameSender
    private let source: Source
    private let picker: PickerSource?
    private let fps: Int
    private let onStatus: ((Status) -> Void)?
    private let stateLock = NSLock()
    private var pickedFilter: SCContentFilter?
    private var pickedGeneration: UInt64 = 0

    private var lastReport = Date()
    private var lastCount: UInt64 = 0

    init(name: String, sender: FrameSender, source: Source, picker: PickerSource?, fps: Int,
         onStatus: ((Status) -> Void)? = nil) {
        self.name = name
        self.sender = sender
        self.source = source
        self.picker = picker
        self.fps = fps
        self.onStatus = onStatus
    }

    func sendDisplaySleep() { sender.sendDisplaySleep() }
    func sendDisplayWake() { sender.sendDisplayWake() }
    func forceKeyframe() { sender.forceKeyframe() }
    func setPaused(_ paused: Bool) { sender.setPaused(paused) }
    func setBrightness(high: Bool) { sender.setBrightness(high: high) }
    func setFlip(_ flipped: Bool) {
        sender.setFlip(flipped)
        sender.forceKeyframe()
    }
    func identify() { sender.identify() }
    func restartDevice() { sender.restartDevice() }

    func usePickerFilter(_ filter: SCContentFilter) {
        stateLock.lock()
        pickedFilter = filter
        pickedGeneration &+= 1
        stateLock.unlock()
        forceKeyframe()
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

        while true {
            let capture = DisplayCapture { [sender] rgb565, landscape in
                sender.submit(frame: rgb565, landscape: landscape)
            }
            let baselineSourceGeneration = sourceGeneration
            var displayShape: (CGDirectDisplayID, Int, Int, Bool)?
            var trackedWindowID: UInt32?
            var trackedWindowLandscape = false

            // ---- Source selection & capture start
            // A manager selection is a runtime override for every configured
            // source type. Clearing a failed picker selection falls back to
            // the original automatic/display/window source.
            let pickerSelection = currentPickerSelection

            if let selection = pickerSelection {
                do {
                    try await capture.start(contentFilter: selection.filter, fps: fps)
                    pickerFailures = 0
                    announced = false
                    print("[\(name)] capturing \(picker!.describe(selection.filter)) "
                        + "from picker selection at \(fps) fps")
                } catch {
                    // A picked window that closed would wedge us here; after
                    // a few tries fall back to automatic display tracking.
                    pickerFailures += 1
                    FileHandle.standardError.write(
                        Data("[\(name)] picker source failed: \(error.localizedDescription)\n".utf8))
                    if pickerFailures >= 3 {
                        clearPickerFilter()
                        pickerFailures = 0
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
            } else if case .window(let winName) = source {
                guard let window = await DisplayCapture.findWindow(matching: winName) else {
                    if !announced {
                        print("[\(name)] waiting for a window matching \"\(winName)\" ...")
                        announced = true
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                trackedWindowID = window.windowID
                trackedWindowLandscape = window.frame.width > window.frame.height
                let app = window.owningApplication?.applicationName ?? "?"
                do {
                    try await capture.start(window: window, fps: fps)
                    announced = false
                    print("[\(name)] capturing window \(app): \"\(window.title ?? "")\" "
                        + "at \(fps) fps")
                } catch {
                    FileHandle.standardError.write(
                        Data("[\(name)] window capture failed: \(error.localizedDescription)\n".utf8))
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
                    let dispName = DisplayCapture.name(for: display.displayID) ?? "?"
                    print("[\(name)] capturing \"\(dispName)\" "
                        + "(\(display.width)x\(display.height)) at \(fps) fps"
                        + (resolved.viaMirror ? " [mirror source]" : ""))
                } catch {
                    FileHandle.standardError.write(
                        Data("[\(name)] capture start failed: \(error.localizedDescription)\n".utf8))
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
            }

            // ---- Watchdog: poll for death, reconfiguration, silent stalls,
            // source changes, and a blackholed network path.
            while true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                reportProgress()

                if sourceGeneration != baselineSourceGeneration {
                    print("[\(name)] source selection changed - switching")
                    break
                }
                if capture.stopped {
                    print("[\(name)] capture stream died - restarting")
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
                if let wid = trackedWindowID, case .window(let winName) = source {
                    let current = await DisplayCapture.findWindow(matching: winName)
                    if current == nil || current!.windowID != wid {
                        print("[\(name)] window changed or closed - restarting capture")
                        break
                    }
                    if (current!.frame.width > current!.frame.height) != trackedWindowLandscape {
                        print("[\(name)] window aspect flipped - restarting capture")
                        break
                    }
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
            }
            await capture.stop()
        }
    }

    private func reportProgress() {
        let now = Date()
        let dt = now.timeIntervalSince(lastReport)
        guard dt >= 5 else { return }
        let count = sender.framesSent
        let fps = Double(count - lastCount) / dt
        let stats = sender.deviceStats
        let hb = sender.heartbeatAge.map { String(format: "%.0fs ago", $0) } ?? "never"
        let diffPct = sender.bandsConsidered > 0
            ? Double(sender.bandsSent) * 100 / Double(sender.bandsConsidered) : 0
        let sourceDescription: String
        if let selection = currentPickerSelection, let picker {
            sourceDescription = picker.describe(selection.filter)
        } else {
            switch source {
            case .auto(let display):
                sourceDescription = display.isEmpty ? "Automatic" : "Automatic: \(display)"
            case .display(let display): sourceDescription = "Display: \(display)"
            case .window(let window): sourceDescription = "Window: \(window)"
            }
        }
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
            sourceDescription: sourceDescription,
            updatedAt: now))
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
