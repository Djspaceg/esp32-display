import Foundation
import SenderProtocol

/// A named set of gesture bindings, chosen per panel.
///
/// Presets exist because one fixed mapping cannot serve a panel that is
/// sometimes a source switcher and sometimes a media remote. They also make the
/// meaning of a gesture contextual, which is what frees the tap: it can freeze
/// the stream under one preset and play music under another without either
/// binding being a compromise.
enum GesturePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    /// What the panel did before presets existed, and still the default: a tap
    /// freezes the stream, a swipe walks the source ring.
    case sourceCycling
    case multimedia
    case windowCycling

    static let standard: GesturePreset = .sourceCycling

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sourceCycling: return "Source cycling"
        case .multimedia: return "Multimedia"
        case .windowCycling: return "Window cycling"
        }
    }

    /// One line for the dropdown's footer, describing the preset's purpose
    /// rather than its bindings — the help readout covers those.
    var summary: String {
        switch self {
        case .sourceCycling:
            return "Freeze what the panel is showing, or step through the screens "
                + "it can mirror."
        case .multimedia:
            return "Use the panel as a media remote for whatever is playing on "
                + "this Mac."
        case .windowCycling:
            return "Step the panel through open windows, and hold to go back to "
                + "the whole screen."
        }
    }

    /// Whether this preset binds a long press, and so needs firmware that
    /// reports one. Derived from the bindings rather than stated separately, so
    /// it cannot disagree with them.
    var usesLongPress: Bool {
        // Orientation is irrelevant to a press, so either value answers this.
        TouchAction.action(for: .longPress, preset: self, landscape: false) != nil
    }
}

/// Which of the panel's two axes a swipe ran along.
///
/// The panel is 172x320, so its long axis is vertical in portrait and horizontal
/// in landscape. Resolving this on the Mac is possible because the firmware
/// reports swipe directions in screen space and flags the orientation on every
/// gesture — the user never has to remember which way the panel is facing.
enum SwipeAxis: Equatable, Sendable {
    case long
    case short
}

/// A swipe, reduced to the two things a binding cares about.
struct SwipeVector: Equatable, Sendable {
    let axis: SwipeAxis
    /// Up or right: the direction that reads as "more of something".
    let towardsIncrease: Bool
    /// Up or left: the direction that reads as "forward through a sequence",
    /// matching how a list and a carousel respectively advance.
    ///
    /// Both senses are carried because they only agree on the vertical axis. A
    /// swipe right is more volume but not a step forward, and collapsing the two
    /// would force one of volume or track order to run backwards.
    let towardsNext: Bool
}

/// What a gesture reported by a panel should make the sender do.
///
/// Separated from the manager so the mapping can be tested without a running
/// app: the interesting part is which gesture means what, not the plumbing that
/// carries it. `nil` from `action(for:preset:landscape:)` means "not bound in
/// this preset", which is a normal outcome — the help readout lists exactly what
/// is bound, so an unbound gesture is visible rather than mysterious.
enum TouchAction: Equatable, Sendable {
    /// Pause a running stream, or resume a paused one. The panel keeps showing
    /// the last frame while paused, so this reads as freeze/unfreeze.
    case togglePause
    /// Move to the next or previous capture source in the ring.
    case cycleSource(forward: Bool)
    case mediaPlayPause
    case volume(up: Bool)
    case track(next: Bool)
    /// Step through the windows currently on screen.
    case cycleWindow(forward: Bool)
    /// Abandon a window pick and show the whole screen again.
    case showFullDisplay

    /// How this action reads in the help readout. Phrased as an effect, because
    /// the row already names the gesture.
    var summary: String {
        switch self {
        case .togglePause: return "Freeze or resume the picture"
        case .cycleSource(let forward):
            return forward ? "Next screen" : "Previous screen"
        case .mediaPlayPause: return "Play or pause"
        case .volume(let up): return up ? "Volume up" : "Volume down"
        case .track(let next): return next ? "Next track" : "Previous track"
        case .cycleWindow(let forward):
            return forward ? "Next window" : "Previous window"
        case .showFullDisplay: return "Back to the whole screen"
        }
    }

