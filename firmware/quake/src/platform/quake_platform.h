// The wire between the engine's system layer (quake_sys_esp32.c, compiled as
// C beside the engine) and the hardware side (quake_hw_bridge.cpp and
// quake_mode.cpp, C++). Declarations only, no Arduino or engine headers, so
// either language includes it cleanly.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- Engine side (quake_sys_esp32.c) ----

/// Allocates the relocated arrays, the frame and depth buffers and the hunk,
/// then runs Host_Init. Returns NULL on success, else why it could not start.
const char* quake_engine_start(int argc, char** argv, uint32_t hunk_bytes);

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

// ---- Hardware side (quake_hw_bridge.cpp) ----

/// Sends engine text (Sys_Printf, so the console too) to Serial.
void quake_console_write(const char* text);

/// One line typed on Serial, ending in its newline, or NULL. Sys_ConsoleInput.
const char* quake_console_read_line(void);

/// Converts one 320x240 8-bit frame through `palette565` (256 big-endian
/// RGB565 entries) and puts it on the panel. Returns only once DMA is done
/// with it; a panel that never completes ends the session.
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
