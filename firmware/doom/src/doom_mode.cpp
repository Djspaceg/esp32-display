// Doom Easter Egg mode controller
//
// Triple-tap detection and mode lifecycle management.
// GPL-2.0 for the doomgeneric integration; this glue file is MIT.
#include "doom_mode.h"

#include <Arduino.h>
#include <string.h>
#include <esp_log.h>
#include <esp_partition.h>
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include "platform/doom_splash.h"

// From doomgeneric_esp32s3.c
extern "C" void push_key(unsigned char key, int pressed);

// From doom_hw_bridge.cpp
extern "C" void doom_display_init(void);
extern "C" void doom_display_blit(const uint16_t* buf, int w, int h);

// doomgeneric entry points (C linkage)
extern "C" {
    void doomgeneric_Create(int argc, char** argv);
    void doomgeneric_Tick(void);
}

static const char* TAG = "doom_mode";

// --- Triple-tap state machine ---
static uint32_t tap_timestamps[3] = {0, 0, 0};
static int tap_count = 0;
static volatile bool doom_active = false;
static volatile bool doom_exit_requested = false;

bool doom_check_triple_tap(uint32_t now_ms, bool button_just_pressed) {
    if (!button_just_pressed) return false;
    if (doom_active) return false;  // Already in Doom

    // Record this press
    if (tap_count == 0 || (now_ms - tap_timestamps[0]) > DOOM_TRIPLE_TAP_WINDOW_MS) {
        // Start fresh sequence
        tap_timestamps[0] = now_ms;
        tap_count = 1;
    } else {
        // Add to sequence
        tap_timestamps[tap_count] = now_ms;
        tap_count++;
    }

    if (tap_count >= 3) {
        // Triple-tap detected! Verify all 3 within the window.
        if ((tap_timestamps[2] - tap_timestamps[0]) <= DOOM_TRIPLE_TAP_WINDOW_MS) {
            tap_count = 0;
            ESP_LOGI(TAG, "Triple-tap detected! Entering Doom mode...");
            return true;
        }
        // Window expired between first and third -- reset
        tap_timestamps[0] = now_ms;
        tap_count = 1;
    }

    return false;
}

bool doom_is_active(void) {
    return doom_active;
}

void doom_request_exit(void) {
    if (doom_active) {
        ESP_LOGI(TAG, "Doom exit requested (BOOT long-press)");
        doom_exit_requested = true;
    }
}

// Check if exit was requested (called from the game loop)
static bool should_exit(void) {
    return doom_exit_requested;
}

void doom_enter(void) {
    ESP_LOGI(TAG, "=== DOOM EASTER EGG ACTIVATED ===");
    ESP_LOGI(TAG, "Panel rotation locked (IMU used for movement, not display rotation)");
    ESP_LOGI(TAG, "Controls:");
    ESP_LOGI(TAG, "  Tilt device    = Move (forward/back/strafe)");
    ESP_LOGI(TAG, "  Touch drag     = Turn/aim");
    ESP_LOGI(TAG, "  Tap            = Shoot");
    ESP_LOGI(TAG, "  Double-tap     = Use/Open");
    ESP_LOGI(TAG, "  2nd finger     = Run");
    ESP_LOGI(TAG, "  BOOT short     = Cycle weapon");
    ESP_LOGI(TAG, "  BOOT 3s hold   = Exit Doom");

    doom_active = true;
    doom_exit_requested = false;

    // Show splash screen while engine initializes
    {
        doom_display_init();

        // Allocate splash buffer in PSRAM (466*466*2 = 434KB)
        uint16_t* splash = (uint16_t*)heap_caps_calloc(466 * 466, sizeof(uint16_t),
                                                        MALLOC_CAP_SPIRAM);
        if (splash) {
            doom_splash::render(splash);
            doom_display_blit(splash, 466, 466);
            heap_caps_free(splash);
        }
    }

    // Initialize doomgeneric
    // -mb 4 = 4MB memory zone (from PSRAM via malloc). PSRAM budget:
    //   4MB zone + 256KB render buf + 434KB scaled buf = ~4.7MB of 8MB
    // Remaining ~3.3MB is free for texture cache etc.
    char* argv[] = {"doom", "-mb", "4", "-iwad", "doom1.wad", NULL};
    int argc = 5;

    doomgeneric_Create(argc, argv);

    // Game loop -- runs until exit requested
    while (!should_exit()) {
        doomgeneric_Tick();

        // Poll BOOT button during Doom:
        //   short press = cycle weapon (KEY_TAB acts as weapon cycle in Doom)
        //   long press (3s) = exit
        {
            static bool btn_was_down = false;
            static uint32_t btn_down_at = 0;
            static bool btn_long_fired = false;

            bool btn_down = (digitalRead(0) == LOW);  // GPIO0 = BOOT
            uint32_t now = millis();

            if (btn_down && !btn_was_down) {
                btn_was_down = true;
                btn_long_fired = false;
                btn_down_at = now;
            } else if (btn_down && btn_was_down && !btn_long_fired &&
                       (now - btn_down_at) >= 3000) {
                btn_long_fired = true;
                ESP_LOGI(TAG, "BOOT long-press (3s) -- exiting Doom");
                doom_request_exit();
            } else if (!btn_down && btn_was_down) {
                btn_was_down = false;
                if (!btn_long_fired && (now - btn_down_at) >= 30) {
                    // Short press = weapon cycle
                    // Inject a '/' key press (weapon forward in Doom)
                    push_key('/', 1);  // press
                    push_key('/', 0);  // release
                }
            }
        }

        // Yield to allow other tasks (watchdog, WiFi stack)
        vTaskDelay(1);
    }

    // Cleanup
    ESP_LOGI(TAG, "Exiting Doom mode...");
    doom_active = false;
    doom_exit_requested = false;

    // Free PSRAM buffers (DG_ScreenBuffer and scaled_buffer are in PSRAM)
    extern void* DG_ScreenBuffer;
    if (DG_ScreenBuffer) {
        heap_caps_free(DG_ScreenBuffer);
        DG_ScreenBuffer = NULL;
    }

    ESP_LOGI(TAG, "Doom cleanup complete. Restarting to normal firmware...");
    // The caller (display_stream.ino) will call esp_restart()
}
