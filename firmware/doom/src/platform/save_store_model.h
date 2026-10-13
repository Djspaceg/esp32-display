// The saved-games store: Quake's config.cfg and saves, Doom's default.cfg and
// saves, kept in a flash area across restarts and firmware updates.
//
// The area is the game_saves partition of the S3 and P4 tables (47 sectors on
// an S3, 128 on a P4); save_store.c.inc finds it. No bundle writes it.
//
// Each file is one record of whole 4 KiB sectors, anywhere in the area. Its
// first sector, the head, starts with a header naming the file and every
// sector it holds (a bitmap, so a record need not be contiguous); its stored
// bytes follow the header and run on through the other sectors in ascending
// order. Nothing else is kept: mounting reads every sector's first bytes and
// keeps each record whose header and payload both pass their CRCs.
//
// A write never touches the record it replaces: the new record goes into free
// sectors, payload first and header last, and only then is the old head
// erased. The power going at any point leaves the old file or the new one,
// whole; two whole copies of a name are resolved at mount to the newer
// (higher sequence), and the older head is erased then. New sectors are taken
// round the area from where the last write stopped, so repeated config saves
// wear every free sector alike.
//
// Room: a file is replaced as above whenever both copies fit. When they do
// not, but the new one fits in the old one's place, the old copy is erased
// first: a slot can always be saved over at its size or smaller, but a power
// cut or flash error during that write loses it. A new file, and an in-place
// save while other files remain, must leave one sector free, so a one-sector
// file is always replaced whole. Every config is one: Quake's config.cfg is
// about 1.8 KB and Doom's two about 1.1 and 0.6 KB, raw.
//
// Pure C over a flash interface, so firmware/test/test_save_store.cpp runs it
// on the host against a NOR flash fake. Compression is the caller's: the
// header records how the payload is encoded and the raw length and CRC.
//
// Head sector, little-endian:
//   0  char[8]  "ESPSAVE2"
//   8  u32      sequence, one more than any other record's
//   12 u32      stored (payload) bytes
//   16 u32      raw bytes, after decoding
//   20 u32      CRC-32 (zlib) of the raw bytes
//   24 u32      CRC-32 of the stored bytes
//   28 u8       encoding: 0 raw, 1 raw deflate
//   29 u8[3]    0
//   32 char[48] name, NUL padded: "quake/id1/s0.sav", "doom/default.cfg"
//   80 u8[16]   sector map, bit N (byte N/8, bit N%8) for sector N; includes
//               the head
//   96 u32      CRC-32 of bytes 0 to 96
//   100         stored bytes
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SAVE_STORE_SECTOR_BYTES 4096u
#define SAVE_STORE_MAX_SECTORS 128u
#define SAVE_STORE_HEAD_BYTES 100u
#define SAVE_STORE_NAME_BYTES 48
#define SAVE_STORE_MAX_FILES 64
#define SAVE_STORE_ENCODING_RAW 0
#define SAVE_STORE_ENCODING_DEFLATE 1

static const char SAVE_STORE_MAGIC[8] = {'E', 'S', 'P', 'S', 'A', 'V', 'E', '2'};

// save_store_write's answer when there is no room, as opposed to a flash
// error: compare the pointer.
static const char SAVE_STORE_FULL[] = "save area full";

typedef struct {
  void* context;
  bool (*read)(void* context, uint32_t offset, void* out, uint32_t length);
  // Clears bits only, as NOR flash does; the sector was erased first.
  bool (*write)(void* context, uint32_t offset, const void* data,
                uint32_t length);
  bool (*erase_sector)(void* context, uint32_t sector);
} save_store_flash_t;

// A set of sectors.
typedef struct {
  uint32_t words[SAVE_STORE_MAX_SECTORS / 32];
} save_store_mask_t;

typedef struct {
  char name[SAVE_STORE_NAME_BYTES];
  uint32_t sequence;
  save_store_mask_t mask;
  uint32_t stored_bytes;
  uint32_t raw_bytes;
  uint32_t raw_crc;
  uint32_t stored_crc;
  uint8_t encoding;
  uint8_t head;
} save_store_file_t;

