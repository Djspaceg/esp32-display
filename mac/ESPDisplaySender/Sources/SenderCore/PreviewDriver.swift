import CoreGraphics
import Foundation
import SenderProtocol

/// Captures a panel's chosen source purely to fill the window's preview, when no
/// streaming session is doing it already.
///
/// Sessions only exist for panels discovered on the network, so with a panel
/// switched off there is nothing capturing and the preview stays empty - which
/// made choosing a source or framing a region impossible to judge until the
/// hardware was plugged in. That is the wrong way round: picking what to send is
/// a decision about the Mac's screen, and the Mac can show you the answer on its
/// own.
///
/// Nothing here touches the network. There is no `FrameSender`, and the frame
/// callback deliberately discards its buffer; only the preview image escapes.
@MainActor
final class PreviewDriver {
    /// Called with each preview image and the panel it was captured for.
    var onPreview: ((CGImage, Bool, String) -> Void)?
    /// Called when the chosen source cannot be captured, so the window can say
    /// why the preview is empty instead of claiming to be previewing nothing.
    var onUnavailable: ((String, String) -> Void)?

    private struct Target: Equatable {
        let serviceName: String
        let source: PanelSource
        /// The display an Automatic source tracks. Part of the identity so
        /// changing it re-resolves.
        let defaultDisplay: String
    }

    private var capture: DisplayCapture?
    private var current: Target?
    /// Bumped on every start and stop, so a capture that finishes starting after
    /// it has been superseded throws itself away instead of taking over.
    private var generation = 0

    var isRunning: Bool { capture != nil }

    /// Preview a panel's source, or carry on if it is already the one running.
    func run(
        serviceName: String, source: PanelSource, defaultDisplay: String, fps: Int
    ) {
        let target = Target(
            serviceName: serviceName, source: source, defaultDisplay: defaultDisplay)
        guard target != current else { return }

        // A marquee drag produces a new region for every step. Reconfigure the
        // running capture rather than rebuilding it, or the preview would
        // stutter and flash black all the way through the drag.
        if let capture,
            let existing = current,
            existing.serviceName == serviceName,
            case .region(let new) = source,
            case .region(let old) = existing.source,
            new.display == old.display
        {
            current = target
            Task { await capture.updateRegion(new.rect) }
            return
        }

        stop()
        current = target
        generation += 1
        let token = generation
        Task { [weak self] in await self?.start(target, fps: fps, token: token) }
    }

    func stop() {
        generation += 1
        current = nil
        let previous = capture
        capture = nil
        guard let previous else { return }
        Task { await previous.stop() }
    }

    private func start(_ target: Target, fps: Int, token: Int) async {
        let name = target.serviceName
        let capture = DisplayCapture(
            onPreview: { [weak self] image, landscape in
                Task { @MainActor in self?.onPreview?(image, landscape, name) }
            },
            // The frames themselves go nowhere: this is a viewfinder, not a
            // sender.
            onFrame: { _, _ in })
        capture.setPreviewEnabled(true)

        do {
            switch target.source {
            case .region(let spec):
                guard let found = await DisplayCapture.findDisplay(named: spec.display)
                else {
                    unavailable(
                        name, "The display \"\(spec.display)\" this region was "
                            + "drawn on is not attached.")
                    return
                }
                let region = spec.clamped(to: found.points)
                // Logged so a disagreement between the outline on screen and the
                // pixels that arrive can be pinned on one side or the other:
                // this is exactly the rectangle handed to ScreenCaptureKit.
                print("preview: sourceRect \(region.rect) of \"\(spec.display)\" "
                    + "(\(Int(found.points.width))x\(Int(found.points.height)) pt, "
                    + "SCDisplay \(found.display.width)x\(found.display.height))")
                try await capture.start(
                    display: found.display, sourceRect: region.rect, fps: fps)

            case .display(let displayName):
                guard let found = await DisplayCapture.findDisplay(named: displayName)
                else {
                    unavailable(name, "The display \"\(displayName)\" is not attached.")
                    return
                }
                try await capture.start(display: found.display, fps: fps)

            case .window(let windowName):
                guard let window = await DisplayCapture.findWindow(matching: windowName)
                else {
                    unavailable(
                        name, "No window matching \"\(windowName)\" is open.")
                    return
                }
                try await capture.start(window: window, fps: fps)

            case .automatic:
                // Resolved exactly as a session would, so the preview shows what
                // would really be sent rather than a guess. A live picker
                // selection cannot be honoured - that lives on a session, and
                // there isn't one - but the stored source covers every pick the
                // app was able to identify.
                guard let resolved = await DisplayCapture.resolve(
                    named: target.defaultDisplay, knownUUID: nil)
                else {
                    unavailable(
                        name, target.defaultDisplay.isEmpty
                            ? "No display available to track automatically."
                            : "The display \"\(target.defaultDisplay)\" is not attached.")
                    return
                }
                try await capture.start(display: resolved.display, fps: fps)
            }
        } catch {
            FileHandle.standardError.write(
                Data("preview capture failed: \(error.localizedDescription)\n".utf8))
            return
        }

        guard token == generation else {
            await capture.stop()
            return
        }
        self.capture = capture
    }

    private func unavailable(_ serviceName: String, _ reason: String) {
        onUnavailable?(serviceName, reason)
    }
}
