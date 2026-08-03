import Foundation
import ScreenCaptureKit
import SenderProtocol

/// What a panel should show, in a form that survives a restart.
///
/// An `SCContentFilter` cannot be serialised: it holds references to live
/// window and display objects that will not exist next launch, and their IDs are
/// reissued anyway. What can be stored is the user's *intent* — a named
/// display, or a window belonging to a named application — which is then
/// re-resolved against whatever is on screen at the time. That is exactly what
/// the hand-written `devices.json` entries have always expressed, so this maps
/// onto `SourceSpec` and reuses the resolution machinery already in place.
enum PanelSource: Equatable, Sendable {
    /// Track the configured virtual display, or honour a live picker choice.
    case automatic
    case display(String)
    case window(String)

    init(_ spec: SourceSpec?) {
        guard let spec else {
            self = .automatic
            return
        }
        // Window wins when both are set, matching DeviceSourceConfig: it is
        // the more specific intent.
        if let window = spec.window, !window.isEmpty {
            self = .window(window)
        } else if let display = spec.display, !display.isEmpty {
            self = .display(display)
        } else {
            self = .automatic
        }
    }

    /// The persisted form, or nil for automatic, which is the default and so
    /// needs no record.
    var spec: SourceSpec? {
        switch self {
        case .automatic: return nil
        case .display(let name): return SourceSpec(display: name)
        case .window(let name): return SourceSpec(window: name)
        }
    }

    func sessionSource(defaultDisplay: String) -> DeviceSession.Source {
        switch self {
        case .automatic: return .auto(defaultDisplay: defaultDisplay)
        case .display(let name): return .display(name)
        case .window(let name): return .window(name)
        }
    }

    /// How the choice reads in the UI.
    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .display(let name): return "Display: \(name)"
        case .window(let name): return "Window: \(name)"
        }
    }

    /// Derive a storable source from a picker selection.
    ///
    /// For windows the owning application's name is preferred over the window
    /// title, because titles are not stable identifiers: a document window is
    /// renamed by opening a document and a browser window by following a link,
    /// so a stored title usually matches nothing on the next launch.
    /// `DisplayCapture.findWindow` matches either, and the application name
    /// still resolves after the window has been retitled.
    ///
    /// The accessors that reveal what a filter points at arrived in macOS 15.2.
    /// Below that a picker choice still applies to the running session; it just
    /// cannot be stored, because nothing in the filter identifies it.
    @MainActor
    static func from(_ filter: SCContentFilter) -> PanelSource {
        guard #available(macOS 15.2, *) else { return .automatic }
        switch filter.style {
        case .display:
            guard let display = filter.includedDisplays.first,
                  let name = DisplayCapture.currentName(for: display.displayID),
                  !name.isEmpty
            else { return .automatic }
            return .display(name)

        case .window:
            guard let window = filter.includedWindows.first else { return .automatic }
            if let app = window.owningApplication?.applicationName, !app.isEmpty {
                return .window(app)
            }
            if let title = window.title, !title.isEmpty { return .window(title) }
            return .automatic

        case .application:
            guard let app = filter.includedApplications.first,
                  !app.applicationName.isEmpty
            else { return .automatic }
            return .window(app.applicationName)

        default:
            return .automatic
        }
    }
}
