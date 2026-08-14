// Hardware bridge between Doom Easter Egg and the existing firmware drivers.
//
// This file provides the doom_display_*, doom_imu_*, and doom_touch_*
// functions that doomgeneric_esp32s3.c calls. It reuses the board's existing
// panel, touch, and I2C infrastructure rather than re-initializing them.
//
// Only compiled for ESP32-S3 (guarded in display_stream.ino).
// MIT licensed (platform glue, not part of the GPL engine).
#if defined(CONFIG_IDF_TARGET_ESP32S3)

#include <Arduino.h>
#include <Wire.h>
#include <esp_lcd_panel_ops.h>
#include <esp_lcd_panel_io.h>

#include <board_config.h>
#include <board_touch.h>

// --- Display bridge ---
// The QSPI AMOLED (CO5300 466x466) is already initialized by the main firmware
// before Doom mode is entered. We reuse the panel handle. The panel accepts
// RGB565 big-endian pixel data via esp_lcd_panel_draw_bitmap().

// Panel handle getter defined in display_stream.ino
extern "C" esp_lcd_panel_handle_t doom_get_panel_handle(void);

void doom_display_init(void) {
    // Panel is already initialized by display_stream. AMOLED brightness is
    // via panel command 0x51 (no backlight pin). Max brightness for Doom.
    Serial.println("[doom] Display bridge ready (reusing existing panel)");
}

void doom_display_blit(const uint16_t* rgb565_buf, int width, int height) {
    esp_lcd_panel_handle_t p = doom_get_panel_handle();
    if (p) {
        esp_lcd_panel_draw_bitmap(p, 0, 0, width, height, rgb565_buf);
    }
}

// --- IMU bridge (QMI8658) ---
// The QMI8658 6-axis IMU shares the touch I2C bus (GPIO15 SDA, GPIO14 SCL).
// We read the accelerometer to get pitch/roll for movement control.

static const uint8_t QMI8658_ADDR = 0x6B;
static const uint8_t QMI8658_REG_AX_L = 0x35;  // Accelerometer X low byte
static bool imu_initialized = false;

// QMI8658 register write helper
static void qmi_write(uint8_t reg, uint8_t val) {
    Wire.beginTransmission(QMI8658_ADDR);
    Wire.write(reg);
    Wire.write(val);
    Wire.endTransmission();
}

// QMI8658 register read helper (multi-byte)
static void qmi_read(uint8_t reg, uint8_t* buf, size_t len) {
    Wire.beginTransmission(QMI8658_ADDR);
    Wire.write(reg);
    Wire.endTransmission(false);
    Wire.requestFrom(QMI8658_ADDR, (uint8_t)len);
    for (size_t i = 0; i < len && Wire.available(); i++) {
        buf[i] = Wire.read();
    }
}

void doom_imu_init(void) {
    // The I2C bus is already initialized by the touch driver.
    // Configure QMI8658 accelerometer:
    //   CTRL1 (0x02) = 0x60: address auto-increment, big-endian
    //   CTRL2 (0x03) = 0x07: accel enable, ±4g, 460Hz ODR
    //   CTRL7 (0x08) = 0x01: enable accelerometer
    qmi_write(0x02, 0x60);
    qmi_write(0x03, 0x07);  // ±4g, 460Hz
    qmi_write(0x08, 0x01);  // accel only (gyro not needed for tilt)
    delay(20);  // Let it stabilize

    imu_initialized = true;
    Serial.println("[doom] IMU (QMI8658) initialized for tilt control");
}

