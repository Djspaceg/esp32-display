// WAD file access for ESP32-S3 Doom Easter Egg
//
// The doom1.wad shareware file lives in a dedicated flash partition
// (type 0x42, subtype 0x06) and is memory-mapped into the address space
// for zero-copy reads. This replaces doomgeneric's standard fopen/fread
// file access with direct pointer arithmetic.
//
// GPL-2.0 (part of the Doom engine integration)
#include <string.h>
#include <esp_partition.h>
#include <esp_log.h>
#include <spi_flash_mmap.h>

#include "w_file.h"
#include "doom_mode.h"

static const char* WAD_TAG = "doom_wad";

// The universal S3 table omits storage above 8 MiB so it remains safe on the
// GC9107 carrier. The CO5300 bridge exposes the historical 16 MiB WAD region
// only after confirming the physical flash can contain it.
extern const esp_partition_t* doom_raw_wad_partition(void);

static const void* wad_mapped_ptr = NULL;
static uint32_t wad_size = 0;
static spi_flash_mmap_handle_t wad_map_handle;

static uint32_t wad_u32_le(const uint8_t* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

// Called once at Doom init to map and structurally validate the WAD partition.
static bool ensure_wad_mapped(void) {
    if (wad_mapped_ptr != NULL) return true;

    const esp_partition_t* part = esp_partition_find_first(
        (esp_partition_type_t)DOOM_WAD_PARTITION_TYPE,
        (esp_partition_subtype_t)DOOM_WAD_PARTITION_SUBTYPE,
        NULL);
    if (part == NULL) part = doom_raw_wad_partition();

    if (!part || part->size < 12) {
        ESP_LOGE(WAD_TAG, "WAD partition missing or too small");
        return false;
    }

    esp_err_t err = esp_partition_mmap(
        part, 0, part->size,
        ESP_PARTITION_MMAP_DATA,
        &wad_mapped_ptr, &wad_map_handle);

    if (err != ESP_OK) {
        ESP_LOGE(WAD_TAG, "Failed to mmap WAD partition: %s", esp_err_to_name(err));
        wad_mapped_ptr = NULL;
        return false;
    }

    const uint32_t mapped_size = part->size;
    const uint8_t* header = (const uint8_t*)wad_mapped_ptr;
    bool valid_magic = memcmp(header, "IWAD", 4) == 0 ||
                       memcmp(header, "PWAD", 4) == 0;
    uint32_t lump_count = wad_u32_le(header + 4);
    uint32_t directory_offset = wad_u32_le(header + 8);
    bool valid_directory = mapped_size >= DOOM_WAD_EXPECTED_BYTES &&
                           lump_count > 0 &&
                           directory_offset <= DOOM_WAD_EXPECTED_BYTES &&
                           lump_count <=
                               (DOOM_WAD_EXPECTED_BYTES - directory_offset) / 16;
    if (valid_directory) {
        for (uint32_t i = 0; i < lump_count; ++i) {
            const uint8_t* entry = header + directory_offset + i * 16;
            int32_t file_offset = (int32_t)wad_u32_le(entry);
            int32_t file_size = (int32_t)wad_u32_le(entry + 4);
            if (file_offset < 0 || file_size < 0 ||
                (uint32_t)file_offset > DOOM_WAD_EXPECTED_BYTES ||
                (uint32_t)file_size >
                    DOOM_WAD_EXPECTED_BYTES - (uint32_t)file_offset) {
                valid_directory = false;
                break;
            }
        }
    }
    if (!valid_magic || !valid_directory) {
        ESP_LOGE(WAD_TAG,
                 "Invalid WAD structure (magic=%02x%02x%02x%02x lumps=%lu dir=%lu partition=%lu)",
                 header[0], header[1], header[2], header[3],
                 (unsigned long)lump_count, (unsigned long)directory_offset,
                 (unsigned long)mapped_size);
        esp_partition_munmap(wad_map_handle);
        wad_mapped_ptr = NULL;
        wad_size = 0;
        return false;
    }

    wad_size = DOOM_WAD_EXPECTED_BYTES;
    ESP_LOGI(WAD_TAG, "WAD mapped: %lu bytes at %p (%.4s, %lu lumps)",
             (unsigned long)wad_size, wad_mapped_ptr, header,
             (unsigned long)lump_count);
    return true;
}

bool doom_wad_available(void) {
    return ensure_wad_mapped();
}

// --- doomgeneric WAD file interface ---
// These replace the standard w_file_stdc.c functions

static wad_file_t doom_wad_file;

wad_file_t* W_OpenFile(char* path) {
    (void)path;  // We ignore the path -- there's only one WAD
    if (!ensure_wad_mapped()) {
        return NULL;
    }

    doom_wad_file.file_class = NULL;
    doom_wad_file.length = wad_size;
    doom_wad_file.mapped = (byte*)wad_mapped_ptr;

    return &doom_wad_file;
}

void W_CloseFile(wad_file_t* wad) {
    (void)wad;
    // Don't unmap -- the partition stays mapped for the lifetime of Doom mode
}

size_t W_Read(wad_file_t* wad, unsigned int offset,
              void* buffer, size_t buffer_len) {
    (void)wad;

    if (!wad_mapped_ptr || offset >= wad_size) return 0;
    if (buffer_len > wad_size - offset) {
        buffer_len = wad_size - offset;
    }

    memcpy(buffer, (const uint8_t*)wad_mapped_ptr + offset, buffer_len);
    return buffer_len;
}
