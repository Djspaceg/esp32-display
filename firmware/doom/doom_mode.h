// Doom Easter Egg mode for ESP32-S3-Touch-AMOLED-1.75C
//
// Activated by triple-tapping the BOOT button (GPIO0) within 800ms.
// Runs alongside the normal display_stream firmware -- suspends streaming,
// launches Doom, and returns to normal on BOOT long-press (3s).
//
// Only compiled into the S3 build (guarded by CONFIG_IDF_TARGET_ESP32S3).
// The C6 binary is unaffected.
#pragma once

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Call from the button ISR or polling loop with the current press count
/// and timing. Returns true when a triple-tap is detected.
///
/// Implementation: tracks up to 3 presses within TRIPLE_TAP_WINDOW_MS.
/// Resets if the window expires without reaching 3.
bool doom_check_triple_tap(uint32_t now_ms, bool button_just_pressed);

/// Enter Doom mode. This function does not return until the player exits
/// (BOOT long-press 3s). The caller should:
///   1. Suspend UDP listener and mDNS advertising
///   2. Free PSRAM frame buffers used by display_stream
///   3. Call doom_enter()
///   4. On return: esp_restart() to cleanly restore normal firmware state
///
/// Internally:
///   - Memory-maps the WAD partition
///   - Initializes doomgeneric with DG_* platform functions
///   - Runs the game loop until exit is requested
///   - Cleans up and returns
void doom_enter(void);

/// Check if Doom mode is currently active (for use by other subsystems
/// that need to know whether to yield resources).
bool doom_is_active(void);

/// Signal Doom to exit on the next tick (called from button handler
/// when BOOT long-press 3s is detected during Doom mode).
void doom_request_exit(void);

#ifdef __cplusplus
}
#endif

// Configuration
#define DOOM_TRIPLE_TAP_WINDOW_MS  800   // 3 presses must complete within this
#define DOOM_RENDER_WIDTH          320   // Native Doom resolution
#define DOOM_RENDER_HEIGHT         200
#define DOOM_TARGET_FPS            35    // Target frame rate

// WAD partition type/subtype (must match partitions_s3_doom.csv)
#define DOOM_WAD_PARTITION_TYPE    0x42
#define DOOM_WAD_PARTITION_SUBTYPE 0x06
