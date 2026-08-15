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

static const char* TAG = "doom_wad";

static const void* wad_mapped_ptr = NULL;
static uint32_t wad_size = 0;
static spi_flash_mmap_handle_t wad_map_handle;

// Called once at Doom init to map the WAD partition
static void ensure_wad_mapped(void) {
    if (wad_mapped_ptr != NULL) return;

    const esp_partition_t* part = esp_partition_find_first(
        (esp_partition_type_t)DOOM_WAD_PARTITION_TYPE,
        (esp_partition_subtype_t)DOOM_WAD_PARTITION_SUBTYPE,
        NULL);

    if (!part) {
        ESP_LOGE(TAG, "WAD partition not found! Flash doom1.wad with: "
                      "tools/espdisp.py flash-wad doom1.wad");
        return;
    }

    esp_err_t err = esp_partition_mmap(
        part, 0, part->size,
        ESP_PARTITION_MMAP_DATA,
        &wad_mapped_ptr, &wad_map_handle);

    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to mmap WAD partition: %s", esp_err_to_name(err));
        wad_mapped_ptr = NULL;
        return;
    }

    wad_size = part->size;

    // Verify WAD magic ("IWAD" or "PWAD" at offset 0)
    const char* magic = (const char*)wad_mapped_ptr;
    if (memcmp(magic, "IWAD", 4) != 0 && memcmp(magic, "PWAD", 4) != 0) {
        ESP_LOGE(TAG, "WAD partition does not contain valid WAD data "
                      "(magic: %02x %02x %02x %02x)",
                      magic[0], magic[1], magic[2], magic[3]);
        esp_partition_munmap(wad_map_handle);
        wad_mapped_ptr = NULL;
        return;
    }

    ESP_LOGI(TAG, "WAD mapped: %lu bytes at %p (%.4s)",
             (unsigned long)wad_size, wad_mapped_ptr, magic);
}

// --- doomgeneric WAD file interface ---
// These replace the standard w_file_stdc.c functions

static wad_file_t doom_wad_file;

wad_file_t* W_OpenFile(char* path) {
    (void)path;  // We ignore the path -- there's only one WAD
    ensure_wad_mapped();

    if (!wad_mapped_ptr) {
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

    if (!wad_mapped_ptr) return 0;
    if (offset + buffer_len > wad_size) {
        // Clamp to available data
        if (offset >= wad_size) return 0;
        buffer_len = wad_size - offset;
    }

    memcpy(buffer, (const uint8_t*)wad_mapped_ptr + offset, buffer_len);
    return buffer_len;
}
