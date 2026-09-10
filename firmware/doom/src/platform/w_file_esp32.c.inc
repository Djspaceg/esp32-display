// WAD file access for ESP32-S3 Doom Easter Egg
//
// The doom1.wad shareware file is memory-mapped into the address space for
// zero-copy reads. This replaces doomgeneric's standard fopen/fread file
// access with direct pointer arithmetic.
//
// Canonical S3 and P4 images carry a real Doom partition (type 0x42, subtype
// 0x06), which is mapped with esp_partition_mmap. The raw S3 mapping path
// remains only for legacy developer images whose 16 MiB table omitted the
// partition entry but wrote the WAD at DOOM_WAD_PARTITION_OFFSET.
//
// GPL-2.0 (part of the Doom engine integration)
#include <string.h>
#include <esp_partition.h>
#include <esp_flash.h>
#include <esp_log.h>
#include <spi_flash_mmap.h>

#include "w_file.h"
#include "doom_mode.h"

static const char* WAD_TAG = "doom_wad";

static const void* wad_mapped_ptr = NULL;
static uint32_t wad_size = 0;
static spi_flash_mmap_handle_t wad_map_handle;
// Which API produced wad_map_handle, so structural-validation failure unmaps
// with the matching function (esp_partition_munmap vs spi_flash_munmap).
static bool wad_mapped_via_partition = false;

static uint32_t wad_u32_le(const uint8_t* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

// Map the raw WAD flash region on carriers whose partition table omits it.
// Returns the WAD-aligned pointer and the mmap handle on success. Uses only
// the public spi_flash_mmap API: no synthetic esp_partition_t, no ROM/MMU
// private calls, and no copy into RAM/PSRAM -- access stays zero-copy.
static bool map_raw_wad_region(const void** out_ptr,
                               spi_flash_mmap_handle_t* out_handle) {
    uint32_t physical_size = 0;
    esp_err_t err = esp_flash_get_physical_size(esp_flash_default_chip,
                                                &physical_size);
    if (err != ESP_OK) {
        ESP_LOGE(WAD_TAG, "esp_flash_get_physical_size failed: %s",
                 esp_err_to_name(err));
        return false;
    }

    // Overflow-safe check that the flash physically covers the whole region
    // [OFFSET, OFFSET + BYTES). The geometry ends exactly at 0x1000000, so a
    // 16 MiB carrier passes and smaller carriers are rejected here.
    if (physical_size < DOOM_WAD_PARTITION_BYTES ||
        DOOM_WAD_PARTITION_OFFSET > physical_size - DOOM_WAD_PARTITION_BYTES) {
        ESP_LOGE(WAD_TAG,
                 "Flash too small for WAD region (physical=%lu, need >= 0x%lx)",
                 (unsigned long)physical_size,
                 (unsigned long)DOOM_WAD_PARTITION_OFFSET +
                     (unsigned long)DOOM_WAD_PARTITION_BYTES);
        return false;
    }

    // spi_flash_mmap requires the source address to be MMU-page aligned. Align
    // the source down and grow the mapped length by the same delta so the WAD
    // stays fully covered; the aligned mapping still ends at 0x1000000, within
    // the installed S3 mmap ceiling. Offset the returned pointer past the delta
    // so callers see the WAD start.
    const uint32_t src_aligned =
        DOOM_WAD_PARTITION_OFFSET & ~(uint32_t)(SPI_FLASH_MMU_PAGE_SIZE - 1);
    const uint32_t delta = DOOM_WAD_PARTITION_OFFSET - src_aligned;
    const uint32_t map_len = DOOM_WAD_PARTITION_BYTES + delta;

    const void* base = NULL;
    err = spi_flash_mmap(src_aligned, map_len, SPI_FLASH_MMAP_DATA,
                         &base, out_handle);
    if (err != ESP_OK) {
        ESP_LOGE(WAD_TAG, "Failed to mmap raw WAD region: %s",
                 esp_err_to_name(err));
        return false;
    }

    *out_ptr = (const uint8_t*)base + delta;
    return true;
}

// Called once at Doom init to map and structurally validate the WAD partition.
static bool ensure_wad_mapped(void) {
    if (wad_mapped_ptr != NULL) return true;

    const esp_partition_t* part = esp_partition_find_first(
        (esp_partition_type_t)DOOM_WAD_PARTITION_TYPE,
        (esp_partition_subtype_t)DOOM_WAD_PARTITION_SUBTYPE,
        "doom_wad");

    uint32_t mapped_size = 0;
    if (part != NULL) {
        // A real Doom partition exists: map it through the partition API.
        if (part->size < 12) {
            ESP_LOGE(WAD_TAG, "WAD partition too small");
            return false;
        }
        esp_err_t err = esp_partition_mmap(
            part, 0, part->size,
            ESP_PARTITION_MMAP_DATA,
            &wad_mapped_ptr, &wad_map_handle);
        if (err != ESP_OK) {
            ESP_LOGE(WAD_TAG, "Failed to mmap WAD partition: %s",
                     esp_err_to_name(err));
            wad_mapped_ptr = NULL;
            return false;
        }
        wad_mapped_via_partition = true;
        mapped_size = part->size;
    } else {
        // No partition table entry: map the raw WAD region directly.
#if defined(CONFIG_IDF_TARGET_ESP32P4)
        // The S3 raw fallback overlaps P4's app1 OTA slot. P4 must find the
        // dedicated partition above both 8 MiB application slots.
        ESP_LOGE(WAD_TAG, "P4 Doom requires the doom_wad partition");
        return false;
#else
        if (!map_raw_wad_region(&wad_mapped_ptr, &wad_map_handle)) {
            wad_mapped_ptr = NULL;
            return false;
        }
        wad_mapped_via_partition = false;
        mapped_size = DOOM_WAD_PARTITION_BYTES;
#endif
    }

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
        if (wad_mapped_via_partition) {
            esp_partition_munmap(wad_map_handle);
        } else {
            spi_flash_munmap(wad_map_handle);
        }
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
