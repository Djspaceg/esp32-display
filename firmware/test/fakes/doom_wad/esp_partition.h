// Host fake of the esp_partition surface w_file_esp32.c.inc uses, backed by
// a byte vector the test fills (see test_doom_wad.cpp).
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "esp_flash.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef int esp_partition_type_t;
typedef int esp_partition_subtype_t;
typedef uint32_t esp_partition_mmap_handle_t;
typedef enum { ESP_PARTITION_MMAP_DATA, ESP_PARTITION_MMAP_INST } esp_partition_mmap_memory_t;

typedef struct {
  esp_partition_type_t type;
  esp_partition_subtype_t subtype;
  uint32_t address;
  uint32_t size;
  char label[17];
} esp_partition_t;

const esp_partition_t *esp_partition_find_first(esp_partition_type_t type,
                                                esp_partition_subtype_t subtype,
                                                const char *label);
esp_err_t esp_partition_mmap(const esp_partition_t *partition, size_t offset,
                             size_t size, esp_partition_mmap_memory_t memory,
                             const void **out_ptr,
                             esp_partition_mmap_handle_t *out_handle);
void esp_partition_munmap(esp_partition_mmap_handle_t handle);
esp_err_t esp_partition_register_external(
    esp_flash_t *flash_chip, size_t offset, size_t size, const char *label,
    esp_partition_type_t type, esp_partition_subtype_t subtype,
    const esp_partition_t **registered_partition);
esp_err_t esp_partition_read(const esp_partition_t *partition,
                             size_t src_offset, void *dst, size_t size);

#ifdef __cplusplus
}
#endif
