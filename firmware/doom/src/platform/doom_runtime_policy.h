// Hardware-free Doom display and touch policy.
//
// Kept C-compatible because the renderer is compiled inside the C unity build,
// while the host test suite includes the same policy from C++.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "doom_touch_bridge.h"

typedef struct {
    int panel_width;
    int panel_height;
    int scaled_width;
    int scaled_height;
    int x_offset;
    int y_offset;
    bool round_mask;
} doom_frame_layout_t;

typedef enum {
    DOOM_CONTROLS_IMU_TOUCH,
    DOOM_CONTROLS_TOUCH_ONLY,
} doom_control_scheme_t;

typedef enum {
    DOOM_TOUCH_ZONE_AIM,
    DOOM_TOUCH_ZONE_MOVE,
} doom_touch_zone_t;

static inline doom_frame_layout_t doom_frame_layout_for_panel(
    int panel_width, int panel_height, bool round_mask) {
    doom_frame_layout_t layout = {
        panel_width, panel_height, 0, 0, 0, 0, round_mask,
    };
    if (panel_width <= 0 || panel_height <= 0) return layout;

    layout.scaled_width = panel_width;
    layout.scaled_height = (panel_width * 200) / 320;
    if (layout.scaled_height > panel_height) {
        layout.scaled_height = panel_height;
        layout.scaled_width = (panel_height * 320) / 200;
    }
    layout.x_offset = (panel_width - layout.scaled_width) / 2;
    layout.y_offset = (panel_height - layout.scaled_height) / 2;
    return layout;
}

static inline doom_touch_zone_t doom_touch_zone_for_press(
    doom_control_scheme_t scheme, int panel_width, int start_x) {
    if (scheme == DOOM_CONTROLS_TOUCH_ONLY &&
        panel_width > 0 && start_x < panel_width / 2) {
        return DOOM_TOUCH_ZONE_MOVE;
    }
    return DOOM_TOUCH_ZONE_AIM;
}

static inline int doom_touch_axis_delta(
    int current, int origin, int deadzone, int max_magnitude) {
    const int displacement = current - origin;
    const int absolute = displacement < 0 ? -displacement : displacement;
    if (absolute <= deadzone) return 0;
    int magnitude = absolute - deadzone;
    if (magnitude > max_magnitude) magnitude = max_magnitude;
    return displacement < 0 ? -magnitude : magnitude;
}

// Tilt walking on IMU boards, from doom_imu_read()'s pitch and roll in
// degrees. Each axis has a dead band either side of level; past it the board
// walks or strafes for as long as it stays tilted. A positive pitch walks
// forward: the opposite sign walked forward until the 1.75-inch round's player
// reported walking as backwards. Sideways tilt was not reported and keeps its
// sign.
#define DOOM_TILT_WALK_DEG    12.0f
#define DOOM_TILT_STRAFE_DEG  15.0f

typedef struct {
    bool forward;
    bool back;
    bool left;
    bool right;
} doom_tilt_move_t;

static inline doom_tilt_move_t doom_tilt_movement(float pitch, float roll) {
    doom_tilt_move_t move;
    move.forward = pitch > DOOM_TILT_WALK_DEG;
    move.back = pitch < -DOOM_TILT_WALK_DEG;
    move.left = roll < -DOOM_TILT_STRAFE_DEG;
    move.right = roll > DOOM_TILT_STRAFE_DEG;
    return move;
}

// What a completed swipe in the aim zone does during play: up is the next
// weapon, down is Use (the Space key: open a door, press a switch). Only a
// quick swipe counts: a press held longer than max_ms is a deliberate joystick
// hold, and the vertical drift of its release must not become an action.
typedef enum {
    DOOM_GAMEPLAY_SWIPE_NONE,
    DOOM_GAMEPLAY_SWIPE_NEXT_WEAPON,
    DOOM_GAMEPLAY_SWIPE_USE,
} doom_gameplay_swipe_t;

static inline doom_gameplay_swipe_t doom_gameplay_swipe_action(
    doom_touch_gesture_t gesture, uint32_t press_duration_ms,
    uint32_t max_ms) {
    if (press_duration_ms > max_ms) return DOOM_GAMEPLAY_SWIPE_NONE;
    if (gesture == DOOM_TOUCH_GESTURE_SWIPE_UP) {
        return DOOM_GAMEPLAY_SWIPE_NEXT_WEAPON;
    }
    if (gesture == DOOM_TOUCH_GESTURE_SWIPE_DOWN) {
        return DOOM_GAMEPLAY_SWIPE_USE;
    }
    return DOOM_GAMEPLAY_SWIPE_NONE;
}

// The power key as Doom sees it, folded from one poll of the PMU's latched
// interrupt bits. Doom holds Fire for as long as held is true.
typedef struct {
    bool held;    // the key is down as of the latest poll
    bool served;  // this press has already held Fire or been given its shot
} doom_power_key_t;

// One poll's worth of the PMU's latched PWR key bits.
typedef struct {
    bool down;         // negative edge: the key went down
    bool up;           // positive edge: the key came back up
    bool short_press;  // a press shorter than the long-press time has ended
    bool long_press;   // the key has been held past the long-press time
} doom_power_key_bits_t;

// Fold one poll's bits into *key. Returns true when a press began and ended
// without Fire ever being held for it, so the caller still fires once.
//
// The PMU latches every edge, so none is lost between polls (about 28 ms
// apart, far quicker than a finger can let go and press again), but their
// order inside one poll is not kept. The rules lean on that, and are chosen so
// that switch bounce, a short-press bit that lands a poll late, or edges whose
// polarity is the reverse of their register names can never leave Fire held
// after the key is let go:
//   - any edge while held is a release (both at once is a bouncy release; a
//     lone down edge can only be a release whose polarity is reversed);
//   - a down edge while up starts a press, and both at once while up is a
//     whole press the poll missed the middle of;
//   - a completed short press means the key is up;
//   - a long press with no edge beside it means the key is down.
static inline bool doom_power_key_step(doom_power_key_t* key,
                                       doom_power_key_bits_t bits) {
    const bool was_held = key->held;
    if (bits.down && !was_held) key->served = false;  // a new press begins
    if (was_held) {
        if (bits.down || bits.up) key->held = false;
    } else if (bits.down && !bits.up) {
        key->held = true;
    }
    if (bits.long_press && !bits.down && !bits.up) key->held = true;
    if (bits.short_press) key->held = false;

    const bool whole_press_missed = bits.down && bits.up && !was_held;
    const bool fire_once = !key->served && !key->held &&
                           (bits.short_press || whole_press_missed);
    if (key->held || fire_once) key->served = true;
    // The short-press bit closes its press, so the next one starts unserved
    // even if its own down edge reads the other way round.
    if (bits.short_press && !key->held) key->served = false;
    return fire_once;
}

// Where the PWR key is the menu key rather than Fire (a carrier some of whose
// units have no BOOT key): whether the poll just folded by doom_power_key_step
// ended a press, given whether the key was held before it and what the step
// returned. One press is one Escape: its release, or a whole press that came
// and went between two polls; a short-press bit landing a poll after the
// release is not a second press, because the hold already served it.
static inline bool doom_power_key_press_ended(bool was_held,
                                              const doom_power_key_t* key,
                                              bool missed_press) {
    return (was_held && !key->held) || missed_press;
}
