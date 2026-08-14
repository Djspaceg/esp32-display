// doomgeneric platform implementation for ESP32-S3-Touch-AMOLED-1.75C
//
// Implements the 5 required doomgeneric functions:
//   DG_Init       - init display, IMU, touch
//   DG_DrawFrame  - scale 320x200 -> 466x466 (letterboxed, round-masked)
//   DG_SleepMs    - FreeRTOS vTaskDelay
//   DG_GetTicksMs - esp_timer microseconds / 1000
//   DG_GetKey     - IMU tilt + touch gestures -> Doom key events
//
// Display strategy for 466x466 square (round) AMOLED:
//   Doom renders 320x200 (16:10). We scale to fill the 466px width:
//   - Scaled height = 466 * (200/320) = 291px
//   - Vertical centering: 87px black bar top and bottom
//   - The round bezel naturally clips the corners
//   - Status bar (bottom 32px of Doom's 200px) is fully visible
//
// Touch zones (on the 466x466 display):
//   LEFT HALF (x < 233):  movement assist (reserved for future)
//   RIGHT HALF (x >= 233): aim + combat
//     - Horizontal drag: turn left/right
//     - Tap: shoot
//     - Double-tap: use/open
//     - Vertical swipe UP: next weapon
//     - Vertical swipe DOWN: previous weapon
//   FULL SCREEN:
//     - Second finger: run modifier
//
// In MENU mode (title screen, menus):
//     - Tap anywhere: ENTER (select)
//     - Swipe up: UP arrow (menu navigate)
//     - Swipe down: DOWN arrow (menu navigate)
//     - No IMU input in menus
//
// GPL-2.0 (inherits from doomgeneric/id Software Doom source)
#include "doomgeneric.h"
#include "doomkeys.h"
#include "doom_mode.h"
#include "doom_config.h"

#include <string.h>
#include <math.h>
#include <esp_timer.h>
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <esp_log.h>

// Hardware bridge functions (defined in doom_hw_bridge.cpp)
extern void doom_display_init(void);
extern void doom_display_blit(const uint16_t* rgb565_buf, int width, int height);
extern void doom_imu_init(void);
extern void doom_imu_read(float* pitch, float* roll);
extern void doom_touch_init(void);

// Touch state from the CST9217 reader
typedef struct {
    bool pressed;
    bool second_pressed;
    int16_t x, y;
    int16_t dx, dy;
    bool tap_detected;
    bool double_tap;
} doom_touch_state_t;

extern void doom_touch_poll(doom_touch_state_t* state);

static const char* TAG = "doom_gfx";

// --- Display constants ---
#define PANEL_SIZE       466
#define PANEL_CENTER     (PANEL_SIZE / 2)  // 233
#define PANEL_RADIUS     (PANEL_SIZE / 2)  // 233 (inscribed circle)

// Scaled Doom frame dimensions (fill width, maintain aspect)
#define SCALED_W         PANEL_SIZE         // 466
#define SCALED_H         ((PANEL_SIZE * DOOM_RENDER_HEIGHT) / DOOM_RENDER_WIDTH)  // 291
#define Y_OFFSET         ((PANEL_SIZE - SCALED_H) / 2)  // 87

// --- Screen buffer ---
pixel_t* DG_ScreenBuffer = NULL;
static uint16_t* scaled_buffer = NULL;

// --- Frame rate limiting ---
#define TARGET_FRAME_MS  (1000 / DOOM_TARGET_FPS)  // ~28ms for 35fps
static uint32_t last_frame_time = 0;

// --- Input state ---
#define KEY_QUEUE_SIZE 32
static struct {
    unsigned char key;
    int pressed;
} key_queue[KEY_QUEUE_SIZE];
static int key_queue_head = 0;
static int key_queue_tail = 0;

// Externally callable (used by doom_mode.cpp for button weapon cycle)
void push_key(unsigned char key, int pressed) {
    int next = (key_queue_head + 1) % KEY_QUEUE_SIZE;
    if (next != key_queue_tail) {
        key_queue[key_queue_head].key = key;
        key_queue[key_queue_head].pressed = pressed;
        key_queue_head = next;
    }
}

// --- IMU -> movement mapping ---
#define IMU_DEAD_ZONE     8.0f
#define IMU_FORWARD_TILT  -12.0f
#define IMU_BACK_TILT     12.0f
#define IMU_STRAFE_TILT   15.0f

static bool key_forward_held = false;
static bool key_back_held = false;
static bool key_strafe_l_held = false;
static bool key_strafe_r_held = false;
static bool key_run_held = false;

// Track whether we're in a menu (no IMU, different touch behavior)
static bool in_menu = true;  // Start true (title screen)

