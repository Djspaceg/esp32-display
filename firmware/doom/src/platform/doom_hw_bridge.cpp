// Hardware bridge between Doom and the existing firmware drivers.
//
// This file provides the doom_display_*, doom_imu_*, and doom_touch_*
// functions that the doomgeneric platform calls. It reuses the board's existing
// panel, touch, and I2C infrastructure rather than re-initializing them.
#if defined(ESPDISP_DOOM_RUNTIME)

#include <Arduino.h>
#include <Wire.h>
#include <stdarg.h>
#include <stdio.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <esp_lcd_panel_ops.h>
#include <esp_lcd_panel_io.h>

#include <board_config.h>
#include <board_motion.h>
#include <board_power.h>
#include <board_touch.h>
#include <touch_gesture.h>
#include <touch_map.h>

#include "doom_mode.h"
#include "doom_log.h"
#include "doom_runtime_policy.h"

// Settled by display_stream before Doom is entered.
extern const board::Config* bcfg;
extern int16_t PANEL_W;
extern int16_t PANEL_H;

// --- Serial diagnostics (doom_log.h) ---
// A static line buffer rather than a stack one: these run on loopTask during
// the stage whose stack margin they report. Every caller is on loopTask.
static char s_log_line[256];

extern "C" void doom_log(const char* format, ...) {
    va_list args;
    va_start(args, format);
    vsnprintf(s_log_line, sizeof(s_log_line), format, args);
    va_end(args);
    Serial.print("[doom] ");
    Serial.println(s_log_line);
    // A panic or reset can follow any of these lines; do not leave the last
    // one in the TX buffer.
    Serial.flush();
}

// The saved-games store's lines (save_store.c.inc), from the Doom loop or the
// Quake task; one at a time, as only one game runs a boot.
extern "C" void save_store_log_line(const char* line) {
    Serial.print("[save] ");
    Serial.println(line);
    Serial.flush();
}

extern "C" void doom_log_stage(const char* stage) {
    // ESP-IDF reports the high-water mark in bytes.
    doom_log("stage %s: %s stack min free %u bytes", stage,
             pcTaskGetName(NULL), (unsigned)uxTaskGetStackHighWaterMark(NULL));
}

// --- Display bridge ---
// The selected panel is already initialized by display_stream. Frame submission
// remains behind its boarddisplay facade so P4 uses the existing MIPI DSI path.

// display_stream owns the panel completion ISR and exposes a blocking write.
// Returning only after completion is required because Doom immediately reuses
// its one scaled frame buffer, and frees the splash after this call.
extern "C" bool doom_display_blit_blocking(const uint16_t* pixels,
                                             int width, int height);

extern "C" void doom_display_init(void) {
    Serial.println("[doom] Display bridge ready (reusing existing panel)");
}

extern "C" int doom_display_width(void) {
    return PANEL_W;
}

extern "C" int doom_display_height(void) {
    return PANEL_H;
}

extern "C" bool doom_display_round(void) {
    return bcfg != nullptr && bcfg->panel != nullptr &&
           bcfg->panel->roundDisplay;
}

extern "C" bool doom_motion_available(void) {
    return bcfg != nullptr && bcfg->hasMotion();
}

extern "C" int doom_boot_pin(void) {
    return bcfg != nullptr ? bcfg->pinBootButton : board::NO_PIN;
}

extern "C" void doom_display_blit(const uint16_t* rgb565_buf, int width, int height) {
    if (!doom_display_blit_blocking(rgb565_buf, width, height)) {
        // The panel is what failed, so the reason goes to Serial only.
        doom_fail_restart("panel DMA did not complete", false);
    }
}

// --- IMU bridge (QMI8658) ---
// The QMI8658 6-axis IMU shares the touch I2C bus (GPIO15 SDA, GPIO14 SCL).
// We read the accelerometer to get pitch/roll for movement control.

static bool imu_initialized = false;

extern "C" void doom_imu_init(void) {
    if (!doom_motion_available()) {
        imu_initialized = false;
        Serial.println("[doom] No IMU; touch-only movement enabled");
        return;
    }
    if (!boardmotion::init(*bcfg)) {
        doom_fail_restart("QMI8658 motion sensor unavailable", true);
    }
    imu_initialized = true;
    Serial.println("[doom] IMU ready for tilt control");
}

extern "C" void doom_imu_read(float* pitch, float* roll) {
    if (!imu_initialized) {
        *pitch = 0.0f;
        *roll = 0.0f;
        return;
    }

    boardmotion::Sample sample = {};
    if (!boardmotion::read(sample)) {
        *pitch = 0.0f;
        *roll = 0.0f;
        return;
    }

    int16_t ax = sample.x;
    int16_t ay = sample.y;
    int16_t az = sample.z;

    // Convert to g (±4g range, 16-bit signed -> 8192 LSB/g)
    float fax = ax / 8192.0f;
    float fay = ay / 8192.0f;
    float faz = az / 8192.0f;

    // Compute pitch and roll from accelerometer (degrees)
    // pitch = rotation about X axis (nose up/down)
    // roll = rotation about Y axis (lean left/right)
    *pitch = atan2f(-fax, sqrtf(fay * fay + faz * faz)) * 57.2958f;
    *roll = atan2f(fay, faz) * 57.2958f;
}

