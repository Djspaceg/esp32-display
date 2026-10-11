// Structural WAD check shared by the Doom boot (w_file_esp32.c.inc, over the
// memory-mapped WAD) and the BOOT triple-press preflight (over flash reads),
// so the normal firmware refuses exactly the WADs the Doom boot would.
//
// Hardware-free and C-compatible; unit tested on the host through
// firmware/test/test_doom_wad.cpp.
#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "doom_mode.h"

typedef enum {
    DOOM_WAD_OK = 0,
    DOOM_WAD_READ_FAILED,
    DOOM_WAD_TOO_SMALL,
    DOOM_WAD_BAD_MAGIC,
    DOOM_WAD_BAD_DIRECTORY,
    DOOM_WAD_BAD_LUMP,
} doom_wad_status_t;

typedef struct {
    uint8_t magic[4];
    uint32_t lump_count;
    uint32_t directory_offset;
} doom_wad_header_t;

// Copies len bytes at offset (from the start of the WAD) into dst.
typedef bool (*doom_wad_read_fn)(void* ctx, uint32_t offset, void* dst,
                                 uint32_t len);

static inline uint32_t doom_wad_u32_le(const uint8_t* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

// region_bytes is the size of the storage the WAD sits in, and file_bytes the
// WAD's own length: the directory and every lump must lie within it.
static inline doom_wad_status_t doom_wad_check_file(doom_wad_read_fn read,
                                                    void* ctx,
                                                    uint32_t region_bytes,
                                                    uint32_t file_bytes,
                                                    doom_wad_header_t* header) {
    memset(header, 0, sizeof(*header));
    if (region_bytes < 12) return DOOM_WAD_TOO_SMALL;

    uint8_t raw[12];
    if (!read(ctx, 0, raw, sizeof(raw))) return DOOM_WAD_READ_FAILED;
    memcpy(header->magic, raw, 4);
    header->lump_count = doom_wad_u32_le(raw + 4);
    header->directory_offset = doom_wad_u32_le(raw + 8);

    if (memcmp(raw, "IWAD", 4) != 0 && memcmp(raw, "PWAD", 4) != 0) {
        return DOOM_WAD_BAD_MAGIC;
    }
    const uint32_t lump_count = header->lump_count;
    const uint32_t directory_offset = header->directory_offset;
    if (region_bytes < file_bytes || lump_count == 0 ||
        directory_offset > file_bytes ||
        lump_count > (file_bytes - directory_offset) / 16) {
        return DOOM_WAD_BAD_DIRECTORY;
    }

    // Sixteen directory entries per read keeps flash-backed reads few and the
    // stack cost small.
    uint8_t entries[16 * 16];
    for (uint32_t first = 0; first < lump_count; first += 16) {
        uint32_t count = lump_count - first;
        if (count > 16) count = 16;
        if (!read(ctx, directory_offset + first * 16, entries, count * 16)) {
            return DOOM_WAD_READ_FAILED;
        }
        for (uint32_t i = 0; i < count; ++i) {
            const int32_t file_offset =
                (int32_t)doom_wad_u32_le(entries + i * 16);
            const int32_t file_size =
                (int32_t)doom_wad_u32_le(entries + i * 16 + 4);
            if (file_offset < 0 || file_size < 0 ||
                (uint32_t)file_offset > file_bytes ||
                (uint32_t)file_size >
                    file_bytes - (uint32_t)file_offset) {
                return DOOM_WAD_BAD_LUMP;
            }
        }
    }
    return DOOM_WAD_OK;
}

// The bundled doom1.wad in the doom_wad partition, which has no file length:
// the directory and every lump must lie within DOOM_WAD_EXPECTED_BYTES, the
// shareware file.
static inline doom_wad_status_t doom_wad_check(doom_wad_read_fn read,
                                               void* ctx,
                                               uint32_t region_bytes,
                                               doom_wad_header_t* header) {
    return doom_wad_check_file(read, ctx, region_bytes,
                               DOOM_WAD_EXPECTED_BYTES, header);
}

static inline const char* doom_wad_status_text(doom_wad_status_t status) {
    switch (status) {
        case DOOM_WAD_OK: return "WAD ok";
        case DOOM_WAD_READ_FAILED: return "WAD flash read failed";
        case DOOM_WAD_TOO_SMALL: return "WAD storage too small";
        case DOOM_WAD_BAD_MAGIC: return "WAD header missing";
        case DOOM_WAD_BAD_DIRECTORY: return "WAD header has a bad directory";
        case DOOM_WAD_BAD_LUMP: return "WAD lump outside the file";
    }
    return "WAD invalid";
}
