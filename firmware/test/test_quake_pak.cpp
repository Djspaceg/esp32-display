// Host tests for the read-only Quake data file's model
// (firmware/quake/src/platform/quake_pak_model.h): which partition contents
// count as a usable pack, how long the served file is, and how its reads and
// seeks behave at the edges.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "../quake/src/platform/quake_pak_model.h"

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

struct Flash {
  std::vector<uint8_t> bytes;
  int reads = 0;
  bool failReads = false;
};

bool readFlash(void* context, uint32_t offset, void* out, uint32_t length) {
  Flash* flash = static_cast<Flash*>(context);
  ++flash->reads;
  if (flash->failReads) return false;
  if (offset > flash->bytes.size() || length > flash->bytes.size() - offset) {
    return false;
  }
  std::memcpy(out, flash->bytes.data() + offset, length);
  return true;
}

void putU32(std::vector<uint8_t>& b, size_t at, uint32_t v) {
  b[at] = v & 0xFF;
  b[at + 1] = (v >> 8) & 0xFF;
  b[at + 2] = (v >> 16) & 0xFF;
  b[at + 3] = (v >> 24) & 0xFF;
}

struct Entry {
  std::string name;
  uint32_t offset;
  uint32_t size;
};

// A partition of `partition` bytes (erased to 0xFF, as flash is) holding a
// pack with the given entries and its directory at `directory`.
Flash makePack(uint32_t partition, uint32_t directory,
               const std::vector<Entry>& entries) {
  Flash flash;
  flash.bytes.assign(partition, 0xFF);
  std::memcpy(flash.bytes.data(), "PACK", 4);
  putU32(flash.bytes, 4, directory);
  putU32(flash.bytes, 8, (uint32_t)entries.size() * QUAKE_PAK_ENTRY_BYTES);
  for (size_t i = 0; i < entries.size(); ++i) {
    const size_t at = directory + i * QUAKE_PAK_ENTRY_BYTES;
    std::memset(flash.bytes.data() + at, 0, QUAKE_PAK_ENTRY_NAME_BYTES);
    std::memcpy(flash.bytes.data() + at, entries[i].name.data(),
                entries[i].name.size());
    putU32(flash.bytes, at + 56, entries[i].offset);
    putU32(flash.bytes, at + 60, entries[i].size);
  }
  return flash;
}

const char* check(Flash& flash, uint32_t* bytes) {
  return quake_pak_check(readFlash, &flash, (uint32_t)flash.bytes.size(),
                         bytes);
}

}  // namespace