typedef struct {
  save_store_flash_t flash;
  uint32_t sectors;
  uint32_t next_sequence;
  uint32_t cursor;  // where the next allocation starts looking
  // Heads of replaced copies whose erase failed; retried before a remove,
  // which would otherwise bring the old copy back at the next mount.
  save_store_mask_t stale;
  int count;
  save_store_file_t files[SAVE_STORE_MAX_FILES];
  save_store_file_t scan[SAVE_STORE_MAX_SECTORS];  // mount's working set
} save_store_t;

// zlib's CRC-32, continuing from `crc` (0 to start).
static inline uint32_t save_store_crc32(uint32_t crc, const uint8_t* data,
                                        size_t length) {
  static const uint32_t nibble[16] = {
      0x00000000u, 0x1DB71064u, 0x3B6E20C8u, 0x26D930ACu,
      0x76DC4190u, 0x6B6B51F4u, 0x4DB26158u, 0x5005713Cu,
      0xEDB88320u, 0xF00F9344u, 0xD6D6A3E8u, 0xCB61B38Cu,
      0x9B64C2B0u, 0x86D3D2D4u, 0xA00AE278u, 0xBDBDF21Cu};
  crc = ~crc;
  for (size_t i = 0; i < length; ++i) {
    crc ^= data[i];
    crc = (crc >> 4) ^ nibble[crc & 15];
    crc = (crc >> 4) ^ nibble[crc & 15];
  }
  return ~crc;
}

static inline uint32_t save_store_get32(const uint8_t* p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}

static inline void save_store_put32(uint8_t* p, uint32_t v) {
  p[0] = (uint8_t)v;
  p[1] = (uint8_t)(v >> 8);
  p[2] = (uint8_t)(v >> 16);
  p[3] = (uint8_t)(v >> 24);
}

static inline bool save_store_has(const save_store_mask_t* m, uint32_t s) {
  return (m->words[s / 32] >> (s % 32)) & 1u;
}

static inline void save_store_add(save_store_mask_t* m, uint32_t s) {
  m->words[s / 32] |= 1u << (s % 32);
}

static inline void save_store_take(save_store_mask_t* m, uint32_t s) {
  m->words[s / 32] &= ~(1u << (s % 32));
}

static inline void save_store_union(save_store_mask_t* m,
                                    const save_store_mask_t* other) {
  for (uint32_t i = 0; i < SAVE_STORE_MAX_SECTORS / 32; ++i) {
    m->words[i] |= other->words[i];
  }
}

static inline bool save_store_overlap(const save_store_mask_t* a,
                                      const save_store_mask_t* b) {
  for (uint32_t i = 0; i < SAVE_STORE_MAX_SECTORS / 32; ++i) {
    if (a->words[i] & b->words[i]) return true;
  }
  return false;
}

static inline uint32_t save_store_popcount(const save_store_mask_t* m) {
  uint32_t n = 0;
  for (uint32_t i = 0; i < SAVE_STORE_MAX_SECTORS / 32; ++i) {
    for (uint32_t v = m->words[i]; v != 0; v &= v - 1) ++n;
  }
  return n;
}

// Sectors a payload of `stored` bytes takes.
static inline uint32_t save_store_sectors_for(uint32_t stored) {
  const uint32_t first = SAVE_STORE_SECTOR_BYTES - SAVE_STORE_HEAD_BYTES;
  if (stored <= first) return 1;
  return 1 + (stored - first + SAVE_STORE_SECTOR_BYTES - 1) /
                 SAVE_STORE_SECTOR_BYTES;
}

// Where payload byte `at` of a record lies in the area, and how many bytes
// from there stay in the same sector.
static inline uint32_t save_store_payload_address(uint32_t head,
                                                  const save_store_mask_t* mask,
                                                  uint32_t at,
                                                  uint32_t* run) {
  const uint32_t first = SAVE_STORE_SECTOR_BYTES - SAVE_STORE_HEAD_BYTES;
  if (at < first) {
    *run = first - at;
    return head * SAVE_STORE_SECTOR_BYTES + SAVE_STORE_HEAD_BYTES + at;
  }
  at -= first;
  uint32_t index = at / SAVE_STORE_SECTOR_BYTES;
  const uint32_t within = at % SAVE_STORE_SECTOR_BYTES;
  for (uint32_t sector = 0; sector < SAVE_STORE_MAX_SECTORS; ++sector) {
    if (sector == head || !save_store_has(mask, sector)) continue;
    if (index-- == 0) {
      *run = SAVE_STORE_SECTOR_BYTES - within;
      return sector * SAVE_STORE_SECTOR_BYTES + within;
    }
  }
  *run = 0;
  return 0;
}

