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
/// The kinds of source the dropdown offers, as resting states rather than
/// actions.
///
/// The dropdown shows what a panel *is* set to. Choosing a kind that needs more
/// information opens the relevant chooser, and if the user backs out of it the
/// source never changes, so the dropdown falls back to what it was.
enum PanelSourceKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case automatic
    case display
    case window
    case region

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .display: return "Display"
        case .window: return "Window"
        case .region: return "Region"
        }
    }
}

enum PanelSource: Equatable, Sendable {
    /// Track the configured virtual display, or honour a live picker choice.
    case automatic
    case display(String)
    case window(String)
    /// A rectangle of one display, drawn with the region selector.
    case region(RegionSpec)

    init(_ spec: SourceSpec?) {
        guard let spec else {
            self = .automatic
            return
        }
        // Most specific intent wins, matching DeviceSourceConfig: a region names
        // part of one display, a window names one window, a display names a
        // whole screen.
        if let region = spec.region, !region.display.isEmpty {
            self = .region(region)
        } else if let window = spec.window, !window.isEmpty {
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
        case .region(let region): return SourceSpec(region: region)
        }
    }

    func sessionSource(defaultDisplay: String) -> DeviceSession.Source {
        switch self {
        case .automatic: return .auto(defaultDisplay: defaultDisplay)
        case .display(let name): return .display(name)
        case .window(let name): return .window(name)
        case .region(let region): return .region(region)
        }
    }

    /// The region this source captures, when it captures one.
    var region: RegionSpec? {
        guard case .region(let region) = self else { return nil }
        return region
    }

    /// Which kind of source this is, for the settings dropdown.
    ///
    /// There is no separate application kind. An application pick is *stored* as
    /// a window source - `from(_:)` records the application's name and
    /// `DisplayCapture.findWindow` matches that name - so after a restart it
    /// resolves to a single window anyway. Offering "Application" as its own
    /// choice advertised a distinction that did not survive being saved.
    var kind: PanelSourceKind {
        switch self {
        case .automatic: return .automatic
        case .display: return .display
        case .window: return .window
        case .region: return .region
        }
    }

    /// How the choice reads in the UI.
    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .display(let name): return "Display: \(name)"
        case .window(let name): return "Window: \(name)"
        case .region(let region):
            return "Region: \(region.sizeDescription) on \(region.display)"
        }
    }

    /// The ordered set of sources a swipe walks through.
    ///
    /// `.automatic` leads it deliberately. A swipe is a blunt instrument with no
    /// menu to read, so the ring has to contain a way back to the default —
    /// otherwise a stray swipe strands the panel on a source the user has to
    /// walk over to the Mac to undo.
    ///
    /// Windows and applications are not in the ring. They can only be named by
    /// the picker, and enumerating every open window as swipe targets would turn
    /// one gesture into dozens of steps.
    static func ring(displayNames: [String]) -> [PanelSource] {
        [.automatic] + displayNames.map { .display($0) }
    }

    /// The next source after `current`, wrapping at both ends.
    ///
    /// A `current` the ring does not contain — a window picked in the picker, or
    /// a display that has since been unplugged — resolves to the first entry
    /// rather than to nothing, so a swipe still does something predictable
    /// instead of appearing to be ignored.
    static func next(
        after current: PanelSource, in ring: [PanelSource], forward: Bool
    ) -> PanelSource? {
        guard !ring.isEmpty else { return nil }
        guard let index = ring.firstIndex(of: current) else { return ring[0] }
        let step = forward ? 1 : -1
        return ring[(index + step + ring.count) % ring.count]
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
    /// Returns nil when the pick cannot be identified. That is deliberately not
    /// `.automatic`: reporting a failure as "Automatic" overwrote a deliberate
    /// choice with the opposite of what the user just asked for, so the saved
    /// choice appeared not to stick and invited another attempt.
    @MainActor
    static func from(_ filter: SCContentFilter) -> PanelSource? {
        switch filter.style {
        case .display:
            guard let display = filter.includedDisplays.first,
                  let name = DisplayCapture.currentName(for: display.displayID),
                  !name.isEmpty
            else { return nil }
            return .display(name)

        case .window:
            guard let window = filter.includedWindows.first else { return nil }
            if let app = window.owningApplication?.applicationName, !app.isEmpty {
                return .window(app)
            }
            if let title = window.title, !title.isEmpty { return .window(title) }
            return nil

        case .application:
            guard let app = filter.includedApplications.first,
                  !app.applicationName.isEmpty
            else { return nil }
            return .window(app.applicationName)

        default:
            return nil
        }
    }
}
