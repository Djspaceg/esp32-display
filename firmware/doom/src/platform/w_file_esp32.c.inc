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
#include <spi_flash_mmap.h>

#include "w_file.h"
#include "doom_mode.h"
#include "doom_log.h"
#include "doom_wad_check.h"

static const void* wad_mapped_ptr = NULL;
static uint32_t wad_size = 0;
static spi_flash_mmap_handle_t wad_map_handle;
// Which API produced wad_map_handle, so structural-validation failure unmaps
// with the matching function (esp_partition_munmap vs spi_flash_munmap).
static bool wad_mapped_via_partition = false;
// Why the last ensure_wad_mapped() refused, for the Doom boot's FATAL line.
static const char* wad_failure = "WAD not checked";

// The flash cache maps only 24-bit (16 MiB) flash addresses unless the
// bootloader enables 32-bit cache addressing, which the prebuilt Arduino
// bootloaders do not. esp_partition_mmap() refuses anything past it with
// ESP_ERR_INVALID_ARG; that was the P4 Doom failure on a 4B, whose doom_wad
// then sat at 0x1010000.
#if defined(CONFIG_BOOTLOADER_CACHE_32BIT_ADDR_QUAD_FLASH) || \
    defined(CONFIG_BOOTLOADER_CACHE_32BIT_ADDR_OCTAL_FLASH)
#define DOOM_WAD_MAPPABLE_END 0xFFFFFFFFU
#else
#define DOOM_WAD_MAPPABLE_END 0x1000000U
#endif

static bool wad_partition_mappable(const esp_partition_t* part) {
    return part->address <= DOOM_WAD_MAPPABLE_END &&
           part->size <= DOOM_WAD_MAPPABLE_END - part->address;
}

static const esp_partition_t* find_wad_partition(void) {
    return esp_partition_find_first(
        (esp_partition_type_t)DOOM_WAD_PARTITION_TYPE,
        (esp_partition_subtype_t)DOOM_WAD_PARTITION_SUBTYPE,
        "doom_wad");
}

#if !defined(CONFIG_IDF_TARGET_ESP32P4)
// Overflow-safe check that the flash physically covers the whole raw region
// [OFFSET, OFFSET + BYTES). The geometry ends exactly at 0x1000000, so a
// 16 MiB carrier passes and smaller carriers are rejected here.
static bool raw_wad_region_fits(void) {
    uint32_t physical_size = 0;
    esp_err_t err = esp_flash_get_physical_size(esp_flash_default_chip,
                                                &physical_size);
    if (err != ESP_OK) {
        doom_log("esp_flash_get_physical_size failed: %s",
                 esp_err_to_name(err));
        return false;
    }
    if (physical_size < DOOM_WAD_PARTITION_BYTES ||
        DOOM_WAD_PARTITION_OFFSET > physical_size - DOOM_WAD_PARTITION_BYTES) {
        doom_log("Flash too small for WAD region (physical=%lu, need >= 0x%lx)",
                 (unsigned long)physical_size,
                 (unsigned long)DOOM_WAD_PARTITION_OFFSET +
                     (unsigned long)DOOM_WAD_PARTITION_BYTES);
        return false;
    }
    return true;
}
#endif

// Map the raw WAD flash region on carriers whose partition table omits it.
// Returns the WAD-aligned pointer and the mmap handle on success. Uses only
// the public spi_flash_mmap API: no synthetic esp_partition_t, no ROM/MMU
// private calls, and no copy into RAM/PSRAM -- access stays zero-copy.
#if !defined(CONFIG_IDF_TARGET_ESP32P4)
static bool map_raw_wad_region(const void** out_ptr,
                               spi_flash_mmap_handle_t* out_handle) {
    if (!raw_wad_region_fits()) return false;

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
    esp_err_t err = spi_flash_mmap(src_aligned, map_len, SPI_FLASH_MMAP_DATA,
                                   &base, out_handle);
    if (err != ESP_OK) {
        doom_log("Failed to mmap raw WAD region: %s", esp_err_to_name(err));
        return false;
    }

    *out_ptr = (const uint8_t*)base + delta;
    return true;
}
#endif

static bool read_mapped_wad(void* ctx, uint32_t offset, void* dst,
                            uint32_t len) {
    memcpy(dst, (const uint8_t*)ctx + offset, len);
    return true;
}

