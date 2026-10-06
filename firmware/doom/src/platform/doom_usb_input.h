// USB keyboard and mouse input for Doom: the boundary between the TinyUSB host
// glue (doom_usb_input.cpp) and the platform layer that drives the engine
// (doomgeneric_esp32.c.inc, compiled as C).
//
// Header-only declarations, no Arduino and no TinyUSB, so it includes cleanly
// from either language. The decoding itself lives in doom_usb_input_model.h and
// is host tested; this file is only the wire.
//
// Nothing here runs outside a Doom session. Doom is entered by a one-shot
// reboot, so normal streaming never brings the USB host stack up and a board
// with nothing plugged in behaves exactly as it did before.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Bring up the USB host stack, if this carrier can host a device at all.
/// Safe and silent-ish on carriers that cannot: it logs why and returns.
/// Never fails the Doom boot -- a player with no keyboard still has touch.
void doom_usb_input_init(void);

/// Service the host stack. Cheap, non-blocking, and called from the same
/// places as doom_touch_sample() so a keystroke between two engine ticks is
/// not lost. Does nothing when the stack was never brought up.
void doom_usb_input_service(void);

/// Service once, then translate everything that arrived into engine key
/// events, pushing them through push_key(). `menu_context` is nonzero while a
/// Doom menu is open, which is what decides whether the movement letters are
/// movement or the letters themselves.
void doom_usb_input_poll(int menu_context);

/// Take the accumulated mouse movement in the engine's sense: positive x turns
/// right, positive y walks forward. Returns true when either is nonzero, and
/// clears both.
bool doom_usb_input_take_mouse(int* dx, int* dy);

/// Press every key and button a connected device is still holding.
///
/// Call this when something else has released keys that a USB device may also
/// be holding -- the touch and tilt path drops the movement keys whenever the
/// engine leaves gameplay, and they are the same engine keys. A keyboard sends
/// no report while its key set is unchanged, so without this a key held across
/// that boundary would go silently dead.
void doom_usb_input_reassert(void);

#ifdef __cplusplus
}
#endif
