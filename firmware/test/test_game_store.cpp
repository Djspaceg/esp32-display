// Host tests for the game store directory (firmware/doom/src/platform/
// game_store_model.h): which directory sectors the firmware accepts, which it
// refuses and why, and the legacy layout it falls back to.
//
// The golden directory GAME_STORE_FIXTURE is the one the Mac app's encoder is
// held to (SenderProtocolTests/GameStoreTests.swift), so the two sides cannot
// drift apart.
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "../doom/src/platform/game_store_model.h"
#include "../quake/src/platform/quake_pak_model.h"

#ifndef GAME_STORE_FIXTURE
#error "GAME_STORE_FIXTURE must name game-store-v1.hex"
#endif

static int failures = 0;
#define CHECK(cond)                                                   \
  do {                                                                \
    if (!(cond)) {                                                    \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__,     \
                   __LINE__, #cond);                                  \
      ++failures;                                                     \
    }                                                                 \
  } while (0)

namespace {

const uint32_t AREA = 0x1200000;

std::vector<uint8_t> fixture() {
  std::ifstream in(GAME_STORE_FIXTURE);
  std::vector<uint8_t> bytes;
  unsigned value = 0;
  while (in >> std::hex >> value) bytes.push_back((uint8_t)value);
  std::vector<uint8_t> sector(GAME_STORE_SECTOR_BYTES, 0xFF);
  std::memcpy(sector.data(), bytes.data(), bytes.size());
  return sector;
}

void putU16(std::vector<uint8_t>& b, size_t at, uint16_t v) {
  b[at] = v & 0xFF;
  b[at + 1] = (v >> 8) & 0xFF;
}

void putU32(std::vector<uint8_t>& b, size_t at, uint32_t v) {
  b[at] = v & 0xFF;
  b[at + 1] = (v >> 8) & 0xFF;
  b[at + 2] = (v >> 16) & 0xFF;
  b[at + 3] = (v >> 24) & 0xFF;
}

struct Entry {
  uint8_t kind;
  uint8_t slot;
  uint32_t offset;
  uint32_t length;
  std::string name;
};

// A directory sector built field by field, the CRC computed last, so a test
// can change one field and still present a sector whose CRC is right.
std::vector<uint8_t> directory(const std::vector<Entry>& entries,
                               uint32_t area = AREA, uint16_t version = 1) {
  std::vector<uint8_t> s(GAME_STORE_SECTOR_BYTES, 0xFF);
  std::memcpy(s.data(), "ESPGAMES", 8);
  putU16(s, 8, version);
  putU16(s, 10, 64);
  putU16(s, 12, (uint16_t)entries.size());
  putU16(s, 14, 0);
  putU32(s, 16, area);
  putU32(s, 20, 3);
  putU32(s, 24, 0);
  putU32(s, 28, 0);
  for (size_t i = 0; i < entries.size(); ++i) {
    const size_t at = 32 + i * 64;
    s[at] = entries[i].kind;
    s[at + 1] = entries[i].slot;
    putU16(s, at + 2, 0);
    putU32(s, at + 4, entries[i].offset);
    putU32(s, at + 8, entries[i].length);
    std::memset(s.data() + at + 12, 0, 20);
    std::memcpy(s.data() + at + 12, entries[i].name.data(),
                entries[i].name.size() > 20 ? 20 : entries[i].name.size());
    std::memset(s.data() + at + 32, 0xAB, 32);
  }
  const size_t covered = 32 + entries.size() * 64;
  putU32(s, 24, game_store_crc32(s.data(), covered));
  return s;
}

void reseal(std::vector<uint8_t>& s) {
  const size_t covered = 32 + (size_t)game_store_u16(s.data() + 12) * 64;
  putU32(s, 24, 0);
  putU32(s, 24, game_store_crc32(s.data(), covered));
}

const char* parse(const std::vector<uint8_t>& s, game_store_t* store,
                  uint32_t area = AREA) {
  return game_store_parse(s.data(), area, store);
}

bool refusedWith(const std::vector<uint8_t>& s, const char* reason,
                 uint32_t area = AREA) {
  game_store_t store;
  const char* got = parse(s, &store, area);
  if (got == nullptr || std::strcmp(got, reason) != 0) {
    std::fprintf(stderr, "  wanted \"%s\", got \"%s\"\n", reason,
                 got == nullptr ? "(accepted)" : got);
    return false;
  }
  return store.count == 0;
}

// Rule: the shared fixture parses to exactly what it says, so the app's
// encoder and this parser agree byte for byte.
void testFixture() {
  game_store_t store;
  const std::vector<uint8_t> sector = fixture();
  CHECK(game_store_crc32((const uint8_t*)"123456789", 9) == 0xCBF43926u);
  CHECK(parse(sector, &store) == nullptr);
  CHECK(!store.legacy);
  CHECK(store.count == 2);
  CHECK(store.generation == 7);
  CHECK(store.entries[0].kind == GAME_STORE_KIND_QUAKE_PAK);
  CHECK(store.entries[0].slot == 0);
  CHECK(store.entries[0].offset == 0);
  CHECK(store.entries[0].length == 18689235);
  CHECK(std::strcmp(store.entries[0].name, "pak0.pak") == 0);
  CHECK(store.entries[0].sha256[0] == 0x35 && store.entries[0].sha256[31] == 0xaf);
  CHECK(store.entries[1].kind == GAME_STORE_KIND_DOOM_WAD);
  CHECK(store.entries[1].offset == 0x11D3000);
  CHECK(store.entries[1].length == 4096);
  CHECK(std::strcmp(store.entries[1].name, "miniwad.wad") == 0);
  CHECK(game_store_find_doom(&store, "MINIWAD.WAD") == &store.entries[1]);
  CHECK(game_store_find_doom(&store, "doom2.wad") == nullptr);
  CHECK(game_store_find_quake(&store, 0) == &store.entries[0]);
  CHECK(game_store_find_quake(&store, 1) == nullptr);
}

// Rule: an area with no directory is the legacy layout, accepted with nothing
// listed, so a board written the old way keeps its raw pak0.pak.
void testLegacy() {
  game_store_t store;
  std::vector<uint8_t> erased(GAME_STORE_SECTOR_BYTES, 0xFF);
  CHECK(parse(erased, &store) == nullptr);
  CHECK(store.legacy);
  CHECK(store.count == 0);
  std::vector<uint8_t> packTail(GAME_STORE_SECTOR_BYTES, 0x00);
  CHECK(parse(packTail, &store) == nullptr);
  CHECK(store.legacy);
}

// Rule: a newer version is refused with a reason that says to update; a
// damaged one is refused as damaged, never half read.
void testVersionAndDamage() {
  CHECK(refusedWith(directory({}, AREA, 2),
                    "game store is a newer version; update the firmware"));
  CHECK(refusedWith(directory({}, AREA, 0), "game store directory is damaged"));
  std::vector<uint8_t> flipped =
      directory({{GAME_STORE_KIND_DOOM_WAD, 0, 0, 4096, "miniwad.wad"}});
  flipped[32 + 8] ^= 1;  // the length, after the CRC was taken
  CHECK(refusedWith(flipped, "game store directory is damaged"));
  std::vector<uint8_t> wrongEntryBytes = directory({});
  putU16(wrongEntryBytes, 10, 32);
  reseal(wrongEntryBytes);
  CHECK(refusedWith(wrongEntryBytes, "game store directory is damaged"));
  std::vector<uint8_t> many = directory({});
  putU16(many, 12, 17);
  CHECK(refusedWith(many, "game store has too many files"));
  CHECK(refusedWith(directory({}, 0x800000),
                    "game store was written for a different area size"));
  CHECK(refusedWith(directory({}, 0x1000), "game data area too small", 0x1000));
}

// Rule: every entry lies inside the area's data (never on the directory), on a
// sector boundary, and apart from every other.
void testPlacement() {
  const uint32_t end = AREA - GAME_STORE_SECTOR_BYTES;
  game_store_t store;
  CHECK(parse(directory({{GAME_STORE_KIND_DOOM_WAD, 0, end - 4096, 4096,
                          "last.wad"}}),
              &store) == nullptr);
  CHECK(refusedWith(directory({{GAME_STORE_KIND_DOOM_WAD, 0, end - 4096, 4097,
                                "last.wad"}}),
                    "game store entry is outside the area"));
  CHECK(refusedWith(directory({{GAME_STORE_KIND_DOOM_WAD, 0, 100, 4096,
                                "odd.wad"}}),
                    "game store entry is outside the area"));
  CHECK(refusedWith(directory({{GAME_STORE_KIND_DOOM_WAD, 0, 0, 4,
                                "tiny.wad"}}),
                    "game store entry is outside the area"));
  CHECK(refusedWith(directory({{GAME_STORE_KIND_DOOM_WAD, 0, 0xFFFFF000u,
                                0x2000, "wrap.wad"}}),
                    "game store entry is outside the area"));
  CHECK(refusedWith(directory({{GAME_STORE_KIND_DOOM_WAD, 0, 0, 8192, "a.wad"},
                               {GAME_STORE_KIND_DOOM_WAD, 0, 4096, 4096,
                                "b.wad"}}),
                    "game store entries overlap"));
  CHECK(parse(directory({{GAME_STORE_KIND_DOOM_WAD, 0, 0, 4096, "a.wad"},
                         {GAME_STORE_KIND_DOOM_WAD, 0, 4096, 4096, "b.wad"}}),
              &store) == nullptr);
  CHECK(store.count == 2);
}

// Rule: names are the ones the engines open: a Doom .wad, unique in any case,
// and Quake's pak<slot>.pak, one per slot. Anything else is damage.
void testNames() {
  game_store_t store;
  CHECK(refusedWith(directory({{GAME_STORE_KIND_DOOM_WAD, 0, 0, 4096, "a.wad"},
                               {GAME_STORE_KIND_DOOM_WAD, 0, 8192, 4096,
                                "a.wad"}}),
                    "game store names a file twice"));
  CHECK(refusedWith(directory({{GAME_STORE_KIND_QUAKE_PAK, 0, 0, 4096,
                                "pak0.pak"},
                               {GAME_STORE_KIND_QUAKE_PAK, 0, 8192, 4096,
                                "pak0.pak"}}),
                    "game store names a file twice"));
  CHECK(refusedWith(directory({{GAME_STORE_KIND_DOOM_WAD, 0, 0, 4096,
                                "Doom2.wad"}}),
                    "game store entry is damaged"));
  CHECK(refusedWith(directory({{GAME_STORE_KIND_DOOM_WAD, 0, 0, 4096,
                                "doom2.pak"}}),
                    "game store entry is damaged"));
  CHECK(refusedWith(directory({{GAME_STORE_KIND_DOOM_WAD, 0, 0, 4096,
                                "d w.wad"}}),
                    "game store entry is damaged"));
  CHECK(refusedWith(directory({{GAME_STORE_KIND_QUAKE_PAK, 1, 0, 4096,
                                "pak0.pak"}}),
                    "game store entry is damaged"));
  CHECK(refusedWith(directory({{GAME_STORE_KIND_QUAKE_PAK, 10, 0, 4096,
                                "pak:.pak"}}),
                    "game store entry is damaged"));
  CHECK(refusedWith(directory({{GAME_STORE_KIND_DOOM_WAD, 1, 0, 4096,
                                "a.wad"}}),
                    "game store entry is damaged"));
  CHECK(refusedWith(directory({{3, 0, 0, 4096, "x.bin"}}),
                    "game store holds a file this firmware does not know"));
  CHECK(parse(directory({{GAME_STORE_KIND_QUAKE_PAK, 1, 0, 4096, "pak1.pak"},
                         {GAME_STORE_KIND_DOOM_WAD, 0, 4096, 4096,
                          "freedoom-1_x.wad"}}),
              &store) == nullptr);
  // Bytes after the name's NUL must be NUL too.
  std::vector<uint8_t> trailing =
      directory({{GAME_STORE_KIND_DOOM_WAD, 0, 0, 4096, "a.wad"}});
  trailing[32 + 12 + 10] = 'x';
  reseal(trailing);
  CHECK(refusedWith(trailing, "game store entry is damaged"));

  std::vector<Entry> nine;
  for (uint32_t i = 0; i < 9; ++i) {
    nine.push_back({GAME_STORE_KIND_DOOM_WAD, 0, i * 4096, 4096,
                    std::string("w") + (char)('0' + i) + ".wad"});
  }
  CHECK(refusedWith(directory(nine), "game store has too many Doom WADs"));
  nine.pop_back();
  CHECK(parse(directory(nine), &store) == nullptr);
}

// Rule: the S3 area is what the chip has past 8 MiB, up to Quake's original
// 18 MiB region; none below 9 MiB.
void testS3Area() {
  CHECK(game_store_s3_area_bytes(32u << 20) == 0x1200000);
  CHECK(game_store_s3_area_bytes(16u << 20) == 0x800000);
  CHECK(game_store_s3_area_bytes(8u << 20) == 0);
  CHECK(game_store_s3_area_bytes(9u << 20) == 0x100000);
  CHECK(game_store_directory_offset(0x1200000) == 0x11FF000);
}

// Rule: a stored WAD's menu label is its name without .wad, upper case.
void testLabels() {
  char label[GAME_STORE_NAME_BYTES + 1];
  game_store_doom_label("freedoom1.wad", label);
  CHECK(std::strcmp(label, "FREEDOOM1") == 0);
  game_store_doom_label("my-doom_2.wad", label);
  CHECK(std::strcmp(label, "MY-DOOM_2") == 0);
  game_store_doom_label("doom.wad", label);
  CHECK(std::strcmp(label, "DOOM.WAD") == 0);
  game_store_doom_label("quake.wad", label);
  CHECK(std::strcmp(label, "QUAKE.WAD") == 0);
  game_store_doom_label("streaming.wad", label);
  CHECK(std::strcmp(label, "STREAMING.WAD") == 0);
}

// Rule: Quake opens id1/pak0.pak, pak1.pak, ... in turn; each maps to its slot
// and nothing else does.
void testQuakePaths() {
  CHECK(quake_pak_path_slot("/id1/pak0.pak") == 0);
  CHECK(quake_pak_path_slot("/id1/pak1.pak") == 1);
  CHECK(quake_pak_path_slot("/id1/pak9.pak") == 9);
  CHECK(quake_pak_path_slot("/id1/pak10.pak") == -1);
  CHECK(quake_pak_path_slot("/id1/pak0.pakx") == -1);
  CHECK(quake_pak_path_slot("/id1/config.cfg") == -1);
  CHECK(quake_pak_path_slot("/id2/pak0.pak") == -1);
  CHECK(quake_pak_path_slot(nullptr) == -1);
}

// Rule: Quake is given pak0.pak and each pak after it up to the first gap; a
// legacy area is pak0.pak alone across the whole area; a store without
// pak0.pak gives Quake nothing.
void testQuakeSpans() {
  game_store_t store;
  quake_pak_span_t spans[GAME_STORE_MAX_QUAKE_SLOT + 1];
  const char* problem = "unset";
  std::vector<uint8_t> erased(GAME_STORE_SECTOR_BYTES, 0xFF);
  CHECK(parse(erased, &store) == nullptr);
  CHECK(quake_pak_spans(&store, spans, &problem) == 1);
  CHECK(problem == nullptr);
  CHECK(spans[0].base == 0 && spans[0].bytes == AREA);

  CHECK(parse(directory({{GAME_STORE_KIND_QUAKE_PAK, 1, 0x100000, 8192,
                          "pak1.pak"},
                         {GAME_STORE_KIND_QUAKE_PAK, 0, 0, 8192, "pak0.pak"},
                         {GAME_STORE_KIND_QUAKE_PAK, 3, 0x200000, 8192,
                          "pak3.pak"}}),
              &store) == nullptr);
  CHECK(quake_pak_spans(&store, spans, &problem) == 2);
  CHECK(problem == nullptr);
  CHECK(spans[0].base == 0 && spans[0].bytes == 8192);
  CHECK(spans[1].base == 0x100000 && spans[1].bytes == 8192);

  CHECK(parse(directory({{GAME_STORE_KIND_DOOM_WAD, 0, 0, 8192, "a.wad"},
                         {GAME_STORE_KIND_QUAKE_PAK, 1, 0x100000, 8192,
                          "pak1.pak"}}),
              &store) == nullptr);
  CHECK(quake_pak_spans(&store, spans, &problem) == 0);
  CHECK(problem != nullptr &&
        std::strcmp(problem, "no pak0.pak in the game store") == 0);
}

}  // namespace

int main() {
  testFixture();
  testLegacy();
  testVersionAndDamage();
  testPlacement();
  testNames();
  testS3Area();
  testLabels();
  testQuakePaths();
  testQuakeSpans();
  if (failures != 0) {
    std::fprintf(stderr, "test_game_store: %d failure(s)\n", failures);
    return 1;
  }
  std::printf("test_game_store: ok\n");
  return 0;
}
