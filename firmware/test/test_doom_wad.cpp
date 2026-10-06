// Host test for the Doom WAD access layer (doom/src/platform/
// w_file_esp32.c.inc, compiled unmodified as C by doom_wad_unit.c against
// fakes/doom_wad).
//
// Two properties, on the P4 and S3 storage layouts:
// - Every reason the WAD is refused reaches Serial (through doom_log), even
//   with ESP_LOGx compiled out as it is in the shipping P4 image.
// - doom_wad_preflight(), which the BOOT triple press runs before it reboots
//   into Doom, refuses exactly the WADs the Doom boot itself would refuse.
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <esp_flash.h>
#include <esp_partition.h>
#include <spi_flash_mmap.h>

#include "doom_mode.h"

extern "C" bool doom_wad_available(void);
// The real definition in doom_wad_unit.c overrides this weak stand-in. It
// exists so the test still links against a tree that predates the preflight,
// where it then fails at runtime rather than at link time.
extern "C" __attribute__((weak)) const char *doom_wad_preflight(void) {
  return "preflight missing";
}

static int checks = 0;
static std::string serial;
#define CHECK(cond)                                          \
  do {                                                       \
    checks++;                                                \
    if (!(cond)) {                                           \
      printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      printf("serial was:\n%s", serial.c_str());            \
      return 1;                                              \
    }                                                        \
  } while (0)

extern "C" void doom_log(const char *format, ...) {
  char line[512];
  va_list args;
  va_start(args, format);
  std::vsnprintf(line, sizeof(line), format, args);
  va_end(args);
  serial += line;
  serial += "\n";
}

// ---- Fake flash -------------------------------------------------------------
// Each family's canonical doom_wad partition address (tools/espdisp.py).
#if defined(CONFIG_IDF_TARGET_ESP32P4)
static const uint32_t PARTITION_ADDRESS = 0x9F0000;
static const uint32_t FLASH_BYTES = PARTITION_ADDRESS + DOOM_WAD_PARTITION_BYTES;
#else
static const uint32_t PARTITION_ADDRESS = 0x3FF000;
// The legacy raw region ends exactly at 16 MiB.
static const uint32_t FLASH_BYTES =
    DOOM_WAD_PARTITION_OFFSET + DOOM_WAD_PARTITION_BYTES;
#endif
static std::vector<uint8_t> flash(FLASH_BYTES, 0xFF);
// Where writeValidWad() and put32() write: the partition, or on S3 the raw
// legacy region.
static uint32_t wadBase = PARTITION_ADDRESS;
static uint32_t physicalFlashBytes = 16u * 1024u * 1024u;
static bool havePartition = true;
static esp_partition_t wadPartition = {
    DOOM_WAD_PARTITION_TYPE, DOOM_WAD_PARTITION_SUBTYPE, PARTITION_ADDRESS,
    DOOM_WAD_PARTITION_BYTES, "doom_wad"};
static int liveMappings = 0;
static int partitionReads = 0;

