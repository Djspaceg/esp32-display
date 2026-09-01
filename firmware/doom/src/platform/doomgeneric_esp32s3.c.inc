// doomgeneric platform implementation for ESP32-S3-Touch-AMOLED-1.75C
//
// Implements the 5 required doomgeneric functions:
//   DG_Init       - init display, IMU, touch
//   DG_DrawFrame  - scale 320x200 -> 466x466 (letterboxed, round-masked)
//   DG_SleepMs    - FreeRTOS vTaskDelay
//   DG_GetTicksMs - esp_timer microseconds / 1000
//   DG_PollInput  - sample hardware once per Doom input phase
//   DG_GetKey     - dequeue one sampled Doom key event
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
// Outside active gameplay (title/demo/menu):
//     - Tap on title/demo: ESCAPE (open menu)
//     - Tap in menu: ENTER (select)
//     - Dominant-axis swipe in menu: UP/DOWN/LEFT/RIGHT
//     - No IMU input
//
// GPL-2.0 (inherits from doomgeneric/id Software Doom source)
#include "doomgeneric.h"
#include "doomkeys.h"
#include "doom_mode.h"
#include "doom_config.h"
#include "doomstat.h"
#include "m_controls.h"

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

static const char* GFX_TAG = "doom_gfx";

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

// Externally callable (used by doom_mode.cpp for BOOT menu controls)
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
static bool key_turn_l_held = false;
static bool key_turn_r_held = false;

// Synthetic gameplay taps must remain down through one BuildTiccmd. Menu
// responders act immediately on keydown, but gameplay samples held-key state
// after the event queue is drained; an adjacent down/up pair would disappear.
static bool dg_pulse_key_held = false;
static unsigned char dg_pulse_key = 0;
static uint32_t dg_input_generation = 0;
static uint32_t dg_pulse_release_generation = 0;
static bool dg_fire_pending = false;
static uint32_t dg_fire_due_at = 0;

// --- Touch -> aim/shoot/weapon mapping ---
#define TOUCH_TURN_THRESHOLD  8
#define TOUCH_SWIPE_THRESHOLD 40
#define TOUCH_SWIPE_RATIO     1.5f

typedef enum {
    DG_INPUT_TITLE_OR_DEMO,
    DG_INPUT_MENU,
    DG_INPUT_GAMEPLAY,
} dg_input_context_t;

static bool dg_touch_active = false;
static bool dg_touch_suppressed = false;
static dg_input_context_t dg_touch_context = DG_INPUT_TITLE_OR_DEMO;
static int32_t dg_touch_dx = 0;
static int32_t dg_touch_dy = 0;
static bool dg_swipe_committed = false;

static bool dg_gameplay_input_active(void) {
    return !menuactive && usergame && gamestate == GS_LEVEL && !demoplayback;
}

static dg_input_context_t dg_current_input_context(void) {
    if (menuactive) return DG_INPUT_MENU;
    if (dg_gameplay_input_active()) return DG_INPUT_GAMEPLAY;
    return DG_INPUT_TITLE_OR_DEMO;
}

static void dg_release_gameplay_keys(void) {
    if (key_forward_held) { push_key(KEY_UPARROW, 0); key_forward_held = false; }
    if (key_back_held) { push_key(KEY_DOWNARROW, 0); key_back_held = false; }
    if (key_strafe_l_held) { push_key(KEY_STRAFE_L, 0); key_strafe_l_held = false; }
    if (key_strafe_r_held) { push_key(KEY_STRAFE_R, 0); key_strafe_r_held = false; }
    if (key_run_held) { push_key(KEY_RSHIFT, 0); key_run_held = false; }
    if (key_turn_l_held) { push_key(KEY_LEFTARROW, 0); key_turn_l_held = false; }
    if (key_turn_r_held) { push_key(KEY_RIGHTARROW, 0); key_turn_r_held = false; }
    if (dg_pulse_key_held) {
        push_key(dg_pulse_key, 0);
        dg_pulse_key_held = false;
    }
    dg_fire_pending = false;
}

static void dg_begin_gameplay_pulse(unsigned char key) {
    if (dg_pulse_key_held) {
        push_key(dg_pulse_key, 0);
    }
    push_key(key, 1);
    dg_pulse_key = key;
    dg_pulse_key_held = true;
    dg_pulse_release_generation = dg_input_generation + 1;
}

static void dg_release_gameplay_pulse_for_new_poll(void) {
    if (dg_pulse_key_held &&
        dg_input_generation >= dg_pulse_release_generation) {
        push_key(dg_pulse_key, 0);
        dg_pulse_key_held = false;
    }
}

static void dg_reset_touch_gesture(void) {
    dg_touch_active = false;
    dg_touch_suppressed = false;
    dg_touch_dx = 0;
    dg_touch_dy = 0;
    dg_swipe_committed = false;
}

