import Foundation
import SenderProtocol

/// What a gesture reported by a panel should make the sender do.
///
/// Separated from the manager so the mapping can be tested without a running
/// app: the interesting part is which gesture means what, not the plumbing that
/// carries it. `nil` from `TouchAction.for(_:)` means "no action bound", which
/// is a normal outcome — the firmware classifies four swipe directions and the
/// sender is free to leave some of them unused.
enum TouchAction: Equatable {
    /// Pause a running stream, or resume a paused one. The panel keeps showing
    /// the last frame while paused, so this reads as freeze/unfreeze.
    case togglePause
    /// Move to the next or previous capture source in the ring.
    case cycleSource(forward: Bool)

    /// Both axes cycle the source, because the panel is small and reversible in
    /// software: which edge is "along" the screen depends on whether the user
    /// last flipped it to landscape, and expecting them to remember that before
    /// swiping would make the gesture feel broken half the time. Left and up
    /// advance, matching how a carousel and a list respectively move forward.
    static func `for`(_ gesture: DeviceProtocol.TouchGesture) -> TouchAction? {
        switch gesture {
        case .tap: return .togglePause
        case .swipeLeft, .swipeUp: return .cycleSource(forward: true)
        case .swipeRight, .swipeDown: return .cycleSource(forward: false)
        }
    }
}
