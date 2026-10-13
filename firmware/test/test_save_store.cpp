// Host tests for the saved-games store (firmware/doom/src/platform/
// save_store_model.h): what Quake's config.cfg and saves and Doom's
// default.cfg and saves are kept in, in the 60 KB of flash beside doom_wad.
//
// The flash is faked with NOR rules (a write only clears bits, an erase sets
// a whole sector to 0xFF), and every "restart" mounts a fresh store over the
// same bytes, so what survives is only what reached the flash.
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "../doom/src/platform/save_store_model.h"

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

const uint32_t SECTORS = 15;  // 0xF000, the gap beside doom_wad

struct Flash {
  std::vector<uint8_t> bytes;
  std::vector<int> erases;
  // Operations allowed before the power goes; -1 is never.
  long budget = -1;
  bool dead = false;

  explicit Flash(uint32_t sectors)
      : bytes(sectors * SAVE_STORE_SECTOR_BYTES, 0xFF), erases(sectors, 0) {}

  bool spend() {
    if (dead) return false;
    if (budget == 0) {
      dead = true;
      return false;
    }
    if (budget > 0) --budget;
    return true;
  }
};

bool fakeRead(void* context, uint32_t offset, void* out, uint32_t length) {
  Flash* f = static_cast<Flash*>(context);
  if (f->dead || offset + length > f->bytes.size()) return false;
  std::memcpy(out, f->bytes.data() + offset, length);
  return true;
}

bool fakeWrite(void* context, uint32_t offset, const void* data,
               uint32_t length) {
  Flash* f = static_cast<Flash*>(context);
  if (offset + length > f->bytes.size()) return false;
  const uint8_t* in = static_cast<const uint8_t*>(data);
  // A write cut by the power lands half its bytes.
  const bool torn = f->budget == 0 && !f->dead;
  if (!f->spend()) {
    if (torn) {
      for (uint32_t i = 0; i < length / 2; ++i) f->bytes[offset + i] &= in[i];
    }
    return false;
  }
  for (uint32_t i = 0; i < length; ++i) f->bytes[offset + i] &= in[i];
  return true;
}

bool fakeErase(void* context, uint32_t sector) {
  Flash* f = static_cast<Flash*>(context);
  if (sector >= f->erases.size() || !f->spend()) return false;
  std::memset(f->bytes.data() + sector * SAVE_STORE_SECTOR_BYTES, 0xFF,
              SAVE_STORE_SECTOR_BYTES);
  ++f->erases[sector];
  return true;
}

save_store_flash_t flashOf(Flash& f) {
  save_store_flash_t out;
  out.context = &f;
  out.read = fakeRead;
  out.write = fakeWrite;
  out.erase_sector = fakeErase;
  return out;
}

// A board restart: a new store over the same flash.
const char* mount(save_store_t* store, Flash& f) {
  f.dead = false;
  f.budget = -1;
  return save_store_mount(store, flashOf(f), (uint32_t)(f.erases.size()));
}

std::vector<uint8_t> text(const std::string& s) {
  return std::vector<uint8_t>(s.begin(), s.end());
}

std::vector<uint8_t> pattern(size_t n, uint32_t seed) {
  std::vector<uint8_t> out(n);
  for (size_t i = 0; i < n; ++i) {
    seed = seed * 1103515245u + 12345u;
    out[i] = (uint8_t)(seed >> 16);
  }
  return out;
}

const char* put(save_store_t* store, const char* name,
                const std::vector<uint8_t>& data) {
  return save_store_write(store, name, data.data(), (uint32_t)data.size(),
                          (uint32_t)data.size(),
                          save_store_crc32(0, data.data(), data.size()),
                          SAVE_STORE_ENCODING_RAW);
}

// The file's stored bytes, or empty with ok false when it is not there.
std::vector<uint8_t> get(save_store_t* store, const char* name, bool* ok) {
  *ok = false;
  const int index = save_store_find(store, name);
  if (index < 0) return {};
  std::vector<uint8_t> out(store->files[index].stored_bytes);
  *ok = save_store_read(store, index, 0, out.data(), (uint32_t)out.size());
  return out;
}