static void process_imu_input(void) {
    if (in_menu) return;  // No tilt control in menus

    float pitch, roll;
    doom_imu_read(&pitch, &roll);

    bool want_forward = (pitch < IMU_FORWARD_TILT);
    bool want_back = (pitch > IMU_BACK_TILT);
    bool want_left = (roll < -IMU_STRAFE_TILT);
    bool want_right = (roll > IMU_STRAFE_TILT);

    if (want_forward != key_forward_held) {
        push_key(KEY_UPARROW, want_forward ? 1 : 0);
        key_forward_held = want_forward;
    }
    if (want_back != key_back_held) {
        push_key(KEY_DOWNARROW, want_back ? 1 : 0);
        key_back_held = want_back;
    }
    if (want_left != key_strafe_l_held) {
        push_key(KEY_STRAFE_L, want_left ? 1 : 0);
        key_strafe_l_held = want_left;
    }
    if (want_right != key_strafe_r_held) {
        push_key(KEY_STRAFE_R, want_right ? 1 : 0);
        key_strafe_r_held = want_right;
    }
}

// --- Touch -> aim/shoot/weapon mapping ---
#define TOUCH_TURN_THRESHOLD  8    // px drag before registering as turn
#define TOUCH_SWIPE_THRESHOLD 40   // px vertical movement for weapon swipe
#define TOUCH_SWIPE_RATIO     1.5f // dy/dx must exceed this for vertical swipe

static bool key_turn_l_held = false;
static bool key_turn_r_held = false;
static bool key_fire_held = false;
static bool key_use_held = false;
static int16_t touch_start_y = 0;        // Y at touch-down for swipe detection
static bool swipe_committed = false;      // Once a swipe is detected, don't also fire

