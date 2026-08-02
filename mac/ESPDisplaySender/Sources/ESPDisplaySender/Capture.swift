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

    /// Find the SCDisplay whose NSScreen name contains `nameSubstring`
    /// (case-insensitive). Falls back to matching the panel's distinctive
    /// 172:320 aspect ratio (either orientation), since name lookup can
    /// fail when NSScreen lags a display re-creation.
    static func findDisplay(named nameSubstring: String) async throws -> SCDisplay? {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        if let byName = content.displays.first(where: { d in
            (name(for: d.displayID) ?? "").localizedCaseInsensitiveContains(nameSubstring)
        }) {
            return byName
        }
        let target = Double(PixelConvert.width) / Double(PixelConvert.height)  // 0.5375
        return content.displays.first { d in
            guard d.width > 0, d.height > 0 else { return false }
            let aspect = Double(d.width) / Double(d.height)
            return abs(aspect - target) < 0.01 || abs(aspect - 1.0 / target) < 0.035
        }
    }

    /// Start capturing. Orientation follows the display's aspect ratio:
    /// wider than tall captures landscape (320x172), else portrait (172x320).
    func start(display: SCDisplay, fps: Int) async throws {
        landscape = display.width > display.height
        outW = landscape ? PixelConvert.height : PixelConvert.width
        outH = landscape ? PixelConvert.width : PixelConvert.height

        let filter = SCContentFilter(display: display, excludingWindows: [])

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
        guard type == .screen,
            sampleBuffer.isValid,
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