void testConfigSurvivesRestart() {
  Flash f(SECTORS);
  save_store_t store;
  CHECK(mount(&store, f) == nullptr);
  CHECK(store.count == 0);
  const auto config = text("bind w +forward\n\"volume\" \"0\"\n");
  CHECK(put(&store, "quake/id1/config.cfg", config) == nullptr);

  save_store_t again;
  CHECK(mount(&again, f) == nullptr);
  bool ok = false;
  CHECK(get(&again, "quake/id1/config.cfg", &ok) == config);
  CHECK(ok);
  CHECK(again.count == 1);
}

void testSavesSurviveRestart() {
  Flash f(SECTORS);
  save_store_t store;
  CHECK(mount(&store, f) == nullptr);
  const auto quake = pattern(9000, 1);   // three sectors
  const auto doom = pattern(5000, 2);    // two
  const auto config = text("sfx_volume 0\n");
  CHECK(put(&store, "quake/id1/s0.sav", quake) == nullptr);
  CHECK(put(&store, "doom/doom1.wad/doomsav0.dsg", doom) == nullptr);
  CHECK(put(&store, "doom/default.cfg", config) == nullptr);

  save_store_t again;
  CHECK(mount(&again, f) == nullptr);
  bool ok = false;
  CHECK(get(&again, "quake/id1/s0.sav", &ok) == quake && ok);
  CHECK(get(&again, "doom/doom1.wad/doomsav0.dsg", &ok) == doom && ok);
  CHECK(get(&again, "doom/default.cfg", &ok) == config && ok);
  CHECK(save_store_find(&again, "quake/id1/s1.sav") < 0);
  CHECK(again.count == 3);
  CHECK(save_store_free_sectors(&again) == SECTORS - 6);
}

void testOverwriteKeepsOneCopy() {
  Flash f(SECTORS);
  save_store_t store;
  CHECK(mount(&store, f) == nullptr);
  CHECK(put(&store, "doom/default.cfg", text("one")) == nullptr);
  CHECK(put(&store, "doom/default.cfg", text("two")) == nullptr);
  CHECK(store.count == 1);
  save_store_t again;
  CHECK(mount(&again, f) == nullptr);
  bool ok = false;
  CHECK(get(&again, "doom/default.cfg", &ok) == text("two") && ok);
  CHECK(again.count == 1);
  CHECK(save_store_free_sectors(&again) == SECTORS - 1);
}

void testUnchangedIsNotRewritten() {
  Flash f(SECTORS);
  save_store_t store;
  CHECK(mount(&store, f) == nullptr);
  const auto config = text("\"volume\" \"0\"\n");
  const uint32_t crc = save_store_crc32(0, config.data(), config.size());
  CHECK(!save_store_unchanged(&store, "quake/id1/config.cfg",
                              (uint32_t)config.size(), crc));
  CHECK(put(&store, "quake/id1/config.cfg", config) == nullptr);
  CHECK(save_store_unchanged(&store, "quake/id1/config.cfg",
                             (uint32_t)config.size(), crc));
  CHECK(!save_store_unchanged(&store, "quake/id1/config.cfg",
                              (uint32_t)config.size(), crc ^ 1));
}

void testRemove() {
  Flash f(SECTORS);
  save_store_t store;
  CHECK(mount(&store, f) == nullptr);
  CHECK(put(&store, "quake/id1/s3.sav", pattern(100, 3)) == nullptr);
  CHECK(save_store_remove(&store, "quake/id1/s3.sav"));
  CHECK(!save_store_remove(&store, "quake/id1/s3.sav"));
  save_store_t again;
  CHECK(mount(&again, f) == nullptr);
  CHECK(again.count == 0);
}

