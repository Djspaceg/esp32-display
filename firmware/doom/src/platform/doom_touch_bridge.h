// Shared touch contract between the Doom platform layer and the hardware bridge.
//
// doomgeneric_esp32s3.c.inc (compiled as C, inside the unity build) and
// doom_hw_bridge.cpp (C++) both need the same touch-state layout and the same
// gesture vocabulary. Declaring them once here -- rather than duplicating the
// struct in each translation unit -- keeps the wire between the two halves from
// drifting as one side changes.
//
// Header-only and hardware-free: no Arduino, no I2C, so it includes cleanly from
// either language. The classification itself lives in the board library's
// touch_gesture.h/touch_map.h; this header is only the boundary type.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// One completed, discrete touch gesture, classified on release by the shared
// touchgesture::Tracker. A single press yields at most one of these. Continuous
// turning uses the live point relative to start_x/start_y, while taps use the
// tap_detected/double_tap flags; this enum carries only completed swipes.
typedef enum {
    DOOM_TOUCH_GESTURE_NONE = 0,
    DOOM_TOUCH_GESTURE_SWIPE_LEFT,
    DOOM_TOUCH_GESTURE_SWIPE_RIGHT,
    DOOM_TOUCH_GESTURE_SWIPE_UP,
    DOOM_TOUCH_GESTURE_SWIPE_DOWN,
} doom_touch_gesture_t;

// Snapshot handed from the hardware bridge to the platform input code once per
// poll. Live coordinates and the touch-down origin persist for the full contact;
// press_duration_ms is live while held and remains the completed duration on the
// release poll. Edge fields are accumulated between Doom input polls.
typedef struct {
    bool pressed;         // a finger is down as of the most recent sample
    bool second_pressed;  // a second finger is down (gameplay run modifier)
    int16_t x;            // latest mapped X (framebuffer coordinates)
    int16_t y;            // latest mapped Y (framebuffer coordinates)
    int16_t start_x;      // mapped X captured on touch-down
    int16_t start_y;      // mapped Y captured on touch-down
    uint32_t press_duration_ms;  // live or completed down-to-release age
    bool press_started;   // a new press began since the last poll
    doom_touch_gesture_t gesture;  // one completed swipe since the last poll
    bool tap_detected;    // a single tap completed (fire candidate)
    bool double_tap;      // a double tap completed (use/open)
} doom_touch_state_t;

// Bring up the CST9217 touch controller for Doom. Restarts into the normal
// firmware if the controller is unavailable, matching the one-shot isolated
// reboot architecture -- Doom never limps on with half its input.
void doom_touch_init(void);

// Drain any controller reports and fold them into the pending state: preserve
// the exact touch-down origin and timing, latch press-start, record one completed
// gesture, and update double-tap timing. Cheap when no report is waiting.
void doom_touch_sample(void);

// Sample once, then copy the accumulated state into *state and clear the pending
// edge events. Live pressed/second_pressed/x/y persist so callers can read the
// current contact after the edges are consumed.
void doom_touch_poll(doom_touch_state_t* state);

#ifdef __cplusplus
}
#endif
