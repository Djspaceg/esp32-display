// The read-only Quake data file (quake_pak_vfs.c). C linkage, callable from
// the normal firmware (the boot-menu check) and from the Quake boot.
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Checks that the quake_pak partition holds a usable pack, reading it with
// esp_partition_read() and never mapping it. NULL when it does, otherwise a
// short reason for the serial log. Call from a task with an internal stack.
const char* quake_pak_preflight(void);

// The pack's length after a successful check, else 0.
uint32_t quake_pak_bytes(void);

// The Quake boot: checks the pack and registers /qdata, whose one file
// id1/pak0.pak reads the partition. NULL on success, else the reason.
const char* quake_pak_mount(void);

// The reason the last check or mount refused.
const char* quake_pak_failure(void);

#ifdef __cplusplus
}
#endif
