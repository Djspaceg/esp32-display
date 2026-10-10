// Quake mode for the P4 carriers and the S3 boards with 32 MiB of flash.
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
/// partition; never maps it. On the S3 it first registers the partition, which
/// fails on a chip too small for it.
const char* quake_pak_preflight(void);

#ifdef __cplusplus
}

#include <board_config.h>

/// The carriers Quake runs on: the three P4 boards, whose 32 MB of PSRAM
/// holds its 16 MB heap and whose flash layout has the quake_pak partition,
/// and the S3 boards whose panel holds a 320x240 frame (the 1.75C's 466x466,
/// the 1.85C's 360x360). An S3 also needs a 32 MiB chip for the pak, which
/// quake_pak_preflight() checks; with 16 MiB its menu leaves Quake out.
constexpr bool quakeSupportsBoard(board::Variant variant) {
  return variant == board::Variant::P4_4B || variant == board::Variant::P4_4C ||
         variant == board::Variant::P4_34C ||
         variant == board::Variant::AmoledCo5300 ||
         variant == board::Variant::LcdSt77916;
}
#endif

// The engine heap ("-mem"): id's own default is 8 MB and its floor 5.3 MB;
// 16 MB leaves room for the larger shareware levels with PSRAM to spare. The
// S3's 8 MB of PSRAM cannot give 16, so the heap is this or what PSRAM has
// left once QUAKE_HUNK_RESERVE_BYTES is kept back for the frame, depth buffer
// and surface cache allocated after it (about 880 KB), whichever is smaller.
#define QUAKE_HUNK_BYTES (16u * 1024u * 1024u)
#define QUAKE_HUNK_RESERVE_BYTES (1024u * 1024u)
// The Quake task's stack, in PSRAM: several renderer functions keep 40-130 KB
// working arrays on the stack (R_EdgeDrawing alone 128 KB), more than the
// internal RAM could spare as one block.
#define QUAKE_TASK_STACK_BYTES (320u * 1024u)
