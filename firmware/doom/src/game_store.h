// The board's game data area and its directory (platform/game_store_model.h
// has the format). C linkage: the boot menu, the Doom boot and the Quake boot
// all read it.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include <esp_partition.h>

#include "platform/game_store_model.h"

#ifdef __cplusplus
extern "C" {
#endif

// Finds the game data area (the P4's quake_pak partition; on an S3 the raw
// region past 8 MiB, registered here) and reads its directory, once a boot.
// NULL when it is usable, a directory or the legacy layout; otherwise a short
// reason for the serial log. Call from a task with an internal stack.
const char* game_store_open(void);

// The area, after a NULL game_store_open(); otherwise NULL.
const esp_partition_t* game_store_partition(void);

// The directory, after a NULL game_store_open(); otherwise NULL.
const game_store_t* game_store_directory(void);

// Reads area bytes with esp_partition_read(). Internal stacks only.
bool game_store_read(uint32_t offset, void* out, uint32_t length);

#ifdef __cplusplus
}
#endif
