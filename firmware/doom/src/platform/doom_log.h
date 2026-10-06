// Doom-path diagnostics that always reach the serial port.
//
// Every Doom failure ends in a restart into the normal firmware, so the last
// serial line before that restart is the only record of why. ESP_LOGx cannot
// carry it: the P4 image is built with CONFIG_LOG_MAXIMUM_LEVEL=1, which
// removes most of those lines. These print through Arduino Serial, the same
// path as the sketch's own "doom:" lines. Defined in doom_hw_bridge.cpp
// (log lines) and display_stream/doom_bridge.cpp (the fatal exit).
#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One "[doom] " line on Serial. Not reentrant: call from loopTask only.
void doom_log(const char* format, ...) __attribute__((format(printf, 1, 2)));

/// One "[doom] stage <name>" line carrying the calling task's stack
/// high-water mark (the fewest bytes it has ever had free).
void doom_log_stage(const char* stage);

/// Print "[doom] FATAL: <reason>", show the reason on the panel for a few
/// seconds when show_on_panel is set and the panel is usable, then restart
/// into the normal firmware. Pass show_on_panel=false when the panel itself
/// is what failed.
void doom_fail_restart(const char* reason, bool show_on_panel)
    __attribute__((noreturn));

#ifdef __cplusplus
}
#endif
