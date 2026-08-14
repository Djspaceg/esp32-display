// doomgeneric platform implementation for ESP32-S3-Touch-AMOLED-1.75C
//
// Implements the 5 required doomgeneric functions:
//   DG_Init       - init display in Doom resolution, init IMU, init touch
//   DG_DrawFrame  - scale 320x200 -> 466x466 with round mask, QSPI DMA blit
//   DG_SleepMs    - FreeRTOS vTaskDelay
//   DG_GetTicksMs - esp_timer microseconds / 1000
//   DG_GetKey     - IMU tilt -> WASD, touch drag -> turn, tap -> fire
//
// WAD access: memory-mapped from flash partition (zero-copy reads).
// Display: CO5300 466x466 round AMOLED over QSPI, same panel as normal firmware.
//
// GPL-2.0 (inherits from doomgeneric/id Software Doom source)
#include "doomgeneric.h"
#include "doomkeys.h"
#include "doom_mode.h"

#include <string.h>
#include <esp_timer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <esp_partition.h>
#include <esp_log.h>

// Forward declarations for board-specific drivers (implemented in the
// main firmware's libraries -- we link against them)
extern void doom_display_init(void);
extern void doom_display_blit(const uint16_t* rgb565_buf, int width, int height);
extern void doom_imu_init(void);
extern void doom_imu_read(float* pitch, float* roll);  // degrees
extern void doom_touch_init(void);

// Touch state from the CST9217 reader
typedef struct {
    bool pressed;          // any finger down
    bool second_pressed;   // second finger down (run modifier)
    int16_t x, y;          // primary touch point (0-465)
    int16_t dx, dy;        // delta since last frame
    bool tap_detected;     // short tap this frame
    bool double_tap;       // double-tap this frame
} doom_touch_state_t;

extern void doom_touch_poll(doom_touch_state_t* state);

static const char* TAG = "doom";

// --- Screen buffer ---
// doomgeneric renders at DOOM_RENDER_WIDTH x DOOM_RENDER_HEIGHT in XRGB8888.
// We convert to RGB565 and scale to 466x466 for the AMOLED.
pixel_t* DG_ScreenBuffer = NULL;
static uint16_t* scaled_buffer = NULL;  // 466x466 RGB565 in PSRAM

// --- Input state ---
// Ring buffer for key events (doomgeneric polls one event per DG_GetKey call)
#define KEY_QUEUE_SIZE 32
static struct {
    unsigned char key;
    int pressed;
} key_queue[KEY_QUEUE_SIZE];
static int key_queue_head = 0;
static int key_queue_tail = 0;

static void push_key(unsigned char key, int pressed) {
    int next = (key_queue_head + 1) % KEY_QUEUE_SIZE;
    if (next != key_queue_tail) {
        key_queue[key_queue_head].key = key;
        key_queue[key_queue_head].pressed = pressed;
        key_queue_head = next;
    }
}

// --- IMU -> movement mapping ---
// Tilt thresholds (degrees from neutral)
#define IMU_DEAD_ZONE     8.0f   // ignore tilt < 8 degrees
#define IMU_FORWARD_TILT  -12.0f // pitch forward (negative = nose down)
#define IMU_BACK_TILT     12.0f  // pitch back
#define IMU_STRAFE_TILT   15.0f  // roll threshold for strafe

static bool key_forward_held = false;
static bool key_back_held = false;
static bool key_strafe_l_held = false;
static bool key_strafe_r_held = false;
static bool key_run_held = false;

static void process_imu_input(void) {
    float pitch, roll;
    doom_imu_read(&pitch, &roll);

    // Forward/back from pitch
    bool want_forward = (pitch < IMU_FORWARD_TILT);
    bool want_back = (pitch > IMU_BACK_TILT);

    if (want_forward && !key_forward_held) {
        push_key(KEY_UPARROW, 1);
        key_forward_held = true;
    } else if (!want_forward && key_forward_held) {
        push_key(KEY_UPARROW, 0);
        key_forward_held = false;
    }

    if (want_back && !key_back_held) {
        push_key(KEY_DOWNARROW, 1);
        key_back_held = true;
    } else if (!want_back && key_back_held) {
        push_key(KEY_DOWNARROW, 0);
        key_back_held = false;
    }

    // Strafe from roll
    bool want_left = (roll < -IMU_STRAFE_TILT);
    bool want_right = (roll > IMU_STRAFE_TILT);

    if (want_left && !key_strafe_l_held) {
        push_key(KEY_STRAFE_L, 1);
        key_strafe_l_held = true;
    } else if (!want_left && key_strafe_l_held) {
        push_key(KEY_STRAFE_L, 0);
        key_strafe_l_held = false;
    }

    if (want_right && !key_strafe_r_held) {
        push_key(KEY_STRAFE_R, 1);
        key_strafe_r_held = true;
    } else if (!want_right && key_strafe_r_held) {
        push_key(KEY_STRAFE_R, 0);
        key_strafe_r_held = false;
    }
}

// --- Touch -> aim/shoot mapping ---
// Drag anywhere = turn (left/right arrow keys proportional to dx)
// Tap = fire
// Double-tap = use/open
// Second finger held = run modifier

#define TOUCH_TURN_THRESHOLD  5   // pixels of drag before registering as turn
#define TOUCH_TURN_SPEED      3   // how many drag pixels per turn key-repeat

static bool key_turn_l_held = false;
static bool key_turn_r_held = false;
static bool key_fire_held = false;
static bool key_use_held = false;

