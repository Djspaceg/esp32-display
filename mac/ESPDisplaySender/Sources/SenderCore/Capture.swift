import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit capture of one display, scaled by SCK to 172x320 BGRA,
/// converted to RGB565BE and handed to a callback.
final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "espdisp.capture")
    private var rgbBuffer = [UInt8](repeating: 0, count: PixelConvert.width * PixelConvert.height * 2)
    private let onFrame: ([UInt8], Bool) -> Void
    private let onPreview: ((CGImage, Bool) -> Void)?

    /// Guards every field the capture queue and the supervisor both touch.
    /// Orientation in particular is now written while frames are in flight,
    /// because a resize re-configures the stream instead of replacing it.
    private let stateLock = NSLock()
    private var _landscape = false
    private var _outW = PixelConvert.width
    private var _outH = PixelConvert.height
    private var _framesCaptured: UInt64 = 0
    private var _stopped = false
    private var _stopReason: String?
    private var _lastSampleAt = Date()
    private var _lastFrameAt: Date?
    private var _previewEnabled = false
    private var _configuredFPS = 30

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
    /// frames). A healthy SCStream emits these periodically even for a
    /// static screen, so a long silence means the stream is dead - some
    /// deaths (sleep/wake) never fire the delegate error.
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
    ///   - onFrame: called on the capture queue with each converted
    ///     RGB565BE frame and whether it is landscape (320x172).
    init(
        onPreview: ((CGImage, Bool) -> Void)? = nil,
        onFrame: @escaping ([UInt8], Bool) -> Void
    ) {
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

    /// Displays ScreenCaptureKit can capture, with names and pixel sizes
    /// (what --list-displays prints).
    static func listDisplays() async throws -> [(id: CGDirectDisplayID, name: String, width: Int, height: Int)] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        return content.displays.map { d in
            (id: d.displayID, name: name(for: d.displayID) ?? "(unnamed)",
             width: d.width, height: d.height)
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
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false)
        return content.windows
            .filter { $0.windowLayer == 0 && $0.frame.width >= 100 && $0.frame.height >= 100 }
            .map {
                (id: $0.windowID, app: $0.owningApplication?.applicationName ?? "?",
                 title: $0.title ?? "", width: Int($0.frame.width), height: Int($0.frame.height))
            }
    }

    /// Find a normal application window whose app name or title contains
    /// `matching` (case-insensitive). Largest match wins, preferring
    /// on-screen windows.
    static func findWindow(matching: String) async -> SCWindow? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false)
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

    /// Look a window up by ID in the current shareable content.
    ///
    /// Re-resolving a tracked window by ID rather than by name matters on
    /// resize: `findWindow(matching:)` returns the *largest* match, so
    /// resizing one window of an app that has several could hand the session
    /// to a sibling window and restart capture on the wrong content.
    static func findWindow(id windowID: CGWindowID) async -> SCWindow? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false)
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
    /// Returns nil when the filter cannot be re-resolved, either because the
    /// content is gone or because its style carries no identity we can look up
    /// (the accessors that reveal a filter's contents need macOS 15.2). The
    /// caller then keeps using the filter it already has.
    static func resolveTarget(of filter: SCContentFilter) async -> FilterResolution {
        guard #available(macOS 15.2, *) else { return .notResolvable }
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
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false),
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
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
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

    /// Start capturing a display. Orientation follows the aspect ratio:
    /// wider than tall captures landscape (320x172), else portrait (172x320).
    func start(display: SCDisplay, fps: Int) async throws {
        try await start(
            filter: SCContentFilter(display: display, excludingWindows: []),
            landscape: display.width > display.height, fps: fps)
    }

    /// Start capturing a single window, independent of any display - works
    /// even when the window is occluded or the virtual display is gone.
    func start(window: SCWindow, fps: Int) async throws {
        try await start(
            filter: SCContentFilter(desktopIndependentWindow: window),
            landscape: window.frame.width > window.frame.height, fps: fps)
    }

    /// Start capturing whatever the user chose in macOS's content picker.
    /// Orientation comes from the filter's content rect, so a picked portrait
    /// window streams portrait and a landscape display streams landscape.
    func start(contentFilter: SCContentFilter, fps: Int) async throws {
        let rect = contentFilter.contentRect
        try await start(
            filter: contentFilter, landscape: rect.width > rect.height, fps: fps)
    }

    private func start(filter: SCContentFilter, landscape: Bool, fps: Int) async throws {
        let width = landscape ? PixelConvert.height : PixelConvert.width
        let height = landscape ? PixelConvert.width : PixelConvert.height
        stateLock.withLock {
            _landscape = landscape
            _outW = width
            _outH = height
            _configuredFPS = fps
            _stopped = false
            _stopReason = nil
            _lastSampleAt = Date()
        }

        let stream = SCStream(
            filter: filter,
            configuration: Self.configuration(width: width, height: height, fps: fps),
            delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    private static func configuration(
        width: Int, height: Int, fps: Int
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.showsCursor = true
        config.scalesToFit = true
        return config
    }

    /// Re-orient a running stream in place, without replacing it.
    ///
    /// A resize that flips the source between portrait and landscape used to
    /// require a full restart, because output geometry was fixed when the
    /// stream was created. Restarting is what actually broke mirroring: a
    /// stream started from a picker selection cannot reliably be recreated
    /// from that same filter, so the "fix" for a resize dropped the share
    /// altogether. Reconfiguring keeps the existing stream, and with it the
    /// system's sharing session.
    ///
    /// - Returns: true when the stream was reconfigured.
    @discardableResult
    func reorient(landscape wanted: Bool) async -> Bool {
        guard let stream else { return false }
        let current = stateLock.withLock {
            (landscape: _landscape, fps: _configuredFPS)
        }
        guard current.landscape != wanted else { return false }

        let width = wanted ? PixelConvert.height : PixelConvert.width
        let height = wanted ? PixelConvert.width : PixelConvert.height
        do {
            try await stream.updateConfiguration(
                Self.configuration(width: width, height: height, fps: current.fps))
        } catch {
            FileHandle.standardError.write(
                Data("capture reorient failed: \(error.localizedDescription)\n".utf8))
            return false
        }
        stateLock.withLock {
            _landscape = wanted
            _outW = width
            _outH = height
        }
        return true
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
            try await stream.updateContentFilter(filter)
        } catch {
            FileHandle.standardError.write(
                Data("capture retarget failed: \(error.localizedDescription)\n".utf8))
            return false
        }
        return true
    }

    /// Stop the capture stream, ignoring shutdown errors.
    func stop() async {
        try? await stream?.stopCapture()
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
        _lastSampleAt = Date()
        let width = _outW
        let height = _outH
        let isLandscape = _landscape
        let wantsPreview = _previewEnabled
        stateLock.unlock()

        guard sampleBuffer.isValid,
            let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        // SCK delivers "idle" buffers without status attachments sometimes;
        // only forward complete frames.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw),
            status != .complete
        {
            return
        }

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
        _stopped = true
        _stopReason = error.localizedDescription
        stateLock.unlock()
    }
}
