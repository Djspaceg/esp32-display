// Host test for Doom WADs kept in the game store (doom/src/platform/
// w_file_esp32.c.inc and game_store.c.inc, compiled unmodified as C by
// doom_wad_unit.c against fakes/doom_wad).
//
// The rules, on the P4 and S3 storage layouts:
// - The boot menu's preflight lists every stored WAD the Doom boot would
//   accept, and logs each one it would refuse.
// - A chosen stored WAD is read through the flash API on demand, never mapped
//   (the area crosses 16 MiB, past what the cache maps), and its size is its
//   own, not the shareware file's.
// - A legacy area (no directory) lists nothing and refuses nothing.
// - The bundled doom1.wad in doom_wad is untouched by all of this.
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <esp_flash.h>
#include <esp_partition.h>
#include <spi_flash_mmap.h>

#include "doom_mode.h"
#include "platform/game_store_model.h"
extern "C" {
#include "w_file.h"
bool doom_wad_available(void);
bool doom_wad_is_mapped(void);
void doom_select_store_wad(const char *name);
const char *doom_selected_wad_name(void);
size_t doom_store_wad_preflight(char names[][GAME_STORE_NAME_BYTES + 1],
                                size_t max, const char **problem);
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
#if defined(CONFIG_IDF_TARGET_ESP32P4)
// A shortened quake_pak partition: the firmware takes the area's size from it.
static const uint32_t AREA_ADDRESS = 0xE00000;
static const uint32_t AREA_BYTES = 0x800000;
static const uint32_t FLASH_BYTES = AREA_ADDRESS + AREA_BYTES;
static bool haveAreaPartition = true;
#else
static const uint32_t AREA_ADDRESS = GAME_STORE_S3_OFFSET;
// A 16 MiB chip: an 8 MiB area past the universal table.
static const uint32_t AREA_BYTES = 0x800000;
static const uint32_t FLASH_BYTES = AREA_ADDRESS + AREA_BYTES;
static bool haveAreaPartition = false;  // until registered
#endif
static std::vector<uint8_t> flash(FLASH_BYTES, 0xFF);
static uint32_t physicalFlashBytes = FLASH_BYTES;
static esp_partition_t area = {0x42, 0x07, AREA_ADDRESS, AREA_BYTES,
                               "quake_pak"};
static int liveMappings = 0;
static int registrations = 0;
static esp_flash_t chip = {0};

extern "C" {
esp_flash_t *esp_flash_default_chip = &chip;
const char *esp_err_to_name(esp_err_t) { return "ESP_FAIL"; }

const esp_partition_t *esp_partition_find_first(esp_partition_type_t type,
                                                esp_partition_subtype_t subtype,
                                                const char *label) {
  if (haveAreaPartition && type == 0x42 && subtype == 0x07 &&
      label != nullptr && strcmp(label, "quake_pak") == 0) {
    return &area;
  }
  return nullptr;  // no doom_wad: the bundled WAD is not this test's
}

esp_err_t esp_partition_register_external(
    esp_flash_t *, size_t offset, size_t size, const char *label,
    esp_partition_type_t type, esp_partition_subtype_t subtype,
    const esp_partition_t **out) {
  registrations++;
  if (offset != AREA_ADDRESS || strcmp(label, "quake_pak") != 0 ||
      type != 0x42 || subtype != 0x07 || offset + size > physicalFlashBytes) {
    return ESP_FAIL;
  }
  area.size = (uint32_t)size;
  haveAreaPartition = true;
  if (out != nullptr) *out = &area;
  return ESP_OK;
}

esp_err_t esp_partition_mmap(const esp_partition_t *, size_t, size_t,
                             esp_partition_mmap_memory_t, const void **,
                             esp_partition_mmap_handle_t *) {
  liveMappings++;
  return ESP_FAIL;
}

void esp_partition_munmap(esp_partition_mmap_handle_t) { liveMappings--; }

esp_err_t esp_partition_read(const esp_partition_t *partition,
                             size_t src_offset, void *dst, size_t size) {
  if (src_offset > partition->size || size > partition->size - src_offset ||
      partition->address + src_offset + size > flash.size()) {
    return ESP_FAIL;
  }
  memcpy(dst, flash.data() + partition->address + src_offset, size);
  return ESP_OK;
}

esp_err_t esp_flash_get_physical_size(esp_flash_t *, uint32_t *out_size) {
  *out_size = physicalFlashBytes;
  return ESP_OK;
}

esp_err_t esp_flash_read(esp_flash_t *, void *, uint32_t, uint32_t) {
  return ESP_FAIL;
}

esp_err_t spi_flash_mmap(size_t, size_t, spi_flash_mmap_memory_t,
                         const void **, spi_flash_mmap_handle_t *) {
  liveMappings++;
  return ESP_FAIL;
}

void spi_flash_munmap(spi_flash_mmap_handle_t) { liveMappings--; }
}

// ---- Area contents ----------------------------------------------------------
static void put16(std::vector<uint8_t> &b, size_t at, uint16_t v) {
  b[at] = v & 0xFF;
  b[at + 1] = v >> 8;
}
static void put32(std::vector<uint8_t> &b, size_t at, uint32_t v) {
  for (int i = 0; i < 4; i++) b[at + i] = (uint8_t)(v >> (8 * i));
}

// A structurally valid IWAD of `bytes`, directory at its end, each lump's
// bytes its index so reads can be told apart.
static std::vector<uint8_t> wad(uint32_t bytes, uint32_t lumps = 20) {
  std::vector<uint8_t> w(bytes, 0);
  memcpy(w.data(), "IWAD", 4);
  const uint32_t directory = bytes - lumps * 16;
  put32(w, 4, lumps);
  put32(w, 8, directory);
  for (uint32_t i = 0; i < lumps; i++) {
    put32(w, directory + i * 16, 12 + i * 10);
    put32(w, directory + i * 16 + 4, 10);
    memset(w.data() + 12 + i * 10, (int)(i + 1), 10);
  }
  return w;
}

struct Stored {
  std::string name;
  uint32_t offset;
  std::vector<uint8_t> bytes;
  uint8_t kind = GAME_STORE_KIND_DOOM_WAD;
};

static void writeArea(const std::vector<Stored> &files, bool directory = true) {
  std::fill(flash.begin() + AREA_ADDRESS, flash.end(), 0xFF);
  for (const Stored &f : files) {
    memcpy(flash.data() + AREA_ADDRESS + f.offset, f.bytes.data(),
           f.bytes.size());
  }
  if (!directory) return;
  std::vector<uint8_t> s(GAME_STORE_SECTOR_BYTES, 0xFF);
  memcpy(s.data(), "ESPGAMES", 8);
  put16(s, 8, 1);
  put16(s, 10, 64);
  put16(s, 12, (uint16_t)files.size());
  put16(s, 14, 0);
  put32(s, 16, AREA_BYTES);
  put32(s, 20, 1);
  put32(s, 24, 0);
  put32(s, 28, 0);
  for (size_t i = 0; i < files.size(); ++i) {
    const size_t at = 32 + i * 64;
    s[at] = files[i].kind;
    s[at + 1] = 0;
    put16(s, at + 2, 0);
    put32(s, at + 4, files[i].offset);
    put32(s, at + 8, (uint32_t)files[i].bytes.size());
    memset(s.data() + at + 12, 0, 20);
    memcpy(s.data() + at + 12, files[i].name.data(), files[i].name.size());
    memset(s.data() + at + 32, 0, 32);
  }
  put32(s, 24, game_store_crc32(s.data(), 32 + files.size() * 64));
  memcpy(flash.data() + AREA_ADDRESS + AREA_BYTES - GAME_STORE_SECTOR_BYTES,
         s.data(), s.size());
}

static bool serialHas(const char *text) {
  return serial.find(text) != std::string::npos;
}

static char names[GAME_STORE_MAX_DOOM_WADS][GAME_STORE_NAME_BYTES + 1];

// Rule: every stored WAD the Doom boot would accept is listed, in directory
// order, and one it would refuse is left out with its reason on Serial. A WAD
// larger than the shareware file is fine: its own length bounds it.
static int preflightListsTheGoodWads() {
  serial.clear();
  std::vector<uint8_t> broken = wad(8192);
  put32(broken, 8, 9000);  // directory past its own end
  writeArea({{"big.wad", 0, wad(DOOM_WAD_EXPECTED_BYTES + 100000)},
             {"broken.wad", 0x500000, broken},
             {"small.wad", 0x600000, wad(4096)}});
  const char *problem = "unset";
  const size_t count =
      doom_store_wad_preflight(names, GAME_STORE_MAX_DOOM_WADS, &problem);
  CHECK(count == 2);
  CHECK(strcmp(names[0], "big.wad") == 0);
  CHECK(strcmp(names[1], "small.wad") == 0);
  CHECK(problem != nullptr && strstr(problem, "directory") != nullptr);
  CHECK(serialHas("broken.wad"));
  CHECK(liveMappings == 0);
  return 0;
}

// Rule: a legacy area, with no directory, lists no WADs and is no problem.
static int legacyAreaListsNothing() {
  writeArea({}, false);
  const char *problem = "unset";
  CHECK(doom_store_wad_preflight(names, GAME_STORE_MAX_DOOM_WADS, &problem) ==
        0);
  CHECK(problem == nullptr);
  return 0;
}

// Rule: a chosen stored WAD boots unmapped, its lumps read from the area at
// its own offset, its length its own; the engine is told its name.
static int chosenWadReadsFromTheArea() {
  serial.clear();
  const std::vector<uint8_t> second = wad(6000, 7);
  writeArea({{"first.wad", 0, wad(4096)}, {"second.wad", 0x2000, second}});
  doom_select_store_wad("second.wad");
  CHECK(strcmp(doom_selected_wad_name(), "second.wad") == 0);
  CHECK(doom_wad_available());
  CHECK(!doom_wad_is_mapped());
  CHECK(liveMappings == 0);
  char path[] = "second.wad";
  wad_file_t *file = W_OpenFile(path);
  CHECK(file != nullptr);
  CHECK(file->mapped == nullptr);
  CHECK(file->length == 6000);
  uint8_t lump[10];
  CHECK(W_Read(file, 12 + 3 * 10, lump, sizeof(lump)) == sizeof(lump));
  CHECK(lump[0] == 4 && lump[9] == 4);
  // A read running past the WAD's end is cut at it.
  uint8_t tail[64];
  CHECK(W_Read(file, 6000 - 16, tail, sizeof(tail)) == 16);
  CHECK(W_Read(file, 6000, tail, sizeof(tail)) == 0);
  CHECK(serialHas("second.wad"));
  return 0;
}

// Rule: a chosen WAD that is not in the store refuses the boot, by name.
static int missingWadRefusesTheBoot() {
  serial.clear();
  writeArea({{"first.wad", 0, wad(4096)}});
  doom_select_store_wad("gone.wad");
  CHECK(!doom_wad_available());
  CHECK(serialHas("gone.wad"));
  CHECK(strstr(doom_wad_failure(), "not in the game store") != nullptr);
  return 0;
}

#if !defined(CONFIG_IDF_TARGET_ESP32P4)
// Rule: an S3 too small for an area has none, and says so.
static int smallS3HasNoArea() {
  physicalFlashBytes = 8u * 1024u * 1024u;
  const char *problem = nullptr;
  CHECK(doom_store_wad_preflight(names, GAME_STORE_MAX_DOOM_WADS, &problem) ==
        0);
  CHECK(problem != nullptr && strstr(problem, "flash too small") != nullptr);
  CHECK(registrations == 0);
  return 0;
}
#endif

// Each case runs in its own process: the store is read once a boot, and the
// Doom boot keeps its first answer, exactly as on the board.
int main(int argc, char **argv) {
  const std::string which = argc > 1 ? argv[1] : "";
  int failed = 1;
  if (which == "preflight") {
    failed = preflightListsTheGoodWads();
#if !defined(CONFIG_IDF_TARGET_ESP32P4)
    if (failed == 0 && (registrations != 1 || area.size != AREA_BYTES)) {
      printf("FAIL: the S3 area was not registered once at its size\n");
      failed = 1;
    }
#endif
  } else if (which == "legacy") {
    failed = legacyAreaListsNothing();
  } else if (which == "chosen") {
    failed = chosenWadReadsFromTheArea();
  } else if (which == "missing") {
    failed = missingWadRefusesTheBoot();
  } else if (which == "small-s3") {
#if defined(CONFIG_IDF_TARGET_ESP32P4)
    failed = 0;  // a P4's area is its partition
#else
    failed = smallS3HasNoArea();
#endif
  } else {
    printf("usage: %s preflight|legacy|chosen|missing|small-s3\n", argv[0]);
    return 2;
  }
  if (failed != 0) return 1;
  printf("test_doom_store_wad %s: %d checks passed\n", which.c_str(), checks);
  return 0;
}
