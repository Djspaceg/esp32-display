// Doom mode for supported ESP32 display profiles.
//
// Chosen from the boot-mode menu (display_stream/boot_menu.h), which a power-on
// or a triple press of BOOT opens. The choice restarts into an isolated Doom
// boot that returns to normal firmware on BOOT long-press (3s).
//
// Compiled into family builds that define ESPDISP_DOOM_RUNTIME.
#pragma once

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

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
/// A failure to start does not return: it is reported on Serial and the
/// panel through doom_fail_restart() (platform/doom_log.h), which restarts.
void doom_enter(void);

/// Check, from the normal firmware, that the Doom boot will find a usable
/// WAD: the same partition rule and structural check the Doom boot applies.
/// Returns NULL when it will, otherwise a short reason for the serial log.
/// Only a full USB flash of the bundle writes the WAD; WiFi updates and
/// rescue images write the app alone.
const char* doom_wad_preflight(void);

/// Why the Doom boot's own WAD check last refused, for its FATAL line.
const char* doom_wad_failure(void);

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
#define DOOM_DOUBLE_TAP_WINDOW_MS  400   // Distinguish Fire from Use/Open
#define DOOM_RENDER_WIDTH          320   // Native Doom resolution
#define DOOM_RENDER_HEIGHT         200
#define DOOM_TARGET_FPS            35    // Target frame rate

// WAD storage geometry retained by the universal S3 image. The canonical
// partition table occupies only the first 8 MiB, so uploads preserve this raw
// 16 MiB-carrier region even though it is no longer listed as a partition.
#define DOOM_WAD_PARTITION_TYPE    0x42
#define DOOM_WAD_PARTITION_SUBTYPE 0x06
#define DOOM_WAD_PARTITION_OFFSET  0xBFF000U
#define DOOM_WAD_PARTITION_BYTES   0x401000U
#define DOOM_WAD_EXPECTED_BYTES    4196020U