static void process_touch_input(void) {
    doom_touch_state_t touch;
    doom_touch_poll(&touch);

    // Run modifier from second touch point
    if (touch.second_pressed && !key_run_held) {
        push_key(KEY_RSHIFT, 1);  // Doom's run key
        key_run_held = true;
    } else if (!touch.second_pressed && key_run_held) {
        push_key(KEY_RSHIFT, 0);
        key_run_held = false;
    }

    // Turn from drag
    if (touch.pressed && abs(touch.dx) > TOUCH_TURN_THRESHOLD) {
        if (touch.dx < 0) {
            // Dragging left = turn left
            if (!key_turn_l_held) {
                push_key(KEY_LEFTARROW, 1);
                key_turn_l_held = true;
            }
            if (key_turn_r_held) {
                push_key(KEY_RIGHTARROW, 0);
                key_turn_r_held = false;
            }
        } else {
            // Dragging right = turn right
            if (!key_turn_r_held) {
                push_key(KEY_RIGHTARROW, 1);
                key_turn_r_held = true;
            }
            if (key_turn_l_held) {
                push_key(KEY_LEFTARROW, 0);
                key_turn_l_held = false;
            }
        }
    } else if (!touch.pressed || abs(touch.dx) <= TOUCH_TURN_THRESHOLD) {
        // Released or centered - stop turning
        if (key_turn_l_held) { push_key(KEY_LEFTARROW, 0); key_turn_l_held = false; }
        if (key_turn_r_held) { push_key(KEY_RIGHTARROW, 0); key_turn_r_held = false; }
    }

    // Fire from tap
    if (touch.tap_detected && !key_fire_held) {
        push_key(KEY_FIRE, 1);
        key_fire_held = true;
    } else if (!touch.tap_detected && key_fire_held) {
        push_key(KEY_FIRE, 0);
        key_fire_held = false;
    }

    // Use/open from double-tap
    if (touch.double_tap && !key_use_held) {
        push_key(KEY_USE, 1);
        key_use_held = true;
    } else if (!touch.double_tap && key_use_held) {
        push_key(KEY_USE, 0);
        key_use_held = false;
    }
}

// ==========================================================================
// doomgeneric interface implementation
// ==========================================================================

void DG_Init() {
    ESP_LOGI(TAG, "Initializing Doom Easter Egg...");

    // Allocate screen buffer in PSRAM (320x200 x 4 bytes = 256KB)
    DG_ScreenBuffer = (pixel_t*)heap_caps_calloc(
        DOOM_RENDER_WIDTH * DOOM_RENDER_HEIGHT, sizeof(pixel_t),
        MALLOC_CAP_SPIRAM);
    assert(DG_ScreenBuffer);

    // Allocate scaled output buffer in PSRAM (466x466 x 2 bytes = 434KB)
    scaled_buffer = (uint16_t*)heap_caps_calloc(
        466 * 466, sizeof(uint16_t),
        MALLOC_CAP_SPIRAM);
    assert(scaled_buffer);

    doom_display_init();
    doom_imu_init();
    doom_touch_init();

    ESP_LOGI(TAG, "Doom initialized. PSRAM used: %d KB",
             (256 + 434));
}

void DG_DrawFrame() {
    // Convert XRGB8888 -> RGB565 and scale 320x200 -> 466x466
    // with nearest-neighbor scaling and round mask.
    //
    // The 466x466 panel is round (inscribed circle ~466px diameter).
    // We letterbox: 320x200 scaled to fill width (466px wide),
    // height = 466 * (200/320) = 291px, centered vertically.
    // Black bars above/below. Round corners naturally clip.

    const int src_w = DOOM_RENDER_WIDTH;
    const int src_h = DOOM_RENDER_HEIGHT;
    const int dst_w = 466;
    const int dst_h = 466;

    // Scale to fill width, maintain aspect ratio
    const int scaled_h = (dst_w * src_h) / src_w;  // 291
    const int y_offset = (dst_h - scaled_h) / 2;    // 87

    // Clear buffer (black)
    memset(scaled_buffer, 0, dst_w * dst_h * sizeof(uint16_t));

    // Nearest-neighbor scale with XRGB8888 -> RGB565 conversion
    for (int dy = 0; dy < scaled_h; dy++) {
        int sy = (dy * src_h) / scaled_h;
        uint16_t* dst_row = &scaled_buffer[(dy + y_offset) * dst_w];
        pixel_t* src_row = &DG_ScreenBuffer[sy * src_w];

        for (int dx = 0; dx < dst_w; dx++) {
            int sx = (dx * src_w) / dst_w;
            pixel_t pixel = src_row[sx];

            // XRGB8888 -> RGB565 (big-endian for panel)
            uint8_t r = (pixel >> 16) & 0xFF;
            uint8_t g = (pixel >> 8) & 0xFF;
            uint8_t b = pixel & 0xFF;
            uint16_t rgb565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
            dst_row[dx] = __builtin_bswap16(rgb565);  // big-endian for panel
        }
    }

    // Push to display
    doom_display_blit(scaled_buffer, dst_w, dst_h);
}

void DG_SleepMs(uint32_t ms) {
    vTaskDelay(pdMS_TO_TICKS(ms));
}

uint32_t DG_GetTicksMs() {
    return (uint32_t)(esp_timer_get_time() / 1000);
}

int DG_GetKey(int* pressed, unsigned char* key) {
    // Process hardware inputs into key events
    process_imu_input();
    process_touch_input();

    // Pop from key queue
    if (key_queue_tail != key_queue_head) {
        *key = key_queue[key_queue_tail].key;
        *pressed = key_queue[key_queue_tail].pressed;
        key_queue_tail = (key_queue_tail + 1) % KEY_QUEUE_SIZE;
        return 1;
    }
    return 0;
}

void DG_SetWindowTitle(const char* title) {
    // No-op on embedded
    (void)title;
}