    /// Reduce a swipe to its axis and direction, or nil for gestures that are
    /// not swipes.
    ///
    /// In portrait the framebuffer is 172x320, so up and down run along the long
    /// axis; in landscape it is 320x172 and left and right do. The firmware has
    /// already folded the rotation and the 180 flip into the reported direction,
    /// so "up" here means up as the user sees it.
    ///
    /// QUARTER-TURN ROTATION CHANGES NOTHING HERE, verified against the
    /// firmware's touch_map.h rather than assumed: the panel classifies
    /// gestures on frame coordinates that went through the same quadrant
    /// transform as the pixels (touchmap composes rotation + landscape exactly
    /// as MADCTL does), so a swipe direction always means the direction the
    /// user's finger moved across whatever image they were looking at — the
    /// directions simply rotate with the panel. And the long/short axis split
    /// this function makes is only a real distinction on rectangular panels,
    /// which never rotate by a quarter (rotation 1/3 is gated to square glass,
    /// where both axes are the same length and the split is nominal but
    /// consistent on both ends). So no rotation parameter is needed, and
    /// adding one would imply a dependency that does not exist.
    static func vector(
        of gesture: DeviceProtocol.TouchGesture, landscape: Bool
    ) -> SwipeVector? {
        switch gesture {
        case .tap, .longPress:
            return nil
        case .swipeUp:
            return SwipeVector(
                axis: landscape ? .short : .long,
                towardsIncrease: true, towardsNext: true)
        case .swipeDown:
            return SwipeVector(
                axis: landscape ? .short : .long,
                towardsIncrease: false, towardsNext: false)
        case .swipeRight:
            return SwipeVector(
                axis: landscape ? .long : .short,
                towardsIncrease: true, towardsNext: false)
        case .swipeLeft:
            return SwipeVector(
                axis: landscape ? .long : .short,
                towardsIncrease: false, towardsNext: true)
        }
    }

    /// The single authority on which gesture does what. The help readout is
    /// generated by asking this, so what the panel is documented to do and what
    /// it actually does cannot drift apart.
    static func action(
        for gesture: DeviceProtocol.TouchGesture,
        preset: GesturePreset,
        landscape: Bool
    ) -> TouchAction? {
        switch preset {
        case .sourceCycling:
            // Deliberately axis-blind, preserving the original behaviour: every
            // swipe cycles, with left and up advancing. A source switcher has
            // nothing to gain from telling the axes apart.
            if gesture == .tap { return .togglePause }
            guard let vector = vector(of: gesture, landscape: landscape) else {
                return nil
            }
            return .cycleSource(forward: vector.towardsNext)

        case .multimedia:
            if gesture == .tap { return .mediaPlayPause }
            guard let vector = vector(of: gesture, landscape: landscape) else {
                return nil
            }
            // Volume gets the long axis because it is the axis with room for a
            // deliberate, gradual gesture; track skipping is discrete and suits
            // the short one.
            return vector.axis == .long
                ? .volume(up: vector.towardsIncrease)
                : .track(next: vector.towardsNext)

        case .windowCycling:
            if gesture == .longPress { return .showFullDisplay }
            guard let vector = vector(of: gesture, landscape: landscape),
                  vector.axis == .long
            else { return nil }
            return .cycleWindow(forward: vector.towardsNext)
        }
    }

    /// The gestures a preset binds, in the order they should be presented: the
    /// two presses first, then each swipe axis as a pair, long axis first.
    ///
    /// Ordering by axis is what makes the grouping legible — the two rows that
    /// do the same job to different degrees end up adjacent.
    static func gestureOrder(landscape: Bool) -> [DeviceProtocol.TouchGesture] {
        let longAxis: [DeviceProtocol.TouchGesture] =
            landscape ? [.swipeRight, .swipeLeft] : [.swipeUp, .swipeDown]
        let shortAxis: [DeviceProtocol.TouchGesture] =
            landscape ? [.swipeUp, .swipeDown] : [.swipeRight, .swipeLeft]
        return [.tap, .longPress] + longAxis + shortAxis
    }
}

/// One line of the help readout under the preset dropdown.
struct GestureHelpRow: Identifiable, Equatable {
    /// The gesture, as an instruction: "Swipe up".
    let gesture: String
    /// What it does: "Volume up".
    let effect: String

    var id: String { gesture }
}

extension GestureHelpRow {
    /// How a gesture reads as an instruction.
    ///
    /// Orientation-independent on purpose. "Swipe up" means up as the user sees
    /// it whichever way the panel is turned, because the firmware corrects the
    /// direction before reporting it. What the orientation changes is which
    /// action a swipe lands on, and that is the resolver's job — so the labels
    /// stay fixed while the readout's *pairings* follow the panel.
    static func label(for gesture: DeviceProtocol.TouchGesture) -> String {
        switch gesture {
        case .tap: return "Tap"
        case .longPress: return "Press and hold"
        case .swipeUp: return "Swipe up"
        case .swipeDown: return "Swipe down"
        case .swipeLeft: return "Swipe left"
        case .swipeRight: return "Swipe right"
        }
    }

    /// Every binding a preset has, for the orientation the panel is in.
    ///
    /// Generated from `TouchAction.action(for:preset:landscape:)` rather than
    /// written out beside it, so the readout is a description of the real
    /// behaviour instead of a second copy that can fall behind it. Unbound
    /// gestures are simply absent.
    static func rows(
        for preset: GesturePreset, landscape: Bool
    ) -> [GestureHelpRow] {
        TouchAction.gestureOrder(landscape: landscape).compactMap { gesture in
            guard let action = TouchAction.action(
                for: gesture, preset: preset, landscape: landscape)
            else { return nil }
            return GestureHelpRow(
                gesture: label(for: gesture), effect: action.summary)
        }
    }
}
