import Foundation
import ScreenCaptureKit

/// Bridges macOS's own content picker (Control Center's screen-sharing UI)
/// into the sender, so the user chooses the video source through system UI
/// instead of CLI flags.
///
/// Why this matters: the Displays mirroring dialog ("Entire Screen" /
/// "Window or App" / "Extended Display") has no public API to observe. Two
/// of its three modes are handled natively by display resolution - Extended
/// Display leaves an independently capturable display, and Entire Screen
/// leaves a mirror-set member we can traverse to its source. But "Window or
/// App" tears the virtual display down entirely, leaving nothing to capture.
/// SCContentSharingPicker is Apple's supported equivalent: the user picks a
/// display, window, or app in system UI and we receive an SCContentFilter.
///
/// Once a stream is running with the picker active, macOS shows the
/// screen-sharing indicator in the menu bar, and the user can change the
/// shared content from there at any time - no terminal, no remembered
/// commands. `allowsChangingSelectedContent` keeps that live.
final class PickerSource: NSObject, SCContentSharingPickerObserver {
    private let lock = NSLock()
    private var _filter: SCContentFilter?
    private var _generation: UInt64 = 0

    /// Latest user selection and a generation counter. The capture loop
    /// compares generations to notice a new pick without polling system UI.
    var current: (filter: SCContentFilter, generation: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard let f = _filter else { return nil }
        return (f, _generation)
    }

    var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _generation
    }

    /// Opt in to Control Center's picker. Safe to call once at startup.
    func activate() {
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        // Let the user switch source after the first pick - this is what
        // makes the menu bar affordance useful.
        config.allowsChangingSelectedContent = true
        picker.configuration = config
        // Allow Control Center to offer the picker even before a stream
        // exists, so the user can choose a source at any time.
        picker.maximumStreamCount = 1
        picker.add(self)
        picker.isActive = true
    }

    func deactivate() {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
    }

    /// Show the picker now (used on demand, e.g. SIGUSR1, or when no source
    /// can be found automatically).
    func present() {
        SCContentSharingPicker.shared.present()
    }

    /// Forget the current selection so automatic display resolution takes
    /// over again.
    func clearSelection() {
        lock.lock()
        _filter = nil
        _generation &+= 1
        lock.unlock()
        print("picker: selection cleared - falling back to automatic display tracking")
    }

    // MARK: SCContentSharingPickerObserver

    func contentSharingPicker(
        _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        lock.lock()
        _filter = filter
        _generation &+= 1
        let gen = _generation
        lock.unlock()
        print("picker: user selected \(describe(filter)) (selection #\(gen))")
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker, didCancelFor stream: SCStream?
    ) {
        print("picker: cancelled by user")
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        FileHandle.standardError.write(
            Data("picker failed to start: \(error.localizedDescription)\n".utf8))
    }

    func describe(_ filter: SCContentFilter) -> String {
        let rect = filter.contentRect
        let dims = "\(Int(rect.width))x\(Int(rect.height))"
        switch filter.style {
        case .display: return "a display (\(dims))"
        case .window: return "a window (\(dims))"
        case .application: return "an application (\(dims))"
        default: return "content (\(dims))"
        }
    }
}
