// Quake mode for the P4 display carriers.
//
// Chosen from the boot-mode menu (display_stream/boot_menu.h) like Doom: the
// choice saves a one-shot request and restarts, and the next boot consumes it
// and runs Quake alone, before WiFi, streaming or the loop watchdog start.
// Any failure, and BOOT held for 3 s, restarts into the normal firmware.
//
// Compiled into images that define ESPDISP_QUAKE_RUNTIME (quake_build.h).
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "quake_build.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Run Quake. Does not return until the player leaves; the caller then
/// restarts. A failure to start does not return either: it is reported on
/// Serial and the panel (quake_fail_restart) and restarts.
void quake_enter(void);

/// From the normal firmware: whether the quake_pak partition holds a pack the
/// Quake boot will accept. NULL when it does, else a short reason. Reads the
/// partition; never maps it.
const char* quake_pak_preflight(void);

#ifdef __cplusplus
}

#include <board_config.h>

/// The carriers Quake runs on: the three P4 boards, whose 32 MB of PSRAM
/// holds its 16 MB heap and whose flash layout has the quake_pak partition.
constexpr bool quakeSupportsBoard(board::Variant variant) {
  return variant == board::Variant::P4_4B || variant == board::Variant::P4_4C ||
         variant == board::Variant::P4_34C;
}
#endif

// The engine heap ("-mem"): id's own default is 8 MB and its floor 5.3 MB;
// 16 MB leaves room for the larger shareware levels with PSRAM to spare.
#define QUAKE_HUNK_BYTES (16u * 1024u * 1024u)
// The Quake task's stack, in PSRAM: several renderer functions keep 40-130 KB
// working arrays on the stack (R_EdgeDrawing alone 128 KB), more than the
// internal RAM could spare as one block.
#define QUAKE_TASK_STACK_BYTES (320u * 1024u)
