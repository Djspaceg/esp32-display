// Quake mode for every P4 and S3 board that can run it (quakeSupportsBoard).
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

/// From the normal firmware: whether the game data area (doom/src/
/// game_store.h) holds a pak0.pak the Quake boot will accept. NULL when it
/// does, else a short reason. Reads the area; never maps it. On the S3 the area
/// is registered first; a 16 MiB chip's 8 MiB area cannot hold pak0.pak.
const char* quake_pak_preflight(void);

#ifdef __cplusplus
}

#include <board_config.h>

// The renderer's one hard limit: it draws the engine's 320x240 base frame
// unscaled or at a whole-pixel scale and never shrinks it, so the panel must
// hold that frame in its own orientation (quake_input_model.h frameLayout,
// whose RENDER_WIDTH and RENDER_HEIGHT these must equal).
#define QUAKE_MIN_PANEL_WIDTH 320
#define QUAKE_MIN_PANEL_HEIGHT 240

/// Whether a board can run Quake, from what it is and never from a list of
/// boards: the Doom runtime Quake rides on (its USB input, game store and
/// boot menu), PSRAM for the engine heap and frames, and a panel that holds
/// the base frame. Whether a pak0.pak fits the chip's game data area is
/// quake_pak_preflight()'s, at boot: the shareware pak needs 32 MiB of flash.
inline bool quakeSupportsConfig(const board::Config &cfg) {
  return cfg.platform != nullptr && cfg.panel != nullptr &&
         cfg.platform->usePsramFrameBuffers &&
         cfg.panel->width >= QUAKE_MIN_PANEL_WIDTH &&
         cfg.panel->height >= QUAKE_MIN_PANEL_HEIGHT;
}

inline bool quakeSupportsBoard(board::Variant variant) {
  const board::Config *cfg = board::generatedConfigFor(variant);
  return cfg != nullptr && board::supportsDoom(variant) &&
         quakeSupportsConfig(*cfg);
}
#endif

// The render size on a 1x panel (the S3 boards), a build switch: 0x0 renders
// the whole panel (466x466 on the 1.75C); 372x280 or 320x240 render that 4:3
// window unscaled and centred inside the round glass. A test image may set
// quake_render_width/height before quake_enter() to try another. A size
// larger than the panel (372x280 on the 1.85C's 360x360) renders the whole
// panel.
//
// 372x280 by default. Measured on the 1.75C, timedemo demo1/demo2/demo3:
// 466x466 9.0/10.6/8.6 fps, 372x280 15.3/16.8/14.5, 320x240 18.5/19.8/17.5
// (render 91, 63 and 60 ms a frame). 372x280 is the largest 4:3 whose
// corners stay on the round glass, at about 1.7 times the full panel's rate.
#ifndef QUAKE_RENDER_WIDTH
#define QUAKE_RENDER_WIDTH 372
#endif
#ifndef QUAKE_RENDER_HEIGHT
#define QUAKE_RENDER_HEIGHT 280
#endif
// Where Video Options keeps a chosen size (the "espdisp" NVS namespace); a
// saved size overrides the build switch when it is one this panel offers.
#define QUAKE_RENDER_WIDTH_KEY "quakerw"
#define QUAKE_RENDER_HEIGHT_KEY "quakerh"
#ifdef __cplusplus
extern "C" {
#endif
extern int quake_render_width;
extern int quake_render_height;
#ifdef __cplusplus
}
#endif

// The engine heap ("-mem"): id's own default is 8 MB and its floor 5.3 MB;
// 16 MB leaves room for the larger shareware levels with PSRAM to spare. The
// S3's 8 MB of PSRAM cannot give 16, so the heap is this or what PSRAM has
// left once the frame buffers (allocated first) and QUAKE_HUNK_SLACK_BYTES are
// taken, whichever is smaller. The slack is for what is allocated in PSRAM
// after the hunk: the sound ring, Quake's video palette, and the larger
// mallocs IDF and Arduino make.
#define QUAKE_HUNK_BYTES (16u * 1024u * 1024u)
#define QUAKE_HUNK_SLACK_BYTES (64u * 1024u)
// The Quake task's stack, in PSRAM: several renderer functions keep 40-130 KB
// working arrays on the stack (R_EdgeDrawing alone 128 KB), more than the
// internal RAM could spare as one block. Play at 368x276 used 131 KB of it;
// 256 KB keeps 125 KB spare and gives the S3's hunk the 64 KB it needs to
// reach id's 5.3 MB floor at 466x466.
#define QUAKE_TASK_STACK_BYTES (256u * 1024u)