extern "C" {
esp_flash_t *esp_flash_default_chip = nullptr;
const char *esp_err_to_name(esp_err_t) { return "ESP_FAIL"; }

const esp_partition_t *esp_partition_find_first(esp_partition_type_t type,
                                                esp_partition_subtype_t subtype,
                                                const char *label) {
  if (!havePartition || type != DOOM_WAD_PARTITION_TYPE ||
      subtype != DOOM_WAD_PARTITION_SUBTYPE || label == nullptr ||
      strcmp(label, "doom_wad") != 0) {
    return nullptr;
  }
  return &wadPartition;
}

esp_err_t esp_partition_mmap(const esp_partition_t *partition, size_t offset,
                             size_t size, esp_partition_mmap_memory_t,
                             const void **out_ptr,
                             esp_partition_mmap_handle_t *out_handle) {
  if (offset + size > partition->size) return ESP_FAIL;
  *out_ptr = flash.data() + partition->address + offset;
  *out_handle = 1;
  liveMappings++;
  return ESP_OK;
}

void esp_partition_munmap(esp_partition_mmap_handle_t) { liveMappings--; }

esp_err_t esp_partition_read(const esp_partition_t *partition,
                             size_t src_offset, void *dst, size_t size) {
  partitionReads++;
  if (src_offset > partition->size || size > partition->size - src_offset) {
    return ESP_FAIL;
  }
  memcpy(dst, flash.data() + partition->address + src_offset, size);
  return ESP_OK;
}

esp_err_t esp_flash_get_physical_size(esp_flash_t *, uint32_t *out_size) {
  *out_size = physicalFlashBytes;
  return ESP_OK;
}

esp_err_t esp_flash_read(esp_flash_t *, void *buffer, uint32_t address,
                         uint32_t length) {
  if (address > FLASH_BYTES || length > FLASH_BYTES - address) return ESP_FAIL;
  memcpy(buffer, flash.data() + address, length);
  return ESP_OK;
}

esp_err_t spi_flash_mmap(size_t src_addr, size_t size, spi_flash_mmap_memory_t,
                         const void **out_ptr,
                         spi_flash_mmap_handle_t *out_handle) {
  if (src_addr > FLASH_BYTES || size > FLASH_BYTES - src_addr) return ESP_FAIL;
  *out_ptr = flash.data() + src_addr;
  *out_handle = 2;
  liveMappings++;
  return ESP_OK;
}

void spi_flash_munmap(spi_flash_mmap_handle_t) { liveMappings--; }
}

static void put32(uint32_t at, uint32_t value) {
  for (int i = 0; i < 4; i++) flash[wadBase + at + i] = (uint8_t)(value >> (8 * i));
}

static void eraseWad() {
  std::fill(flash.begin() + wadBase,
            flash.begin() + wadBase + DOOM_WAD_PARTITION_BYTES, 0xFF);
}

// A structurally valid IWAD with its directory at the end of the shareware
// file's length, the shape the shipping doom1.wad has. Forty lumps, so the
// check's sixteen-entry directory reads cross two chunk boundaries.
static const uint32_t TEST_LUMPS = 40;
static uint32_t lumpEntry(uint32_t index) {
  return DOOM_WAD_EXPECTED_BYTES - TEST_LUMPS * 16 + index * 16;
}
static void writeValidWad() {
  std::fill(flash.begin() + wadBase,
            flash.begin() + wadBase + DOOM_WAD_PARTITION_BYTES, 0x00);
  memcpy(&flash[wadBase], "IWAD", 4);
  put32(4, TEST_LUMPS);
  put32(8, lumpEntry(0));
  for (uint32_t i = 0; i < TEST_LUMPS; i++) {
    put32(lumpEntry(i), 12 + i * 100);
    put32(lumpEntry(i) + 4, 100);
  }
}

static bool serialHas(const char *text) {
  return serial.find(text) != std::string::npos;
}

// Every refusal: the Doom boot refuses and its reason reaches Serial, and the
// preflight refuses too, naming a reason.
static int expectRefused(const char *preflightWords, const char *bootWords) {
  serial.clear();
  CHECK(!doom_wad_available());
  CHECK(serialHas(bootWords));
  CHECK(liveMappings == 0);
  const char *reason = doom_wad_preflight();
  CHECK(reason != nullptr);
  CHECK(strstr(reason, preflightWords) != nullptr);
  CHECK(liveMappings == 0);
  return 0;
}

