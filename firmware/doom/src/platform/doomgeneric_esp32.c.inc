// Board-neutral doomgeneric platform implementation for ESP32 displays.
//
// Implements the 5 required doomgeneric functions:
//   DG_Init       - init display, IMU, touch
//   DG_DrawFrame  - scale 320x200 into the selected panel geometry
//   DG_SleepMs    - FreeRTOS vTaskDelay
//   DG_GetTicksMs - esp_timer microseconds / 1000
//   DG_PollInput  - sample hardware once per Doom input phase
//   DG_GetKey     - dequeue one sampled Doom key event
//
// Doom's 320x200 surface is aspect-fit and centered in the selected panel.
// Round panels additionally mask pixels outside their inscribed circle.
//
// Touch zones:
//   IMU boards: whole panel aims; tilt supplies movement
//   Touch-only boards: left half moves, right half aims + fights
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
#include "doom_runtime_policy.h"

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
extern int doom_display_width(void);
extern int doom_display_height(void);
extern bool doom_display_round(void);
extern bool doom_motion_available(void);
extern void doom_imu_init(void);
extern void doom_imu_read(float* pitch, float* roll);

// Touch state layout and doom_touch_init/sample/poll declarations. Shared with
// doom_hw_bridge.cpp so the two halves cannot disagree about the struct.
#include "doom_touch_bridge.h"

static const char* GFX_TAG = "doom_gfx";

// --- Screen buffer ---
pixel_t* DG_ScreenBuffer = NULL;
static uint16_t* scaled_buffer = NULL;
static doom_frame_layout_t frame_layout;
static doom_control_scheme_t control_scheme = DOOM_CONTROLS_IMU_TOUCH;

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
static int dg_mouse_dx = 0;  // synthetic one-tic mouse movement from touch joystick

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
// Touch-down is the centre of a virtual joystick. Horizontal displacement past
// tap slop becomes per-tic mouse movement, so turn rate grows continuously with
// distance and persists while the finger holds position. A vertical release is
// a weapon switch only inside the same 400ms window used for quick taps.
#define TOUCH_TURN_DEADZONE_PX       12
#define TOUCH_TURN_MAX_MOUSE_DELTA  160
#define TOUCH_MOVE_DEADZONE_PX       24
#define TOUCH_WEAPON_SWIPE_MAX_MS   400

typedef enum {
    DG_INPUT_TITLE_OR_DEMO,
    DG_INPUT_MENU,
    DG_INPUT_GAMEPLAY,
} dg_input_context_t;

// The context a physical press belongs to is captured when the press begins, so
// a completed gesture is acted on where the finger first landed even if a BOOT
// press or engine transition moved the context mid-press.
static bool dg_touch_active = false;
static bool dg_touch_suppressed = false;
static dg_input_context_t dg_touch_context = DG_INPUT_TITLE_OR_DEMO;

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
    dg_mouse_dx = 0;
    if (dg_pulse_key_held) {
        push_key(dg_pulse_key, 0);
        dg_pulse_key_held = false;
    }
    dg_fire_pending = false;
}

static void dg_set_movement_keys(bool want_forward, bool want_back,
                                 bool want_left, bool want_right) {
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
    dg_mouse_dx = 0;
}

static int dg_touch_joystick_mouse_dx(const doom_touch_state_t* touch) {
    if (!touch->pressed) return 0;
    return doom_touch_axis_delta(
        touch->x, touch->start_x, TOUCH_TURN_DEADZONE_PX,
        TOUCH_TURN_MAX_MOUSE_DELTA);
}

static void process_imu_input(void) {
    if (!dg_gameplay_input_active()) {
        dg_release_gameplay_keys();
        return;
    }
    if (control_scheme == DOOM_CONTROLS_TOUCH_ONLY) return;

    float pitch, roll;
    doom_imu_read(&pitch, &roll);

    bool want_forward = (pitch < IMU_FORWARD_TILT);
    bool want_back = (pitch > IMU_BACK_TILT);
    bool want_left = (roll < -IMU_STRAFE_TILT);
    bool want_right = (roll > IMU_STRAFE_TILT);

    dg_set_movement_keys(want_forward, want_back, want_left, want_right);
}

