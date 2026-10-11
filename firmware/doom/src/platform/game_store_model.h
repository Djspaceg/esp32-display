// The game store: one directory, in the last 4 KiB sector of the board's
// game data area, naming every game file the Mac app has written there.
//
// The area is the flash Quake's data has always used: the P4's quake_pak
// partition, and on an S3 the raw region from 0x800000 (game_store.c). The
// partition table is unchanged, so no firmware update or erase is needed to
// start using it. The bundled doom1.wad stays where every USB flash puts it, in
// the doom_wad partition, and is not part of the store.
//
// Backward compatible both ways:
// - An area with no directory is the legacy layout: Quake's pak0.pak, raw, at
//   offset 0, as tools/espdisp.py write-data quake_pak and the app before the
//   store wrote it.
// - The app places pak0.pak at offset 0 whenever it can (it moves any file it
//   holds a copy of out of the way), so firmware from before the store still
//   finds it there and boots Quake.
//
// Versioned: a directory whose version is newer than this firmware's is
// refused with a reason that says to update, never misread.
//
// Pure C over plain bytes, so firmware/test/test_game_store.cpp runs it on the
// host. The Mac app's encoder (SenderProtocol/GameStore.swift) writes exactly
// this layout; the shared fixture mac/ESPDisplaySender/Tests/
// SenderProtocolTests/Fixtures/game-store-v1.hex holds both to it.
//
// Directory sector, little-endian:
//   0  char[8]  "ESPGAMES"
//   8  u16      version (1)
//   10 u16      entry bytes (64)
//   12 u16      entry count
//   14 u16      0
//   16 u32      area bytes this directory was written for
//   20 u32      generation, one more on every write
//   24 u32      CRC-32 (zlib) of bytes [0, 32 + 64 * count), this field 0
//   28 u32      0
//   32 entries, each:
//      0  u8       kind (1 Doom WAD, 2 Quake pak)
//      1  u8       slot (Quake: N of id1/pakN.pak; Doom: 0)
//      2  u16      flags (0)
//      4  u32      offset in the area, a multiple of 4096
//      8  u32      length in bytes
//      12 char[20] file name, lowercase, NUL padded
//      32 u8[32]   SHA-256 of the file, for the app to recognise it
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GAME_STORE_MAGIC "ESPGAMES"
#define GAME_STORE_MAGIC_BYTES 8u
#define GAME_STORE_VERSION 1u
#define GAME_STORE_SECTOR_BYTES 4096u
#define GAME_STORE_HEADER_BYTES 32u
#define GAME_STORE_ENTRY_BYTES 64u
#define GAME_STORE_NAME_BYTES 20u
#define GAME_STORE_MAX_ENTRIES 16u
// The boot menu lists each one; more would not fit a round panel's list.
#define GAME_STORE_MAX_DOOM_WADS 8u
// id1/pak0.pak .. pak9.pak.
#define GAME_STORE_MAX_QUAKE_SLOT 9u

#define GAME_STORE_KIND_DOOM_WAD 1u
#define GAME_STORE_KIND_QUAKE_PAK 2u

// The S3 area: from where the universal 8 MiB table ends, up to 18 MiB of what
// the chip has beyond it (a 32 MiB chip: Quake's original region exactly; a
// 16 MiB chip: 8 MiB, room for Doom WADs but not Quake's pak0). Below 1 MiB
// there is no area.
#define GAME_STORE_S3_OFFSET 0x800000u
#define GAME_STORE_S3_MAX_BYTES 0x1200000u
#define GAME_STORE_MIN_AREA_BYTES 0x100000u

typedef struct {
  uint8_t kind;
  uint8_t slot;
  uint32_t offset;
  uint32_t length;
  char name[GAME_STORE_NAME_BYTES + 1];
  uint8_t sha256[32];
} game_store_entry_t;

typedef struct {
  // No directory sector: the legacy layout (a raw pak0.pak at offset 0, if
  // anything). count is then 0.
  bool legacy;
  uint32_t area_bytes;
  uint32_t generation;
  size_t count;
  game_store_entry_t entries[GAME_STORE_MAX_ENTRIES];
} game_store_t;

static inline uint32_t game_store_u32(const uint8_t* p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}

static inline uint16_t game_store_u16(const uint8_t* p) {
  return (uint16_t)(p[0] | (p[1] << 8));
}