// --- PWR key bridge (AXP2101) ---
// The 1.75C's large side button is the PMU's PWR key. Doom boots before the
// normal firmware brings the PMU up, so it is brought up here, on the bus touch
// has already started, and polled from Doom's own input phase. Every other
// board has no AXP2101 and gets nothing from these. The PMU's own long-hold
// power off is untouched; the boot log line from boardpower::init() says after
// how long it acts.

static bool s_power_key_available = false;

extern "C" bool doom_power_key_present(void) {
    return bcfg != nullptr &&
           bcfg->power == board::PowerController::Axp2101;
}

// On a carrier some of whose units have no BOOT key (the T-Watch-S3), the PWR
// key is the only key there is, so it opens and closes the menu as BOOT's
// short press does, and touch alone fires.
extern "C" bool doom_power_key_is_menu(void) {
    return doom_power_key_present() && bcfg->bootButtonOptional;
}

extern "C" bool doom_power_key_init(void) {
    s_power_key_available =
        doom_power_key_present() && boardpower::init(*bcfg);
    if (doom_power_key_present() && !s_power_key_available) {
        // Not fatal: the button is an extra, and touch still fires.
        Serial.println("[doom] PWR key unavailable; touch fire only");
    }
    if (s_power_key_available) {
        // Said after bring-up, from the PMU's own registers, so the warning
        // is this board's real hold time rather than a remembered default.
        int offSeconds = 0;
        const char* action = nullptr;
        const char* role = doom_power_key_is_menu()
                               ? "PWR key press  = Escape (open/close menu)"
                               : "PWR key held   = Shoot";
        if (boardpower::powerKeyHold(offSeconds, action)) {
            doom_log("  %s (a %d s hold: %s)", role, offSeconds, action);
        } else {
            doom_log("  %s", role);
        }
    }
    return s_power_key_available;
}

extern "C" bool doom_power_key_read(doom_power_key_bits_t* bits) {
    if (!s_power_key_available) return false;
    axp2101::PowerKeyEvents events;
    if (!boardpower::powerKeyEvents(events)) return false;
    bits->down = events.down;
    bits->up = events.up;
    bits->short_press = events.shortPress;
    bits->long_press = events.longPress;
    return true;
}

// --- Touch bridge ---
// Consumes the selected boardtouch controller and keeps gesture classification
// outside the engine.

#include "doom_touch_bridge.h"

// Doom runs at one fixed panel orientation regardless of what macOS would ask
// for during normal streaming: portrait-upright, no mounting rotation. The
// gesture tracker and the coordinate transform below are both pinned to it, so
// "swipe up" means up as the player sees the round panel.
static const bool DOOM_TOUCH_LANDSCAPE = false;
static const uint8_t DOOM_TOUCH_ROTATION = 0;

// One finger's presses, classified into taps and swipes on framebuffer
// coordinates. Shared with the C6/normal-firmware touch path, so Doom and the
// streaming panel agree on what a swipe is.
static touchgesture::Tracker s_tracker;
static touchmap::Calibration s_touch_calibration =
    touchmap::CST9217_ON_CO5300;

// Live contact state, surfaced to the platform layer on every poll.
static bool s_pressed = false;
static bool s_second_held = false;
static int16_t s_cur_x = 0;
static int16_t s_cur_y = 0;

// Exact origin and timing of the current/most recently completed press. Doom
// samples touch throughout rendering, so these live in the bridge where a fast
// down/move/release cannot lose its origin before the next engine input poll.
static int16_t s_start_x = 0;
static int16_t s_start_y = 0;
static uint32_t s_touch_down_ms = 0;
static uint32_t s_last_press_duration_ms = 0;

// Double-tap timing: a Tap arriving within DOOM_DOUBLE_TAP_WINDOW_MS of the
// previous one is the second half of a double-tap rather than a new single tap.
static uint32_t s_last_tap_ms = 0;

// Pending edge events, accumulated by doom_touch_sample() and drained by
// doom_touch_poll().
static bool s_pending_press_started = false;
static doom_touch_gesture_t s_pending_gesture = DOOM_TOUCH_GESTURE_NONE;
static bool s_pending_tap = false;
static bool s_pending_double_tap = false;

static doom_touch_gesture_t doom_map_swipe(touchgesture::Gesture g) {
    switch (g) {
        case touchgesture::Gesture::SwipeLeft:
            return DOOM_TOUCH_GESTURE_SWIPE_LEFT;
        case touchgesture::Gesture::SwipeRight:
            return DOOM_TOUCH_GESTURE_SWIPE_RIGHT;
        case touchgesture::Gesture::SwipeUp:
            return DOOM_TOUCH_GESTURE_SWIPE_UP;
        case touchgesture::Gesture::SwipeDown:
            return DOOM_TOUCH_GESTURE_SWIPE_DOWN;
        default:
            return DOOM_TOUCH_GESTURE_NONE;
    }
}