static inline bool save_store_read_payload(const save_store_flash_t* flash,
                                           uint32_t head,
                                           const save_store_mask_t* mask,
                                           uint32_t at, void* out,
                                           uint32_t length) {
  uint8_t* dst = (uint8_t*)out;
  while (length > 0) {
    uint32_t run = 0;
    const uint32_t address = save_store_payload_address(head, mask, at, &run);
    if (run == 0) return false;
    if (run > length) run = length;
    if (!flash->read(flash->context, address, dst, run)) return false;
    dst += run;
    at += run;
    length -= run;
  }
  return true;
}

// A usable file name: 1 to 47 of printable ASCII bar space and backslash,
// '/'-separated parts none of which is empty, "." or "..".
static inline bool save_store_name_valid(const char* name) {
  const size_t length = strnlen(name, SAVE_STORE_NAME_BYTES);
  if (length == 0 || length >= SAVE_STORE_NAME_BYTES) return false;
  size_t part = 0;
  for (size_t i = 0; i <= length; ++i) {
    const char c = name[i];
    if (c == '/' || c == '\0') {
      if (part == 0) return false;
      if (part == 1 && name[i - 1] == '.') return false;
      if (part == 2 && name[i - 1] == '.' && name[i - 2] == '.') return false;
      part = 0;
      continue;
    }
    if (c <= ' ' || c > '~' || c == '\\') return false;
    ++part;
  }
  return true;
}

// A store name from a path under a mount point: `prefix` (or none) then the
// path's parts, with empty and "." parts dropped. False when the result is
// not a usable name.
static inline bool save_store_name_from_path(const char* prefix,
                                             const char* path,
                                             char out[SAVE_STORE_NAME_BYTES]) {
  size_t used = 0;
  out[0] = '\0';
  if (prefix != NULL && prefix[0] != '\0') {
    used = strnlen(prefix, SAVE_STORE_NAME_BYTES);
    if (used >= SAVE_STORE_NAME_BYTES) return false;
    memcpy(out, prefix, used);
  }
  const char* p = path;
  bool last_dot = false;
  while (*p != '\0') {
    while (*p == '/') ++p;
    const char* end = p;
    while (*end != '\0' && *end != '/') ++end;
    const size_t part = (size_t)(end - p);
    if (part == 0) break;
    last_dot = part == 1 && p[0] == '.';
    if (!last_dot) {
      const size_t sep = used > 0 ? 1 : 0;
      if (used + sep + part >= SAVE_STORE_NAME_BYTES) return false;
      if (sep) out[used++] = '/';
      memcpy(out + used, p, part);
      used += part;
    }
    p = end;
  }
  out[used] = '\0';
  // A path naming only a directory ("/id1/", "/id1/.") is not a file.
  if (last_dot) return false;
  if (path[0] != '\0' && path[strlen(path) - 1] == '/') return false;
  if (prefix != NULL && prefix[0] != '\0' &&
      used == strnlen(prefix, SAVE_STORE_NAME_BYTES)) {
    return false;
  }
  return save_store_name_valid(out);
}

static inline int save_store_find(const save_store_t* store,
                                  const char* name) {
  for (int i = 0; i < store->count; ++i) {
    if (strncmp(store->files[i].name, name, SAVE_STORE_NAME_BYTES) == 0) {
      return i;
    }
  }
  return -1;
}

static inline save_store_mask_t save_store_used_mask(const save_store_t* store) {
  save_store_mask_t used;
  memset(&used, 0, sizeof(used));
  for (int i = 0; i < store->count; ++i) {
    save_store_union(&used, &store->files[i].mask);
  }
  return used;
}