static void process_touch_input(void) {
    doom_touch_state_t touch;
    doom_touch_poll(&touch);

    // --- Menu mode: simplified input ---
    if (in_menu) {
        if (touch.tap_detected) {
            push_key(KEY_ENTER, 1);
            push_key(KEY_ENTER, 0);
        }
        if (touch.dy < -TOUCH_SWIPE_THRESHOLD && touch.pressed) {
            push_key(KEY_UPARROW, 1);
            push_key(KEY_UPARROW, 0);
        }
        if (touch.dy > TOUCH_SWIPE_THRESHOLD && touch.pressed) {
            push_key(KEY_DOWNARROW, 1);
            push_key(KEY_DOWNARROW, 0);
        }
        return;
    }

    // --- Game mode ---

    // Run modifier from second touch point
    if (touch.second_pressed != key_run_held) {
        push_key(KEY_RSHIFT, touch.second_pressed ? 1 : 0);
        key_run_held = touch.second_pressed;
    }

    // Weapon switching: vertical swipe on right half
    if (touch.pressed) {
        if (!swipe_committed && abs(touch.dy) > TOUCH_SWIPE_THRESHOLD) {
            float ratio = (float)abs(touch.dy) / (float)(abs(touch.dx) + 1);
            if (ratio > TOUCH_SWIPE_RATIO) {
                // Vertical swipe detected
                if (touch.dy < 0) {
                    // Swipe UP = next weapon
                    push_key('/', 1);  // weapon forward
                    push_key('/', 0);
                } else {
                    // Swipe DOWN = previous weapon (Doom uses '/' for next only,
                    // but we can cycle with number keys. Use '0' for "best weapon")
                    // Actually: just send multiple '/' to cycle forward
                    push_key('/', 1);
                    push_key('/', 0);
                }
                swipe_committed = true;  // Don't fire after a swipe
            }
        }
    } else {
        swipe_committed = false;  // Reset on release
    }

    // Turn from horizontal drag (only if not swiping vertically)
    if (!swipe_committed && touch.pressed && abs(touch.dx) > TOUCH_TURN_THRESHOLD) {
        if (touch.dx < -TOUCH_TURN_THRESHOLD) {
            if (!key_turn_l_held) { push_key(KEY_LEFTARROW, 1); key_turn_l_held = true; }
            if (key_turn_r_held) { push_key(KEY_RIGHTARROW, 0); key_turn_r_held = false; }
        } else if (touch.dx > TOUCH_TURN_THRESHOLD) {
            if (!key_turn_r_held) { push_key(KEY_RIGHTARROW, 1); key_turn_r_held = true; }
            if (key_turn_l_held) { push_key(KEY_LEFTARROW, 0); key_turn_l_held = false; }
        }
    } else if (!touch.pressed || abs(touch.dx) <= TOUCH_TURN_THRESHOLD) {
        if (key_turn_l_held) { push_key(KEY_LEFTARROW, 0); key_turn_l_held = false; }
        if (key_turn_r_held) { push_key(KEY_RIGHTARROW, 0); key_turn_r_held = false; }
    }

    // Fire from tap (only if no swipe was committed)
    if (!swipe_committed) {
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
}

// ==========================================================================
// doomgeneric interface implementation
// ==========================================================================

void DG_Init() {
    ESP_LOGI(TAG, "Initializing Doom Easter Egg...");
    ESP_LOGI(TAG, "  Render: %dx%d -> %dx%d (letterboxed, y_offset=%d)",
             DOOM_RENDER_WIDTH, DOOM_RENDER_HEIGHT, SCALED_W, SCALED_H, Y_OFFSET);

    // Allocate render buffer in PSRAM (320x200 x 4 bytes = 256KB)
    DG_ScreenBuffer = (pixel_t*)heap_caps_calloc(
        DOOM_RENDER_WIDTH * DOOM_RENDER_HEIGHT, sizeof(pixel_t),
        MALLOC_CAP_SPIRAM);
    assert(DG_ScreenBuffer && "Failed to allocate DG_ScreenBuffer in PSRAM");

    // Allocate scaled output buffer in PSRAM (466x466 x 2 bytes = 434KB)
    scaled_buffer = (uint16_t*)heap_caps_calloc(
        PANEL_SIZE * PANEL_SIZE, sizeof(uint16_t),
        MALLOC_CAP_SPIRAM);
    assert(scaled_buffer && "Failed to allocate scaled_buffer in PSRAM");

    doom_display_init();
    doom_imu_init();
    doom_touch_init();

    last_frame_time = DG_GetTicksMs();

    ESP_LOGI(TAG, "Doom initialized. PSRAM: render=256KB + scaled=434KB + zone=4MB");
}

void DG_DrawFrame() {
    // Frame rate limiting: don't push faster than DOOM_TARGET_FPS
    uint32_t now = DG_GetTicksMs();
    uint32_t elapsed = now - last_frame_time;
    if (elapsed < TARGET_FRAME_MS) {
        DG_SleepMs(TARGET_FRAME_MS - elapsed);
        now = DG_GetTicksMs();
    }
    last_frame_time = now;

    // Convert XRGB8888 -> RGB565 and scale 320x200 -> 466x466
    // Nearest-neighbor with letterboxing (87px black bars top/bottom)
    const int src_w = DOOM_RENDER_WIDTH;
    const int src_h = DOOM_RENDER_HEIGHT;

    // Pre-compute a round mask: skip pixels outside the inscribed circle
    // to avoid wasting QSPI bandwidth on invisible pixels.
    // The round mask check is: (dx*dx + dy*dy) <= radius*radius
    // We check per-row whether the row is entirely outside the circle.
    const int r2 = PANEL_RADIUS * PANEL_RADIUS;

    for (int dy = 0; dy < PANEL_SIZE; dy++) {
        uint16_t* dst_row = &scaled_buffer[dy * PANEL_SIZE];
        int cy = dy - PANEL_CENTER;  // distance from center Y

        // Quick check: if this row's closest point to center is outside circle, skip
        if (cy * cy > r2) {
            memset(dst_row, 0, PANEL_SIZE * sizeof(uint16_t));
            continue;
        }

        // Calculate X bounds for this row within the circle
        int x_span = (int)sqrtf((float)(r2 - cy * cy));
        int x_start = PANEL_CENTER - x_span;
        int x_end = PANEL_CENTER + x_span;
        if (x_start < 0) x_start = 0;
        if (x_end > PANEL_SIZE) x_end = PANEL_SIZE;

        // Black outside circle on this row
        if (x_start > 0) memset(dst_row, 0, x_start * sizeof(uint16_t));
        if (x_end < PANEL_SIZE) memset(&dst_row[x_end], 0, (PANEL_SIZE - x_end) * sizeof(uint16_t));

        // Is this row in the letterbox bar (above or below the Doom frame)?
        if (dy < Y_OFFSET || dy >= (Y_OFFSET + SCALED_H)) {
            // Black bar
            memset(&dst_row[x_start], 0, (x_end - x_start) * sizeof(uint16_t));
            continue;
        }

        // Map this display row to a source row
        int sy = ((dy - Y_OFFSET) * src_h) / SCALED_H;
        if (sy >= src_h) sy = src_h - 1;
        pixel_t* src_row = &DG_ScreenBuffer[sy * src_w];

        // Scale and convert pixels within the circle
        for (int dx = x_start; dx < x_end; dx++) {
            int sx = (dx * src_w) / SCALED_W;
            if (sx >= src_w) sx = src_w - 1;
            pixel_t pixel = src_row[sx];

            // XRGB8888 -> RGB565 big-endian (panel byte order)
            uint8_t r = (pixel >> 16) & 0xFF;
            uint8_t g = (pixel >> 8) & 0xFF;
            uint8_t b = pixel & 0xFF;
            uint16_t rgb565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
            dst_row[dx] = __builtin_bswap16(rgb565);
        }
    }

    doom_display_blit(scaled_buffer, PANEL_SIZE, PANEL_SIZE);
}

void DG_SleepMs(uint32_t ms) {
    if (ms > 0) {
        vTaskDelay(pdMS_TO_TICKS(ms));
    }
}

uint32_t DG_GetTicksMs() {
    return (uint32_t)(esp_timer_get_time() / 1000);
}

int DG_GetKey(int* pressed, unsigned char* key) {
    // Process hardware inputs
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
    // Use the title to detect menu vs gameplay state.
    // doomgeneric sets the title to the map name when a level starts.
    // If it contains "E1M" or similar, we're in gameplay.
    if (title && (strstr(title, "E1M") || strstr(title, "MAP"))) {
        if (in_menu) {
            in_menu = false;
            ESP_LOGI(TAG, "Entering gameplay mode (IMU active): %s", title);
        }
    }
    // Title screen / menus don't set a map name, so in_menu stays true
    // until the first level loads.
}