static void process_touch_input(void) {
    doom_touch_state_t touch;
    doom_touch_poll(&touch);
    // Mouse movement is one-tic input. Recomputed below from the held finger's
    // origin-relative displacement; zero everywhere outside gameplay.
    dg_mouse_dx = 0;

    const dg_input_context_t context = dg_current_input_context();
    // A double-tap delivered on the same poll where the delayed single would
    // expire must win before Fire is emitted. Otherwise a second release near
    // the edge of the window produces both Fire and Use.
    if (touch.double_tap) {
        dg_fire_pending = false;
    }
    if (context == DG_INPUT_GAMEPLAY && dg_fire_pending &&
        (int32_t)(DG_GetTicksMs() - dg_fire_due_at) >= 0) {
        dg_fire_pending = false;
        dg_begin_gameplay_pulse(KEY_FIRE);
    }

    // Capture the context each press belongs to when it begins. A gesture is
    // only ever classified on release, so this is what lets a swipe that
    // started on the title screen still open the menu even though the tap that
    // preceded it may have already switched the engine into the menu.
    if (touch.press_started) {
        dg_touch_active = true;
        dg_touch_suppressed = false;
        dg_touch_context = context;
    }
    if (dg_touch_active && context != dg_touch_context) {
        dg_touch_suppressed = true;
    }

    const bool gesture_ended = !touch.pressed && dg_touch_active;
    // Attribute the completed gesture to the press's captured context; if the
    // whole press collapsed into a single poll we never latched one, so fall
    // back to the current context.
    const dg_input_context_t use_context =
        dg_touch_active ? dg_touch_context : context;
    const bool is_swipe = touch.gesture != DOOM_TOUCH_GESTURE_NONE;

    // A contact whose context changed mid-press is discarded rather than
    // reinterpreted. Turn keys, if any were held, are released by the IMU path
    // when it leaves gameplay context.
    if (dg_touch_suppressed) {
        if (gesture_ended) dg_reset_touch_gesture();
        return;
    }

    if (use_context == DG_INPUT_MENU) {
        // Completed gesture dispatch: each swipe is one arrow press, a tap is
        // Enter. No delta thresholds -- the tracker already decided.
        switch (touch.gesture) {
            case DOOM_TOUCH_GESTURE_SWIPE_LEFT:
                ESP_LOGI(GFX_TAG, "touch menu: swipe-left -> left");
                push_key(KEY_LEFTARROW, 1); push_key(KEY_LEFTARROW, 0); break;
            case DOOM_TOUCH_GESTURE_SWIPE_RIGHT:
                ESP_LOGI(GFX_TAG, "touch menu: swipe-right -> right");
                push_key(KEY_RIGHTARROW, 1); push_key(KEY_RIGHTARROW, 0); break;
            case DOOM_TOUCH_GESTURE_SWIPE_UP:
                ESP_LOGI(GFX_TAG, "touch menu: swipe-up -> up");
                push_key(KEY_UPARROW, 1); push_key(KEY_UPARROW, 0); break;
            case DOOM_TOUCH_GESTURE_SWIPE_DOWN:
                ESP_LOGI(GFX_TAG, "touch menu: swipe-down -> down");
                push_key(KEY_DOWNARROW, 1); push_key(KEY_DOWNARROW, 0); break;
            default:
                if (touch.tap_detected || touch.double_tap) {
                    ESP_LOGI(GFX_TAG, "touch menu: tap -> enter");
                    push_key(KEY_ENTER, 1);
                    push_key(KEY_ENTER, 0);
                }
                break;
        }
        if (gesture_ended) dg_reset_touch_gesture();
        return;
    }

    if (use_context != DG_INPUT_GAMEPLAY) {
        // Title/demo: a tap OR any swipe opens the menu. Dispatching the swipe
        // here as well means a swipe is never silently dead before the menu is
        // even open -- the player always gets in.
        if (is_swipe || touch.tap_detected || touch.double_tap) {
            ESP_LOGI(GFX_TAG, "touch title/demo -> escape");
            push_key(KEY_ESCAPE, 1);
            push_key(KEY_ESCAPE, 0);
        }
        if (gesture_ended) dg_reset_touch_gesture();
        return;
    }

    // --- Gameplay ---

    // Run modifier from second touch point.
    if (touch.second_pressed != key_run_held) {
        push_key(KEY_RSHIFT, touch.second_pressed ? 1 : 0);
        key_run_held = touch.second_pressed;
    }

    const doom_touch_zone_t touch_zone = doom_touch_zone_for_press(
        control_scheme, frame_layout.panel_width, touch.start_x);
    if (control_scheme == DOOM_CONTROLS_TOUCH_ONLY &&
        touch_zone == DOOM_TOUCH_ZONE_MOVE) {
        const int move_x = touch.pressed
            ? doom_touch_axis_delta(
                  touch.x, touch.start_x, TOUCH_MOVE_DEADZONE_PX, 1)
            : 0;
        const int move_y = touch.pressed
            ? doom_touch_axis_delta(
                  touch.y, touch.start_y, TOUCH_MOVE_DEADZONE_PX, 1)
            : 0;
        dg_set_movement_keys(
            move_y < 0, move_y > 0, move_x < 0, move_x > 0);
    } else if (control_scheme == DOOM_CONTROLS_TOUCH_ONLY) {
        dg_set_movement_keys(false, false, false, false);
    }

    if (touch_zone == DOOM_TOUCH_ZONE_AIM) {
        // A quick vertical gesture cycles weapons. Once a press is older than
        // 400ms, vertical displacement is ignored so a deliberate joystick
        // hold cannot become a weapon switch when the finger lifts.
        const bool quick_weapon_gesture =
            touch.press_duration_ms <= TOUCH_WEAPON_SWIPE_MAX_MS;
        if (quick_weapon_gesture &&
            touch.gesture == DOOM_TOUCH_GESTURE_SWIPE_UP) {
            ESP_LOGI(GFX_TAG, "touch gameplay: swipe-up -> next weapon");
            dg_begin_gameplay_pulse((unsigned char)key_nextweapon);
        } else if (quick_weapon_gesture &&
                   touch.gesture == DOOM_TOUCH_GESTURE_SWIPE_DOWN) {
            ESP_LOGI(GFX_TAG, "touch gameplay: swipe-down -> previous weapon");
            dg_begin_gameplay_pulse((unsigned char)key_prevweapon);
        }

        // Virtual joystick: the landing point is neutral. Holding farther left
        // or right emits a larger native mouse delta every tic.
        dg_mouse_dx = dg_touch_joystick_mouse_dx(&touch);

        // Fire/use from the tap classification. A swipe this poll is a weapon
        // change, not a fire, so tap handling is skipped when one arrived.
        if (!is_swipe) {
            if (touch.double_tap) {
                dg_fire_pending = false;
                dg_begin_gameplay_pulse(KEY_USE);
            } else if (touch.tap_detected) {
                dg_fire_pending = true;
                dg_fire_due_at =
                    DG_GetTicksMs() + DOOM_DOUBLE_TAP_WINDOW_MS;
            }
        }
    }

    if (gesture_ended) dg_reset_touch_gesture();
}