static inline uint32_t save_store_free_sectors(const save_store_t* store) {
  const save_store_mask_t used = save_store_used_mask(store);
  return store->sectors - save_store_popcount(&used);
}

// Whether `name` already holds exactly these raw bytes, so a write of them
// can be skipped and spare the flash.
static inline bool save_store_unchanged(const save_store_t* store,
                                        const char* name, uint32_t raw_bytes,
                                        uint32_t raw_crc) {
  const int i = save_store_find(store, name);
  return i >= 0 && store->files[i].raw_bytes == raw_bytes &&
         store->files[i].raw_crc == raw_crc;
}

// Reads `length` stored bytes of file `index` from `at`.
static inline bool save_store_read(const save_store_t* store, int index,
                                   uint32_t at, void* out, uint32_t length) {
  if (index < 0 || index >= store->count) return false;
  const save_store_file_t* file = &store->files[index];
  if (at > file->stored_bytes || length > file->stored_bytes - at) {
    return false;
  }
  return save_store_read_payload(&store->flash, file->head, &file->mask, at,
                                 out, length);
}

static inline void save_store_drop(save_store_t* store, int index) {
  store->files[index] = store->files[--store->count];
}

// Parses one sector's header; true with *out filled when it is a record's
// head whose header CRC passes and whose fields fit the area.
static inline bool save_store_parse_head(const uint8_t* h, uint32_t sector,
                                         uint32_t sectors,
                                         save_store_file_t* out) {
  if (memcmp(h, SAVE_STORE_MAGIC, sizeof(SAVE_STORE_MAGIC)) != 0) return false;
  if (save_store_crc32(0, h, 96) != save_store_get32(h + 96)) return false;
  out->sequence = save_store_get32(h + 8);
  out->stored_bytes = save_store_get32(h + 12);
  out->raw_bytes = save_store_get32(h + 16);
  out->raw_crc = save_store_get32(h + 20);
  out->stored_crc = save_store_get32(h + 24);
  out->encoding = h[28];
  out->head = (uint8_t)sector;
  memcpy(out->name, h + 32, SAVE_STORE_NAME_BYTES);
  memset(&out->mask, 0, sizeof(out->mask));
  bool outside = false;  // a sector past the area
  for (uint32_t s = 0; s < SAVE_STORE_MAX_SECTORS; ++s) {
    if ((h[80 + s / 8] >> (s % 8)) & 1u) {
      if (s >= sectors) outside = true;
      save_store_add(&out->mask, s);
    }
  }
  return h[29] == 0 && h[30] == 0 && h[31] == 0 && !outside &&
         out->encoding <= SAVE_STORE_ENCODING_DEFLATE &&
         save_store_has(&out->mask, sector) &&
         save_store_popcount(&out->mask) ==
             save_store_sectors_for(out->stored_bytes) &&
         out->name[SAVE_STORE_NAME_BYTES - 1] == '\0' &&
         save_store_name_valid(out->name);
}

// 1 when a record's payload passes its CRC, 0 when it does not, -1 when the
// flash could not be read (then nothing may be concluded about it).
static inline int save_store_payload_ok(const save_store_flash_t* flash,
                                        const save_store_file_t* file) {
  uint8_t chunk[256];
  uint32_t crc = 0;
  for (uint32_t at = 0; at < file->stored_bytes;) {
    uint32_t n = file->stored_bytes - at;
    if (n > sizeof(chunk)) n = sizeof(chunk);
    if (!save_store_read_payload(flash, file->head, &file->mask, at, chunk,
                                 n)) {
      return -1;
    }
    crc = save_store_crc32(crc, chunk, n);
    at += n;
  }
  return crc == file->stored_crc ? 1 : 0;
}