static void process_imu_input(void) {
    if (!dg_gameplay_input_active()) {
        dg_release_gameplay_keys();
        return;
    }

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

static void process_touch_input(void) {
    doom_touch_state_t touch;
    doom_touch_poll(&touch);

    const dg_input_context_t context = dg_current_input_context();
    if (context == DG_INPUT_GAMEPLAY && dg_fire_pending &&
        (int32_t)(DG_GetTicksMs() - dg_fire_due_at) >= 0) {
        dg_fire_pending = false;
        dg_begin_gameplay_pulse(KEY_FIRE);
    }

    if (touch.pressed) {
        if (!dg_touch_active) {
            dg_touch_active = true;
            dg_touch_suppressed = false;
            dg_touch_context = context;
            dg_touch_dx = 0;
            dg_touch_dy = 0;
            dg_swipe_committed = false;
        } else {
            dg_touch_dx += touch.dx;
            dg_touch_dy += touch.dy;
        }
    }
    bool gesture_ended = !touch.pressed && dg_touch_active;

    // A physical contact belongs to the engine context where it began. If a
    // BOOT press or engine transition changes context while the finger remains
    // down, discard that contact instead of reinterpreting its accumulated
    // motion as a command in the new context.
    if (dg_touch_active && context != dg_touch_context) {
        dg_touch_suppressed = true;
    }
    if (dg_touch_suppressed) {
        if (gesture_ended) dg_reset_touch_gesture();
        return;
    }

    if (menuactive) {
        // Accumulate controller-report deltas so a smooth swipe is not lost
        // merely because no individual report crosses the threshold.
        if (touch.pressed && !dg_swipe_committed &&
            (abs(dg_touch_dx) >= TOUCH_SWIPE_THRESHOLD ||
             abs(dg_touch_dy) >= TOUCH_SWIPE_THRESHOLD)) {
            unsigned char key;
            if (abs(dg_touch_dx) > abs(dg_touch_dy)) {
                key = dg_touch_dx < 0 ? KEY_LEFTARROW : KEY_RIGHTARROW;
            } else {
                key = dg_touch_dy < 0 ? KEY_UPARROW : KEY_DOWNARROW;
            }
            push_key(key, 1);
            push_key(key, 0);
            dg_swipe_committed = true;
        }
        if (touch.tap_detected && !dg_swipe_committed) {
            push_key(KEY_ENTER, 1);
            push_key(KEY_ENTER, 0);
        }
        if (gesture_ended) dg_reset_touch_gesture();
        return;
    }

    if (!dg_gameplay_input_active()) {
        // Attract-mode demos and title screens are not user gameplay. A tap
        // opens the menu instead of firing into a demo that ignores control.
        if (touch.tap_detected && !dg_swipe_committed) {
            push_key(KEY_ESCAPE, 1);
            push_key(KEY_ESCAPE, 0);
        }
        if (gesture_ended) dg_reset_touch_gesture();
        return;
    }

    // Run modifier from second touch point.
    if (touch.second_pressed != key_run_held) {
        push_key(KEY_RSHIFT, touch.second_pressed ? 1 : 0);
        key_run_held = touch.second_pressed;
    }

    // A dominant vertical swipe cycles weapons once per gesture.
    if (touch.pressed && !dg_swipe_committed &&
        abs(dg_touch_dy) >= TOUCH_SWIPE_THRESHOLD) {
        float ratio = (float)abs(dg_touch_dy) / (float)(abs(dg_touch_dx) + 1);
        if (ratio > TOUCH_SWIPE_RATIO) {
            dg_begin_gameplay_pulse((unsigned char)key_nextweapon);
            dg_swipe_committed = true;
        }
    }

    // Turn from horizontal drag (only if not swiping vertically).
    if (!dg_swipe_committed && touch.pressed &&
        abs(touch.dx) > TOUCH_TURN_THRESHOLD) {
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

    if (!dg_swipe_committed) {
        if (touch.double_tap) {
            dg_fire_pending = false;
            dg_begin_gameplay_pulse(KEY_USE);
        } else if (touch.tap_detected) {
            // The bridge reports the first release before it can know whether
            // another tap will follow. Wait out that same classification window
            // so a double-tap means Use without also firing once.
            dg_fire_pending = true;
            dg_fire_due_at = DG_GetTicksMs() + DOOM_DOUBLE_TAP_WINDOW_MS;
        }
    }

    if (gesture_ended) dg_reset_touch_gesture();
}

// ==========================================================================
// doomgeneric interface implementation
// ==========================================================================

void DG_Init() {
    ESP_LOGI(GFX_TAG, "Initializing Doom Easter Egg...");
    ESP_LOGI(GFX_TAG, "  Render: %dx%d -> %dx%d (letterboxed, y_offset=%d)",
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
    // Touch starts Wire; the QMI8658 shares that bus and must follow it.
    doom_touch_init();
    doom_imu_init();

    last_frame_time = DG_GetTicksMs();

    ESP_LOGI(GFX_TAG, "Doom initialized. PSRAM: render=256KB + scaled=434KB + zone=4MB");
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

void DG_PollInput(void) {
    ++dg_input_generation;
    dg_release_gameplay_pulse_for_new_poll();
    process_imu_input();
    process_touch_input();
}

int DG_GetKey(int* pressed, unsigned char* key) {
    // Pure dequeue: hardware is sampled once by DG_PollInput() before the
    // caller drains this queue, so producers cannot refill it mid-drain.
    if (key_queue_tail != key_queue_head) {
        *key = key_queue[key_queue_tail].key;
        *pressed = key_queue[key_queue_tail].pressed;
        key_queue_tail = (key_queue_tail + 1) % KEY_QUEUE_SIZE;
        return 1;
    }
    return 0;
}

void DG_SetWindowTitle(const char* title) {
    // The engine's own menu/game/demo globals are authoritative. Window titles
    // are presentation text and do not reliably change on every state transition.
    (void)title;
}
