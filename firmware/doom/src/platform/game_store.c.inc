// The board's game data area: where it is, and its directory.
//
// On the P4 it is the quake_pak partition (partitions_p4_4b.csv). The S3's
// universal table covers only its common 8 MiB, so there it is the raw flash
// past it, registered here as an external partition of the same name: up to
// the 18 MiB Quake's data has always used, and on a 16 MiB chip the 8 MiB it
// has (game_store_s3_area_bytes).
//
// Part of the Doom unity build; the Quake boot reads it through game_store.h.
#include <esp_flash.h>
#include <esp_partition.h>
#include <string.h>

#include "../game_store.h"

#define GAME_STORE_PARTITION_TYPE 0x42
#define GAME_STORE_PARTITION_SUBTYPE 0x07
#define GAME_STORE_PARTITION_LABEL "quake_pak"

static bool game_store_tried = false;
static const char* game_store_failure = "game store not read";
static const esp_partition_t* game_store_area = NULL;
static game_store_t game_store_state;

#if CONFIG_IDF_TARGET_ESP32S3
// NULL once the S3 region is registered, else why the chip has none.
static const char* game_store_register_s3_area(void) {
  uint32_t physical = 0;
  if (esp_flash_get_physical_size(esp_flash_default_chip, &physical) !=
      ESP_OK) {
    return "could not read the flash size";
  }
  const uint32_t bytes = game_store_s3_area_bytes(physical);
  if (bytes == 0) return "flash too small for game data (needs 16 MiB)";
  // The driver takes its size from the image header, 8 MiB, and refuses to
  // register a partition past it; the chip is bigger, so tell it. Reads past
  // 16 MiB need the chip driver's 4-byte addressing (SPI_FLASH_CHIP_CAP_32MB_
  // SUPPORT); the directory's CRC and each file's own check fail cleanly if
  // they come back wrong.
  if (esp_flash_default_chip->size < physical) {
    esp_flash_default_chip->size = physical;
  }
  if (esp_partition_register_external(
          esp_flash_default_chip, GAME_STORE_S3_OFFSET, bytes,
          GAME_STORE_PARTITION_LABEL,
          (esp_partition_type_t)GAME_STORE_PARTITION_TYPE,
          (esp_partition_subtype_t)GAME_STORE_PARTITION_SUBTYPE,
          NULL) != ESP_OK) {
    return "could not register the game data area";
  }
  return NULL;
}
#endif

bool game_store_read(uint32_t offset, void* out, uint32_t length) {
  return game_store_area != NULL &&
         esp_partition_read(game_store_area, offset, out, length) == ESP_OK;
}

const char* game_store_open(void) {
  if (game_store_tried) return game_store_failure;
  game_store_tried = true;
#if CONFIG_IDF_TARGET_ESP32S3
  game_store_failure = game_store_register_s3_area();
  if (game_store_failure != NULL) return game_store_failure;
#endif
  const esp_partition_t* area = esp_partition_find_first(
      (esp_partition_type_t)GAME_STORE_PARTITION_TYPE,
      (esp_partition_subtype_t)GAME_STORE_PARTITION_SUBTYPE,
      GAME_STORE_PARTITION_LABEL);
  if (area == NULL) {
    game_store_failure =
        "no quake_pak partition (flash the current P4 bundle over USB)";
    return game_store_failure;
  }
  if (area->size < GAME_STORE_MIN_AREA_BYTES) {
    game_store_failure = "game data area too small";
    return game_store_failure;
  }
  static uint8_t sector[GAME_STORE_SECTOR_BYTES];
  if (esp_partition_read(area, game_store_directory_offset(area->size),
                         sector, sizeof(sector)) != ESP_OK) {
    game_store_failure = "game store directory read failed";
    return game_store_failure;
  }
  game_store_failure = game_store_parse(sector, area->size, &game_store_state);
  if (game_store_failure == NULL) game_store_area = area;
  return game_store_failure;
}

const esp_partition_t* game_store_partition(void) { return game_store_area; }

const game_store_t* game_store_directory(void) {
  return game_store_area != NULL ? &game_store_state : NULL;
}
