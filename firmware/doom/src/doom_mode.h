// Doom mode for supported ESP32 display profiles.
//
// Chosen from the boot-mode menu (display_stream/boot_menu.h), which a power-on
// or a triple press of BOOT opens. The choice restarts into an isolated Doom
// boot that returns to normal firmware on BOOT long-press (3s).
//
// Compiled into family builds that define ESPDISP_DOOM_RUNTIME.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#include "platform/game_store_model.h"

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

/// Plays the game store's WAD `name` (game_store.h) this boot instead of the
/// bundled doom1.wad. Call before doom_enter(); NULL or "" keeps doom1.wad.
void doom_select_store_wad(const char* name);

/// The WAD this boot plays, as the engine is told it: "doom1.wad" or the
/// stored file's name.
const char* doom_selected_wad_name(void);

/// Whether the WAD is memory-mapped (the bundled one) rather than read into
/// the engine's zone as it is used (a stored one). Meaningful once
/// doom_enter() has checked it.
bool doom_wad_is_mapped(void);

/// The boot menu's list of stored WADs the Doom boot would accept, checked
/// the same way through the flash API: up to `max` names, in directory order,
/// and how many. *problem is the first reason one was left out, or why the
/// store could not be read; NULL when nothing was refused.
size_t doom_store_wad_preflight(char names[][GAME_STORE_NAME_BYTES + 1],
                                size_t max, const char** problem);

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

// WAD storage geometry of the legacy S3 developer images, whose 16 MiB table
// omitted the doom_wad entry. The universal table's doom_wad partition replaces
// it; on a universal 16 MiB S3 this raw region now lies inside the game data
// area (game_store.h), which the Mac app may write.
#define DOOM_WAD_PARTITION_TYPE    0x42
#define DOOM_WAD_PARTITION_SUBTYPE 0x06
#define DOOM_WAD_PARTITION_OFFSET  0xBFF000U
#define DOOM_WAD_PARTITION_BYTES   0x401000U
#define DOOM_WAD_EXPECTED_BYTES    4196020U