static int refusesWhatTheBootRefuses() {
#if defined(CONFIG_IDF_TARGET_ESP32P4)
  // An app-only install (WiFi update, rescue image) over a table without the
  // partition: the S3 raw fallback would overlap P4's second app slot.
  havePartition = false;
  writeValidWad();
  if (expectRefused("no doom_wad partition", "doom_wad partition") != 0) return 1;
  havePartition = true;

  // A valid WAD in a partition the flash cache cannot map: the P4 layout
  // before this move (0x1010000), which a WiFi update leaves in place. The
  // old preflight read it fine and let the board reboot into a Doom boot
  // that could not map it.
  wadPartition.address = 0x1010000;
  flash.resize(0x1010000 + DOOM_WAD_PARTITION_BYTES, 0xFF);
  wadBase = 0x1010000;
  writeValidWad();
  if (expectRefused("16 MiB", "the cache can map") != 0) return 1;
  wadPartition.address = PARTITION_ADDRESS;
  wadBase = PARTITION_ADDRESS;
#endif

  // The partition exists but nothing was ever written to it (erased flash).
  eraseWad();
  if (expectRefused("header", "Invalid WAD structure") != 0) return 1;

  // Right magic, directory pointing past the WAD.
  writeValidWad();
  put32(8, DOOM_WAD_EXPECTED_BYTES);
  if (expectRefused("header", "Invalid WAD structure") != 0) return 1;

  // Right header, one lump in the third directory chunk running past the WAD.
  writeValidWad();
  put32(lumpEntry(33) + 4, DOOM_WAD_EXPECTED_BYTES);
  if (expectRefused("lump", "Invalid WAD structure") != 0) return 1;

  // The last lump ending one byte past the WAD is refused (ending exactly at
  // its end is accepted; see acceptsTheValidWad).
  writeValidWad();
  put32(lumpEntry(TEST_LUMPS - 1) + 4,
        DOOM_WAD_EXPECTED_BYTES - (12 + (TEST_LUMPS - 1) * 100) + 1);
  if (expectRefused("lump", "Invalid WAD structure") != 0) return 1;

  // A negative lump offset (bit 31 set) in the second chunk is refused, as
  // the engine reads it signed.
  writeValidWad();
  put32(lumpEntry(17), 0x80000000u);
  if (expectRefused("lump", "Invalid WAD structure") != 0) return 1;
  return 0;
}

#if defined(CONFIG_IDF_TARGET_ESP32P4)
static int acceptsTheValidWad() {
  serial.clear();
  writeValidWad();
  put32(lumpEntry(TEST_LUMPS - 1) + 4,
        DOOM_WAD_EXPECTED_BYTES - (12 + (TEST_LUMPS - 1) * 100));
  partitionReads = 0;
  CHECK(doom_wad_preflight() == nullptr);
  // The preflight reads through the flash API; it never maps the WAD.
  CHECK(partitionReads > 0);
  CHECK(liveMappings == 0);
  CHECK(doom_wad_available());
  CHECK(serialHas("WAD mapped"));
  return 0;
}
#else
// Legacy S3 developer images: no table entry, WAD at the raw offset.
static int s3RawRegionStillWorks() {
  havePartition = false;
  wadBase = DOOM_WAD_PARTITION_OFFSET;
  serial.clear();
  eraseWad();
  if (expectRefused("header", "Invalid WAD structure") != 0) return 1;
  // An 8 MiB carrier cannot hold the raw region at all.
  writeValidWad();
  physicalFlashBytes = 8u * 1024u * 1024u;
  if (expectRefused("flash too small", "Flash too small for WAD region") != 0) {
    return 1;
  }
  physicalFlashBytes = 16u * 1024u * 1024u;
  CHECK(doom_wad_preflight() == nullptr);
  CHECK(doom_wad_available());
  CHECK(serialHas("WAD mapped"));
  return 0;
}
#endif

int main() {
  if (refusesWhatTheBootRefuses() != 0) return 1;
#if defined(CONFIG_IDF_TARGET_ESP32P4)
  if (acceptsTheValidWad() != 0) return 1;
  printf("test_doom_wad (p4): %d checks passed\n", checks);
#else
  if (s3RawRegionStillWorks() != 0) return 1;
  printf("test_doom_wad (s3): %d checks passed\n", checks);
#endif
  return 0;
}
