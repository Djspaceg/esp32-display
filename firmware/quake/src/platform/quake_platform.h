// The wire between the engine's system layer (quake_sys_esp32.c, compiled as
// C beside the engine) and the hardware side (quake_hw_bridge.cpp and
// quake_mode.cpp, C++). Declarations only, no Arduino or engine headers, so
// either language includes it cleanly.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- Engine side (quake_sys_esp32.c) ----

/// Allocates the relocated arrays, the frame, depth buffer and surface cache,
/// then the hunk, then runs Host_Init. The hunk is hunk_bytes, or less where
/// PSRAM would not then keep slack_bytes free. Returns NULL on success, else
/// why it could not start.
const char* quake_engine_start(int argc, char** argv, uint32_t hunk_bytes,
                               uint32_t slack_bytes);

/// One pass of the host loop: Host_Frame with the time since the last pass.
/// Quake itself skips passes that come sooner than 1/72 s.
void quake_engine_frame(void);

/// Whether a menu, the console or a chat line has the keyboard, or the console
/// is forced up (no game and no demo), which is what decides what a touch
/// means.
bool quake_engine_in_menu(void);

/// Queues a line of console text, as if typed at the console.
void quake_engine_command(const char* text);

/// Frames drawn since start, for the frame-rate line.
uint32_t quake_engine_frames_rendered(void);

/// The codec's output rate, from quake_audio_setup(); 0 leaves Quake silent.
void quake_audio_set_rate(uint32_t rate);

/// The sound bridge's render callback (doom_audio_bridge.h): the next
/// `frames` frames of the mixing ring, on the bridge's output task.
void quake_audio_render(int16_t* out, size_t frames, unsigned channels);

/// r_dspeeds' per-stage times for one frame, in ms (r_misc.c R_PrintDSpeeds):
/// render total, world edges, brush models, edge scan with span drawing and
/// surface caching, alias models, view model, particles.
void quake_profile_frame(float render, float world, float bmodels, float scan,
                         float entities, float viewmodel, float particles);

/// Seconds spent building one cache surface (d_surf.c D_CacheSurface).
void quake_profile_surface_cache(double seconds);

// The S3 gives the second page to the hunk's floor: id's 5.3 MB guard
// (MINIMUM_MEMORY) is lowered to 5 MB there, which the shareware demos use
// under half of (2,465 KB at most, serial_s3_diagE.log). host.c reads it.
#if defined(ARDUINO_ESP32S3_DEV)
#define QUAKE_PLATFORM_MINIMUM_MEMORY 0x500000
#endif

// ---- Hardware side (quake_hw_bridge.cpp) ----

/// Sends engine text (Sys_Printf, so the console too) to Serial.
void quake_console_write(const char* text);

/// One line typed on Serial, ending in its newline, or NULL. Sys_ConsoleInput.
const char* quake_console_read_line(void);

/// The engine's frame size for this panel (quake_input_model.h frameLayout).
void quake_display_render_size(int* width, int* height);


/// 2 when frames go to the panel from another core while the next one is drawn
/// (the S3's 1x panel), so the engine draws into two pages in turn; else 1.
int quake_display_pages(void);

/// Stops frames going to the panel (the failure card's writes come next).
void quake_display_quiesce(void);

/// Converts one 8-bit frame through `palette565` (256 big-endian RGB565
/// entries) and puts it on the panel. With one page it returns once DMA is
/// done with it; with two it returns once the previous frame is on the panel,
/// and `pixels` is the panel's until the next call returns. A panel that never
/// completes ends the session.
void quake_display_present(const uint8_t* pixels, const uint16_t* palette565);

/// Samples touch, BOOT, USB and Serial and queues what they mean.
void quake_input_service(void);

/// QG_GetKey: one queued key event. Returns 0 when none is left.
int quake_input_get_key(int* down, int* key);

/// QG_GetMouseMove: accumulated mouse counts since the last call.
void quake_input_get_mouse(int* x, int* y);

/// Ends the session: Quake's own quit, or BOOT held for 3 s. Never returns.
void quake_quit(void) __attribute__((noreturn));

/// One "[quake] " line on Serial.
void quake_log(const char* format, ...) __attribute__((format(printf, 1, 2)));

/// Prints "[quake] FATAL: <reason>", shows it on the panel when it can, and
/// restarts into the normal firmware (display_stream/quake_bridge.cpp).
void quake_fail_restart(const char* reason, bool show_on_panel)
    __attribute__((noreturn));

#ifdef __cplusplus
}
#endif
