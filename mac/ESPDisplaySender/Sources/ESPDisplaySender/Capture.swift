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
    private let onFrame: ([UInt8]) -> Void

    private(set) var framesCaptured: UInt64 = 0

    init(onFrame: @escaping ([UInt8]) -> Void) {
        self.onFrame = onFrame
    }

    /// Name of a display (as shown in System Settings / BetterDisplay) for a
    /// CGDirectDisplayID, via NSScreen.
    static func name(for displayID: CGDirectDisplayID) -> String? {
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
    /// (case-insensitive).
    static func findDisplay(named nameSubstring: String) async throws -> SCDisplay? {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        return content.displays.first { d in
            (name(for: d.displayID) ?? "").localizedCaseInsensitiveContains(nameSubstring)
        }
    }

    func start(display: SCDisplay, fps: Int) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = PixelConvert.width
        config.height = PixelConvert.height
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

        if PixelConvert.bgraToRGB565BE(pixelBuffer, into: &rgbBuffer) {
            framesCaptured &+= 1
            onFrame(rgbBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("capture stopped: \(error)\n".utf8))
    }
}
