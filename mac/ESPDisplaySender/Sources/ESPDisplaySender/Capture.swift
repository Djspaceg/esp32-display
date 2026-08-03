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
    private var landscape = false
    private var outW = PixelConvert.width
    private var outH = PixelConvert.height

    private(set) var framesCaptured: UInt64 = 0
    /// Set when the stream dies (display unplugged, reconfigured, etc.).
    private(set) var stopped = false
    /// Last time ANY sample arrived (including idle/incomplete status
    /// frames). A healthy SCStream emits these periodically even for a
    /// static screen, so a long silence means the stream is dead - some
    /// deaths (sleep/wake) never fire the delegate error.
    private(set) var lastSampleAt = Date()

    init(onFrame: @escaping ([UInt8], Bool) -> Void) {
        self.onFrame = onFrame
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
        self.landscape = landscape
        outW = landscape ? PixelConvert.height : PixelConvert.width
        outH = landscape ? PixelConvert.width : PixelConvert.height

        let config = SCStreamConfiguration()
        config.width = outW
        config.height = outH
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.showsCursor = true
        config.scalesToFit = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    // MARK: SCStreamOutput

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        lastSampleAt = Date()
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

        if PixelConvert.bgraToRGB565BE(pixelBuffer, width: outW, height: outH, into: &rgbBuffer) {
            framesCaptured &+= 1
            onFrame(rgbBuffer, landscape)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("capture stopped: \(error)\n".utf8))
        stopped = true
    }
}