int main() {
  // --- a well-formed pack ---------------------------------------------------
  {
    // Data first, directory last, as id's packer and the shareware pak0 lay
    // it out: the file ends where the directory does.
    Flash flash = makePack(4096, 1000, {{"gfx/palette.lmp", 12, 768},
                                        {"progs.dat", 780, 200}});
    uint32_t bytes = 123;
    CHECK(check(flash, &bytes) == nullptr);
    CHECK(bytes == 1000 + 2 * QUAKE_PAK_ENTRY_BYTES);
  }
  {
    // A directory before the data: the file ends at the furthest entry.
    Flash flash = makePack(8192, 12, {{"a", 200, 100}, {"b", 300, 4000}});
    uint32_t bytes = 0;
    CHECK(check(flash, &bytes) == nullptr);
    CHECK(bytes == 4300);
  }
  {
    // An entry may end exactly at the partition's end.
    Flash flash = makePack(4096, 12, {{"a", 4000, 96}});
    uint32_t bytes = 0;
    CHECK(check(flash, &bytes) == nullptr);
    CHECK(bytes == 4096);
  }
  {
    // A directory longer than one read chunk (8 entries) is walked whole: a
    // bad entry in the last chunk is still found.
    std::vector<Entry> entries;
    for (int i = 0; i < 20; ++i) entries.push_back({"e", 12, 10});
    Flash good = makePack(8192, 4000, entries);
    uint32_t bytes = 0;
    CHECK(check(good, &bytes) == nullptr);
    CHECK(good.reads >= 1 + 3);
    entries.back().size = 9000;
    Flash bad = makePack(8192, 4000, entries);
    CHECK(check(bad, &bytes) != nullptr);
    CHECK(bytes == 0);
  }

  // --- what is refused ------------------------------------------------------
  {
    // Erased flash: never written with `write-data quake_pak`. The reason
    // names the command that fixes it.
    Flash flash;
    flash.bytes.assign(4096, 0xFF);
    uint32_t bytes = 7;
    const char* reason = check(flash, &bytes);
    CHECK(reason != nullptr);
    CHECK(reason != nullptr && std::strstr(reason, "write-data") != nullptr);
    CHECK(bytes == 0);
  }
  {
    Flash flash = makePack(4096, 1000, {{"a", 12, 10}});
    flash.bytes[0] = 'I';  // a WAD, say
    uint32_t bytes = 0;
    CHECK(check(flash, &bytes) != nullptr);
  }
  {
    // Directory length not a whole number of entries.
    Flash flash = makePack(4096, 1000, {{"a", 12, 10}});
    putU32(flash.bytes, 8, 65);
    uint32_t bytes = 0;
    CHECK(check(flash, &bytes) != nullptr);
  }
  {
    // Empty directory.
    Flash flash = makePack(4096, 1000, {});
    uint32_t bytes = 0;
    CHECK(check(flash, &bytes) != nullptr);
  }
  {
    // Directory overlapping the header.
    Flash flash = makePack(4096, 1000, {{"a", 12, 10}});
    putU32(flash.bytes, 4, 8);
    uint32_t bytes = 0;
    CHECK(check(flash, &bytes) != nullptr);
  }
  {
    // Directory running past the partition, including the u32 wrap case
    // (offset + length overflowing to a small number).
    Flash flash = makePack(4096, 1000, {{"a", 12, 10}});
    putU32(flash.bytes, 4, 4090);
    uint32_t bytes = 0;
    CHECK(check(flash, &bytes) != nullptr);
    putU32(flash.bytes, 4, 0xFFFFFFC0u);
    CHECK(check(flash, &bytes) != nullptr);
  }
  {
    // More entries than the engine accepts.
    Flash flash = makePack(4096, 1000, {{"a", 12, 10}});
    putU32(flash.bytes, 8, (QUAKE_PAK_MAX_ENTRIES + 1) * QUAKE_PAK_ENTRY_BYTES);
    uint32_t bytes = 0;
    CHECK(check(flash, &bytes) != nullptr);
  }
  {
    // An entry past the partition, and one whose offset + size wraps.
    Flash flash = makePack(4096, 1000, {{"a", 4000, 97}});
    uint32_t bytes = 0;
    CHECK(check(flash, &bytes) != nullptr);
    Flash wrap = makePack(4096, 1000, {{"a", 100, 0xFFFFFFF0u}});
    CHECK(check(wrap, &bytes) != nullptr);
  }
  {
    // A partition too small for even a header, and a failing flash read.
    Flash tiny;
    tiny.bytes.assign(8, 0);
    uint32_t bytes = 0;
    CHECK(check(tiny, &bytes) != nullptr);
    Flash flash = makePack(4096, 1000, {{"a", 12, 10}});
    flash.failReads = true;
    CHECK(check(flash, &bytes) != nullptr);
  }

  // --- the real shareware pak, when this checkout has it ------------------
  {
    // tools/fetch_game_data.sh --game quake puts it here; it is never
    // committed, so this case runs only where it was fetched.
    const char* path = QUAKE_TEST_PAK_PATH;
    if (FILE* f = std::fopen(path, "rb")) {
      Flash flash;
      // The quake_pak partition is 18 MiB.
      flash.bytes.assign(0x1200000, 0xFF);
      const size_t got = std::fread(flash.bytes.data(), 1, flash.bytes.size(), f);
      std::fclose(f);
      uint32_t bytes = 0;
      CHECK(check(flash, &bytes) == nullptr);
      CHECK(bytes == got);
      CHECK(bytes == 18689235u);
      std::printf("test_quake_pak: shareware pak0.pak checked (%u bytes)\n",
                  (unsigned)bytes);
    } else {
      std::printf("test_quake_pak: no local pak0.pak; shareware case skipped\n");
    }
  }

  // --- the served file --------------------------------------------------------
  CHECK(quake_pak_path_matches("/id1/pak0.pak"));
  CHECK(!quake_pak_path_matches("/id1/pak1.pak"));
  CHECK(!quake_pak_path_matches("/id1/pak0.pak2"));
  CHECK(!quake_pak_path_matches("/id1/pak0.pa"));
  CHECK(!quake_pak_path_matches("/id1/config.cfg"));
  CHECK(!quake_pak_path_matches("id1/pak0.pak"));
  CHECK(!quake_pak_path_matches(""));
  CHECK(!quake_pak_path_matches(nullptr));

  // Seeks: SEEK_SET, SEEK_CUR and SEEK_END inside the file, the very end
  // allowed, before the start or past the end refused, unknown whence refused.
  CHECK(quake_pak_seek(0, 1000, 100, 0) == 100);
  CHECK(quake_pak_seek(100, 1000, 50, 1) == 150);
  CHECK(quake_pak_seek(100, 1000, -100, 1) == 0);
  CHECK(quake_pak_seek(100, 1000, -101, 1) == -1);
  CHECK(quake_pak_seek(0, 1000, 0, 2) == 1000);
  CHECK(quake_pak_seek(0, 1000, -1, 2) == 999);
  CHECK(quake_pak_seek(0, 1000, 1, 2) == -1);
  CHECK(quake_pak_seek(0, 1000, 1001, 0) == -1);
  CHECK(quake_pak_seek(0, 1000, -1, 0) == -1);
  CHECK(quake_pak_seek(0, 1000, 0, 3) == -1);
  // Large offsets do not wrap.
  CHECK(quake_pak_seek(0xFFFFFF00u, 0xFFFFFFFFu, 0x7FFFFFFF, 1) == -1);

  // Reads return what remains, never more, and nothing at or past the end.
  CHECK(quake_pak_read_length(0, 1000, 10) == 10);
  CHECK(quake_pak_read_length(990, 1000, 100) == 10);
  CHECK(quake_pak_read_length(1000, 1000, 1) == 0);
  CHECK(quake_pak_read_length(2000, 1000, 1) == 0);
  CHECK(quake_pak_read_length(0, 1000, 0) == 0);
  CHECK(quake_pak_read_length(0, 18689235u, (size_t)0x80000000u) == 18689235u);

  if (failures != 0) {
    std::fprintf(stderr, "test_quake_pak: %d failure(s)\n", failures);
    return 1;
  }
  std::printf("test_quake_pak: OK\n");
  return 0;
}