void doom_imu_read(float* pitch, float* roll) {
    if (!imu_initialized) {
        *pitch = 0.0f;
        *roll = 0.0f;
        return;
    }

    // Read 6 bytes: AX_L, AX_H, AY_L, AY_H, AZ_L, AZ_H
    uint8_t buf[6];
    qmi_read(QMI8658_REG_AX_L, buf, 6);

    int16_t ax = (int16_t)(buf[1] << 8 | buf[0]);
    int16_t ay = (int16_t)(buf[3] << 8 | buf[2]);
    int16_t az = (int16_t)(buf[5] << 8 | buf[4]);

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

#include "../doom/doom_mode.h"

// Touch state tracking for gesture detection
static int16_t touch_last_x = 0;
static int16_t touch_last_y = 0;
static bool touch_was_pressed = false;
static uint32_t touch_down_at = 0;
static uint32_t touch_last_tap_at = 0;

// CST9217 supports 2 touches. The existing boardtouch::poll() reads one.
// We read both points directly for Doom mode.
static const uint8_t CST9217_ADDR = 0x5A;
static const uint16_t CST9217_REG_TOUCH = 0xD000;

typedef struct {
    bool pressed;
    int16_t x, y;
} touch_point_t;

static void read_cst9217_points(touch_point_t* p1, touch_point_t* p2) {
    // Read touch data: 5-byte header + 5 bytes per point (max 2)
    uint8_t buf[15];

    Wire.beginTransmission(CST9217_ADDR);
    Wire.write((uint8_t)(CST9217_REG_TOUCH >> 8));
    Wire.write((uint8_t)(CST9217_REG_TOUCH & 0xFF));
    Wire.endTransmission(false);
    Wire.requestFrom(CST9217_ADDR, (uint8_t)15);

    for (int i = 0; i < 15 && Wire.available(); i++) {
        buf[i] = Wire.read();
    }

    // Header byte 0: report type (should be 0xAB for valid touch)
    // Header byte 5: point 1 event + x_high
    // Layout per point: [event|x_h][x_l][y_h][y_l][pressure]
    uint8_t num_points = buf[0] == 0xAB ? (buf[1] & 0x0F) : 0;

    p1->pressed = (num_points >= 1);
    p2->pressed = (num_points >= 2);

    if (p1->pressed) {
        p1->x = ((buf[5] & 0x0F) << 8) | buf[6];
        p1->y = (buf[7] << 8) | buf[8];
    } else {
        p1->x = p1->y = 0;
    }

    if (p2->pressed) {
        p2->x = ((buf[10] & 0x0F) << 8) | buf[11];
        p2->y = (buf[12] << 8) | buf[13];
    } else {
        p2->x = p2->y = 0;
    }
}

void doom_touch_init(void) {
    // Touch controller already initialized by boardtouch::init()
    touch_last_x = 0;
    touch_last_y = 0;
    touch_was_pressed = false;
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

void doom_touch_poll(doom_touch_state_t* state) {
    touch_point_t p1, p2;
    read_cst9217_points(&p1, &p2);

    state->pressed = p1.pressed;
    state->second_pressed = p2.pressed;
    state->x = p1.x;
    state->y = p1.y;

    // Compute delta
    if (p1.pressed && touch_was_pressed) {
        state->dx = p1.x - touch_last_x;
        state->dy = p1.y - touch_last_y;
    } else {
        state->dx = 0;
        state->dy = 0;
    }

    // Tap detection: press and release within 200ms, movement < 20px
    uint32_t now = millis();
    state->tap_detected = false;
    state->double_tap = false;

    if (p1.pressed && !touch_was_pressed) {
        // Finger just went down
        touch_down_at = now;
    } else if (!p1.pressed && touch_was_pressed) {
        // Finger just lifted
        uint32_t held_ms = now - touch_down_at;
        if (held_ms < 200 && abs(p1.x - touch_last_x) < 20 &&
            abs(p1.y - touch_last_y) < 20) {
            // It's a tap
            if (now - touch_last_tap_at < 400) {
                state->double_tap = true;  // Two taps within 400ms
            } else {
                state->tap_detected = true;
            }
            touch_last_tap_at = now;
        }
    }

    touch_last_x = p1.x;
    touch_last_y = p1.y;
    touch_was_pressed = p1.pressed;
}

#endif  // CONFIG_IDF_TARGET_ESP32S3
