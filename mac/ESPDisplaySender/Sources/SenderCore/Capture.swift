import AppKit
import CoreMedia
import Foundation
import os
import ScreenCaptureKit
import SenderProtocol

/// ScreenCaptureKit capture of one display, scaled by SCK to the panel's own
/// pixel size in BGRA, converted to RGB565BE and handed to a callback.
final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "espdisp.capture")
    /// The panel this capture is feeding. Every output size below comes from it.
    ///
    /// Has to match the geometry of the `FrameSender` the frames go to:
    /// `send(frame:)` preconditions on `geometry.frameBytes`, so a capture
    /// scaled to a different panel's size would not send a squashed picture, it
    /// would trap. `DeviceSession` passes its sender's geometry for that reason,
    /// and the default here is the same 172x320 default the sender has, so the
    /// two cannot drift apart by omission.
    private let geometry: PanelGeometry
    private var rgbBuffer: [UInt8]
    private let onFrame: ([UInt8], Bool) -> Void
    private let onPreview: ((CGImage, Bool) -> Void)?

    /// Guards every field the capture queue and the supervisor both touch.
    private let stateLock = NSLock()
    /// The frame shape. It follows the panel's rotation (`streamsLandscape`),
    /// never the source, and a rotation that changes it reshapes the running
    /// stream in place (`reshape`) so a picker share survives it.
    private var _landscape: Bool
    private var _outW: Int
    private var _outH: Int
    /// Reconfigurations asked for but not yet handed to the stream. Region
    /// drags and reshapes share one queue, applied newest-wins by one drain at a
    /// time, so a slow region update can never land after a reshape and put the
    /// old frame shape back.
    private var _pendingRect: CGRect?
    private var _pendingLandscape: Bool?
    private var _pendingContentSize: CGSize?
    private var _reconfiguring = false
    private var _framesCaptured: UInt64 = 0
    private var _stopped = false
    private var _stopReason: String?
    private var _lastSampleAt = Date()
    private var _lastFrameAt: Date?
    /// Status of the last sample, for the log line when a stall is detected.
    private var _lastSampleStatus: SCFrameStatus?
    /// The stream whose samples are accepted. Cleared before stopping and when
    /// a start times out, so a stream that starts late or will not stop cannot
    /// keep feeding frames into a session that has moved on.
    private var _acceptedStream: ObjectIdentifier?
    private var _previewEnabled = false
    private var _configuredFPS = 30
    /// The sub-rectangle being captured, or nil for the whole source.
    private var _sourceRect: CGRect?
    /// The captured content's size, whose shape decides where it is centred
    /// in the frame (`letterbox`). Nil when it is not known.
    private var _contentSize: CGSize?

    /// Preview cadence. Frames go to the panel as fast as they arrive; the UI
    /// only needs enough to look live, and each preview image costs a
    /// 172x320 RGBA expansion plus a SwiftUI redraw.
    private static let previewInterval: TimeInterval = 0.1
    /// Touched only on the capture queue.
    private var lastPreviewAt = Date.distantPast

    var framesCaptured: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _framesCaptured
    }

    /// Set when the stream dies (display unplugged, reconfigured, the user
    /// stopping the share from the menu bar, etc.).
    var stopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _stopped
    }

    /// Why the stream stopped, for the UI. Previously the delegate's error
    /// went to stderr and only a bare flag survived, so a stream that died
    /// and could not be restarted looked identical to an idle one.
    var stopReason: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _stopReason
    }

    /// Last time ANY sample arrived (including idle/incomplete status
    /// frames). Not a liveness signal: status-only samples keep it fresh on a
    /// stream delivering no pixels, and a static screen may send nothing at
    /// all. The stall log reports it to tell those two apart.
    var lastSampleAt: Date {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _lastSampleAt
    }

    /// Last time a *usable* frame was converted and sent on, as opposed to any
    /// sample arriving. This is the honest answer to "is the panel still being
    /// fed", which `lastSampleAt` is not: SCK keeps emitting idle samples from
    /// a stream that is delivering no pixels.
    var lastFrameAt: Date? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _lastFrameAt
    }

    /// The last sample's frame status, e.g. "idle" or "blank", or "none".
    var lastSampleStatusDescription: String {
        stateLock.withLock {
            guard let status = _lastSampleStatus else { return "none" }
            switch status {
            case .complete: return "complete"
            case .idle: return "idle"
            case .blank: return "blank"
            case .suspended: return "suspended"
            case .started: return "started"
            case .stopped: return "stopped"
            @unknown default: return "status \(status.rawValue)"
            }
        }
    }

    var landscape: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _landscape
    }

    /// Turn preview conversion on or off. Off by default so panels nobody is
    /// looking at pay nothing.
    func setPreviewEnabled(_ enabled: Bool) {
        stateLock.lock()
        _previewEnabled = enabled
        stateLock.unlock()
    }

    /// - Parameters:
    ///   - onPreview: called on the capture queue, at most every 100ms, with
    ///     an image of the frame just sent. Only while preview is enabled.
    ///   - geometry: the panel's native pixel size. Must be the geometry of the
    ///     sender these frames are handed to.
    ///   - landscape: whether to stream landscape frames, from
    ///     `streamsLandscape(geometry:rotation:)`. A rotation that changes it
    ///     later goes through `reshape(landscape:)`.
    ///   - onFrame: called on the capture queue with each converted
    ///     RGB565BE frame and whether it is landscape (the axes swapped).
    init(
        geometry: PanelGeometry = .panel172x320,
        landscape: Bool = false,
        onPreview: ((CGImage, Bool) -> Void)? = nil,
        onFrame: @escaping ([UInt8], Bool) -> Void
    ) {
        self.geometry = geometry
        self.rgbBuffer = [UInt8](repeating: 0, count: geometry.frameBytes)
        self._landscape = landscape
        self._outW = geometry.frameWidth(landscape: landscape)
        self._outH = geometry.frameHeight(landscape: landscape)
        self.onFrame = onFrame
        self.onPreview = onPreview
    }

    /// Name of a display (as shown in System Settings / BetterDisplay) for a
    /// CGDirectDisplayID, via NSScreen.
    ///
    /// NSScreen only refreshes when the main run loop processes display
    /// change notifications - which never happens in a plain CLI tool. Pump
    /// it briefly so re-created displays (e.g. after a BetterDisplay
    /// rotation) show up with their new IDs.
    static func name(for displayID: CGDirectDisplayID) -> String? {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        return currentName(for: displayID)
    }

    /// Name lookup without pumping the run loop, for callers already inside a
    /// main-thread callback where re-entering it is not acceptable. Safe there
    /// because AppKit has just processed the display notifications itself.
    static func currentName(for displayID: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                num == displayID
            {
                return screen.localizedName
            }
        }
        return nil
    }

    /// How long a ScreenCaptureKit call may take before the supervisor gives up
    /// on it. Each normally completes in well under a second.
    static let callDeadline: TimeInterval = 10

    /// The shareable content, or an error if ScreenCaptureKit does not answer
    /// within `callDeadline`. Every lookup goes through here: the supervisor
    /// makes one of these every watchdog tick, and a single fetch that never
    /// returned used to stop the watchdog for good.
    static func shareableContent(
        excludingDesktopWindows: Bool, onScreenWindowsOnly: Bool
    ) async throws -> SCShareableContent {
        // Circuit breaker: an expired call leaves its task parked inside
        // ScreenCaptureKit, so while it stays wedged ask at most every
        // `unresponsiveRetry` instead of leaking a task on every lookup.
        if let expiredAt = lastExpiry.withLock({ $0 }),
            ProcessInfo.processInfo.systemUptime - expiredAt < unresponsiveRetry
        {
            throw CaptureDeadlineExpired(operation: "Listing shareable content")
        }
        do {
            let content = try await withCaptureDeadline(
                callDeadline, "Listing shareable content"
            ) {
                try await SCShareableContent.excludingDesktopWindows(
                    excludingDesktopWindows, onScreenWindowsOnly: onScreenWindowsOnly)
            }
            responsiveness.withLock { $0 = false }
            lastExpiry.withLock { $0 = nil }
            return content
        } catch let error as CaptureDeadlineExpired {
            responsiveness.withLock { $0 = true }
            lastExpiry.withLock { $0 = ProcessInfo.processInfo.systemUptime }
            throw error
        }
    }

    /// How long lookups fail fast after one timed out.
    static let unresponsiveRetry: TimeInterval = 30
    private static let lastExpiry = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)

    /// True while the last shareable-content fetch timed out. The lookups
    /// built on it answer nil either way, and without this a wedged
    /// ScreenCaptureKit read as "the display is not there": a calm Waiting
    /// status, and a picker selection thrown away as gone.
    static var isUnresponsive: Bool { responsiveness.withLock { $0 } }
    private static let responsiveness = OSAllocatedUnfairLock(initialState: false)

    /// Processes owning a normal on-screen window, or nil if ScreenCaptureKit
    /// could not be asked. For application-only filters, which deliver nothing
    /// while every window of the application is minimised or hidden.
    static func onScreenWindowOwnerPIDs() async -> [pid_t]? {
        guard let content = try? await shareableContent(
            excludingDesktopWindows: true, onScreenWindowsOnly: true)
        else { return nil }
        return content.windows
            .filter { $0.windowLayer == 0 && $0.isOnScreen }
            .compactMap { $0.owningApplication?.processID }
    }

    /// Whether this login session is off the console or its screen is locked.
    /// Either way capture legitimately delivers nothing, so the stall monitor
    /// holds rather than reporting a failure.
    static func sessionIsInactive() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        let onConsole = info[kCGSessionOnConsoleKey as String] as? Bool ?? true
        let locked = info["CGSSessionScreenIsLocked"] as? Bool ?? false
        return !onConsole || locked
    }

    /// Whether a display is asleep. A slept display legitimately delivers no
    /// frames, so the stall monitor holds rather than restarting into it. Nil
    /// means the source is not one display (a window, a picker selection), and
    /// the main display stands in for it.
    static func isAsleep(_ displayID: CGDirectDisplayID?) -> Bool {
        CGDisplayIsAsleep(displayID ?? CGMainDisplayID()) != 0
    }

    /// Displays ScreenCaptureKit can capture, with names and pixel sizes
    /// (what --list-displays prints).
    static func listDisplays() async throws -> [(id: CGDirectDisplayID, name: String, width: Int, height: Int)] {
        let content = try await shareableContent(
            excludingDesktopWindows: false, onScreenWindowsOnly: false)
        return content.displays.map { d in
            (id: d.displayID, name: name(for: d.displayID) ?? "(unnamed)",
             width: d.width, height: d.height)
        }
    }

    /// Capturable displays paired with the names the UI shows.
    ///
    /// Unlike `listDisplays` this hands back the `SCDisplay` itself, so a caller
    /// that needs to build a filter does not have to fetch the shareable content
    /// a second time and hope the set did not change in between. Names come from
    /// `currentName`, without pumping the run loop: callers here are reacting to
    /// user input, not to a display reconfiguration, so NSScreen is already
    /// current and re-entering the run loop would only risk reentrancy.
    static func capturableDisplays() async -> [(display: SCDisplay, name: String)] {
        guard let content = try? await shareableContent(
            excludingDesktopWindows: false, onScreenWindowsOnly: false)
        else { return [] }
        return content.displays.map {
            (display: $0, name: currentName(for: $0.displayID) ?? "(unnamed)")
        }
    }

    /// Stable identity for a display: the CoreGraphics UUID survives
    /// displayID reassignment, rotation, resolution changes, and mirroring -
    /// unlike displayID (reissued) and NSScreen names (mirrored displays
    /// vanish from NSScreen entirely).
    static func uuid(for displayID: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, cfUUID) as String?
    }

    /// All online displays per CoreGraphics - includes mirror targets that
    /// SCShareableContent and NSScreen both hide.
    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    struct Resolved {
        let display: SCDisplay      // what to hand to SCStream
        let targetUUID: String?     // stable identity of the *target* display
        let viaMirror: Bool         // capturing the mirror source's pixels
    }

    /// Normal application windows large enough to be worth capturing
    /// (what --list-windows prints).
    static func listWindows() async throws -> [(id: UInt32, app: String, title: String, width: Int, height: Int)] {
        let content = try await shareableContent(
            excludingDesktopWindows: true, onScreenWindowsOnly: false)
        return content.windows
            .filter { $0.windowLayer == 0 && $0.frame.width >= 100 && $0.frame.height >= 100 }
            .map {
                (id: $0.windowID, app: $0.owningApplication?.applicationName ?? "?",
                 title: $0.title ?? "", width: Int($0.frame.width), height: Int($0.frame.height))
            }
    }

    /// Windows a gesture can step through, with the `SCWindow` itself so the
    /// caller can build a filter without fetching the content a second time.
    ///
    /// On-screen only: cycling onto a minimised or hidden window would send the
    /// panel something the user cannot see, which reads as the gesture having
    /// broken the stream.
    ///
    /// Sorted by application, then by window ID. That ordering matters more than
    /// it looks: ScreenCaptureKit returns windows in z-order, which changes the
    /// moment the user clicks something, so cycling would appear to jump around
    /// and revisit windows. Sorting by an identity that does not move keeps one
    /// swipe equal to one step, and keeps an app's windows adjacent.
    static func cyclableWindows() async -> [(window: SCWindow, label: String)] {
        guard let content = try? await shareableContent(
            excludingDesktopWindows: true, onScreenWindowsOnly: true)
        else { return [] }
        return content.windows
            .filter {
                $0.windowLayer == 0 && $0.frame.width >= 100 && $0.frame.height >= 100
            }
            .sorted { a, b in
                let appA = a.owningApplication?.applicationName ?? ""
                let appB = b.owningApplication?.applicationName ?? ""
                guard appA == appB else {
                    return appA.localizedCaseInsensitiveCompare(appB)
                        == .orderedAscending
                }
                return a.windowID < b.windowID
            }
            .map { window in
                let app = window.owningApplication?.applicationName ?? "Window"
                let title = window.title ?? ""
                return (window: window, label: title.isEmpty ? app : "\(app): \(title)")
            }
    }

    /// Find a normal application window whose app name or title contains
    /// `matching` (case-insensitive). Largest match wins, preferring
    /// on-screen windows.
    static func findWindow(matching: String) async -> SCWindow? {
        guard let content = try? await shareableContent(
            excludingDesktopWindows: true, onScreenWindowsOnly: false)
        else { return nil }
        let candidates = content.windows.filter { w in
            guard w.windowLayer == 0, w.frame.width >= 100, w.frame.height >= 100
            else { return false }
            let app = w.owningApplication?.applicationName ?? ""
            let title = w.title ?? ""
            return app.localizedCaseInsensitiveContains(matching)
                || title.localizedCaseInsensitiveContains(matching)
        }
        return candidates.max { a, b in
            let scoreA = (a.isOnScreen ? 1e9 : 0) + a.frame.width * a.frame.height
            let scoreB = (b.isOnScreen ? 1e9 : 0) + b.frame.width * b.frame.height
            return scoreA < scoreB
        }
    }

    /// A capturable display matching a name, with its size in **points**.
    ///
    /// Deliberately not `resolve(named:knownUUID:)`. That one carries mirror
    /// traversal and a 172:320 aspect-ratio guess, both aimed at finding a
    /// virtual panel display; for a region the user has literally drawn on a
    /// screen, a plain name match is what is wanted, and guessing at a different
    /// display would silently capture the wrong rectangle.
    ///
    /// The size comes from `NSScreen`, not from `SCDisplay`, because
    /// `sourceRect` is specified in points in the display's logical coordinate
    /// system and NSScreen is the authority on that.
    @MainActor
    static func findDisplay(named name: String) async -> (display: SCDisplay, points: CGSize)? {
        guard let content = try? await shareableContent(
            excludingDesktopWindows: false, onScreenWindowsOnly: false)
        else { return nil }
        for display in content.displays {
            guard let screenName = currentName(for: display.displayID),
                screenName == name
            else { continue }
            let points = screen(for: display.displayID)?.frame.size
                ?? CGSize(width: display.width, height: display.height)
            return (display, points)
        }
        return nil
    }

    /// The `NSScreen` backing a display ID, for its point geometry.
    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID) == displayID
        }
    }

    /// The `NSScreen` whose name matches, for turning a stored region back into
    /// window coordinates.
    static func screen(named name: String) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return false }
            return currentName(for: id) == name
        }
    }

    /// The screen the user is most likely to want to frame: the one with the
    /// keyboard focus, falling back to the first attached.
    static func preferredScreen() -> (name: String, size: CGSize)? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
            let id = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
            let name = currentName(for: id)
        else { return nil }
        return (name, screen.frame.size)
    }

    /// Look a window up by ID in the current shareable content.
    ///
    /// Re-resolving a tracked window by ID rather than by name matters on
    /// resize: `findWindow(matching:)` returns the *largest* match, so
    /// resizing one window of an app that has several could hand the session
    /// to a sibling window and restart capture on the wrong content.
    static func findWindow(id windowID: CGWindowID) async -> SCWindow? {
        guard let content = try? await shareableContent(
            excludingDesktopWindows: true, onScreenWindowsOnly: false)
        else { return nil }
        return content.windows.first { $0.windowID == windowID }
    }

    /// What a content filter currently points at, resolved against live
    /// shareable content rather than the objects captured when it was made.
    struct FilterTarget {
        /// A filter rebuilt from fresh objects, safe to start a stream with.
        let filter: SCContentFilter
        /// The window this filter follows, when it follows exactly one.
        let windowID: CGWindowID?
        /// Application owning that window, for finding its replacement if the
        /// window itself is recreated.
        let owner: String?
        /// Current size of the content, for orientation decisions.
        let size: CGSize
    }

    /// Outcome of re-resolving a filter. The three cases need different
    /// responses, which a plain optional could not express: content that has
    /// gone must not be retried, whereas a filter we simply cannot inspect
    /// should still be used as-is.
    enum FilterResolution {
        /// Rebuilt successfully against live content.
        case resolved(FilterTarget)
        /// The window or display this filter names no longer exists.
        case contentGone
        /// Nothing here identifies a single window or display to look up, so
        /// the caller should keep using the filter it has.
        case notResolvable
    }

    /// Rebuild a content filter against the current shareable content.
    ///
    /// An `SCContentFilter` holds references to the window and display objects
    /// that existed when the user picked them. Those references go stale - a
    /// resize or full-screen transition can have macOS destroy and recreate
    /// the window - and a stale filter starts a stream that never delivers a
    /// frame. Re-resolving before every (re)start is what makes a picked
    /// window survive being resized.
    ///
    /// Returns `.contentGone` when the window or display it named has gone, and
    /// `.notResolvable` when its style carries no single identity to look up, in
    /// which case the caller keeps using the filter it already has.
    static func resolveTarget(of filter: SCContentFilter) async -> FilterResolution {
        switch filter.style {
        case .window:
            guard let stale = filter.includedWindows.first else { return .notResolvable }
            let owner = stale.owningApplication?.applicationName
            if let fresh = await findWindow(id: stale.windowID) {
                return .resolved(FilterTarget(
                    filter: SCContentFilter(desktopIndependentWindow: fresh),
                    windowID: fresh.windowID,
                    owner: owner,
                    size: fresh.frame.size))
            }
            // The window ID is gone. A resize or full-screen transition can
            // recreate a window under a new ID, so try the owning application
            // before declaring the source lost.
            if let owner, let replacement = await findWindow(matching: owner) {
                return .resolved(FilterTarget(
                    filter: SCContentFilter(desktopIndependentWindow: replacement),
                    windowID: replacement.windowID,
                    owner: owner,
                    size: replacement.frame.size))
            }
            return .contentGone

        case .display:
            guard let stale = filter.includedDisplays.first else { return .notResolvable }
            guard let content = try? await shareableContent(
                    excludingDesktopWindows: false, onScreenWindowsOnly: false),
                let fresh = content.displays.first(where: {
                    $0.displayID == stale.displayID
                })
            else { return .contentGone }
            return .resolved(FilterTarget(
                filter: SCContentFilter(display: fresh, excludingWindows: []),
                windowID: nil,
                owner: nil,
                size: CGSize(width: fresh.width, height: fresh.height)))

        default:
            // Application filters name no single window or display to
            // re-resolve, so the existing filter stays in use.
            return .notResolvable
        }
    }

    /// Find the target display, robust to whatever macOS/BetterDisplay just
    /// did to it. Match order:
    ///   1. Known UUID among capturable displays (survives all reconfigs)
    ///   2. NSScreen name (learns the UUID for subsequent lookups)
    ///   3. Mirror traversal: if the UUID exists online but isn't
    ///      capturable, it became a mirror target - capture the mirror
    ///      SOURCE, which shows the identical pixels
    ///   4. The panel's distinctive 172:320 aspect ratio, either orientation
    static func resolve(named nameSubstring: String, knownUUID: String?) async -> Resolved? {
        guard let content = try? await shareableContent(
            excludingDesktopWindows: false, onScreenWindowsOnly: false)
        else { return nil }
        let displays = content.displays

        if let known = knownUUID,
            let d = displays.first(where: { uuid(for: $0.displayID) == known })
        {
            return Resolved(display: d, targetUUID: known, viaMirror: false)
        }

        if let d = displays.first(where: { d in
            (name(for: d.displayID) ?? "").localizedCaseInsensitiveContains(nameSubstring)
        }) {
            return Resolved(display: d, targetUUID: uuid(for: d.displayID), viaMirror: false)
        }

        if let known = knownUUID {
            for id in onlineDisplayIDs() where uuid(for: id) == known {
                let source = CGDisplayMirrorsDisplay(id)
                if source != kCGNullDirectDisplay,
                    let d = displays.first(where: { $0.displayID == source })
                {
                    return Resolved(display: d, targetUUID: known, viaMirror: true)
                }
            }
        }

        // Cold start while already mirrored (no UUID learned yet, name gone
        // from NSScreen): an online display that mirrors another, isn't
        // built-in, and isn't independently capturable is our virtual
        // display. Capture its source and learn the UUID for later.
        for id in onlineDisplayIDs() {
            let source = CGDisplayMirrorsDisplay(id)
            if source != kCGNullDirectDisplay,
                CGDisplayIsBuiltin(id) == 0,
                !displays.contains(where: { $0.displayID == id }),
                let d = displays.first(where: { $0.displayID == source })
            {
                return Resolved(display: d, targetUUID: uuid(for: id), viaMirror: true)
            }
        }

        // Deliberately still the 172x320 aspect rather than the panel's own.
        // This is a last-resort guess at WHICH Mac display the user meant, on a
        // static method with no panel in scope, and its whole basis is that
        // somebody made a virtual display shaped like the original panel. A
        // square panel would make this match any square display, which is a
        // worse guess than not matching - and every path that knows the panel
        // (an explicit display, a window, the picker) reaches capture without
        // coming through here.
        let target = Double(PixelConvert.width) / Double(PixelConvert.height)  // 0.5375
        if let d = displays.first(where: { d in
            guard d.width > 0, d.height > 0 else { return false }
            let aspect = Double(d.width) / Double(d.height)
            return abs(aspect - target) < 0.01 || abs(aspect - 1.0 / target) < 0.035
        }) {
            return Resolved(display: d, targetUUID: uuid(for: d.displayID), viaMirror: false)
        }
        return nil
    }

    /// Whether a capture streams landscape frames (the panel's height wide).
    ///
    /// One rule for every kind of source - Screen, Window, Region and a picker
    /// selection alike - because the firmware reads the landscape bit as a
    /// quarter turn: rectangular glass addresses a frame through
    /// `(rotation & 2) + landscape` and square glass through
    /// `rotation + landscape` (`panelorient::quadrant`). Up on the Mac is up on
    /// the glass only when landscape means exactly "rectangular glass mounted a
    /// quarter turn", and never on square glass, which turns for every rotation
    /// itself. The source's own shape is fitted into that frame
    /// (`scalesToFit`) and never picks it: taking it from the source is what
    /// turned a wide Screen or Window a quarter turn at rotation 0 while a
    /// Region beside it stayed upright.
    static func streamsLandscape(geometry: PanelGeometry, rotation: Int) -> Bool {
        geometry.width != geometry.height && rotation % 2 != 0
    }

    /// Start capturing a display, fitted into this capture's frame shape.
    func start(display: SCDisplay, fps: Int) async throws {
        try await start(
            filter: SCContentFilter(display: display, excludingWindows: []),
            fps: fps,
            contentSize: CGSize(width: display.width, height: display.height))
    }

    /// Start capturing a single window, independent of any display - works
    /// even when the window is occluded or the virtual display is gone.
    func start(window: SCWindow, fps: Int) async throws {
        try await start(
            filter: SCContentFilter(desktopIndependentWindow: window), fps: fps,
            contentSize: window.frame.size)
    }

    /// Start capturing a rectangle of a display rather than the whole thing.
    ///
    /// `sourceRect` is in points relative to the display's top-left corner,
    /// which is what ScreenCaptureKit asks for. The frame shape still comes
    /// from the panel's rotation; setting the rotation is what turns the
    /// rectangle on its side to match (`applyRegionQuarterTurn`).
    func start(display: SCDisplay, sourceRect: CGRect, fps: Int) async throws {
        try await start(
            filter: SCContentFilter(display: display, excludingWindows: []),
            fps: fps,
            sourceRect: sourceRect,
            contentSize: sourceRect.size)
    }

    /// Start capturing whatever the user chose in macOS's content picker.
    func start(contentFilter: SCContentFilter, fps: Int) async throws {
        try await start(
            filter: contentFilter, fps: fps, contentSize: contentFilter.contentRect.size)
    }

    private func start(
        filter: SCContentFilter, fps: Int, sourceRect: CGRect? = nil, contentSize: CGSize
    ) async throws {
        let (width, height) = stateLock.withLock { (_outW, _outH) }
        stateLock.withLock {
            _configuredFPS = fps
            _sourceRect = sourceRect
            _contentSize = contentSize
            _stopped = false
            _stopReason = nil
            _lastSampleAt = Date()
        }

        let stream = SCStream(
            filter: filter,
            configuration: Self.configuration(
                width: width, height: height, fps: fps, sourceRect: sourceRect,
                contentSize: contentSize),
            delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        let identity = ObjectIdentifier(stream)
        stateLock.withLock { _acceptedStream = identity }
        do {
            try await withCaptureDeadline(
                Self.callDeadline, "Starting capture",
                onLateSuccess: { _ in Task { try? await stream.stopCapture() } }
            ) {
                try await stream.startCapture()
            }
        } catch {
            stateLock.withLock {
                if _acceptedStream == identity { _acceptedStream = nil }
            }
            throw error
        }
        self.stream = stream
    }

    static func configuration(
        width: Int, height: Int, fps: Int, sourceRect: CGRect? = nil,
        contentSize: CGSize? = nil
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.showsCursor = true
        config.scalesToFit = true
        // Left unset for a whole-display or window capture: the header is
        // explicit that an unset sourceRect streams the entire display or
        // window, and a zero rect is not the same thing.
        if let sourceRect { config.sourceRect = sourceRect }
        if let contentSize,
            let destination = letterbox(content: contentSize, width: width, height: height)
        {
            config.destinationRect = destination
        }
        return config
    }

    /// Where content of `content`'s shape sits, fitted and centred, in a
    /// `width` x `height` frame, in whole pixels. Nil for an unusable size.
    ///
    /// Needed because ScreenCaptureKit fits the source into the frame but pins
    /// it to the top-left corner, so a wide window on square glass sat at the
    /// top with all the black below it instead of split above and below.
    static func letterbox(content: CGSize, width: Int, height: Int) -> CGRect? {
        guard content.width > 0, content.height > 0, width > 0, height > 0 else {
            return nil
        }
        let frameW = Double(width)
        let frameH = Double(height)
        let fit = min(frameW / content.width, frameH / content.height)
        let fittedW = min(frameW, max(1, (content.width * fit).rounded()))
        let fittedH = min(frameH, max(1, (content.height * fit).rounded()))
        return CGRect(
            x: ((frameW - fittedW) / 2).rounded(),
            y: ((frameH - fittedH) / 2).rounded(),
            width: fittedW, height: fittedH)
    }

    /// Point a running stream at a different rectangle of the same display.
    ///
    /// Reconfigures rather than restarts, because the marquee sends one of these
    /// for every step of a drag and rebuilding the stream that often would make
    /// the panel flicker and reset its band diff. The frame shape is kept: it
    /// follows the panel's rotation, not the rectangle.
    ///
    /// - Returns: false when the stream could not be reconfigured.
    @discardableResult
    func updateRegion(_ rect: CGRect) async -> Bool {
        await reconfigure(rect: rect, landscape: nil, contentSize: rect.size)
    }

    /// Re-centre a running stream for content that changed size, such as a
    /// window being resized. Nothing is sent when the size is unchanged.
    ///
    /// - Returns: false when the stream could not be reconfigured.
    @discardableResult
    func updateContentSize(_ size: CGSize) async -> Bool {
        await reconfigure(rect: nil, landscape: nil, contentSize: size)
    }

    /// Change the frame shape of a running stream in place, for a rotation that
    /// crosses between an even and an odd quarter turn.
    ///
    /// Reconfiguring keeps the existing stream, and with it the system's
    /// sharing session: a stream started from a picker selection cannot
    /// reliably be recreated from that same filter, so a restart here could
    /// drop the share altogether. The source rectangle, if any, is kept.
    ///
    /// - Returns: false when the stream could not be reconfigured, and the
    ///   caller should restart capture instead.
    @discardableResult
    func reshape(landscape: Bool) async -> Bool {
        await reconfigure(rect: nil, landscape: landscape, contentSize: nil)
    }

    /// Stands in for ScreenCaptureKit's reconfigure in tests, so the drain can
    /// run without a stream. Called with the frame size and source rectangle.
    var configureForTesting: ((Int, Int, CGRect?) async throws -> Void)?

    /// The frame size samples are currently converted at.
    var frameSizeForTesting: (width: Int, height: Int) {
        stateLock.withLock { (_outW, _outH) }
    }

    private func reconfigure(
        rect: CGRect?, landscape: Bool?, contentSize: CGSize?
    ) async -> Bool {
        guard stream != nil || configureForTesting != nil else { return false }
        let drains = stateLock.withLock { () -> Bool in
            if let rect { _pendingRect = rect }
            if let landscape { _pendingLandscape = landscape }
            if let contentSize { _pendingContentSize = contentSize }
            guard !_reconfiguring else { return false }
            _reconfiguring = true
            return true
        }
        // Another call is draining: it picks this value up before it finishes.
        guard drains else { return true }
        while true {
            let next = stateLock.withLock {
                () -> (rect: CGRect?, landscape: Bool, content: CGSize?, fps: Int)? in
                let rect = _pendingRect ?? _sourceRect
                let landscape = _pendingLandscape ?? _landscape
                let content = _pendingContentSize ?? _contentSize
                _pendingRect = nil
                _pendingLandscape = nil
                _pendingContentSize = nil
                guard rect != _sourceRect || landscape != _landscape
                    || content != _contentSize
                else {
                    _reconfiguring = false
                    return nil
                }
                return (rect, landscape, content, _configuredFPS)
            }
            guard let next else { return true }
            // Read each pass: stop() can take the stream away mid-drain, and
            // then nothing below applies and success must not be reported.
            let hook = configureForTesting
            let stream = self.stream
            guard hook != nil || stream != nil else {
                stateLock.withLock { _reconfiguring = false }
                return false
            }
            let width = geometry.frameWidth(landscape: next.landscape)
            let height = geometry.frameHeight(landscape: next.landscape)
            // Expect the new size before asking for it: ScreenCaptureKit may
            // deliver the first new-size frame before the call returns, and on
            // a static screen that is the only one. Frames still in flight at
            // the old size are dropped by PixelConvert's size check, and
            // FrameSender keyframes on the landscape change.
            let before = stateLock.withLock { () -> (landscape: Bool, width: Int, height: Int) in
                let before = (_landscape, _outW, _outH)
                _landscape = next.landscape
                _outW = width
                _outH = height
                return before
            }
            do {
                if let hook {
                    try await hook(width, height, next.rect)
                } else if let stream {
                    try await withCaptureDeadline(Self.callDeadline, "Reconfiguring capture") {
                        try await stream.updateConfiguration(
                            Self.configuration(
                                width: width, height: height, fps: next.fps,
                                sourceRect: next.rect, contentSize: next.content))
                    }
                }
            } catch {
                FileHandle.standardError.write(
                    Data("capture reconfigure failed: \(error.localizedDescription)\n".utf8))
                stateLock.withLock {
                    _landscape = before.landscape
                    _outW = before.width
                    _outH = before.height
                    _reconfiguring = false
                    // A shape change that did not apply leaves the stream in the
                    // old shape under a panel at the new rotation, and nothing
                    // else would notice: have the watchdog rebuild it, which
                    // starts in the shape the rotation calls for.
                    // The same holds for a reshape queued behind this call,
                    // which the drain stops before reaching.
                    let queuedShape = _pendingLandscape.map { $0 != before.landscape } ?? false
                    _pendingRect = nil
                    _pendingLandscape = nil
                    _pendingContentSize = nil
                    if next.landscape != before.landscape || queuedShape {
                        _stopped = true
                        _stopReason = "the frame shape could not be changed"
                    }
                }
                markWedgedIfExpired(error)
                return false
            }
            stateLock.withLock {
                _sourceRect = next.rect
                _contentSize = next.content
            }
        }
    }

    /// Point a running stream at freshly resolved content, without replacing
    /// it. Used when a tracked window has been recreated (some resize and
    /// full-screen transitions do that) so the stale references in the old
    /// filter no longer refer to anything.
    ///
    /// - Returns: true when the filter was swapped in.
    @discardableResult
    func retarget(to filter: SCContentFilter) async -> Bool {
        guard let stream else { return false }
        do {
            try await withCaptureDeadline(Self.callDeadline, "Retargeting capture") {
                try await stream.updateContentFilter(filter)
            }
        } catch {
            FileHandle.standardError.write(
                Data("capture retarget failed: \(error.localizedDescription)\n".utf8))
            markWedgedIfExpired(error)
            return false
        }
        return true
    }

    /// A reconfigure that timed out may still apply later, leaving the stream
    /// at a size this capture no longer expects. Mark it stopped so the
    /// watchdog rebuilds it on its next tick instead of waiting out a stall.
    private func markWedgedIfExpired(_ error: Error) {
        guard let expired = error as? CaptureDeadlineExpired else { return }
        stateLock.withLock {
            _stopped = true
            _stopReason = expired.localizedDescription
        }
    }

    /// Stop the capture stream, ignoring shutdown errors.
    ///
    /// Bounded like every other ScreenCaptureKit call: the supervisor awaits
    /// this before every restart, so a stop that never returned would wedge it.
    /// Samples are refused first, so a stream that will not stop cannot feed
    /// the session after it has moved on.
    func stop() async {
        stateLock.withLock { _acceptedStream = nil }
        if let stream {
            _ = try? await withCaptureDeadline(Self.callDeadline, "Stopping capture") {
                try await stream.stopCapture()
            }
        }
        stream = nil
    }

    // MARK: SCStreamOutput

    /// SCStreamOutput callback: convert each complete BGRA sample to
    /// RGB565BE and forward it to `onFrame`.
    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        stateLock.lock()
        guard _acceptedStream == ObjectIdentifier(stream) else {
            stateLock.unlock()
            return
        }
        _lastSampleAt = Date()
        let width = _outW
        let height = _outH
        let isLandscape = _landscape
        let wantsPreview = _previewEnabled
        stateLock.unlock()

        guard sampleBuffer.isValid else { return }

        // SCK delivers "idle" buffers without status attachments sometimes;
        // only forward new frames. `.started` is one: the first frame of a
        // stream, which is what shows a restarted stream is alive on a screen
        // that is not changing. Read before the pixel check so status-only
        // samples still leave their status for the stall log.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw)
        {
            stateLock.withLock { _lastSampleStatus = status }
            guard Self.carriesNewFrame(status) else { return }
        }

        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        if PixelConvert.bgraToRGB565BE(pixelBuffer, width: width, height: height, into: &rgbBuffer) {
            stateLock.lock()
            _framesCaptured &+= 1
            _lastFrameAt = Date()
            stateLock.unlock()
            onFrame(rgbBuffer, isLandscape)
            emitPreviewIfDue(width: width, height: height, landscape: isLandscape,
                             enabled: wantsPreview)
        }
    }

    /// Whether a sample with this status is a new picture to send. `.started`
    /// counts: it is the first frame of a stream, and on a static screen the
    /// only one, so it is what shows a probe-restarted stream is alive.
    static func carriesNewFrame(_ status: SCFrameStatus) -> Bool {
        status == .complete || status == .started
    }

    /// Hand the UI an image of the frame just sent, no more often than
    /// `previewInterval`. Runs on the capture queue, so the throttle is what
    /// keeps a 40 fps stream from driving 40 SwiftUI redraws a second.
    private func emitPreviewIfDue(
        width: Int, height: Int, landscape: Bool, enabled: Bool
    ) {
        guard enabled, let onPreview else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPreviewAt) >= Self.previewInterval else { return }
        lastPreviewAt = now
        guard let image = PixelConvert.imageFromRGB565BE(
            rgbBuffer, width: width, height: height)
        else { return }
        onPreview(image, landscape)
    }

    /// SCStreamDelegate callback: mark the stream dead so the supervisor
    /// loop restarts capture, keeping the reason so the UI can show it.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("capture stopped: \(error)\n".utf8))
        stateLock.lock()
        // A stream this capture has already let go of (stopped, or abandoned
        // when its start timed out) says nothing about the one running now.
        guard _acceptedStream == ObjectIdentifier(stream) else {
            stateLock.unlock()
            return
        }
        _stopped = true
        _stopReason = error.localizedDescription
        stateLock.unlock()
    }
}
