import CoreGraphics
import Foundation

/// What the capture half of a session is doing, in terms the window can show.
///
/// Capture problems used to exist only in stderr: the stream delegate's error
/// was logged and reduced to a bare flag, and every capture-start failure was
/// a `continue` in the supervisor loop. A panel whose mirroring had broken
/// therefore looked identical to one that was working - same "Online" badge,
/// same last-seen time, because those come from device heartbeats, which keep
/// arriving whether or not any frame does. This type is the missing signal.
enum CaptureStatus: Equatable, Sendable {
    /// No stream yet: the session is still looking for something to capture.
    case waiting(String)
    /// A stream is running and frames are being sent.
    case streaming
    /// The stream went away and is being re-established.
    case recovering(String)
    /// Capture is not running, and will not be until something changes.
    case failed(String)
    /// Deliberately not capturing: the user paused it, or the panel is gone.
    case suspended(String)

    /// One line describing the state, for the preview row.
    var summary: String {
        switch self {
        case .waiting(let detail): return detail
        case .streaming: return "Streaming"
        case .recovering(let detail): return detail
        case .failed(let detail): return detail
        case .suspended(let detail): return detail
        }
    }

    /// True while frames should be reaching the panel.
    var isStreaming: Bool {
        if case .streaming = self { return true }
        return false
    }

    /// Whether this state deserves the user's attention. A recovery in
    /// progress does not: streams are restarted routinely, and flagging every
    /// restart would train the user to ignore the indicator.
    var needsAttention: Bool {
        switch self {
        case .failed: return true
        case .waiting, .streaming, .recovering, .suspended: return false
        }
    }
}

/// One frame as the panel is showing it, for the app's own preview.
///
/// Compared by sequence number rather than by pixels: the point of the
/// comparison is "is this a different frame", and comparing two 55k-pixel
/// images to answer that would cost more than drawing them.
struct PreviewFrame: Equatable {
    let image: CGImage
    let landscape: Bool
    let sequence: UInt64
    let capturedAt: Date

    static func == (lhs: PreviewFrame, rhs: PreviewFrame) -> Bool {
        lhs.sequence == rhs.sequence
    }
}

/// The live preview of one panel, published separately from `PanelSnapshot`.
///
/// Deliberately not part of the snapshot: `panels` is a published array that
/// SwiftUI diffs on every change, so putting a ten-per-second image in it
/// would redraw the whole window at that rate. Only the preview view observes
/// this object, and only the selected panel feeds it.
@MainActor
final class FramePreview: ObservableObject {
    /// The most recent frame, or nil when nothing is being captured.
    @Published private(set) var frame: PreviewFrame?
    /// Which panel `frame` belongs to, so a stale image is never shown
    /// against a newly selected panel.
    @Published private(set) var serviceName: String?

    private var sequence: UInt64 = 0

    /// Point the preview at a panel, discarding any frame from the previous
    /// one. Passing nil turns the preview off.
    func focus(on serviceName: String?) {
        guard self.serviceName != serviceName else { return }
        self.serviceName = serviceName
        frame = nil
    }

    /// Accept a frame, ignoring anything that arrives from a panel the user is
    /// no longer looking at (a session's in-flight callback can outlive a
    /// selection change).
    func accept(image: CGImage, landscape: Bool, from serviceName: String) {
        guard self.serviceName == serviceName else { return }
        sequence &+= 1
        frame = PreviewFrame(
            image: image, landscape: landscape, sequence: sequence, capturedAt: Date())
    }

    /// Drop the current image without changing which panel is focused, so the
    /// preview does not keep showing content that is no longer being sent.
    func clearFrame() {
        frame = nil
    }
}
