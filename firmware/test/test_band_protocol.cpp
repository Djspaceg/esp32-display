// Host-side unit tests for the band protocol logic. Every rule in here
// corresponds to a failure observed on real hardware/WiFi. Build and run:
//   firmware/test/run_tests.sh
#include <cassert>
#include <cstdio>
#include <utility>
#include <vector>

#include "../display_stream/band_protocol.h"
#include "../display_stream/device_protocol.h"

using namespace bandproto;

static int checks = 0;
#define CHECK(cond)                                              \
  do {                                                           \
    checks++;                                                    \
    if (!(cond)) {                                               \
      printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);     \
      return 1;                                                  \
    }                                                            \
  } while (0)

static Header hdr(uint16_t frame, uint16_t band, uint16_t dirty,
                  bool landscape = false) {
  Header h;
  h.frameId = frame;
  h.bandIndex = band;
  h.dirtyCount = dirty;
  h.landscape = landscape;
  return h;
}

int main() {
  bool dropped;

  // --- geometry: bands tile the 110,080-byte frame exactly, both ways
  CHECK(BANDS_PORTRAIT * BAND_BYTES_PORTRAIT == 110080);
  CHECK(BANDS_LANDSCAPE * BAND_BYTES_LANDSCAPE == 110080);
  CHECK(HEADER_BYTES + BAND_BYTES_PORTRAIT <= 1400);  // MTU-safe
  CHECK(HEADER_BYTES + BAND_BYTES_LANDSCAPE <= 1400);

  // --- parseHeader: little-endian fields, orientation in bit 15
  {
    const uint8_t raw[6] = {0x34, 0x12, 0x05, 0x00, 0x50, 0x80};
    Header h = parseHeader(raw);
    CHECK(h.frameId == 0x1234);
    CHECK(h.bandIndex == 5);
    CHECK(h.dirtyCount == 0x50);
    CHECK(h.landscape == true);
    const uint8_t raw2[6] = {0x00, 0x00, 0x00, 0x00, 0x50, 0x00};
    CHECK(parseHeader(raw2).landscape == false);
  }

  // --- geometry rejection
  {
    Reassembler r;
    CHECK(r.onChunk(hdr(1, 0, 0), dropped) == ChunkAction::Reject);
    CHECK(r.onChunk(hdr(1, 80, 80, false), dropped) == ChunkAction::Reject);
    CHECK(r.onChunk(hdr(1, 0, 81, false), dropped) == ChunkAction::Reject);
    // band 85 is valid in landscape (86 bands) but not portrait
    CHECK(r.onChunk(hdr(1, 85, 86, true), dropped) == ChunkAction::Apply);
    Reassembler r2;
    CHECK(r2.onChunk(hdr(1, 85, 86, false), dropped) == ChunkAction::Reject);
  }

  // --- full keyframe completes on the last band
  {
    Reassembler r;
    for (int b = 0; b < BANDS_PORTRAIT - 1; b++) {
      CHECK(r.onChunk(hdr(7, b, BANDS_PORTRAIT), dropped) == ChunkAction::Apply);
    }
    CHECK(r.onChunk(hdr(7, BANDS_PORTRAIT - 1, BANDS_PORTRAIT), dropped) ==
          ChunkAction::ApplyComplete);
  }

  // --- dirty subset: completes after dirtyCount bands, any indices
  {
    Reassembler r;
    CHECK(r.onChunk(hdr(9, 5, 3), dropped) == ChunkAction::Apply);
    CHECK(r.onChunk(hdr(9, 42, 3), dropped) == ChunkAction::Apply);
    CHECK(r.onChunk(hdr(9, 6, 3), dropped) == ChunkAction::ApplyComplete);
    CHECK(!dropped);
  }

  // --- duplicates never complete a frame early (the "frames with holes" bug)
  {
    Reassembler r;
    CHECK(r.onChunk(hdr(3, 5, 2), dropped) == ChunkAction::Apply);
    CHECK(r.onChunk(hdr(3, 5, 2), dropped) == ChunkAction::Duplicate);
    CHECK(r.onChunk(hdr(3, 5, 2), dropped) == ChunkAction::Duplicate);
    CHECK(r.onChunk(hdr(3, 6, 2), dropped) == ChunkAction::ApplyComplete);
  }

  // --- late chunks of older frames are ignored, current frame unharmed
  //     (the reassembly-thrash bug: one stale chunk used to kill two frames)
  {
    Reassembler r;
    CHECK(r.onChunk(hdr(100, 0, 2), dropped) == ChunkAction::Apply);
    CHECK(r.onChunk(hdr(99, 1, 2), dropped) == ChunkAction::IgnoreStale);
    CHECK(r.onChunk(hdr(98, 1, 80), dropped) == ChunkAction::IgnoreStale);
    CHECK(r.onChunk(hdr(100, 1, 2), dropped) == ChunkAction::ApplyComplete);
  }

  // --- a newer frame abandons a partial one and reports the drop
  {
    Reassembler r;
    CHECK(r.onChunk(hdr(10, 0, 3), dropped) == ChunkAction::Apply);
    CHECK(r.onChunk(hdr(11, 0, 2), dropped) == ChunkAction::Apply);
    CHECK(dropped);
    CHECK(r.onChunk(hdr(11, 1, 2), dropped) == ChunkAction::ApplyComplete);
    CHECK(!dropped);
  }

  // --- frame id wraparound: 0 is newer than 65535
  {
    Reassembler r;
    CHECK(r.onChunk(hdr(65535, 0, 2), dropped) == ChunkAction::Apply);
    CHECK(r.onChunk(hdr(0, 0, 2), dropped) == ChunkAction::Apply);
    CHECK(dropped);  // partial 65535 abandoned
    CHECK(r.onChunk(hdr(0, 1, 2), dropped) == ChunkAction::ApplyComplete);
  }

  // --- sender restart: persistent "stale" ids force a resync
  //     (ids reset to 0; without this the device rejects for up to 32k frames)
  {
    Reassembler r;
    CHECK(r.onChunk(hdr(30000, 0, 2), dropped) == ChunkAction::Apply);
    int ignored = 0;
    ChunkAction last = ChunkAction::Reject;
    for (int i = 0; i < 2 * MAX_BANDS + 1; i++) {
      last = r.onChunk(hdr(2, i % 40, 80), dropped);
      if (last == ChunkAction::IgnoreStale) ignored++;
    }
    CHECK(ignored == 2 * MAX_BANDS - 1);
    CHECK(last == ChunkAction::Apply);  // resynced onto frame 2
  }

  // --- orientation adopted per frame
  {
    Reassembler r;
    CHECK(r.onChunk(hdr(1, 0, 1, true), dropped) == ChunkAction::ApplyComplete);
    CHECK(r.landscape() == true);
    CHECK(r.onChunk(hdr(2, 0, 1, false), dropped) == ChunkAction::ApplyComplete);
    CHECK(r.landscape() == false);
  }

  // --- run coalescing
  {
    auto runs = [](std::initializer_list<int> setBits, int total) {
      uint8_t bits[BITMAP_BYTES] = {0};
      for (int b : setBits) bits[b >> 3] |= 1 << (b & 7);
      std::vector<std::pair<int, int>> out;
      forEachRun(bits, total, [&](int s, int e) { out.push_back({s, e}); });
      return out;
    };
    CHECK(runs({}, 80).empty());
    CHECK((runs({0}, 80) == std::vector<std::pair<int, int>>{{0, 1}}));
    CHECK((runs({3, 4, 5, 9, 79}, 80) ==
           std::vector<std::pair<int, int>>{{3, 6}, {9, 10}, {79, 80}}));
    uint8_t bits[BITMAP_BYTES];
    memset(bits, 0xFF, sizeof(bits));
    std::vector<std::pair<int, int>> out;
    forEachRun(bits, 80, [&](int s, int e) { out.push_back({s, e}); });
    CHECK((out == std::vector<std::pair<int, int>>{{0, 80}}));
  }

  // --- versioned device information and management controls
  {
    deviceproto::ControlCommand command;
    const uint8_t control[12] = {
        0x45, 0x43, 0x54, 0x4c, 0x01, 0x02, 0x34, 0x12,
        0x01, 0x00, 0x00, 0x00};
    CHECK(deviceproto::parseControl(control, sizeof(control), command));
    CHECK(command.opcode == deviceproto::ControlOpcode::Flip);
    CHECK(command.sequence == 0x1234);
    CHECK(command.value == 1);
    CHECK(!deviceproto::parseControl(control, sizeof(control) - 1, command));

    uint8_t badVersion[12];
    memcpy(badVersion, control, sizeof(control));
    badVersion[4] = 99;
    CHECK(!deviceproto::parseControl(badVersion, sizeof(badVersion), command));
    uint8_t badOpcode[12];
    memcpy(badOpcode, control, sizeof(control));
    badOpcode[5] = 99;
    CHECK(!deviceproto::parseControl(badOpcode, sizeof(badOpcode), command));
    uint8_t badValue[12];
    memcpy(badValue, control, sizeof(control));
    badValue[8] = 2;
    CHECK(!deviceproto::parseControl(badValue, sizeof(badValue), command));
  }
  {
    uint8_t info[96] = {0};
    const uint8_t id[6] = {0x02, 0x00, 0x00, 0x12, 0x34, 0x56};
    size_t infoLen = deviceproto::writeInfo(
        info, sizeof(info), 0x13, 0x3f, 0x01020304, -51, 128,
        id, "panel", "1.2.3");
    CHECK(infoLen == 37);
    const uint8_t expectedPrefix[27] = {
        0x45, 0x49, 0x4e, 0x46, 0x01, 0x02, 0x01, 0x13,
        0x3f, 0x00, 0x00, 0x00, 0x04, 0x03, 0x02, 0x01,
        0xcd, 0xff, 0x80, 0x05, 0x05,
        0x02, 0x00, 0x00, 0x12, 0x34, 0x56};
    CHECK(memcmp(info, expectedPrefix, sizeof(expectedPrefix)) == 0);
    CHECK(memcmp(info + 27, "panel1.2.3", 10) == 0);
    CHECK(deviceproto::writeInfo(
              info, 10, 0, 0, 0, 0, 0, id, "panel", "1.2.3") == 0);

    uint8_t ack[deviceproto::ACK_PACKET_BYTES] = {0};
    CHECK(deviceproto::writeAck(
              ack, deviceproto::ControlOpcode::Flip, 0x1234, 0, 0x03, 128) == 12);
    const uint8_t expectedAck[12] = {
        0x45, 0x41, 0x43, 0x4b, 0x01, 0x02, 0x34, 0x12,
        0x00, 0x03, 0x80, 0x00};
    CHECK(memcmp(ack, expectedAck, sizeof(expectedAck)) == 0);
  }

  printf("OK: %d checks passed\n", checks);
  return 0;
}