static void doom_touch_reset_state(void) {
    s_tracker.reset();
    s_pressed = false;
    s_second_held = false;
    s_cur_x = 0;
    s_cur_y = 0;
    s_start_x = 0;
    s_start_y = 0;
    s_touch_down_ms = 0;
    s_last_press_duration_ms = 0;
    s_last_tap_ms = 0;
    s_pending_press_started = false;
    s_pending_gesture = DOOM_TOUCH_GESTURE_NONE;
    s_pending_tap = false;
    s_pending_double_tap = false;
}

extern "C" void doom_touch_init(void) {
    // Doom owns the controller for its isolated reboot session; initialize the
    // shared boardtouch state before any Doom input sampling begins.
    if (bcfg == nullptr) {
        doom_fail_restart("board profile unavailable", false);
    }
    s_touch_calibration = bcfg->variant == board::Variant::P4_4B
        ? touchmap::GT911_ON_ST7703_4B
        : bcfg->variant == board::Variant::P4_4C
        ? touchmap::GT911_ON_JD9365_4C
        : bcfg->variant == board::Variant::P4_34C
        ? touchmap::GT911_ON_JD9365_34C
        : bcfg->variant == board::Variant::LilygoTwatchS3
        ? touchmap::FT6336_ON_TWATCH_S3
        : touchmap::CST9217_ON_CO5300;
    bool available = boardtouch::init(*bcfg);
    if (!available) {
        doom_fail_restart("touch unavailable", true);
    }
    doom_touch_reset_state();
    Serial.println("[doom] Touch bridge ready (boardtouch, gesture tracker)");
}

extern "C" void doom_touch_sample(void) {
    // Consume at most one mailbox report per call. Doom invokes this throughout
    // scaling, frame pacing, DMA waits, and input polling, so another report is
    // serviced within a few milliseconds. One-at-a-time also bounds this call
    // when the active-low INT level fallback is recovering an ACK failure.
    boardtouch::Sample sample = {};
    if (boardtouch::poll(sample)) {
        const bool wasPressed = s_pressed;
        const uint32_t now = millis();
        const touchmap::Point p = touchmap::map(
            (int16_t)sample.rawX, (int16_t)sample.rawY, DOOM_TOUCH_LANDSCAPE,
            DOOM_TOUCH_ROTATION, s_touch_calibration);

        const touchgesture::Event ev =
            s_tracker.onReport(sample.pressed, p.x, p.y, now);

        if (sample.pressed) {
            if (ev.pressStarted) {
                s_pending_press_started = true;
                s_start_x = ev.startX;
                s_start_y = ev.startY;
                s_touch_down_ms = now;
                s_last_press_duration_ms = 0;
            }
            s_cur_x = p.x;
            s_cur_y = p.y;
            s_pressed = true;
            s_second_held = sample.points >= 2;
        } else {
            // A release report carries no coordinates; retain the last mapped
            // position and the completed duration for the engine's release poll.
            if (wasPressed) {
                s_last_press_duration_ms = now - s_touch_down_ms;
            }
            s_pressed = false;
            s_second_held = false;
        }

        if (ev.gesture == touchgesture::Gesture::Tap) {
            if (s_last_tap_ms != 0 &&
                (uint32_t)(now - s_last_tap_ms) < DOOM_DOUBLE_TAP_WINDOW_MS) {
                // Second tap inside the window: this is a double-tap, and the
                // single-fire the first tap may have scheduled must be cancelled
                // rather than fired. The C side reads double_tap and drops its
                // pending fire. Clear the clock so a third tap starts a new pair.
                s_pending_double_tap = true;
                s_pending_tap = false;
                s_last_tap_ms = 0;
            } else {
                s_pending_tap = true;
                s_last_tap_ms = now;
            }
        } else if (ev.gesture != touchgesture::Gesture::None) {
            // A swipe (or any non-tap classification) is not a tap; keep only
            // the latest completed swipe for dispatch.
            s_pending_gesture = doom_map_swipe(ev.gesture);
        }

    }
}

extern "C" void doom_touch_poll(doom_touch_state_t* state) {
    doom_touch_sample();

    state->pressed = s_pressed;
    state->second_pressed = s_second_held;
    state->x = s_cur_x;
    state->y = s_cur_y;
    state->start_x = s_start_x;
    state->start_y = s_start_y;
    state->press_duration_ms = s_pressed
        ? (uint32_t)(millis() - s_touch_down_ms)
        : s_last_press_duration_ms;
    state->press_started = s_pending_press_started;
    state->gesture = s_pending_gesture;
    state->tap_detected = s_pending_tap;
    state->double_tap = s_pending_double_tap;

    // Consume edge events; live contact/origin/timing state persists.
    s_pending_press_started = false;
    s_pending_gesture = DOOM_TOUCH_GESTURE_NONE;
    s_pending_tap = false;
    s_pending_double_tap = false;
}

#endif  // ESPDISP_DOOM_RUNTIME