// Reads the area: every record whose header and payload pass, the newest of
// each name. Older copies are erased. NULL, or why the area is unusable.
static inline const char* save_store_mount(save_store_t* store,
                                           save_store_flash_t flash,
                                           uint32_t sectors) {
  memset(store, 0, sizeof(*store));
  store->flash = flash;
  store->sectors = sectors;
  if (sectors == 0 || sectors > SAVE_STORE_MAX_SECTORS) {
    return "save area has an unusable size";
  }
  // A read failure fails the mount rather than dropping the record, whose
  // sectors would then be reused.
  save_store_file_t* found = store->scan;
  uint32_t count = 0;
  for (uint32_t sector = 0; sector < sectors; ++sector) {
    uint8_t head[SAVE_STORE_HEAD_BYTES];
    if (!flash.read(flash.context, sector * SAVE_STORE_SECTOR_BYTES, head,
                    sizeof(head))) {
      return "save area read failed";
    }
    if (!save_store_parse_head(head, sector, sectors, &found[count])) continue;
    const int payload = save_store_payload_ok(&flash, &found[count]);
    if (payload < 0) return "save area read failed";
    if (payload > 0) ++count;
  }
  // Newest first; a record overlapping a newer one or repeating its name
  // loses.
  for (uint32_t i = 1; i < count; ++i) {
    for (uint32_t j = i; j > 0 && found[j].sequence > found[j - 1].sequence;
         --j) {
      const save_store_file_t t = found[j];
      found[j] = found[j - 1];
      found[j - 1] = t;
    }
  }
  save_store_mask_t claimed, stale;  // stale: heads to erase
  memset(&claimed, 0, sizeof(claimed));
  memset(&stale, 0, sizeof(stale));
  for (uint32_t i = 0; i < count; ++i) {
    const save_store_file_t* file = &found[i];
    if (store->next_sequence <= file->sequence) {
      store->next_sequence = file->sequence + 1;
    }
    if (save_store_overlap(&file->mask, &claimed) ||
        save_store_find(store, file->name) >= 0 ||
        store->count >= SAVE_STORE_MAX_FILES) {
      save_store_add(&stale, file->head);
      continue;
    }
    save_store_union(&claimed, &file->mask);
    store->files[store->count++] = *file;
    // Allocation carries on after the newest record.
    if (store->count == 1) store->cursor = (file->head + 1) % sectors;
  }
  for (uint32_t sector = 0; sector < sectors; ++sector) {
    if (save_store_has(&stale, sector) && !save_store_has(&claimed, sector) &&
        !flash.erase_sector(flash.context, sector)) {
      save_store_add(&store->stale, sector);  // retried before a remove
    }
  }
  return NULL;
}