// The power going at every single flash operation of an overwrite leaves
// either the old file or the new one, whole, and never both nor neither.
void testPowerLossDuringOverwrite() {
  const auto before = pattern(6000, 4);
  const auto after = pattern(7000, 5);
  int sawOld = 0, sawNew = 0;
  for (long budget = 0; budget < 64; ++budget) {
    Flash f(SECTORS);
    save_store_t store;
    CHECK(mount(&store, f) == nullptr);
    CHECK(put(&store, "doom/doom1.wad/doomsav1.dsg", before) == nullptr);
    CHECK(put(&store, "doom/default.cfg", text("keep")) == nullptr);
    f.budget = budget;
    put(&store, "doom/doom1.wad/doomsav1.dsg", after);
    save_store_t again;
    CHECK(mount(&again, f) == nullptr);
    bool ok = false;
    const auto got = get(&again, "doom/doom1.wad/doomsav1.dsg", &ok);
    CHECK(ok);
    CHECK(got == before || got == after);
    if (got == before) ++sawOld;
    if (got == after) ++sawNew;
    CHECK(get(&again, "doom/default.cfg", &ok) == text("keep") && ok);
    CHECK(again.count == 2);
    // And the store still takes writes afterwards.
    CHECK(put(&again, "doom/doom1.wad/doomsav1.dsg", before) == nullptr);
    save_store_t third;
    CHECK(mount(&third, f) == nullptr);
    CHECK(get(&third, "doom/doom1.wad/doomsav1.dsg", &ok) == before && ok);
  }
  CHECK(sawOld > 0);
  CHECK(sawNew > 0);
}

// Flash from before the store (erased, or anything at all) mounts empty and
// takes writes.
void testGarbageArea() {
  Flash f(SECTORS);
  f.bytes = pattern(f.bytes.size(), 6);
  save_store_t store;
  CHECK(mount(&store, f) == nullptr);
  CHECK(store.count == 0);
  CHECK(put(&store, "quake/id1/config.cfg", text("x")) == nullptr);
  save_store_t again;
  CHECK(mount(&again, f) == nullptr);
  bool ok = false;
  CHECK(get(&again, "quake/id1/config.cfg", &ok) == text("x") && ok);
}

// A damaged payload byte drops that file only.
void testCorruptPayloadIgnored() {
  Flash f(SECTORS);
  save_store_t store;
  CHECK(mount(&store, f) == nullptr);
  CHECK(put(&store, "a/one", pattern(5000, 7)) == nullptr);
  CHECK(put(&store, "a/two", text("fine")) == nullptr);
  const int index = save_store_find(&store, "a/one");
  CHECK(index >= 0);
  const uint32_t head = store.files[index].head;
  f.bytes[head * SAVE_STORE_SECTOR_BYTES + SAVE_STORE_HEAD_BYTES + 10] ^= 0x01;
  save_store_t again;
  CHECK(mount(&again, f) == nullptr);
  CHECK(save_store_find(&again, "a/one") < 0);
  bool ok = false;
  CHECK(get(&again, "a/two", &ok) == text("fine") && ok);
}

// Two whole copies of one name (the power went before the old head was
// erased): the newer wins and the older is cleared.
void testDuplicateResolvedToNewest() {
  Flash f(SECTORS);
  save_store_t store;
  CHECK(mount(&store, f) == nullptr);
  CHECK(put(&store, "doom/default.cfg", text("old")) == nullptr);
  const std::vector<uint8_t> snapshot = f.bytes;
  CHECK(put(&store, "doom/default.cfg", text("new")) == nullptr);
  // Put the old head back where it was, as if its erase never happened.
  for (size_t i = 0; i < snapshot.size(); ++i) {
    if (snapshot[i] != 0xFF) f.bytes[i] = snapshot[i];
  }
  save_store_t again;
  CHECK(mount(&again, f) == nullptr);
  bool ok = false;
  CHECK(get(&again, "doom/default.cfg", &ok) == text("new") && ok);
  CHECK(again.count == 1);
  save_store_t third;
  CHECK(mount(&third, f) == nullptr);
  CHECK(third.count == 1);
  CHECK(save_store_free_sectors(&third) == SECTORS - 1);
}

