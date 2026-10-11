// Hardware-free half of the read-only Quake data file: whether a flash
// partition holds a usable pack, how long that pack is, and how reads and
// seeks on the one file it serves behave.
//
// Pure C over plain bytes and a read callback, so the host suite
// (firmware/test/test_quake_pak.cpp) runs it without IDF, a partition or a
// board. The partition reads and the VFS registration that feed it live in
// quake_pak_vfs.c.
//
// The structural rule is tools/espdisp.py validate_quake_pak()'s, which is
// what `write-data quake_pak` refuses to write: "PACK" magic, a directory that
// is a whole number of 64-byte entries and lies after the header, and every
// entry inside the data. It adds one limit the tool does not: no more entries
// than the engine itself accepts (MAX_FILES_IN_PACK). The firmware cannot see the file's own length (a
// partition has no file size), so the partition is the bound, and the pack's
// length is where its last byte ends: the directory or the furthest entry.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

// The game store's directory (firmware/doom/src/platform), which says where
// each pak is.
#include "platform/game_store_model.h"

#ifdef __cplusplus
extern "C" {
#endif

#define QUAKE_PAK_HEADER_BYTES 12u
#define QUAKE_PAK_ENTRY_BYTES 64u
#define QUAKE_PAK_ENTRY_NAME_BYTES 56u
// The engine's own ceiling (common.c MAX_FILES_IN_PACK). A directory with
// more entries would be refused by COM_LoadPackFile anyway.
#define QUAKE_PAK_MAX_ENTRIES 2048u

// The one path the data file answers to, below the mount point. Quake opens
// "<basedir>/id1/pak0.pak"; the platform passes basedir "/qdata".
#define QUAKE_PAK_MOUNT "/qdata"
#define QUAKE_PAK_FILE_PATH "/id1/pak0.pak"

// Reads `length` bytes at `offset` of the partition into `out`. Returns false
// on a failed read.
typedef bool (*quake_pak_read_fn)(void* context, uint32_t offset, void* out,
                                  uint32_t length);

static inline uint32_t quake_pak_u32le(const uint8_t* p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}

// Checks the pack at the start of a partition of `partition_bytes`. Returns
// NULL when it is usable and sets *pack_bytes to its length; otherwise a short
// reason for the serial log, and *pack_bytes is 0.
static inline const char* quake_pak_check(quake_pak_read_fn read,
                                          void* context,
                                          uint32_t partition_bytes,
                                          uint32_t* pack_bytes) {
  *pack_bytes = 0;
  uint8_t header[QUAKE_PAK_HEADER_BYTES];
  if (partition_bytes < QUAKE_PAK_HEADER_BYTES) return "partition too small";
  if (!read(context, 0, header, sizeof(header))) return "header read failed";
  if (header[0] != 'P' || header[1] != 'A' || header[2] != 'C' ||
      header[3] != 'K') {
    return "no PACK header (write it with tools/espdisp.py write-data quake_pak)";
  }
  const uint32_t directory = quake_pak_u32le(header + 4);
  const uint32_t length = quake_pak_u32le(header + 8);
  if (length == 0 || length % QUAKE_PAK_ENTRY_BYTES != 0 ||
      length / QUAKE_PAK_ENTRY_BYTES > QUAKE_PAK_MAX_ENTRIES ||
      directory < QUAKE_PAK_HEADER_BYTES || directory > partition_bytes ||
      length > partition_bytes - directory) {
    return "pack directory does not fit the partition";
  }
  uint32_t end = directory + length;
  // A few entries per read: the shareware directory is 339 entries, 21 KB.
  uint8_t entries[QUAKE_PAK_ENTRY_BYTES * 8];
  for (uint32_t at = directory; at < directory + length;) {
    uint32_t chunk = directory + length - at;
    if (chunk > sizeof(entries)) chunk = sizeof(entries);
    if (!read(context, at, entries, chunk)) return "directory read failed";
    for (uint32_t i = 0; i < chunk; i += QUAKE_PAK_ENTRY_BYTES) {
      const uint8_t* entry = entries + i;
      const uint32_t offset =
          quake_pak_u32le(entry + QUAKE_PAK_ENTRY_NAME_BYTES);
      const uint32_t size =
          quake_pak_u32le(entry + QUAKE_PAK_ENTRY_NAME_BYTES + 4);
      if (offset > partition_bytes || size > partition_bytes - offset) {
        return "a pack entry points past the partition";
      }
      if (offset + size > end) end = offset + size;
    }
    at += chunk;
  }
  *pack_bytes = end;
  return NULL;
}

// Whether `path` (below the mount point) names the data file. Quake builds
// the path itself, always in this exact form.
static inline bool quake_pak_path_matches(const char* path) {
  const char* want = QUAKE_PAK_FILE_PATH;
  if (path == NULL) return false;
  while (*want != '\0' && *path == *want) {
    ++want;
    ++path;
  }
  return *want == '\0' && *path == '\0';
}

// Which pak `path` (below the mount point) names: N for "/id1/pakN.pak", N
// from 0 to 9, else -1. Quake opens pak0.pak, pak1.pak, ... in turn until one
// is missing; the game store holds each in its own slot.
static inline int quake_pak_path_slot(const char* path) {
  static const char prefix[] = "/id1/pak";
  if (path == NULL || strncmp(path, prefix, sizeof(prefix) - 1) != 0) {
    return -1;
  }
  const char* rest = path + sizeof(prefix) - 1;
  if (rest[0] < '0' || rest[0] > '9' || strcmp(rest + 1, ".pak") != 0) {
    return -1;
  }
  return rest[0] - '0';
}

// Where one pak Quake is given lies in the game data area.
typedef struct {
  uint32_t base;
  uint32_t bytes;
} quake_pak_span_t;

// The paks Quake is given from a parsed area: a legacy area is pak0.pak alone,
// from offset 0 across the whole area (quake_pak_check finds its end); a store
// gives pak0.pak and each slot after it up to the first gap, since Quake stops
// at the first missing pakN.pak. Returns how many, filling spans[0..n); 0 with
// *problem when there is no pak0.pak.
static inline int quake_pak_spans(const game_store_t* store,
                                  quake_pak_span_t* spans,
                                  const char** problem) {
  *problem = NULL;
  if (store->legacy) {
    spans[0].base = 0;
    spans[0].bytes = store->area_bytes;
    return 1;
  }
  int count = 0;
  for (uint8_t slot = 0; slot <= GAME_STORE_MAX_QUAKE_SLOT; ++slot) {
    const game_store_entry_t* entry = game_store_find_quake(store, slot);
    if (entry == NULL) break;
    spans[count].base = entry->offset;
    spans[count].bytes = entry->length;
    ++count;
  }
  if (count == 0) *problem = "no pak0.pak in the game store";
  return count;
}

// Where a seek lands, or -1 when it would leave the file. whence is 0, 1 or 2
// (SEEK_SET, SEEK_CUR, SEEK_END). Seeking to the very end is allowed; past it
// is refused rather than creating a hole nobody could read.
static inline int64_t quake_pak_seek(uint32_t position, uint32_t file_bytes,
                                     int64_t offset, int whence) {
  int64_t base;
  switch (whence) {
    case 0: base = 0; break;
    case 1: base = position; break;
    case 2: base = file_bytes; break;
    default: return -1;
  }
  const int64_t target = base + offset;
  if (target < 0 || target > (int64_t)file_bytes) return -1;
  return target;
}

// How many of `count` bytes a read at `position` returns: what remains of the
// file, never more.
static inline uint32_t quake_pak_read_length(uint32_t position,
                                             uint32_t file_bytes,
                                             size_t count) {
  if (position >= file_bytes) return 0;
  const uint32_t remaining = file_bytes - position;
  return count < remaining ? (uint32_t)count : remaining;
}

#ifdef __cplusplus
}
#endif