// Stores `stored` bytes as `name`, replacing any file of that name. NULL, or
// why it was not stored: SAVE_STORE_FULL leaves the old file untouched; a
// flash error on the in-place path above may have erased it.
static inline const char* save_store_write(save_store_t* store,
                                           const char* name,
                                           const void* payload,
                                           uint32_t stored, uint32_t raw_bytes,
                                           uint32_t raw_crc, int encoding) {
  if (!save_store_name_valid(name)) return "unusable file name";
  const uint32_t needed = save_store_sectors_for(stored);
  if (needed > store->sectors) return "too big for the save area";
  const int found_old = save_store_find(store, name);
  if (found_old < 0 && store->count >= SAVE_STORE_MAX_FILES) {
    return "save area holds its most files";
  }
  save_store_mask_t used = save_store_used_mask(store);
  uint32_t room = store->sectors - save_store_popcount(&used);
  int old = found_old;
  if (needed > room) {
    const uint32_t place =
        room + (old < 0 ? 0 : save_store_popcount(&store->files[old].mask));
    // In place it still leaves a sector free while other files remain, for
    // their configs to be replaced whole.
    if (old < 0 || needed > place ||
        (needed == place && store->count > 1)) {
      return SAVE_STORE_FULL;
    }
    // No room for both copies: the old one goes first.
    if (!store->flash.erase_sector(store->flash.context,
                                   store->files[old].head)) {
      return "save area erase failed";
    }
    save_store_drop(store, old);
    old = -1;
    used = save_store_used_mask(store);
    room = store->sectors - save_store_popcount(&used);
  } else if (old < 0 && needed == room) {
    return SAVE_STORE_FULL;  // a new file leaves one sector free
  }
  // Free sectors round from the cursor; the first is the head.
  save_store_mask_t mask;
  memset(&mask, 0, sizeof(mask));
  uint32_t head = 0;
  uint32_t last = store->cursor;
  for (uint32_t step = 0, taken = 0; step < store->sectors && taken < needed;
       ++step) {
    const uint32_t sector = (store->cursor + step) % store->sectors;
    if (save_store_has(&used, sector)) continue;
    if (taken++ == 0) head = sector;
    save_store_add(&mask, sector);
    last = sector;
  }
  store->cursor = (last + 1) % store->sectors;
  for (uint32_t sector = 0; sector < store->sectors; ++sector) {
    if (save_store_has(&mask, sector)) {
      if (!store->flash.erase_sector(store->flash.context, sector)) {
        return "save area erase failed";
      }
      save_store_take(&store->stale, sector);
    }
  }
  // Payload, the head sector's share last, then the header.
  const uint8_t* bytes = (const uint8_t*)payload;
  const uint32_t first = SAVE_STORE_SECTOR_BYTES - SAVE_STORE_HEAD_BYTES;
  for (uint32_t at = stored > first ? first : stored; at < stored;) {
    uint32_t run = 0;
    const uint32_t address = save_store_payload_address(head, &mask, at, &run);
    if (run > stored - at) run = stored - at;
    if (!store->flash.write(store->flash.context, address, bytes + at, run)) {
      return "save area write failed";
    }
    at += run;
  }
  if (stored > 0 &&
      !store->flash.write(store->flash.context,
                          head * SAVE_STORE_SECTOR_BYTES + SAVE_STORE_HEAD_BYTES,
                          bytes, stored > first ? first : stored)) {
    return "save area write failed";
  }
  save_store_file_t file;
  memset(&file, 0, sizeof(file));
  strncpy(file.name, name, SAVE_STORE_NAME_BYTES - 1);
  file.sequence = store->next_sequence;
  file.mask = mask;
  file.stored_bytes = stored;
  file.raw_bytes = raw_bytes;
  file.raw_crc = raw_crc;
  file.stored_crc = save_store_crc32(0, bytes, stored);
  file.encoding = (uint8_t)encoding;
  file.head = (uint8_t)head;
  uint8_t h[SAVE_STORE_HEAD_BYTES];
  memset(h, 0, sizeof(h));
  memcpy(h, SAVE_STORE_MAGIC, sizeof(SAVE_STORE_MAGIC));
  save_store_put32(h + 8, file.sequence);
  save_store_put32(h + 12, file.stored_bytes);
  save_store_put32(h + 16, file.raw_bytes);
  save_store_put32(h + 20, file.raw_crc);
  save_store_put32(h + 24, file.stored_crc);
  h[28] = file.encoding;
  memcpy(h + 32, file.name, SAVE_STORE_NAME_BYTES);
  for (uint32_t s = 0; s < SAVE_STORE_MAX_SECTORS; ++s) {
    if (save_store_has(&mask, s)) h[80 + s / 8] |= (uint8_t)(1u << (s % 8));
  }
  save_store_put32(h + 96, save_store_crc32(0, h, 96));
  if (!store->flash.write(store->flash.context,
                          head * SAVE_STORE_SECTOR_BYTES, h, sizeof(h))) {
    return "save area write failed";
  }
  store->next_sequence++;
  if (old >= 0) {
    // The new copy is whole; a failed erase here is resolved at next mount,
    // or retried by a remove.
    if (!store->flash.erase_sector(store->flash.context,
                                   store->files[old].head)) {
      save_store_add(&store->stale, store->files[old].head);
    }
    store->files[old] = file;
  } else {
    store->files[store->count++] = file;
  }
  return NULL;
}

// Removes `name`; false when there is no such file or the erase failed.
static inline bool save_store_remove(save_store_t* store, const char* name) {
  const int i = save_store_find(store, name);
  if (i < 0) return false;
  const save_store_mask_t used = save_store_used_mask(store);
  for (uint32_t sector = 0; sector < store->sectors; ++sector) {
    if (save_store_has(&store->stale, sector) &&
        !save_store_has(&used, sector) &&
        store->flash.erase_sector(store->flash.context, sector)) {
      save_store_take(&store->stale, sector);
    }
  }
  if (!store->flash.erase_sector(store->flash.context, store->files[i].head)) {
    return false;
  }
  save_store_drop(store, i);
  return true;
}

#ifdef __cplusplus
}
#endif
