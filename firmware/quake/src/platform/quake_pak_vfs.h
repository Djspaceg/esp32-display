// The read-only Quake data file (quake_pak_vfs.c). C linkage, callable from
// the normal firmware (the boot-menu check) and from the Quake boot.
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Checks that the game data area holds a usable pak0.pak, and any pak1.pak and
// on after it, reading them with esp_partition_read() and never mapping them.
// NULL when it does, otherwise a short reason for the serial log. Call from a
// task with an internal stack.
const char* quake_pak_preflight(void);

// pak0.pak's length after a successful check, else 0.
uint32_t quake_pak_bytes(void);

// The Quake boot: checks the paks and registers /qdata, whose id1/pakN.pak
// files read the area and whose every other file (config.cfg, the saves) is
// in the saved-games store. NULL on success, else the reason.
const char* quake_pak_mount(void);

// The reason the last check or mount refused.
const char* quake_pak_failure(void);

#ifdef __cplusplus
}
#endif
