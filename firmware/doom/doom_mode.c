// Doom Easter Egg mode controller
//
// Triple-tap detection and mode lifecycle management.
// GPL-2.0 for the doomgeneric integration; this glue file is MIT.
#include "doom_mode.h"

#include <string.h>
#include <esp_log.h>
#include <esp_partition.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

// doomgeneric entry points
extern void doomgeneric_Create(int argc, char** argv);
extern void doomgeneric_Tick(void);

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

    // Initialize doomgeneric
    // -mb 8 = 8MB memory (PSRAM), -iwad dummy (we override W_OpenFile)
    char* argv[] = {"doom", "-mb", "8", "-iwad", "doom1.wad", NULL};
    int argc = 5;

    doomgeneric_Create(argc, argv);

    // Game loop -- runs until exit requested
    while (!should_exit()) {
        doomgeneric_Tick();

        // Yield to allow other tasks (button handler, watchdog)
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
