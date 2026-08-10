import AppKit
import ApplicationServices

/// Drives this Mac's playback and volume from a panel gesture.
///
/// Everything here goes through the same mechanism — a synthesised media key —
/// rather than volume taking a separate CoreAudio path. One mechanism means one
/// permission and one failure mode, instead of a preset where two of five
/// gestures keep working after the user declines a prompt. It also gets the
/// system's own volume HUD for free, which is the only feedback the user gets
/// that a swipe landed, and it moves the volume by the same step the keyboard
/// does rather than one this app invented.
///
/// Media keys are not app-directed: they go to whatever macOS considers the
/// current media app, which is what makes the panel a remote for "whatever is
/// playing" rather than for one hard-coded player.
enum MediaControl {

    enum Key: Equatable, Sendable {
        case playPause
        case nextTrack
        case previousTrack
        case volumeUp
        case volumeDown
    }

    /// Why a key could not be sent, or nil on success. A message rather than a
    /// bool because the caller surfaces it to the user, and "nothing happened"
    /// is the one outcome this feature cannot afford.
    @discardableResult
    static func send(_ key: Key) -> String? {
        guard isAuthorized else {
            return "ESPDisplaySender needs Accessibility permission to control "
                + "playback. Grant it in System Settings > Privacy & Security > "
                + "Accessibility, then try the gesture again."
        }
        // Down then up: media apps act on the press, but a key left logically
        // down is a stuck modifier as far as the window server is concerned.
        for pressed in [true, false] {
            guard let event = systemDefinedEvent(keyCode(for: key), pressed: pressed),
                  let posted = event.cgEvent
            else {
                return "macOS refused to construct the media key event."
            }
            posted.post(tap: .cghidEventTap)
        }
        return nil
    }

    /// Whether this process may post synthetic events.
    ///
    /// Worth knowing about the grant: it is tied to the signed binary, so
    /// rebuilding the app can invalidate it and macOS will then silently drop
    /// posted events rather than erroring. That is why callers report the refusal
    /// rather than assuming a gesture that does nothing means the panel is at
    /// fault.
    static var isAuthorized: Bool { AXIsProcessTrusted() }

    /// Ask macOS to show the Accessibility prompt.
    ///
    /// Only opens the prompt once per process per grant state; macOS itself
    /// decides whether to show anything, so this is safe to call from a button.
    static func requestAuthorization() {
        let option = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([option: true] as CFDictionary)
    }

    // MARK: event construction

    /// Values from IOKit's `ev_keymap.h` (`NX_KEYTYPE_*`). Spelled out because
    /// that header is not surfaced to Swift; the values are long-standing public
    /// constants that every media-key sender relies on.
    private static func keyCode(for key: Key) -> Int32 {
        switch key {
        case .volumeUp: return 0        // NX_KEYTYPE_SOUND_UP
        case .volumeDown: return 1      // NX_KEYTYPE_SOUND_DOWN
        case .playPause: return 16      // NX_KEYTYPE_PLAY
        case .nextTrack: return 17      // NX_KEYTYPE_NEXT
        case .previousTrack: return 18  // NX_KEYTYPE_PREVIOUS
        }
    }

    /// A system-defined event of subtype 8, which is how macOS represents the
    /// keys on the top row that are not really keys.
    ///
    /// The encoding is fixed by the window server: the key code goes in the high
    /// half of `data1`, the press state in the next byte, and the same state is
    /// mirrored in the modifier flags. `data2` is -1 because these events carry
    /// no second payload.
    private static func systemDefinedEvent(
        _ code: Int32, pressed: Bool
    ) -> NSEvent? {
        let state: Int = pressed ? 0x0A : 0x0B
        return NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: (Int(code) << 16) | (state << 8),
            data2: -1)
    }
}
