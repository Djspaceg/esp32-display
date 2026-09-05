// Hardware bridge between Doom Easter Egg and the existing firmware drivers.
//
// This file provides the doom_display_*, doom_imu_*, and doom_touch_*
// functions that doomgeneric_esp32s3.c calls. It reuses the board's existing
// panel, touch, and I2C infrastructure rather than re-initializing them.
//
// The universal S3 build links this bridge, but display_stream enters it only
// after runtime detection has selected the CO5300 carrier.
#if defined(ESPDISP_DOOM_RUNTIME)

#include <Arduino.h>
#include <Wire.h>
#include <esp_lcd_panel_ops.h>
#include <esp_lcd_panel_io.h>

#include <board_config.h>
#include <board_motion.h>
#include <board_touch.h>

#include "doom_mode.h"

// The common S3 partition table intentionally fits 8 MiB carriers. On the
// 16 MiB CO5300 carrier, preserve the historical WAD region above 8 MiB and
// expose it as a read-only synthetic partition for zero-copy mapping.
extern "C" const esp_partition_t* doom_raw_wad_partition(void) {
    static const esp_partition_t partition = {
        nullptr,
        static_cast<esp_partition_type_t>(DOOM_WAD_PARTITION_TYPE),
        static_cast<esp_partition_subtype_t>(DOOM_WAD_PARTITION_SUBTYPE),
        DOOM_WAD_PARTITION_OFFSET,
        DOOM_WAD_PARTITION_BYTES,
        0x1000,
        "doom_wad",
        false,
        true,
    };
    return ESP.getFlashChipSize() >=
            DOOM_WAD_PARTITION_OFFSET + DOOM_WAD_PARTITION_BYTES
        ? &partition : nullptr;
}

// --- Display bridge ---
// The QSPI AMOLED (CO5300 466x466) is already initialized by the main firmware
// before Doom mode is entered. We reuse the panel handle. The panel accepts
// RGB565 big-endian pixel data via esp_lcd_panel_draw_bitmap().

// display_stream owns the panel completion ISR and exposes a blocking write.
// Returning only after completion is required because Doom immediately reuses
// its one scaled frame buffer, and frees the splash after this call.
extern "C" bool doom_display_blit_blocking(const uint16_t* pixels,
                                             int width, int height);

extern "C" void doom_display_init(void) {
    // Panel is already initialized by display_stream. AMOLED brightness is
    // via panel command 0x51 (no backlight pin). Max brightness for Doom.
    Serial.println("[doom] Display bridge ready (reusing existing panel)");
}

extern "C" void doom_display_blit(const uint16_t* rgb565_buf, int width, int height) {
    if (!doom_display_blit_blocking(rgb565_buf, width, height)) {
        Serial.println("[doom] FATAL: panel DMA did not complete; restarting");
        Serial.flush();
        delay(20);
        ESP.restart();
        while (true) delay(1000);
    }
}

// --- IMU bridge (QMI8658) ---
// The QMI8658 6-axis IMU shares the touch I2C bus (GPIO15 SDA, GPIO14 SCL).
// We read the accelerometer to get pitch/roll for movement control.

static bool imu_initialized = false;

extern "C" void doom_imu_init(void) {
    const board::Config& cfg = board::configFor(board::Variant::AmoledCo5300);
    if (!boardmotion::init(cfg)) {
        Serial.println("[doom] FATAL: QMI8658 unavailable; restarting normally");
        Serial.flush();
        delay(20);
        ESP.restart();
        while (true) delay(1000);
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

// --- Touch bridge (CST9217 dual-point) ---
// Extends the existing single-point touch reader to report two points and
// gesture classification for Doom input.

#include "doom_touch_bridge.h"

#include <touch_gesture.h>
#include <touch_map.h>

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
    const board::Config& cfg = board::configFor(board::Variant::AmoledCo5300);
    bool available = boardtouch::init(cfg);
    if (!available) {
        Serial.println("[doom] FATAL: CST9217 unavailable; restarting normally");
        Serial.flush();
        delay(20);
        ESP.restart();
        while (true) delay(1000);
    }
    doom_touch_reset_state();
    Serial.println("[doom] Touch bridge ready (CST9217, gesture tracker)");
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
            DOOM_TOUCH_ROTATION, touchmap::CST9217_ON_CO5300);

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