// zlib's CRC-32 (reflected 0xEDB88320), bitwise: the directory is 1 KiB at
// most and is read once a boot.
static inline uint32_t game_store_crc32(const uint8_t* data, size_t length) {
  uint32_t crc = 0xFFFFFFFFu;
  for (size_t i = 0; i < length; ++i) {
    crc ^= data[i];
    for (int bit = 0; bit < 8; ++bit) {
      crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
  }
  return ~crc;
}

// Where the directory sector sits in an area of `area_bytes`.
static inline uint32_t game_store_directory_offset(uint32_t area_bytes) {
  return area_bytes - GAME_STORE_SECTOR_BYTES;
}

// The S3 area's size on a chip of `physical_bytes`, or 0 when there is none.
static inline uint32_t game_store_s3_area_bytes(uint32_t physical_bytes) {
  if (physical_bytes < GAME_STORE_S3_OFFSET + GAME_STORE_MIN_AREA_BYTES) {
    return 0;
  }
  const uint32_t beyond = physical_bytes - GAME_STORE_S3_OFFSET;
  return beyond < GAME_STORE_S3_MAX_BYTES ? beyond : GAME_STORE_S3_MAX_BYTES;
}

static inline char game_store_lower(char c) {
  return (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
}

static inline bool game_store_names_equal(const char* a, const char* b) {
  if (a == NULL || b == NULL) return false;
  while (*a != '\0' && game_store_lower(*a) == game_store_lower(*b)) {
    ++a;
    ++b;
  }
  return *a == '\0' && *b == '\0';
}

static inline bool game_store_ends_with(const char* name, size_t length,
                                        const char* suffix) {
  const size_t suffix_length = strlen(suffix);
  return length >= suffix_length &&
         memcmp(name + length - suffix_length, suffix, suffix_length) == 0;
}

// A stored name: 5 to 20 of [a-z0-9._-], NUL padded, and for its kind a .wad
// (Doom) or exactly pak<slot>.pak (Quake), because that is the name the
// engine opens it by.
static inline bool game_store_name_valid(const uint8_t* raw, uint8_t kind,
                                         uint8_t slot, char* out) {
  size_t length = 0;
  while (length < GAME_STORE_NAME_BYTES && raw[length] != 0) ++length;
  for (size_t i = length; i < GAME_STORE_NAME_BYTES; ++i) {
    if (raw[i] != 0) return false;
  }
  if (length < 5) return false;
  for (size_t i = 0; i < length; ++i) {
    const char c = (char)raw[i];
    const bool ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
                    c == '.' || c == '_' || c == '-';
    if (!ok) return false;
    out[i] = c;
  }
  out[length] = '\0';
  if (kind == GAME_STORE_KIND_DOOM_WAD) {
    return game_store_ends_with(out, length, ".wad");
  }
  char want[] = "pak0.pak";
  want[3] = (char)('0' + slot);
  return strcmp(out, want) == 0;
}

// Reads the directory sector of an area of `area_bytes`. NULL when the area is
// usable: either a valid directory, or none at all (out->legacy). Otherwise a
// short reason for the serial log, and out holds nothing.
static inline const char* game_store_parse(const uint8_t* sector,
                                           uint32_t area_bytes,
                                           game_store_t* out) {
  memset(out, 0, sizeof(*out));
  out->area_bytes = area_bytes;
  if (area_bytes < GAME_STORE_MIN_AREA_BYTES ||
      area_bytes % GAME_STORE_SECTOR_BYTES != 0) {
    return "game data area too small";
  }
  if (memcmp(sector, GAME_STORE_MAGIC, GAME_STORE_MAGIC_BYTES) != 0) {
    out->legacy = true;
    return NULL;
  }
  const uint16_t version = game_store_u16(sector + 8);
  if (version > GAME_STORE_VERSION) {
    return "game store is a newer version; update the firmware";
  }
  if (version != GAME_STORE_VERSION ||
      game_store_u16(sector + 10) != GAME_STORE_ENTRY_BYTES ||
      game_store_u16(sector + 14) != 0 || game_store_u32(sector + 28) != 0) {
    return "game store directory is damaged";
  }
  const uint16_t count = game_store_u16(sector + 12);
  if (count > GAME_STORE_MAX_ENTRIES) return "game store has too many files";
  if (game_store_u32(sector + 16) != area_bytes) {
    return "game store was written for a different area size";
  }
  const size_t covered =
      GAME_STORE_HEADER_BYTES + (size_t)count * GAME_STORE_ENTRY_BYTES;
  uint8_t copy[GAME_STORE_HEADER_BYTES +
               GAME_STORE_MAX_ENTRIES * GAME_STORE_ENTRY_BYTES];
  memcpy(copy, sector, covered);
  memset(copy + 24, 0, 4);
  if (game_store_crc32(copy, covered) != game_store_u32(sector + 24)) {
    return "game store directory is damaged";
  }

  const uint32_t data_end = game_store_directory_offset(area_bytes);
  size_t doom_wads = 0;
  for (uint16_t i = 0; i < count; ++i) {
    const uint8_t* raw =
        sector + GAME_STORE_HEADER_BYTES + (size_t)i * GAME_STORE_ENTRY_BYTES;
    game_store_entry_t* entry = &out->entries[i];
    entry->kind = raw[0];
    entry->slot = raw[1];
    entry->offset = game_store_u32(raw + 4);
    entry->length = game_store_u32(raw + 8);
    memcpy(entry->sha256, raw + 32, sizeof(entry->sha256));
    if (entry->kind == GAME_STORE_KIND_DOOM_WAD) {
      if (entry->slot != 0) return "game store entry is damaged";
      if (++doom_wads > GAME_STORE_MAX_DOOM_WADS) {
        return "game store has too many Doom WADs";
      }
    } else if (entry->kind == GAME_STORE_KIND_QUAKE_PAK) {
      if (entry->slot > GAME_STORE_MAX_QUAKE_SLOT) {
        return "game store entry is damaged";
      }
    } else {
      return "game store holds a file this firmware does not know";
    }
    if (game_store_u16(raw + 2) != 0 ||
        !game_store_name_valid(raw + 12, entry->kind, entry->slot,
                               entry->name)) {
      return "game store entry is damaged";
    }
    if (entry->offset % GAME_STORE_SECTOR_BYTES != 0 || entry->length < 12 ||
        entry->offset > data_end || entry->length > data_end - entry->offset) {
      return "game store entry is outside the area";
    }
    for (uint16_t j = 0; j < i; ++j) {
      const game_store_entry_t* other = &out->entries[j];
      const bool apart = entry->offset >= other->offset + other->length ||
                         other->offset >= entry->offset + entry->length;
      if (!apart) return "game store entries overlap";
      if (other->kind == entry->kind &&
          (entry->kind == GAME_STORE_KIND_QUAKE_PAK
               ? other->slot == entry->slot
               : game_store_names_equal(other->name, entry->name))) {
        return "game store names a file twice";
      }
    }
  }
  out->count = count;
  out->generation = game_store_u32(sector + 20);
  return NULL;
}

// The Doom WAD named `name` (any case), or NULL.
static inline const game_store_entry_t* game_store_find_doom(
    const game_store_t* store, const char* name) {
  for (size_t i = 0; i < store->count; ++i) {
    const game_store_entry_t* entry = &store->entries[i];
    if (entry->kind == GAME_STORE_KIND_DOOM_WAD &&
        game_store_names_equal(entry->name, name)) {
      return entry;
    }
  }
  return NULL;
}

// The Quake pak in `slot`, or NULL.
static inline const game_store_entry_t* game_store_find_quake(
    const game_store_t* store, uint8_t slot) {
  for (size_t i = 0; i < store->count; ++i) {
    const game_store_entry_t* entry = &store->entries[i];
    if (entry->kind == GAME_STORE_KIND_QUAKE_PAK && entry->slot == slot) {
      return entry;
    }
  }
  return NULL;
}

// The boot menu's label for a stored WAD: its name without ".wad", upper case,
// so "freedoom1.wad" reads FREEDOOM1. A stored doom.wad keeps its extension,
// DOOM.WAD, so it is not a second row reading DOOM, the bundled doom1.wad's.
// `out` holds GAME_STORE_NAME_BYTES + 1.
static inline void game_store_doom_label(const char* name, char* out) {
  size_t length = strlen(name);
  if (length > GAME_STORE_NAME_BYTES) length = GAME_STORE_NAME_BYTES;
  if (game_store_ends_with(name, length, ".wad") &&
      !(length == 8 && game_store_names_equal(name, "doom.wad"))) {
    length -= 4;
  }
  for (size_t i = 0; i < length; ++i) {
    const char c = name[i];
    out[i] = (c >= 'a' && c <= 'z') ? (char)(c - 'a' + 'A') : c;
  }
  out[length] = '\0';
}

#ifdef __cplusplus
}
#endif