// New files never take the last room an overwrite of the largest file needs,
// so a slot can always be saved over.
void testRoomKeptForOverwrite() {
  Flash f(SECTORS);
  save_store_t store;
  CHECK(mount(&store, f) == nullptr);
  const auto big = pattern(4 * SAVE_STORE_SECTOR_BYTES, 8);  // five sectors
  CHECK(put(&store, "quake/id1/s0.sav", big) == nullptr);       // 10 free
  CHECK(put(&store, "quake/id1/s1.sav", big) == nullptr);       // 5 free
  // A third would leave nothing to rewrite either with.
  CHECK(put(&store, "quake/id1/s2.sav", big) != nullptr);
  CHECK(put(&store, "quake/id1/config.cfg", text("cfg")) != nullptr);
  CHECK(save_store_free_sectors(&store) == 5);
  // Both slots can still be saved over, again and again.
  for (int i = 0; i < 6; ++i) {
    CHECK(put(&store, i % 2 ? "quake/id1/s0.sav" : "quake/id1/s1.sav",
              pattern(4 * SAVE_STORE_SECTOR_BYTES, 9 + i)) == nullptr);
  }
  CHECK(save_store_remove(&store, "quake/id1/s1.sav"));
  CHECK(put(&store, "quake/id1/config.cfg", text("cfg")) == nullptr);
  // Too big for the area at all.
  CHECK(put(&store, "x", pattern(SECTORS * SAVE_STORE_SECTOR_BYTES, 1)) !=
        nullptr);
}

// A config saved over and over wears the area evenly, not one sector.
void testWearSpreads() {
  Flash f(SECTORS);
  save_store_t store;
  CHECK(mount(&store, f) == nullptr);
  CHECK(put(&store, "quake/id1/s0.sav", pattern(9000, 10)) == nullptr);
  for (int i = 0; i < 300; ++i) {
    char body[32];
    std::snprintf(body, sizeof(body), "\"volume\" \"%d\"\n", i);
    CHECK(put(&store, "quake/id1/config.cfg", text(body)) == nullptr);
  }
  int most = 0, least = 1 << 30;
  for (int e : f.erases) {
    if (e > most) most = e;
    if (e < least) least = e;
  }
  // 600 erases over the 12 sectors the save leaves free.
  CHECK(most <= 60);
  save_store_t again;
  CHECK(mount(&again, f) == nullptr);
  bool ok = false;
  CHECK(get(&again, "quake/id1/config.cfg", &ok) == text("\"volume\" \"299\"\n"));
  CHECK(again.count == 2);
}

void testNames() {
  char out[SAVE_STORE_NAME_BYTES];
  CHECK(save_store_name_from_path("doom", "/doom1.wad//./doomsav0.dsg", out));
  CHECK(std::strcmp(out, "doom/doom1.wad/doomsav0.dsg") == 0);
  CHECK(save_store_name_from_path("quake", "/id1/config.cfg", out));
  CHECK(std::strcmp(out, "quake/id1/config.cfg") == 0);
  CHECK(save_store_name_from_path(nullptr, "/doom/default.cfg", out));
  CHECK(std::strcmp(out, "doom/default.cfg") == 0);
  CHECK(!save_store_name_from_path("quake", "/id1/../x", out));
  CHECK(!save_store_name_from_path("quake", "/", out));
  CHECK(!save_store_name_from_path("quake", "/id1/", out));
  CHECK(!save_store_name_from_path(nullptr, "", out));
  std::string longPath = "/" + std::string(SAVE_STORE_NAME_BYTES, 'a');
  CHECK(!save_store_name_from_path(nullptr, longPath.c_str(), out));
  // The longest Doom save name fits: a 20-character WAD name.
  CHECK(save_store_name_from_path("doom", "/freedoom-12345678.wad/doomsav5.dsg",
                                  out));
}

void testCrcIsZlibs() {
  const char* s = "123456789";
  CHECK(save_store_crc32(0, (const uint8_t*)s, 9) == 0xCBF43926u);
  uint32_t crc = save_store_crc32(0, (const uint8_t*)s, 4);
  crc = save_store_crc32(crc, (const uint8_t*)s + 4, 5);
  CHECK(crc == 0xCBF43926u);
}

}  // namespace

int main() {
  testConfigSurvivesRestart();
  testSavesSurviveRestart();
  testOverwriteKeepsOneCopy();
  testUnchangedIsNotRewritten();
  testRemove();
  testPowerLossDuringOverwrite();
  testGarbageArea();
  testCorruptPayloadIgnored();
  testDuplicateResolvedToNewest();
  testRoomKeptForOverwrite();
  testWearSpreads();
  testNames();
  testCrcIsZlibs();
  if (failures != 0) {
    std::fprintf(stderr, "test_save_store: %d failure(s)\n", failures);
    return 1;
  }
  std::printf("test_save_store: all passed\n");
  return 0;
}
