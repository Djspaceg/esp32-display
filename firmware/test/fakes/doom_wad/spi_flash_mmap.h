#pragma once

#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SPI_FLASH_MMU_PAGE_SIZE 0x10000
typedef uint32_t spi_flash_mmap_handle_t;
typedef enum { SPI_FLASH_MMAP_DATA, SPI_FLASH_MMAP_INST } spi_flash_mmap_memory_t;

esp_err_t spi_flash_mmap(size_t src_addr, size_t size,
                         spi_flash_mmap_memory_t memory, const void **out_ptr,
                         spi_flash_mmap_handle_t *out_handle);
void spi_flash_munmap(spi_flash_mmap_handle_t handle);

#ifdef __cplusplus
}
#endif
