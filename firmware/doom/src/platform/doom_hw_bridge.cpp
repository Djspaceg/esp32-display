// Hardware bridge between Doom Easter Egg and the existing firmware drivers.
//
// This file provides the doom_display_*, doom_imu_*, and doom_touch_*
// functions that doomgeneric_esp32s3.c calls. It reuses the board's existing
// panel, touch, and I2C infrastructure rather than re-initializing them.
//
// Compiled only for the exact s3-175 target.
#if defined(ESPDISP_DOOM_S3_175)

#include <Arduino.h>
#include <Wire.h>
#include <esp_lcd_panel_ops.h>
#include <esp_lcd_panel_io.h>

#include <board_config.h>
#include <board_motion.h>
#include <board_touch.h>

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
    const board::Config& cfg = board::configFor(board::COMPILED_VARIANT);
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

#include "doom_mode.h"

// Touch state tracking for gesture detection
static int16_t touch_last_x = 0;
static int16_t touch_last_y = 0;
static int16_t touch_start_x = 0;
static int16_t touch_start_y = 0;
static uint8_t touch_points = 0;
static bool touch_was_pressed = false;
static bool touch_moved = false;
static uint32_t touch_down_at = 0;
static uint32_t touch_last_tap_at = 0;

extern "C" void doom_touch_init(void) {
    // Header-only boardtouch state is translation-unit local. Initialize it
    // here, in the same translation unit that polls it, rather than from the
    // display sketch's separate copy.
    const board::Config& cfg = board::configFor(board::COMPILED_VARIANT);
    bool available = boardtouch::init(cfg);
    if (!available) {
        Serial.println("[doom] FATAL: CST9217 unavailable; restarting normally");
        Serial.flush();
        delay(20);
        ESP.restart();
        while (true) delay(1000);
    }
    touch_last_x = 0;
    touch_last_y = 0;
    touch_start_x = 0;
    touch_start_y = 0;
    touch_points = 0;
    touch_was_pressed = false;
    touch_moved = false;
    Serial.println("[doom] Touch bridge ready (CST9217, dual-point mode)");
}

// Defined in doomgeneric_esp32s3.c
typedef struct {
    bool pressed;
    bool second_pressed;
    int16_t x, y;
    int16_t dx, dy;
    bool tap_detected;
    bool double_tap;
} doom_touch_state_t;

extern "C" void doom_touch_poll(doom_touch_state_t* state) {
    state->pressed = touch_was_pressed;
    state->second_pressed = touch_points >= 2;
    state->x = touch_last_x;
    state->y = touch_last_y;
    state->dx = 0;
    state->dy = 0;
    state->tap_detected = false;
    state->double_tap = false;

    boardtouch::Sample sample = {};
    if (!boardtouch::poll(sample)) {
        return;  // no new controller report; preserve the held state
    }

    uint32_t now = millis();
    if (sample.pressed) {
        int16_t x = (int16_t)sample.rawX;
        int16_t y = (int16_t)sample.rawY;
        if (!touch_was_pressed) {
            touch_down_at = now;
            touch_start_x = x;
            touch_start_y = y;
            touch_moved = false;
        } else {
            state->dx = x - touch_last_x;
            state->dy = y - touch_last_y;
            if (abs(x - touch_start_x) >= 20 || abs(y - touch_start_y) >= 20) {
                touch_moved = true;
            }
        }
        touch_last_x = x;
        touch_last_y = y;
        touch_points = sample.points;
        touch_was_pressed = true;
        state->pressed = true;
        state->second_pressed = sample.points >= 2;
        state->x = x;
        state->y = y;
        return;
    }

    // A release report carries no coordinates. Use the accumulated movement
    // from touch-down rather than comparing a synthetic (0,0) release point.
    if (touch_was_pressed && now - touch_down_at < 200 && !touch_moved) {
        if (now - touch_last_tap_at < DOOM_DOUBLE_TAP_WINDOW_MS) {
            state->double_tap = true;
        } else {
            state->tap_detected = true;
        }
        touch_last_tap_at = now;
    }
    touch_was_pressed = false;
    touch_points = 0;
    state->pressed = false;
    state->second_pressed = false;
}

#endif  // ESPDISP_DOOM_S3_175
