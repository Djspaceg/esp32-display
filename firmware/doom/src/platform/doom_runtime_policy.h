// Hardware-free Doom display and touch policy.
//
// Kept C-compatible because the renderer is compiled inside the C unity build,
// while the host test suite includes the same policy from C++.
#pragma once

#include <stdbool.h>
#include <math.h>
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

// Gravity in the panel's own frame: right, down (both in the glass) and out
// of the glass, from a raw sensor sample through the board descriptor's axis
// map (Config::motionXAxis/XSign for panel-right, motionYAxis/YSign for
// panel-down; the remaining axis is out of the glass). Every IMU board's tilt
// then means the same physical tilt.
typedef struct {
    float right;
    float down;
    float out;
} doom_panel_accel_t;

static inline doom_panel_accel_t doom_panel_accel(
    int16_t x, int16_t y, int16_t z, uint8_t right_axis, int8_t right_sign,
    uint8_t down_axis, int8_t down_sign) {
    const float raw[3] = {x / 8192.0f, y / 8192.0f, z / 8192.0f};
    doom_panel_accel_t a;
    a.right = raw[right_axis % 3] * (float)right_sign;
    a.down = raw[down_axis % 3] * (float)down_sign;
    a.out = raw[3 - (right_axis % 3) - (down_axis % 3)];
    return a;
}

// Pitch and roll, in degrees, as the 1.75C's player tuned them: pitch from
// the panel-down component (the top edge tipped away is positive), roll from
// panel-right. The out-of-glass component enters as a magnitude, so a sensor
// whose third axis points into the glass (the T-Watch-S3's, mounted on the
// bottom layer) reads level face up rather than upside down.
static inline void doom_tilt_angles(doom_panel_accel_t a, float* pitch,
                                    float* roll) {
    const float out = a.out < 0 ? -a.out : a.out;
    *pitch = atan2f(-a.down, sqrtf(a.right * a.right + out * out)) * 57.2958f;
    *roll = atan2f(a.right, out) * 57.2958f;
}

// How the board is held when play starts is level: a watch worn tipped
// toward the face, or a handheld board held at an angle, stands still until
// it moves from there. Averaged over the samples doom_imu_init() takes.
typedef struct {
    float pitch_sum;
    float roll_sum;
    int samples;
} doom_tilt_neutral_t;

static inline void doom_tilt_neutral_add(doom_tilt_neutral_t* n, float pitch,
                                         float roll) {
    n->pitch_sum += pitch;
    n->roll_sum += roll;
    ++n->samples;
}

static inline void doom_tilt_relative(const doom_tilt_neutral_t* n,
                                      float* pitch, float* roll) {
    if (n->samples <= 0) return;
    *pitch -= n->pitch_sum / (float)n->samples;
    *roll -= n->roll_sum / (float)n->samples;
}

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

// BOOT's three tiers (doom_mode.cpp), for a menu key that stands in for it:
// a release under DOOM_MENU_KEY_BACK_MS is Escape (open/close the menu), one
// up to DOOM_MENU_KEY_EXIT_MS is Backspace (previous menu), and a hold that
// reaches DOOM_MENU_KEY_EXIT_MS leaves Doom while still held, so a release
// after it does nothing more. Doom's own Quit Game prompt answers only 'y',
// which no touch gesture or key here sends, so the hold is the way out.
//
// The exit is at 2 s, not BOOT's 3 s. A PMU key has a ceiling BOOT does not:
// the AXP2101 powers the board off after a 4 s hold (REG 27H). On the
// T-Watch-S3 a hold its player meant as about 3 seconds measured 2560 ms,
// and went back a menu instead of leaving; 2 s is reached by such a hold and
// leaves two seconds before the power-off.
#define DOOM_MENU_KEY_BACK_MS 600u
#define DOOM_MENU_KEY_EXIT_MS 2000u

typedef enum {
    DOOM_MENU_KEY_NONE,
    DOOM_MENU_KEY_ESCAPE,
    DOOM_MENU_KEY_BACK,
} doom_menu_key_action_t;

static inline bool doom_menu_key_exit_due(uint32_t held_ms) {
    return held_ms >= DOOM_MENU_KEY_EXIT_MS;
}

static inline doom_menu_key_action_t doom_menu_key_release_action(
    uint32_t held_ms, bool exit_fired) {
    if (exit_fired || doom_menu_key_exit_due(held_ms)) return DOOM_MENU_KEY_NONE;
    return held_ms >= DOOM_MENU_KEY_BACK_MS ? DOOM_MENU_KEY_BACK
                                            : DOOM_MENU_KEY_ESCAPE;
}