// Called once at Doom init to map and structurally validate the WAD partition.
static bool ensure_wad_mapped(void) {
    if (wad_mapped_ptr != NULL) return true;

    const esp_partition_t* part = find_wad_partition();

    uint32_t mapped_size = 0;
    if (part != NULL) {
        // A real Doom partition exists: map it through the partition API.
        if (part->size < 12) {
            doom_log("WAD partition too small");
            wad_failure = "doom_wad partition too small";
            return false;
        }
        if (!wad_partition_mappable(part)) {
            doom_log("doom_wad partition 0x%lx+0x%lx is past the 0x%lx bytes "
                     "of flash the cache can map; a full USB flash of the "
                     "current bundle moves it",
                     (unsigned long)part->address, (unsigned long)part->size,
                     (unsigned long)DOOM_WAD_MAPPABLE_END);
            wad_failure = "doom_wad is past the 16 MiB flash map";
            return false;
        }
        esp_err_t err = esp_partition_mmap(
            part, 0, part->size,
            ESP_PARTITION_MMAP_DATA,
            &wad_mapped_ptr, &wad_map_handle);
        if (err != ESP_OK) {
            doom_log("Failed to mmap WAD partition: %s",
                     esp_err_to_name(err));
            wad_failure = "WAD partition could not be mapped";
            wad_mapped_ptr = NULL;
            return false;
        }
        wad_mapped_via_partition = true;
        mapped_size = part->size;
    } else {
        // No partition table entry: map the raw WAD region directly.
#if defined(CONFIG_IDF_TARGET_ESP32P4)
        // The S3 raw fallback overlaps P4's app1 OTA slot. P4 must find its
        // dedicated partition after both application slots.
        doom_log("P4 Doom requires the doom_wad partition");
        wad_failure = "no doom_wad partition";
        return false;
#else
        if (!map_raw_wad_region(&wad_mapped_ptr, &wad_map_handle)) {
            wad_failure = "raw WAD region could not be mapped";
            wad_mapped_ptr = NULL;
            return false;
        }
        wad_mapped_via_partition = false;
        mapped_size = DOOM_WAD_PARTITION_BYTES;
#endif
    }

    doom_wad_header_t header;
    const doom_wad_status_t status = doom_wad_check(
        read_mapped_wad, (void*)wad_mapped_ptr, mapped_size, &header);
    if (status != DOOM_WAD_OK) {
        doom_log("Invalid WAD structure (%s; magic=%02x%02x%02x%02x lumps=%lu dir=%lu partition=%lu)",
                 doom_wad_status_text(status),
                 header.magic[0], header.magic[1], header.magic[2],
                 header.magic[3], (unsigned long)header.lump_count,
                 (unsigned long)header.directory_offset,
                 (unsigned long)mapped_size);
        if (wad_mapped_via_partition) {
            esp_partition_munmap(wad_map_handle);
        } else {
            spi_flash_munmap(wad_map_handle);
        }
        wad_mapped_ptr = NULL;
        wad_size = 0;
        wad_failure = doom_wad_status_text(status);
        return false;
    }

    wad_size = DOOM_WAD_EXPECTED_BYTES;
    doom_log("WAD mapped: %lu bytes at %p (%.4s, %lu lumps)",
             (unsigned long)wad_size, wad_mapped_ptr,
             (const char*)header.magic, (unsigned long)header.lump_count);
    return true;
}

bool doom_wad_available(void) {
    return ensure_wad_mapped();
}

const char* doom_wad_failure(void) {
    return wad_failure;
}

// --- Preflight for the normal firmware ---
// Run by the BOOT triple press before it reboots into Doom. Reads the WAD
// through the flash API instead of mapping it, so the streaming firmware's
// address space is left alone, and applies the same partition rule and
// structural check as ensure_wad_mapped().

static bool read_partition_wad(void* ctx, uint32_t offset, void* dst,
                               uint32_t len) {
    return esp_partition_read((const esp_partition_t*)ctx, offset, dst, len) ==
           ESP_OK;
}

#if !defined(CONFIG_IDF_TARGET_ESP32P4)
static bool read_raw_wad(void* ctx, uint32_t offset, void* dst,
                         uint32_t len) {
    (void)ctx;
    return esp_flash_read(esp_flash_default_chip, dst,
                          DOOM_WAD_PARTITION_OFFSET + offset, len) == ESP_OK;
}
#endif

const char* doom_wad_preflight(void) {
    doom_wad_header_t header;
    doom_wad_status_t status;
    const esp_partition_t* part = find_wad_partition();
    if (part != NULL) {
        // Reading works anywhere in flash; the Doom boot maps. Refuse what
        // it cannot map, or a WAD past 16 MiB passes here and fails there.
        if (!wad_partition_mappable(part)) {
            return "doom_wad is past the 16 MiB flash map";
        }
        status = doom_wad_check(read_partition_wad, (void*)part, part->size,
                                &header);
    } else {
#if defined(CONFIG_IDF_TARGET_ESP32P4)
        return "no doom_wad partition";
#else
        if (!raw_wad_region_fits()) return "flash too small for the WAD";
        status = doom_wad_check(read_raw_wad, NULL, DOOM_WAD_PARTITION_BYTES,
                                &header);
#endif
    }
    return status == DOOM_WAD_OK ? NULL : doom_wad_status_text(status);
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