// ==========================================================================
// doomgeneric interface implementation
// ==========================================================================

void DG_Init() {
    frame_layout = doom_frame_layout_for_panel(
        doom_display_width(), doom_display_height(), doom_display_round());
    control_scheme = doom_motion_available()
        ? DOOM_CONTROLS_IMU_TOUCH
        : DOOM_CONTROLS_TOUCH_ONLY;
    ESP_LOGI(GFX_TAG, "Initializing Doom Easter Egg...");
    ESP_LOGI(GFX_TAG, "  Render: %dx%d -> %dx%d (letterboxed, y_offset=%d)",
             DOOM_RENDER_WIDTH, DOOM_RENDER_HEIGHT,
             frame_layout.scaled_width, frame_layout.scaled_height,
             frame_layout.y_offset);

    // Allocate render buffer in PSRAM (320x200 x 4 bytes = 256KB)
    DG_ScreenBuffer = (pixel_t*)heap_caps_calloc(
        DOOM_RENDER_WIDTH * DOOM_RENDER_HEIGHT, sizeof(pixel_t),
        MALLOC_CAP_SPIRAM);
    assert(DG_ScreenBuffer && "Failed to allocate DG_ScreenBuffer in PSRAM");

    // Allocate the full-panel RGB565 output buffer in PSRAM.
    scaled_buffer = (uint16_t*)heap_caps_calloc(
        frame_layout.panel_width * frame_layout.panel_height, sizeof(uint16_t),
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

    // Convert XRGB8888 -> RGB565 and scale with nearest-neighbor letterboxing.
    const int src_w = DOOM_RENDER_WIDTH;
    const int src_h = DOOM_RENDER_HEIGHT;
    const int panel_w = frame_layout.panel_width;
    const int panel_h = frame_layout.panel_height;
    const int panel_center_x = panel_w / 2;
    const int panel_center_y = panel_h / 2;
    const int panel_radius = (panel_w < panel_h ? panel_w : panel_h) / 2;
    const int r2 = panel_radius * panel_radius;

    for (int dy = 0; dy < panel_h; dy++) {
        // Scaling panel rows is the longest stretch of a frame with no other
        // yield point. Draining touch a handful of times across it keeps a
        // fast down/move/release from falling entirely between two polls.
        if ((dy & 63) == 0) {
            doom_touch_sample();
        }

        uint16_t* dst_row = &scaled_buffer[dy * panel_w];
        memset(dst_row, 0, panel_w * sizeof(uint16_t));
        int x_start = 0;
        int x_end = panel_w;
        if (frame_layout.round_mask) {
            int cy = dy - panel_center_y;
            if (cy * cy > r2) {
                memset(dst_row, 0, panel_w * sizeof(uint16_t));
                continue;
            }
            int x_span = (int)sqrtf((float)(r2 - cy * cy));
            x_start = panel_center_x - x_span;
            x_end = panel_center_x + x_span;
            if (x_start < 0) x_start = 0;
            if (x_end > panel_w) x_end = panel_w;
        }

        // Is this row in the letterbox bar (above or below the Doom frame)?
        if (dy < frame_layout.y_offset ||
            dy >= frame_layout.y_offset + frame_layout.scaled_height) {
            continue;
        }
        if (x_start < frame_layout.x_offset) {
            x_start = frame_layout.x_offset;
        }
        const int content_x_end =
            frame_layout.x_offset + frame_layout.scaled_width;
        if (x_end > content_x_end) x_end = content_x_end;

        // Map this display row to a source row
        int sy = ((dy - frame_layout.y_offset) * src_h) /
                 frame_layout.scaled_height;
        if (sy >= src_h) sy = src_h - 1;
        pixel_t* src_row = &DG_ScreenBuffer[sy * src_w];

        // Scale and convert pixels within the circle
        for (int dx = x_start; dx < x_end; dx++) {
            int sx = ((dx - frame_layout.x_offset) * src_w) /
                     frame_layout.scaled_width;
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

    doom_display_blit(scaled_buffer, panel_w, panel_h);
}

void DG_SleepMs(uint32_t ms) {
    // Sampling touch across the sleep, not just at poll time, keeps a quick
    // down/move/release from collapsing between Doom ticks.
    const uint32_t step = 4;  // ms between samples during the sleep
    uint32_t remaining = ms;
    while (remaining > step) {
        doom_touch_sample();
        vTaskDelay(pdMS_TO_TICKS(step));
        remaining -= step;
    }
    doom_touch_sample();
    if (remaining > 0) {
        vTaskDelay(pdMS_TO_TICKS(remaining));
    }
    doom_touch_sample();
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

int DG_GetMouse(int* dx, int* dy) {
    if (dg_mouse_dx == 0) return 0;
    *dx = dg_mouse_dx;
    *dy = 0;
    dg_mouse_dx = 0;
    return 1;
}

void DG_SetWindowTitle(const char* title) {
    // The engine's own menu/game/demo globals are authoritative. Window titles
    // are presentation text and do not reliably change on every state transition.
    (void)title;
}
