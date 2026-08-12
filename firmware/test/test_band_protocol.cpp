// Host-side unit tests for the band protocol logic. Every rule in here
// corresponds to a failure observed on real hardware/WiFi. Build and run:
//   firmware/test/run_tests.sh
#include <cassert>
#include <cstdio>
#include <cstring>
#include <utility>
#include <vector>

#include "../display_stream/band_compress.h"
#include "../display_stream/band_protocol.h"
#include "../display_stream/chip_identity.h"
#include "../display_stream/control_queue.h"
#include "../display_stream/device_protocol.h"
#include "../display_stream/ota_policy.h"
#include "../display_stream/panel_state.h"
#include "../libraries/espdisp_board/src/board_config.h"
#include "../libraries/espdisp_board/src/panel_orientation.h"
#include "../libraries/espdisp_board/src/touch_gesture.h"
#include "../libraries/espdisp_board/src/touch_map.h"

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

  const Geometry G172 = GEOMETRY_172X320;

  // Every band starts where the previous one ended, every packet fits the
  // budget, and the bands cover the frame exactly - the invariants that make
  // "band index" and "buffer offset" interchangeable at both ends.
  auto tilesExactly = [](const Geometry &g, bool landscape) {
    size_t total = 0;
    for (uint16_t b = 0; b < g.bandCount(landscape); b++) {
      if (g.bandOffset(b, landscape) != total) return false;
      if (HEADER_BYTES + g.bandPayloadBytes(b, landscape) > MAX_PACKET_BYTES) {
        return false;
      }
      total += g.bandPayloadBytes(b, landscape);
    }
    return total == g.frameBytes();
  };

  // --- geometry: the layout derived for 172x320 is byte-identical to the
  //     historical hardcoded wire format, so shipped panels are unaffected
  CHECK(G172.valid());
  CHECK(G172.frameBytes() == 110080);
  CHECK(G172.bandCount(false) == 80);           // 80 bands...
  CHECK(G172.rowsPerBand(false) == 4);          // ...of 4 rows...
  CHECK(G172.bandPayloadBytes(0, false) == 1376);  // ...x 344B
  CHECK(G172.bandRows(79, false) == 4);  // divides evenly: no short band
  CHECK(G172.bandCount(true) == 86);
  CHECK(G172.rowsPerBand(true) == 2);
  CHECK(G172.bandPayloadBytes(0, true) == 1280);
  CHECK(G172.bandRows(85, true) == 2);
  CHECK(G172.maxBandCount() == 86);
  CHECK(tilesExactly(G172, false));
  CHECK(tilesExactly(G172, true));

  // --- geometry: the square AMOLED family (412x412, 466x466, 480x480) runs
  //     one-row bands and is orientation-symmetric
  {
    const Geometry sizes[] = {{412, 412}, {466, 466}, {480, 480}};
    for (const Geometry &g : sizes) {
      CHECK(g.valid());
      CHECK(g.rowsPerBand(false) == 1);
      CHECK(g.bandCount(false) == g.height);
      // Square: the landscape bit changes nothing on the wire.
      CHECK(g.bandCount(true) == g.bandCount(false));
      CHECK(g.rowBytes(true) == g.rowBytes(false));
      CHECK(g.maxBandCount() == g.height);
      CHECK(tilesExactly(g, false));
      CHECK(tilesExactly(g, true));
    }
    const Geometry g466 = {466, 466};
    CHECK(g466.bandPayloadBytes(0, false) == 932);
    CHECK(g466.frameBytes() == 434312);
    CHECK(g466.bandOffset(465, false) == 433380);
  }

  // --- geometry: a height that does not divide evenly gets a short last band
  {
    const Geometry g = {172, 322};  // synthetic: 4-row bands, 2-row remainder
    CHECK(g.valid());
    CHECK(g.bandCount(false) == 81);
    CHECK(g.bandRows(79, false) == 4);
    CHECK(g.bandRows(80, false) == 2);
    CHECK(g.bandPayloadBytes(80, false) == 688);
    CHECK(tilesExactly(g, false));
    CHECK(tilesExactly(g, true));
  }

  // --- geometry: what the protocol cannot carry is refused up front
  {
    CHECK(!(Geometry{0, 0}).valid());
    CHECK(!(Geometry{0, 320}).valid());
    CHECK(!(Geometry{172, 0}).valid());
    CHECK(!(Geometry{800, 800}).valid());  // a row exceeds the packet budget
    CHECK(!(Geometry{698, 100}).valid());  // 1396B row, 2 over the budget
    CHECK((Geometry{697, 100}).valid());   // 1394B row fits exactly
    CHECK(!(Geometry{400, 520}).valid());  // 520 one-row bands > MAX_BANDS

    // A reassembler handed an impossible geometry refuses every chunk
    // rather than indexing a bitmap it does not have.
    Reassembler r(Geometry{800, 800});
    CHECK(r.onChunk(hdr(1, 0, 1), dropped) == ChunkAction::Reject);
  }

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
    Reassembler r(G172);
    CHECK(r.onChunk(hdr(1, 0, 0), dropped) == ChunkAction::Reject);
    CHECK(r.onChunk(hdr(1, 80, 80, false), dropped) == ChunkAction::Reject);
    CHECK(r.onChunk(hdr(1, 0, 81, false), dropped) == ChunkAction::Reject);
    // band 85 is valid in landscape (86 bands) but not portrait
    CHECK(r.onChunk(hdr(1, 85, 86, true), dropped) == ChunkAction::Apply);
    Reassembler r2(G172);
    CHECK(r2.onChunk(hdr(1, 85, 86, false), dropped) == ChunkAction::Reject);
  }

  // --- full keyframe completes on the last band
  {
    Reassembler r(G172);
    const uint16_t bands = G172.bandCount(false);
    for (int b = 0; b < bands - 1; b++) {
      CHECK(r.onChunk(hdr(7, b, bands), dropped) == ChunkAction::Apply);
    }
    CHECK(r.onChunk(hdr(7, bands - 1, bands), dropped) ==
          ChunkAction::ApplyComplete);
  }

  // --- a 466-band AMOLED keyframe completes the same way
  {
    const Geometry g466 = {466, 466};
    Reassembler r(g466);
    const uint16_t bands = g466.bandCount(false);
    CHECK(bands == 466);
    for (int b = 0; b < bands - 1; b++) {
      CHECK(r.onChunk(hdr(21, b, bands), dropped) == ChunkAction::Apply);
    }
    CHECK(r.onChunk(hdr(21, bands - 1, bands), dropped) ==
          ChunkAction::ApplyComplete);
    // Band 466 does not exist on this panel, in either orientation.
    CHECK(r.onChunk(hdr(22, 466, 466, false), dropped) == ChunkAction::Reject);
    CHECK(r.onChunk(hdr(22, 466, 466, true), dropped) == ChunkAction::Reject);
  }

  // --- dirty subset: completes after dirtyCount bands, any indices
  {
    Reassembler r(G172);
    CHECK(r.onChunk(hdr(9, 5, 3), dropped) == ChunkAction::Apply);
    CHECK(r.onChunk(hdr(9, 42, 3), dropped) == ChunkAction::Apply);
    CHECK(r.onChunk(hdr(9, 6, 3), dropped) == ChunkAction::ApplyComplete);
    CHECK(!dropped);
  }

  // --- duplicates never complete a frame early (the "frames with holes" bug)
  {
    Reassembler r(G172);
    CHECK(r.onChunk(hdr(3, 5, 2), dropped) == ChunkAction::Apply);
    CHECK(r.onChunk(hdr(3, 5, 2), dropped) == ChunkAction::Duplicate);
    CHECK(r.onChunk(hdr(3, 5, 2), dropped) == ChunkAction::Duplicate);
    CHECK(r.onChunk(hdr(3, 6, 2), dropped) == ChunkAction::ApplyComplete);
  }

  // --- late chunks of older frames are ignored, current frame unharmed
  //     (the reassembly-thrash bug: one stale chunk used to kill two frames)
  {
    Reassembler r(G172);
    CHECK(r.onChunk(hdr(100, 0, 2), dropped) == ChunkAction::Apply);
    CHECK(r.onChunk(hdr(99, 1, 2), dropped) == ChunkAction::IgnoreStale);
    CHECK(r.onChunk(hdr(98, 1, 80), dropped) == ChunkAction::IgnoreStale);
    CHECK(r.onChunk(hdr(100, 1, 2), dropped) == ChunkAction::ApplyComplete);
  }

  // --- a newer frame abandons a partial one and reports the drop
  {
    Reassembler r(G172);
    CHECK(r.onChunk(hdr(10, 0, 3), dropped) == ChunkAction::Apply);
    CHECK(r.onChunk(hdr(11, 0, 2), dropped) == ChunkAction::Apply);
    CHECK(dropped);
    CHECK(r.onChunk(hdr(11, 1, 2), dropped) == ChunkAction::ApplyComplete);
    CHECK(!dropped);
  }

  // --- frame id wraparound: 0 is newer than 65535
  {
    Reassembler r(G172);
    CHECK(r.onChunk(hdr(65535, 0, 2), dropped) == ChunkAction::Apply);
    CHECK(r.onChunk(hdr(0, 0, 2), dropped) == ChunkAction::Apply);
    CHECK(dropped);  // partial 65535 abandoned
    CHECK(r.onChunk(hdr(0, 1, 2), dropped) == ChunkAction::ApplyComplete);
  }

  // --- sender restart: persistent "stale" ids force a resync
  //     (ids reset to 0; without this the device rejects for up to 32k frames)
  {
    Reassembler r(G172);
    CHECK(r.onChunk(hdr(30000, 0, 2), dropped) == ChunkAction::Apply);
    // The resync threshold is two frames' worth of chunks for THIS panel's
    // geometry: 172 on 172x320, exactly what the hardcoded protocol used.
    const int resync = 2 * G172.maxBandCount();
    CHECK(resync == 172);
    int ignored = 0;
    ChunkAction last = ChunkAction::Reject;
    for (int i = 0; i < resync + 1; i++) {
      last = r.onChunk(hdr(2, i % 40, 80), dropped);
      if (last == ChunkAction::IgnoreStale) ignored++;
    }
    CHECK(ignored == resync - 1);
    CHECK(last == ChunkAction::Apply);  // resynced onto frame 2
  }

  // --- orientation adopted per frame
  {
    Reassembler r(G172);
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

  // --- continuous brightness: any level 1..255, and 0 is refused because a
  //     black backlight looks like a dead panel (sleep has its own command)
  {
    deviceproto::ControlCommand command;
    uint8_t level[12] = {
        0x45, 0x43, 0x54, 0x4c, 0x01, 0x05, 0x34, 0x12,
        0x00, 0x00, 0x00, 0x00};

    for (int wanted : {1, 24, 128, 200, 255}) {
      level[8] = (uint8_t)wanted;
      CHECK(deviceproto::parseControl(level, sizeof(level), command));
      CHECK(command.opcode == deviceproto::ControlOpcode::BrightnessLevel);
      CHECK(command.value == wanted);
    }

    level[8] = 0;
    CHECK(!deviceproto::parseControl(level, sizeof(level), command));

    // 256 and above cannot fit the backlight register.
    level[8] = 0;
    level[9] = 1;
    CHECK(!deviceproto::parseControl(level, sizeof(level), command));

    // A negative value must not wrap into a plausible level.
    memset(level + 8, 0xff, 4);
    CHECK(!deviceproto::parseControl(level, sizeof(level), command));

    // Opcode 8 does not exist yet; the range check has to still reject it.
    // (Opcodes 6 and 7 were the "future" value here in turn, until Rotate
    // and then Power claimed them - their acceptance is asserted in the
    // rotation and power blocks below.)
    uint8_t future[12] = {
        0x45, 0x43, 0x54, 0x4c, 0x01, 0x08, 0x34, 0x12,
        0x01, 0x00, 0x00, 0x00};
    CHECK(!deviceproto::parseControl(future, sizeof(future), command));

    // The binary high/low command keeps its old 0-or-1 contract.
    uint8_t binary[12] = {
        0x45, 0x43, 0x54, 0x4c, 0x01, 0x01, 0x34, 0x12,
        0x01, 0x00, 0x00, 0x00};
    CHECK(deviceproto::parseControl(binary, sizeof(binary), command));
    CHECK(command.opcode == deviceproto::ControlOpcode::Brightness);
    binary[8] = 128;
    CHECK(!deviceproto::parseControl(binary, sizeof(binary), command));

    // The level capability is advertised separately, so a sender can tell a
    // panel that accepts levels from one that only accepts high/low.
    CHECK(deviceproto::CAP_BRIGHTNESS_LEVEL == 0x80u);
    CHECK((deviceproto::CAP_BRIGHTNESS & deviceproto::CAP_BRIGHTNESS_LEVEL) == 0u);
  }

  // --- quarter-turn rotation: the Rotate opcode on the wire -----------------
  {
    deviceproto::ControlCommand command;
    // Byte-for-byte: opcode 6, value 3, little-endian sequence. The Swift
    // suite asserts the same bytes from its own hand-written encoder; neither
    // side shares a fixture, so a drift fails a test instead of agreeing with
    // itself.
    uint8_t rotate[12] = {
        0x45, 0x43, 0x54, 0x4c, 0x01, 0x06, 0x34, 0x12,
        0x03, 0x00, 0x00, 0x00};
    CHECK(deviceproto::parseControl(rotate, sizeof(rotate), command));
    CHECK(command.opcode == deviceproto::ControlOpcode::Rotate);
    CHECK(command.sequence == 0x1234);
    CHECK(command.value == 3);

    // The whole representable range, and the first value beyond it. The
    // panel-shape rule (1 and 3 only on square glass) deliberately does NOT
    // live in the parser - the sketch NACKs those so a sender can tell
    // "refused" from "lost" - so the parser accepts all four everywhere.
    for (int value : {0, 1, 2, 3}) {
      rotate[8] = (uint8_t)value;
      CHECK(deviceproto::parseControl(rotate, sizeof(rotate), command));
      CHECK(command.opcode == deviceproto::ControlOpcode::Rotate);
      CHECK(command.value == value);
    }
    rotate[8] = 4;
    CHECK(!deviceproto::parseControl(rotate, sizeof(rotate), command));
    // A negative value must not wrap into a plausible rotation.
    memset(rotate + 8, 0xff, 4);
    CHECK(!deviceproto::parseControl(rotate, sizeof(rotate), command));

    // Flip keeps its old 0-or-1 contract: rotation is a NEW opcode rather
    // than widened Flip values, because old firmware rejects Flip > 1
    // silently (no ack, indistinguishable from packet loss). This build must
    // reject those values too, or the two generations would disagree about
    // what a Flip payload may hold.
    uint8_t wideFlip[12] = {
        0x45, 0x43, 0x54, 0x4c, 0x01, 0x02, 0x34, 0x12,
        0x02, 0x00, 0x00, 0x00};
    CHECK(!deviceproto::parseControl(wideFlip, sizeof(wideFlip), command));
    wideFlip[8] = 3;
    CHECK(!deviceproto::parseControl(wideFlip, sizeof(wideFlip), command));

    // The capability bit, pinned because the Swift side spells the same
    // number out by hand (DeviceProtocol.Capabilities.rotate).
    CHECK(deviceproto::CAP_ROTATE == 1u << 13);
    CHECK((deviceproto::CAP_ROTATE & deviceproto::CAP_COMPRESSED_BANDS) == 0);
    CHECK((deviceproto::CAP_ROTATE & deviceproto::CAP_FLIP) == 0);
    CHECK((deviceproto::CAP_ROTATE & deviceproto::CAP_TOUCH) == 0);

    // And the exact ack bytes a panel confirming a Rotate puts on the wire:
    // opcode 6, status 0, flags carrying rotation 3 in bits 5-6 (0x60), bit 1
    // clear (a quarter turn is not the old 180 flip), brightness-high and
    // wifi set - 0x71 in all.
    uint8_t ack[deviceproto::ACK_PACKET_BYTES] = {0};
    CHECK(deviceproto::writeAck(ack, deviceproto::ControlOpcode::Rotate,
                                0x1234, 0,
                                panelstate::deviceFlags(true, 3, false, false,
                                                        true, false),
                                128) == 12);
    const uint8_t expectedAck[12] = {
        0x45, 0x41, 0x43, 0x4b, 0x01, 0x06, 0x34, 0x12,
        0x00, 0x71, 0x80, 0x00};
    CHECK(memcmp(ack, expectedAck, sizeof(expectedAck)) == 0);
  }

  // --- Power: a standing on/off instruction, independent of ESLP/EWAK -----
  {
    uint8_t on[deviceproto::CONTROL_PACKET_BYTES] = {
        0x45, 0x43, 0x54, 0x4c, deviceproto::CONTROL_PROTOCOL_VERSION,
        (uint8_t)deviceproto::ControlOpcode::Power, 0x01, 0x00,
        0x01, 0x00, 0x00, 0x00};
    deviceproto::ControlCommand command;
    CHECK(deviceproto::parseControl(on, sizeof(on), command));
    CHECK(command.opcode == deviceproto::ControlOpcode::Power);
    CHECK(command.value == 1);

    uint8_t off[deviceproto::CONTROL_PACKET_BYTES] = {
        0x45, 0x43, 0x54, 0x4c, deviceproto::CONTROL_PROTOCOL_VERSION,
        (uint8_t)deviceproto::ControlOpcode::Power, 0x02, 0x00,
        0x00, 0x00, 0x00, 0x00};
    CHECK(deviceproto::parseControl(off, sizeof(off), command));
    CHECK(command.value == 0);

    // Only 0 and 1 are meaningful for a binary on/off - anything else is
    // refused the same way an out-of-range Rotate value is, so a sender
    // finds out rather than the panel guessing what a "2" would mean.
    uint8_t bad[deviceproto::CONTROL_PACKET_BYTES];
    memcpy(bad, on, sizeof(bad));
    bad[8] = 2;
    CHECK(!deviceproto::parseControl(bad, sizeof(bad), command));

    // Pinned for the same reason CAP_ROTATE is above: the Swift side spells
    // this number out by hand (DeviceProtocol.Capabilities.power).
    CHECK(deviceproto::CAP_POWER == 1u << 14);
    CHECK((deviceproto::CAP_POWER & deviceproto::CAP_ROTATE) == 0);
    CHECK((deviceproto::CAP_POWER & deviceproto::CAP_COMPRESSED_BANDS) == 0);

    // The ack for turning off: opcode 7, status 0, flags with bit 7 set and
    // nothing else (upright, awake, not idle, wifi up), brightness 0 because
    // the backlight sink actually went dark.
    uint8_t offAck[deviceproto::ACK_PACKET_BYTES] = {0};
    CHECK(deviceproto::writeAck(offAck, deviceproto::ControlOpcode::Power,
                                0x0002, 0,
                                panelstate::deviceFlags(false, 0, false, false,
                                                        true, true),
                                0) == 12);
    const uint8_t expectedOffAck[12] = {
        0x45, 0x41, 0x43, 0x4b, 0x01, 0x07, 0x02, 0x00,
        0x00, 0x90, 0x00, 0x00};
    CHECK(memcmp(offAck, expectedOffAck, sizeof(expectedOffAck)) == 0);
  }

  // --- idle text: what the panel shows when no sender is driving it
  {
    const char *two[2] = {"Studio", "back at 14:30"};
    uint8_t packet[deviceproto::IDLE_TEXT_MAX_BYTES];
    size_t len = deviceproto::writeIdleText(packet, sizeof(packet), two, 2);
    CHECK(len == 8 + (1 + 6) + (1 + 13));

    const uint8_t expectedHeader[8] = {0x45, 0x54, 0x58, 0x54, 0x01, 0x02, 0x00, 0x00};
    CHECK(memcmp(packet, expectedHeader, sizeof(expectedHeader)) == 0);

    deviceproto::IdleTextMessage parsed;
    CHECK(deviceproto::parseIdleText(packet, len, parsed));
    CHECK(parsed.lineCount == 2);
    CHECK(strcmp(parsed.lines[0], "Studio") == 0);
    CHECK(strcmp(parsed.lines[1], "back at 14:30") == 0);

    // Clearing is an empty push, not a special packet.
    size_t emptyLen = deviceproto::writeIdleText(packet, sizeof(packet), nullptr, 0);
    CHECK(emptyLen == 8);
    CHECK(deviceproto::parseIdleText(packet, emptyLen, parsed));
    CHECK(parsed.lineCount == 0);

    // A full-size push must fit the stated maximum exactly.
    const char *maxLine = "abcdefghijklmnopqrstuvwxyz01";
    CHECK(strlen(maxLine) == deviceproto::IDLE_TEXT_MAX_LINE_BYTES);
    const char *four[4] = {maxLine, maxLine, maxLine, maxLine};
    size_t fullLen = deviceproto::writeIdleText(packet, sizeof(packet), four, 4);
    CHECK(fullLen == deviceproto::IDLE_TEXT_MAX_BYTES);
    CHECK(deviceproto::parseIdleText(packet, fullLen, parsed));
    CHECK(parsed.lineCount == 4);
    CHECK(strcmp(parsed.lines[3], maxLine) == 0);

    // More lines than the panel has room for is refused, not truncated.
    const char *five[5] = {"a", "b", "c", "d", "e"};
    CHECK(deviceproto::writeIdleText(packet, sizeof(packet), five, 5) == 0);

    // The font is a 5x7 ASCII bitmap, so unrenderable bytes are refused at
    // both ends rather than drawn as blanks.
    const char *tab[1] = {"a\tb"};
    CHECK(deviceproto::writeIdleText(packet, sizeof(packet), tab, 1) == 0);
    const char *high[1] = {"caf\xc3\xa9"};
    CHECK(deviceproto::writeIdleText(packet, sizeof(packet), high, 1) == 0);

    // A line longer than the maximum is refused.
    const char *tooLong[1] = {"abcdefghijklmnopqrstuvwxyz012"};
    CHECK(deviceproto::writeIdleText(packet, sizeof(packet), tooLong, 1) == 0);

    // Not enough room to write means nothing is written.
    uint8_t tiny[9];
    CHECK(deviceproto::writeIdleText(tiny, sizeof(tiny), two, 2) == 0);
  }

  // --- idle text: malformed input is refused
  {
    deviceproto::IdleTextMessage parsed;
    uint8_t good[16];
    const char *one[1] = {"hello"};
    size_t len = deviceproto::writeIdleText(good, sizeof(good), one, 1);
    CHECK(len == 14);

    CHECK(!deviceproto::parseIdleText(good, 7, parsed));  // short header

    uint8_t badMagic[16];
    memcpy(badMagic, good, len);
    badMagic[0] = 'X';
    CHECK(!deviceproto::parseIdleText(badMagic, len, parsed));

    uint8_t badVersion[16];
    memcpy(badVersion, good, len);
    badVersion[4] = 99;
    CHECK(!deviceproto::parseIdleText(badVersion, len, parsed));

    uint8_t tooManyLines[16];
    memcpy(tooManyLines, good, len);
    tooManyLines[5] = 5;
    CHECK(!deviceproto::parseIdleText(tooManyLines, len, parsed));

    // A length that runs past the packet must not read out of bounds.
    uint8_t overrun[16];
    memcpy(overrun, good, len);
    overrun[8] = 250;
    CHECK(!deviceproto::parseIdleText(overrun, len, parsed));

    // Trailing bytes mean the two sides disagree about the layout.
    uint8_t trailing[17];
    memcpy(trailing, good, len);
    trailing[len] = 0x41;
    CHECK(!deviceproto::parseIdleText(trailing, len + 1, parsed));

    // A declared line the packet does not contain at all.
    uint8_t missingLine[8] = {0x45, 0x54, 0x58, 0x54, 0x01, 0x01, 0x00, 0x00};
    CHECK(!deviceproto::parseIdleText(missingLine, sizeof(missingLine), parsed));

    // Refusing must leave the caller's message untouched.
    deviceproto::IdleTextMessage keep;
    keep.lineCount = 3;
    CHECK(!deviceproto::parseIdleText(badMagic, len, keep));
    CHECK(keep.lineCount == 3);

    CHECK(deviceproto::CAP_IDLE_TEXT == 0x100u);
  }

  // --- idle text NVS round-trip: what survives a reboot ---------------------
  // The panel only holds a pushed template in RAM; these are the functions
  // that let it also land in flash, so the user's own screensaver card
  // reappears after a power cycle instead of resetting to the built-in one.
  {
    auto makeMessage = [](const char *const *lines, uint8_t count) {
      deviceproto::IdleTextMessage msg;
      memset(&msg, 0, sizeof(msg));
      msg.lineCount = count;
      for (uint8_t i = 0; i < count; i++) {
        strncpy(msg.lines[i], lines[i], deviceproto::IDLE_TEXT_MAX_LINE_BYTES);
      }
      return msg;
    };

    // Equality is what gates the NVS write: two messages the same in content
    // must compare equal however they arrived.
    {
      const char *two[2] = {"Studio", "back at 14:30"};
      const char *sameTwo[2] = {"Studio", "back at 14:30"};
      const char *different[2] = {"Studio", "back at 14:31"};
      const char *shorter[1] = {"Studio"};
      auto a = makeMessage(two, 2);
      auto b = makeMessage(sameTwo, 2);
      auto c = makeMessage(different, 2);
      auto d = makeMessage(shorter, 1);
      CHECK(deviceproto::idleTextEqual(a, b));
      CHECK(!deviceproto::idleTextEqual(a, c));
      CHECK(!deviceproto::idleTextEqual(a, d));

      // Two empty messages (the panel's own boot default) are equal, so a
      // never-configured device does not get an NVS write for "no change."
      deviceproto::IdleTextMessage empty1, empty2;
      memset(&empty1, 0, sizeof(empty1));
      memset(&empty2, 0, sizeof(empty2));
      CHECK(deviceproto::idleTextEqual(empty1, empty2));
    }

    // Round trip through the storage encoding: what a real template
    // actually looks like once flattened and rebuilt.
    {
      const char *two[2] = {"Studio", "back at 14:30"};
      auto msg = makeMessage(two, 2);
      char encoded[deviceproto::IDLE_TEXT_MAX_BYTES];
      size_t n = deviceproto::encodeIdleTextForStorage(
          msg, encoded, sizeof(encoded));
      CHECK(n == 6 + 1 + 13);  // "Studio" + '\n' + "back at 14:30"
      CHECK(strcmp(encoded, "Studio\nback at 14:30") == 0);

      auto restored = deviceproto::decodeIdleTextFromStorage(encoded);
      CHECK(deviceproto::idleTextEqual(msg, restored));
    }

    // The empty template - a cleared screensaver, or a device that has
    // never been pushed one - round-trips to zero lines, not one blank line.
    {
      deviceproto::IdleTextMessage empty;
      memset(&empty, 0, sizeof(empty));
      char encoded[deviceproto::IDLE_TEXT_MAX_BYTES];
      size_t n = deviceproto::encodeIdleTextForStorage(
          empty, encoded, sizeof(encoded));
      CHECK(n == 0);
      CHECK(encoded[0] == '\0');

      auto restored = deviceproto::decodeIdleTextFromStorage("");
      CHECK(restored.lineCount == 0);
      auto restoredFromNull = deviceproto::decodeIdleTextFromStorage(nullptr);
      CHECK(restoredFromNull.lineCount == 0);
    }

    // A single line needs no separator at all.
    {
      const char *one[1] = {"hello"};
      auto msg = makeMessage(one, 1);
      char encoded[deviceproto::IDLE_TEXT_MAX_BYTES];
      size_t n = deviceproto::encodeIdleTextForStorage(
          msg, encoded, sizeof(encoded));
      CHECK(n == 5);
      CHECK(strcmp(encoded, "hello") == 0);
      auto restored = deviceproto::decodeIdleTextFromStorage(encoded);
      CHECK(restored.lineCount == 1);
      CHECK(strcmp(restored.lines[0], "hello") == 0);
    }

    // A full-size push - four lines at the maximum line length - has to fit
    // the buffer this header advertises as the ceiling, separators included.
    {
      const char *maxLine = "abcdefghijklmnopqrstuvwxyz01";
      CHECK(strlen(maxLine) == deviceproto::IDLE_TEXT_MAX_LINE_BYTES);
      const char *four[4] = {maxLine, maxLine, maxLine, maxLine};
      auto msg = makeMessage(four, 4);
      char encoded[deviceproto::IDLE_TEXT_MAX_BYTES];
      size_t n = deviceproto::encodeIdleTextForStorage(
          msg, encoded, sizeof(encoded));
      CHECK(n > 0);
      CHECK(n < deviceproto::IDLE_TEXT_MAX_BYTES);  // room for the '\0' too

      auto restored = deviceproto::decodeIdleTextFromStorage(encoded);
      CHECK(deviceproto::idleTextEqual(msg, restored));
    }

    // Too little room to encode is refused (0), not silently truncated -
    // saveIdleTextPrefs() leaves NVS untouched rather than storing a
    // template that would decode back into something shorter than the
    // sender actually pushed.
    {
      const char *two[2] = {"Studio", "back at 14:30"};
      auto msg = makeMessage(two, 2);
      char tiny[4];
      CHECK(deviceproto::encodeIdleTextForStorage(msg, tiny, sizeof(tiny)) == 0);
    }
  }

  // --- backlight priority: sleep beats idle beats the user's level
  {
    CHECK(panelstate::backlightLevel(false, false, false, false, 128, 10) == 128);
    CHECK(panelstate::backlightLevel(false, false, true, false, 128, 10) == 10);
    CHECK(panelstate::backlightLevel(false, true, false, false, 128, 10) == 0);
    // Asleep wins even while idle: the Mac's screens being off is the
    // strongest signal there is nothing worth lighting.
    CHECK(panelstate::backlightLevel(false, true, true, false, 128, 10) == 0);
    // The user's level is honoured exactly, not rounded to high/low.
    CHECK(panelstate::backlightLevel(false, false, false, false, 1, 10) == 1);
    CHECK(panelstate::backlightLevel(false, false, false, false, 255, 10) == 255);

    // A finger outranks sleep and idle: someone touching a dark panel is
    // asking whether it is alive, and the answer has to be visible. This is
    // what lets tap-to-wake work from both the idle card and the Mac's
    // display sleep, without the panel having to contradict the Mac about
    // sleep state.
    CHECK(panelstate::backlightLevel(false, false, true, true, 128, 10) == 128);
    CHECK(panelstate::backlightLevel(false, true, false, true, 128, 10) == 128);
    CHECK(panelstate::backlightLevel(false, true, true, true, 128, 10) == 128);
    // ...and it wakes to the level the user chose, not to full blast.
    CHECK(panelstate::backlightLevel(false, true, true, true, 40, 10) == 40);

    // manuallyOff beats every one of those, including the finger. A user
    // who turned the panel off gave a standing instruction; a touch
    // answering "is this on?" would just turn it back on without asking,
    // which is not what "off" means. Swept against every other combination
    // so no future reordering of the ternary can let one slip through.
    CHECK(panelstate::backlightLevel(true, false, false, false, 128, 10) == 0);
    CHECK(panelstate::backlightLevel(true, false, false, true, 128, 10) == 0);
    CHECK(panelstate::backlightLevel(true, true, false, false, 128, 10) == 0);
    CHECK(panelstate::backlightLevel(true, false, true, false, 128, 10) == 0);
    CHECK(panelstate::backlightLevel(true, true, true, true, 128, 10) == 0);
    for (int bits = 0; bits < 8; bits++) {
      CHECK(panelstate::backlightLevel(true, (bits & 1) != 0, (bits & 2) != 0,
                                       (bits & 4) != 0, 200, 5) == 0);
    }
  }

  // --- the high/low flag is derived, so it cannot disagree with the level
  {
    CHECK(!panelstate::brightnessIsHigh(24, 24));
    CHECK(!panelstate::brightnessIsHigh(1, 24));
    CHECK(panelstate::brightnessIsHigh(25, 24));
    CHECK(panelstate::brightnessIsHigh(128, 24));
    CHECK(panelstate::brightnessIsHigh(255, 24));
  }

  // --- flags byte packing, which the sender reads back as device state
  {
    // The historical five bits, with rotation expressed as 0 (upright) or 2
    // (the old flip). These values are byte-identical to what the pre-rotation
    // firmware sent, which is what keeps old senders reading the truth.
    CHECK(panelstate::deviceFlags(false, 0, false, false, false, false) == 0x00);
    CHECK(panelstate::deviceFlags(true, 0, false, false, false, false) == 0x01);
    CHECK(panelstate::deviceFlags(false, 2, false, false, false, false) == 0x42);
    CHECK(panelstate::deviceFlags(false, 0, true, false, false, false) == 0x04);
    CHECK(panelstate::deviceFlags(false, 0, false, true, false, false) == 0x08);
    CHECK(panelstate::deviceFlags(false, 0, false, false, true, false) == 0x10);
    CHECK(panelstate::deviceFlags(true, 2, false, false, true, false) == 0x53);
    CHECK(panelstate::deviceFlags(true, 2, true, true, true, false) == 0x5F);

    // Rotation rides in bits 5-6, and bit 1 (the old flipped flag) is set
    // exactly when the rotation is the 180 - never for a quarter turn, which
    // an old sender must not be told is a flip. Swept across every rotation
    // so the consistency rule is checked as a rule, not at samples.
    for (uint8_t rotation = 0; rotation < 4; rotation++) {
      const uint8_t flags =
          panelstate::deviceFlags(false, rotation, false, false, false, false);
      CHECK(((flags >> 5) & 0x03) == rotation);
      CHECK(((flags & 0x02) != 0) == (rotation == 2));
      // Nothing but bit 1 and bits 5-6 may move with rotation.
      CHECK((flags & ~(uint8_t)0x62) == 0x00);
    }
    // The two encodings agree under every other flag combination too: bit 1
    // and bits 5-6 must be consistent whatever else is set.
    for (int bits = 0; bits < 16; bits++) {
      for (uint8_t rotation = 0; rotation < 4; rotation++) {
        const uint8_t flags = panelstate::deviceFlags(
            (bits & 1) != 0, rotation, (bits & 2) != 0, (bits & 4) != 0,
            (bits & 8) != 0, false);
        CHECK(((flags >> 5) & 0x03) == rotation);
        CHECK(((flags & 0x02) != 0) == (rotation == 2));
      }
    }
    // Spot values for the new bits, spelled as bytes like the rest of this
    // file: rotation 1 is 0x20, rotation 3 is 0x60, and neither sets bit 1.
    CHECK(panelstate::deviceFlags(false, 1, false, false, false, false) == 0x20);
    CHECK(panelstate::deviceFlags(false, 3, false, false, false, false) == 0x60);
    CHECK(panelstate::deviceFlags(true, 1, true, true, true, false) == 0x3D);
    // A rotation above 3 cannot leak into other bits.
    CHECK(panelstate::deviceFlags(false, (uint8_t)7, false, false, false, false) ==
          panelstate::deviceFlags(false, 3, false, false, false, false));

    // manuallyOff is bit 7, independent of every other bit including
    // rotation and the historical flipped flag - a manually-off panel that
    // is also rotated must report both facts at once.
    CHECK(panelstate::deviceFlags(false, 0, false, false, false, true) == 0x80);
    CHECK(panelstate::deviceFlags(true, 2, true, true, true, true) == 0xDF);
    CHECK(panelstate::deviceFlags(false, 3, false, false, false, true) == 0xE0);
    for (int bits = 0; bits < 16; bits++) {
      for (uint8_t rotation = 0; rotation < 4; rotation++) {
        const uint8_t withoutOff = panelstate::deviceFlags(
            (bits & 1) != 0, rotation, (bits & 2) != 0, (bits & 4) != 0,
            (bits & 8) != 0, false);
        const uint8_t withOff = panelstate::deviceFlags(
            (bits & 1) != 0, rotation, (bits & 2) != 0, (bits & 4) != 0,
            (bits & 8) != 0, true);
        // Setting manuallyOff must flip bit 7 and touch nothing else.
        CHECK(withOff == (uint8_t)(withoutOff | 0x80));
      }
    }
  }

  // --- idle card battery line: shown only for a board with a PMU and a
  //     reading that has not aged out
  {
    CHECK(!panelstate::shouldShowBatteryLine(false, false));
    CHECK(!panelstate::shouldShowBatteryLine(false, true));  // no PMU: never
    CHECK(!panelstate::shouldShowBatteryLine(true, false));  // stale reading
    CHECK(panelstate::shouldShowBatteryLine(true, true));
  }

  // --- the quarter-turn quadrant behind MADCTL and touch --------------------
  // panel_init.h cannot be host-tested (it needs the esp_lcd headers), so the
  // arithmetic it drives MADCTL with lives in panel_orientation.h and is
  // pinned here instead. The table below is the historical applyOrientation
  // matrix copied out BY HAND - portrait MADCTL 0, landscape MV|MX, flipped
  // MX|MY, landscape-flipped MV|MY - so the generalisation to four rotations
  // has to reproduce the shipped four states byte-for-byte or fail here.
  {
    using panelorient::mirrorX;
    using panelorient::mirrorY;
    using panelorient::quadrant;
    using panelorient::swapXY;

    struct Legacy {
      bool landscape, flip180;      // the old inputs
      bool swap, mx, my;            // what shipped firmware set MADCTL to
    };
    const Legacy legacy[] = {
        {false, false, false, false, false},  // portrait: MADCTL 0
        {true, false, true, true, false},     // landscape: MV|MX
        {false, true, false, true, true},     // flipped: MX|MY
        {true, true, true, false, true},      // landscape flipped: MV|MY
    };
    for (const Legacy &l : legacy) {
      const uint8_t q = quadrant(l.flip180 ? 2 : 0, l.landscape);
      CHECK(swapXY(q) == l.swap);
      CHECK(mirrorX(q) == l.mx);
      CHECK(mirrorY(q) == l.my);
    }

    // The composition rule itself: rotation and landscape add, modulo 4.
    for (uint8_t rotation = 0; rotation < 4; rotation++) {
      CHECK(quadrant(rotation, false) == rotation);
      CHECK(quadrant(rotation, true) == ((rotation + 1) & 3));
    }
    // A rotation that was never masked upstream still lands in range.
    CHECK(quadrant(6, false) == 2);
    CHECK(quadrant(7, true) == 0);

    // Each quadrant's MADCTL triple, spelled out so no two quadrants can
    // collapse together: q odd swaps, mx on 1 and 2, my on 2 and 3.
    CHECK(!swapXY(0) && !mirrorX(0) && !mirrorY(0));
    CHECK(swapXY(1) && mirrorX(1) && !mirrorY(1));
    CHECK(!swapXY(2) && mirrorX(2) && mirrorY(2));
    CHECK(swapXY(3) && !mirrorX(3) && mirrorY(3));
    // All four triples are distinct - a swapped pair of rows above would
    // otherwise still pass the per-row checks.
    for (uint8_t a = 0; a < 4; a++) {
      for (uint8_t b = (uint8_t)(a + 1); b < 4; b++) {
        CHECK(swapXY(a) != swapXY(b) || mirrorX(a) != mirrorX(b) ||
              mirrorY(a) != mirrorY(b));
      }
    }
    // Two more quarter turns are a point reflection: the mirror bits both
    // toggle and the axis swap holds still. This is the arithmetic fact that
    // makes "rotation 2 == the old flip" true by construction.
    for (uint8_t q = 0; q < 4; q++) {
      const uint8_t r = (uint8_t)((q + 2) & 3);
      CHECK(swapXY(r) == swapXY(q));
      CHECK(mirrorX(r) == !mirrorX(q));
      CHECK(mirrorY(r) == !mirrorY(q));
    }
  }

  // --- control admission: the sender repeats every command three times, so
  //     de-duplication decides whether a brightness change is applied once or
  //     three times, and when a lost acknowledgement is replayed
  {
    auto make = [](uint16_t sequence, int32_t value) {
      deviceproto::ControlCommand command;
      command.opcode = deviceproto::ControlOpcode::Brightness;
      command.sequence = sequence;
      command.value = value;
      return command;
    };

    controlq::ControlQueue queue;
    CHECK(queue.pending() == 0);

    // First arrival is queued; its repeats are dropped rather than applied
    // again, and must NOT be acknowledged yet because nothing has happened.
    CHECK(queue.offer(make(1, 1)) == controlq::Admission::Enqueued);
    CHECK(queue.pending() == 1);
    CHECK(queue.offer(make(1, 1)) == controlq::Admission::Dropped);
    CHECK(queue.offer(make(1, 1)) == controlq::Admission::Dropped);
    CHECK(queue.pending() == 1);
    CHECK(!queue.hasDuplicateAck());

    // The loop applies it.
    deviceproto::ControlCommand taken;
    CHECK(queue.take(taken));
    CHECK(taken.sequence == 1);
    CHECK(queue.pending() == 0);
    CHECK(!queue.take(taken));  // nothing left
    queue.markApplied(1);

    // Now a late repeat is worth acknowledging again: the sender may not have
    // received the first acknowledgement.
    CHECK(queue.offer(make(1, 1)) == controlq::Admission::ReplayAck);
    CHECK(queue.pending() == 0);  // not re-applied
    deviceproto::ControlCommand replay;
    CHECK(queue.takeDuplicateAck(replay));
    CHECK(replay.sequence == 1);
    CHECK(!queue.takeDuplicateAck(replay));  // consumed

    // A different sequence is a different command even with the same value.
    CHECK(queue.offer(make(2, 1)) == controlq::Admission::Enqueued);
  }

  // --- control queue: a full queue drops rather than overwriting
  {
    auto make = [](uint16_t sequence) {
      deviceproto::ControlCommand command;
      command.opcode = deviceproto::ControlOpcode::Identify;
      command.sequence = sequence;
      command.value = 5;
      return command;
    };

    controlq::ControlQueue queue;
    for (uint16_t i = 0; i < controlq::QUEUE_CAPACITY; i++) {
      CHECK(queue.offer(make((uint16_t)(100 + i))) == controlq::Admission::Enqueued);
    }
    CHECK(queue.pending() == controlq::QUEUE_CAPACITY);

    // Overflow is dropped, and must not corrupt what is already queued.
    CHECK(queue.offer(make(200)) == controlq::Admission::Dropped);
    CHECK(queue.pending() == controlq::QUEUE_CAPACITY);

    // Everything queued comes back in order.
    for (uint16_t i = 0; i < controlq::QUEUE_CAPACITY; i++) {
      deviceproto::ControlCommand taken;
      CHECK(queue.take(taken));
      CHECK(taken.sequence == (uint16_t)(100 + i));
    }
    CHECK(queue.pending() == 0);

    // The ring wraps: after draining, new commands are accepted again.
    CHECK(queue.offer(make(300)) == controlq::Admission::Enqueued);
  }

  // --- control queue: the ring forgets, so a sequence reused much later is
  //     treated as new rather than silently ignored
  {
    auto make = [](uint16_t sequence) {
      deviceproto::ControlCommand command;
      command.opcode = deviceproto::ControlOpcode::Flip;
      command.sequence = sequence;
      command.value = 1;
      return command;
    };

    controlq::ControlQueue queue;
    CHECK(queue.offer(make(7)) == controlq::Admission::Enqueued);
    deviceproto::ControlCommand taken;
    CHECK(queue.take(taken));
    queue.markApplied(7);
    CHECK(queue.offer(make(7)) == controlq::Admission::ReplayAck);
    CHECK(queue.takeDuplicateAck(taken));

    // Push capacity-many other sequences through both rings.
    for (uint16_t i = 0; i < controlq::QUEUE_CAPACITY; i++) {
      CHECK(queue.offer(make((uint16_t)(500 + i))) == controlq::Admission::Enqueued);
      CHECK(queue.take(taken));
      queue.markApplied((uint16_t)(500 + i));
    }

    // 7 has aged out of both rings, so it is accepted again. This is correct:
    // the sender picks a random starting sequence and wraps, so refusing
    // forever would eventually wedge a control.
    CHECK(queue.offer(make(7)) == controlq::Admission::Enqueued);
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

  // --- board variant detection: one binary, two boards ---------------------
  {
    using board::Variant;

    // The discriminator: the Touch board carries an AXS5106L touch controller
    // and a QMI8658A IMU on the shared I2C bus (observed at 0x63 and 0x6B);
    // the non-touch board has nothing there.
    CHECK(board::variantFromI2cProbe(true, 2) == Variant::TouchJd9853);
    CHECK(board::variantFromI2cProbe(true, 1) == Variant::TouchJd9853);
    CHECK(board::variantFromI2cProbe(true, 0) == Variant::LcdSt7789);

    // Fail toward Touch. A probe that could not run says nothing about which
    // board this is, and the two wrong answers are not equally cheap: calling a
    // Touch board "non-touch" drives GPIO8 as a LED output, and GPIO8 is that
    // board's BOOT button switched to ground.
    CHECK(board::variantFromI2cProbe(false, 0) == Variant::TouchJd9853);
    CHECK(board::variantFromI2cProbe(false, 5) == Variant::TouchJd9853);
    CHECK(board::resolve(Variant::Unknown) == Variant::TouchJd9853);
    CHECK(board::configFor(Variant::Unknown).driver == board::PanelDriver::Jd9853);

    // ...but resolve() must never disturb a verdict we do have.
    CHECK(board::resolve(Variant::LcdSt7789) == Variant::LcdSt7789);
    CHECK(board::resolve(Variant::TouchJd9853) == Variant::TouchJd9853);

    const board::Config &st = board::configFor(Variant::LcdSt7789);
    const board::Config &jd = board::configFor(Variant::TouchJd9853);
    CHECK(st.variant == Variant::LcdSt7789);
    CHECK(jd.variant == Variant::TouchJd9853);
    CHECK(st.driver == board::PanelDriver::St7789);
    CHECK(jd.driver == board::PanelDriver::Jd9853);

    // Pin tables, asserted so a copy-paste between rows cannot pass silently.
    CHECK(st.pinSclk == 7 && st.pinMosi == 6 && st.pinRst == 21 && st.pinBl == 22);
    CHECK(jd.pinSclk == 1 && jd.pinMosi == 2 && jd.pinRst == 22 && jd.pinBl == 23);
    // CS and DC are the only panel pins the two boards agree on.
    CHECK(st.pinCs == jd.pinCs && st.pinCs == 14);
    CHECK(st.pinDc == jd.pinDc && st.pinDc == 15);
    // Every other panel pin must actually differ, or the table is wrong.
    CHECK(st.pinSclk != jd.pinSclk);
    CHECK(st.pinMosi != jd.pinMosi);
    CHECK(st.pinRst != jd.pinRst);
    CHECK(st.pinBl != jd.pinBl);

    // Only the non-touch board has an addressable LED, so nothing may drive
    // GPIO8 on the Touch board - its function there is undocumented and it is
    // measurably not the button.
    CHECK(st.hasRgbLed() && st.pinRgbLed == 8);
    CHECK(!jd.hasRgbLed() && jd.pinRgbLed == board::NO_PIN);

    // The BOOT button is GPIO9 on BOTH boards. Waveshare's pinout table claims
    // GPIO8 for the Touch board; that is wrong, and trusting it shipped a
    // firmware whose button did nothing on that variant. Measured by holding
    // both pins INPUT_PULLUP and watching which moves: GPIO9 every press, GPIO8
    // never. This assertion exists so the table cannot quietly regress to the
    // documented-but-false value.
    CHECK(st.pinBootButton == 9);
    CHECK(jd.pinBootButton == 9);
    CHECK(jd.pinBootButton != 8);

    // No board may drive a LED on a pin it also reads as a button.
    CHECK(st.pinRgbLed != st.pinBootButton);
    CHECK(jd.pinRgbLed != jd.pinBootButton);

    // Touch is gated to the board that has it, and its interrupt pin is the
    // other board's panel reset - which is why it must never be enabled blind.
    CHECK(!st.hasTouch() && st.pinTouchRst == board::NO_PIN &&
          st.pinTouchInt == board::NO_PIN);
    CHECK(jd.hasTouch() && jd.pinTouchRst == 20 && jd.pinTouchInt == 21);
    CHECK(jd.pinTouchInt == st.pinRst);
    // Detection runs before the variant is known, so its hardcoded touch-reset
    // pin has to agree with the table it cannot yet read.
    CHECK(board::PIN_PROBE_TP_RST == jd.pinTouchRst);

    // The old firmware's backlight pin is the new board's reset line: proof
    // that reusing the ST7789 table on a Touch board would PWM LCD_RST.
    CHECK(st.pinBl == jd.pinRst);

    // Panel geometry is shared, which is exactly why the Mac side, the band
    // protocol, and the buffer sizing need no board awareness.
    CHECK(st.colOffset == 34 && jd.colOffset == 34);
    CHECK(st.invertColor && jd.invertColor);

    // The stored CFGBOARD override: round-trips, and an unrecognised byte falls
    // back to auto-detection rather than pinning the board to a value this
    // firmware cannot interpret. Note only an explicit override is persisted -
    // an auto-detected verdict deliberately is not cached, so a one-off bad
    // probe cannot become permanent.
    CHECK(board::variantFromStored((uint8_t)Variant::LcdSt7789) == Variant::LcdSt7789);
    CHECK(board::variantFromStored((uint8_t)Variant::TouchJd9853) == Variant::TouchJd9853);
    CHECK(board::variantFromStored(0) == Variant::Unknown);
    CHECK(board::variantFromStored(99) == Variant::Unknown);

    // CFGBOARD override tokens, including the empty and null cases.
    CHECK(board::variantFromName("st7789") == Variant::LcdSt7789);
    CHECK(board::variantFromName("jd9853") == Variant::TouchJd9853);
    CHECK(board::variantFromName("auto") == Variant::Unknown);
    CHECK(board::variantFromName("") == Variant::Unknown);
    CHECK(board::variantFromName(nullptr) == Variant::Unknown);
    CHECK(board::variantFromName("st") == Variant::Unknown);  // prefixes are not tokens

    // Tokens round-trip through the parser, so CFGSHOW output can be fed back
    // into CFGBOARD verbatim.
    CHECK(board::variantFromName(board::variantToken(Variant::LcdSt7789)) ==
          Variant::LcdSt7789);
    CHECK(board::variantFromName(board::variantToken(Variant::TouchJd9853)) ==
          Variant::TouchJd9853);
    CHECK(board::variantFromName(board::variantToken(Variant::AmoledCo5300)) ==
          Variant::AmoledCo5300);
    CHECK(strcmp(board::variantToken(Variant::Unknown), "auto") == 0);

    // Host tests compile without an IDF target, which is the C6 path: the
    // variant is Unknown until the boot probe says otherwise.
    CHECK(board::COMPILED_VARIANT == Variant::Unknown);

    // The C6 boards on the new per-board fields: single-lane SPI with a D/C
    // line and a PWM backlight, 172x320, 80MHz - the pre-AMOLED world exactly.
    for (const board::Config *c : {&st, &jd}) {
      CHECK(c->bus == board::PanelBus::Spi);
      CHECK(!c->isQspi());
      CHECK(c->panelW == 172 && c->panelH == 320);
      CHECK(c->pclkHz == 80 * 1000 * 1000);
      CHECK(c->pinData1 == board::NO_PIN && c->pinData2 == board::NO_PIN &&
            c->pinData3 == board::NO_PIN);
      CHECK(c->pinDc != board::NO_PIN);
      CHECK(c->hasBacklightPin());
    }
    CHECK(st.touch == board::TouchController::None);
    CHECK(st.pinTouchSda == board::NO_PIN && st.pinTouchScl == board::NO_PIN);
    CHECK(jd.touch == board::TouchController::Axs5106l);
    // Neither C6 board has a PMU: they run off USB with no cell and no gauge,
    // so neither may advertise a battery.
    for (const board::Config *c : {&st, &jd}) {
      CHECK(c->power == board::PowerController::None);
      CHECK(!c->hasBattery());
    }
    // Touch rides the shared detection bus on the C6 Touch board.
    CHECK(jd.pinTouchSda == board::PIN_PROBE_SDA);
    CHECK(jd.pinTouchScl == board::PIN_PROBE_SCL);
  }

  // --- the S3 AMOLED board entry -------------------------------------------
  {
    using board::Variant;
    const board::Config &am = board::configFor(Variant::AmoledCo5300);

    CHECK(am.variant == Variant::AmoledCo5300);
    CHECK(am.driver == board::PanelDriver::Co5300);
    CHECK(am.bus == board::PanelBus::Qspi);
    CHECK(am.isQspi());

    // Waveshare's pin_config.h for the 1.75C, asserted pin by pin so a
    // copy-paste between rows cannot pass silently.
    CHECK(am.pinSclk == 38);
    CHECK(am.pinMosi == 4);  // SDIO0
    CHECK(am.pinData1 == 5 && am.pinData2 == 6 && am.pinData3 == 7);
    CHECK(am.pinCs == 12);
    CHECK(am.pinRst == 2);

    // QSPI has no D/C line and an AMOLED has no backlight: both absences are
    // what panel_init keys its bring-up and brightness paths on.
    CHECK(am.pinDc == board::NO_PIN);
    CHECK(!am.hasBacklightPin());

    CHECK(am.panelW == 466 && am.panelH == 466);
    CHECK(am.pclkHz == 40 * 1000 * 1000);
    CHECK(am.colOffset == 6);
    CHECK(!am.invertColor);
    CHECK(!am.hasRgbLed());

    // Round glass: the idle card must keep inside the inscribed square. The
    // C6 panels are rectangular and keep their full-frame placement.
    CHECK(am.roundDisplay);
    CHECK(!board::configFor(Variant::LcdSt7789).roundDisplay);
    CHECK(!board::configFor(Variant::TouchJd9853).roundDisplay);

    // CST9217 on its own I2C bus; reset shared with the panel, so touch
    // bring-up must never pulse it independently.
    CHECK(am.touch == board::TouchController::Cst9217);
    CHECK(am.hasTouch());
    CHECK(am.pinTouchSda == 15 && am.pinTouchScl == 14);
    CHECK(am.pinTouchInt == 11);
    CHECK(am.pinTouchRst == am.pinRst);

    // AXP2101 PMU: the only board here with a battery. It has no pins of its
    // own - it shares the touch I2C bus, which is why hasBattery() tests those
    // pins too, and why the reader must not go looking for a PMU reset line.
    CHECK(am.power == board::PowerController::Axp2101);
    CHECK(am.hasBattery());
    CHECK(am.pinTouchSda != board::NO_PIN && am.pinTouchScl != board::NO_PIN);
    CHECK(!board::configFor(Variant::LcdSt7789).hasBattery());
    CHECK(!board::configFor(Variant::TouchJd9853).hasBattery());

    // The panel dimensions in the table produce a carryable band geometry -
    // the link between the board table and the wire format.
    const Geometry g = {am.panelW, am.panelH};
    CHECK(g.valid());
    CHECK(g.bandCount(false) == 466);
    CHECK(g.maxBandCount() <= MAX_BANDS);

    // Round-trips for the new variant: NVS byte, CFGBOARD token.
    CHECK(board::variantFromStored((uint8_t)Variant::AmoledCo5300) ==
          Variant::AmoledCo5300);
    CHECK(board::variantFromName("co5300") == Variant::AmoledCo5300);
    CHECK(strcmp(board::variantToken(Variant::AmoledCo5300), "co5300") == 0);

    // resolve() never lands on the S3 board from Unknown: an inconclusive C6
    // probe must fall back to a C6 board, and the S3 build never probes.
    CHECK(board::resolve(Variant::Unknown) != Variant::AmoledCo5300);
    CHECK(board::resolve(Variant::AmoledCo5300) == Variant::AmoledCo5300);
  }

  // --- touch coordinate mapping --------------------------------------------
  // Touch has to go through the same orientation transform the pixels do, or
  // taps land somewhere other than where they were aimed. These assert the
  // mapping's internal consistency; which way round the panel's axes actually
  // run is a hardware fact, checked with the touch mode of display_test.
  {
    using touchmap::Point;
    const int16_t SHORT = touchmap::PANEL_SHORT;  // 172
    const int16_t LONG = touchmap::PANEL_LONG;    // 320

    CHECK(SHORT == 172 && LONG == 320);
    CHECK(touchmap::frameWidth(false) == SHORT);
    CHECK(touchmap::frameHeight(false) == LONG);
    CHECK(touchmap::frameWidth(true) == LONG);
    CHECK(touchmap::frameHeight(true) == SHORT);

    // Step 1 in isolation: the controller's X runs opposite the panel's.
    CHECK(touchmap::rawToGlass(0, 0).x == SHORT - 1);
    CHECK(touchmap::rawToGlass(SHORT - 1, 0).x == 0);
    CHECK(touchmap::rawToGlass(0, 17).y == 17);  // Y passes through untouched

    // Portrait: every corner lands in the corresponding framebuffer corner.
    // Raw (SHORT-1, 0) is the display's top-left once the X mirror is undone.
    CHECK(touchmap::map(SHORT - 1, 0, false, 0).x == 0);
    CHECK(touchmap::map(SHORT - 1, 0, false, 0).y == 0);
    CHECK(touchmap::map(0, LONG - 1, false, 0).x == SHORT - 1);
    CHECK(touchmap::map(0, LONG - 1, false, 0).y == LONG - 1);

    // Rotation 2 (the old 180 flip) is a point reflection, so the same finger
    // position must map to the opposite corner.
    CHECK(touchmap::map(SHORT - 1, 0, false, 2).x == SHORT - 1);
    CHECK(touchmap::map(SHORT - 1, 0, false, 2).y == LONG - 1);
    CHECK(touchmap::map(0, LONG - 1, false, 2).x == 0);
    CHECK(touchmap::map(0, LONG - 1, false, 2).y == 0);

    // Landscape swaps the axes: the long panel axis becomes framebuffer X, so a
    // touch at one end of it must land at a framebuffer X extreme, never beyond.
    CHECK(touchmap::map(SHORT - 1, 0, true, 0).x == 0);
    CHECK(touchmap::map(SHORT - 1, LONG - 1, true, 0).x == LONG - 1);

    // A quarter turn in portrait IS the landscape transform - the quadrant
    // composes as rotation + landscape, so the display's portrait top-left
    // corner must land exactly where landscape puts it (clockwise: the
    // landscape frame's bottom-left).
    CHECK(touchmap::map(SHORT - 1, 0, false, 1).x == 0);
    CHECK(touchmap::map(SHORT - 1, 0, false, 1).y == SHORT - 1);
    CHECK(touchmap::map(SHORT - 1, LONG - 1, false, 1).x == LONG - 1);
    // ...and rotation 3 is its point reflection through the landscape frame.
    CHECK(touchmap::map(SHORT - 1, 0, false, 3).x == LONG - 1);
    CHECK(touchmap::map(SHORT - 1, 0, false, 3).y == 0);
    CHECK(touchmap::map(0, LONG - 1, false, 3).x == 0);
    CHECK(touchmap::map(0, LONG - 1, false, 3).y == SHORT - 1);

    // Whether the frame is landscape-shaped follows the total quadrant, and
    // collapses to the landscape flag whenever the rotation is 0 or 2 - which
    // is every rectangular panel, quarter turns being square-only.
    for (uint8_t rotation = 0; rotation < 4; rotation++) {
      CHECK(touchmap::swapsAxes(false, rotation) == ((rotation & 1) != 0));
      // Landscape adds one quarter turn, so it toggles the parity.
      CHECK(touchmap::swapsAxes(true, rotation) == ((rotation & 1) == 0));
    }
    CHECK(touchmap::swapsAxes(false, 0) == false);
    CHECK(touchmap::swapsAxes(false, 2) == false);
    CHECK(touchmap::swapsAxes(true, 0) == true);
    CHECK(touchmap::swapsAxes(true, 2) == true);
    CHECK(touchmap::swapsAxes(false, 1) == true);
    CHECK(touchmap::swapsAxes(false, 3) == true);
    CHECK(touchmap::swapsAxes(true, 1) == false);
    CHECK(touchmap::swapsAxes(true, 3) == false);

    // Structural properties that must hold in every orientation, checked over
    // the whole coordinate space rather than at hand-picked points, and now
    // over all four rotations in both landscape states rather than only the
    // two the old flip could reach. A transform that is wrong by one
    // reflection still satisfies these, which is why the corner assertions
    // above exist too - but an off-by-one or a swapped axis that overruns the
    // framebuffer does not.
    for (int16_t ry = 0; ry < LONG; ry += 7) {
      for (int16_t rx = 0; rx < SHORT; rx += 5) {
        for (int orientation = 0; orientation < 8; orientation++) {
          const bool landscape = (orientation & 1) != 0;
          const uint8_t rotation = (uint8_t)(orientation >> 1);
          const bool swapped = touchmap::swapsAxes(landscape, rotation);
          Point p = touchmap::map(rx, ry, landscape, rotation);
          // In range, always - bounded by the quadrant's frame shape.
          CHECK(p.x >= 0 && p.x < touchmap::frameWidth(swapped));
          CHECK(p.y >= 0 && p.y < touchmap::frameHeight(swapped));
          // Two more quarter turns are the old flip involution: the rotated
          // point is the original reflected through the centre, whatever
          // rotation it started from.
          Point q = touchmap::map(rx, ry, landscape,
                                  (uint8_t)((rotation + 2) & 3));
          CHECK(q.x == touchmap::frameWidth(swapped) - 1 - p.x);
          CHECK(q.y == touchmap::frameHeight(swapped) - 1 - p.y);
          // The composition rule itself: a quarter turn in portrait is the
          // landscape transform, i.e. only the TOTAL quadrant matters. This
          // is the property that keeps touch agreeing with MADCTL, which is
          // driven by the same quadrant().
          Point viaLandscape =
              touchmap::map(rx, ry, true, rotation);
          Point viaRotation =
              touchmap::map(rx, ry, false, (uint8_t)((rotation + 1) & 3));
          CHECK(viaLandscape.x == viaRotation.x);
          CHECK(viaLandscape.y == viaRotation.y);
        }
      }
    }

    // The mapping must be injective within an orientation, or two different
    // finger positions would be indistinguishable after transform. Checked
    // for each rotation, since a constant transform would pass the range
    // checks above.
    for (uint8_t rotation = 0; rotation < 4; rotation++) {
      const bool swapped = touchmap::swapsAxes(false, rotation);
      // A raw X step must move exactly one framebuffer axis; a raw Y step
      // the other.
      Point a = touchmap::map(10, 20, false, rotation);
      Point bx = touchmap::map(11, 20, false, rotation);
      Point by = touchmap::map(10, 21, false, rotation);
      if (swapped) {
        CHECK(a.y != bx.y && a.x == bx.x);
        CHECK(a.x != by.x && a.y == by.y);
      } else {
        CHECK(a.x != bx.x && a.y == bx.y);
        CHECK(a.y != by.y && a.x == by.x);
      }
    }
    CHECK(touchmap::map(10, 20, true, 0).y != touchmap::map(11, 20, true, 0).y);
    CHECK(touchmap::map(10, 20, true, 0).x != touchmap::map(10, 21, true, 0).x);

    // Clamping: controllers report just outside the active area near the bezel,
    // and an unclamped point would index past the framebuffer.
    CHECK(touchmap::clampToFrame({-5, -5}, false).x == 0);
    CHECK(touchmap::clampToFrame({-5, -5}, false).y == 0);
    CHECK(touchmap::clampToFrame({9999, 9999}, false).x == SHORT - 1);
    CHECK(touchmap::clampToFrame({9999, 9999}, false).y == LONG - 1);
    CHECK(touchmap::clampToFrame({9999, 9999}, true).x == LONG - 1);
    CHECK(touchmap::clampToFrame({9999, 9999}, true).y == SHORT - 1);
    // A point already inside is left exactly alone.
    CHECK(touchmap::clampToFrame({7, 9}, false).x == 7);
    CHECK(touchmap::clampToFrame({7, 9}, false).y == 9);
    // map() clamps, so even a wildly out-of-range report stays addressable.
    CHECK(touchmap::map(9999, 9999, false, 0).x >= 0);
    CHECK(touchmap::map(9999, 9999, false, 0).y <= LONG - 1);
    // Including under a quarter turn, whose frame shape is the swapped one.
    CHECK(touchmap::map(9999, 9999, false, 1).x <= LONG - 1);
    CHECK(touchmap::map(9999, 9999, false, 1).y <= SHORT - 1);
    CHECK(touchmap::map(-9999, -9999, false, 3).x >= 0);
    CHECK(touchmap::map(-9999, -9999, false, 3).y >= 0);
  }

  // --- touch coordinate mapping: CO5300/CST9217 (square, 466x466) ----------
  // The 1.75C's calibration differs from the C6's default in both axis facts
  // (rawXMirrored is false, not true - see touch_map.h's STATUS note) and in
  // being square, which collapses several of the C6 sweep's distinctions:
  // frameWidth/frameHeight no longer differ by orientation, and every
  // quadrant has the same frame shape. What still has to hold is the same
  // structural contract - in range, the rotate-by-2 involution, and the
  // portrait-quarter-turn == landscape composition rule - now exercised
  // against a Calibration explicitly, since this is the first calibration
  // that is not the default.
  {
    using touchmap::Point;
    const touchmap::Calibration cal = touchmap::CST9217_ON_CO5300;
    const int16_t SIDE = cal.panelShort;
    CHECK(SIDE == 466 && cal.panelLong == 466);
    CHECK(!cal.rawXMirrored);
    CHECK(cal.rotateClockwise);

    // Square glass: landscape and portrait share one frame shape.
    CHECK(touchmap::frameWidth(false, cal) == SIDE);
    CHECK(touchmap::frameHeight(false, cal) == SIDE);
    CHECK(touchmap::frameWidth(true, cal) == SIDE);
    CHECK(touchmap::frameHeight(true, cal) == SIDE);

    // Step 1 in isolation: unlike the C6, the raw X passes through unmirrored.
    CHECK(touchmap::rawToGlass(0, 0, cal).x == 0);
    CHECK(touchmap::rawToGlass(SIDE - 1, 0, cal).x == SIDE - 1);
    CHECK(touchmap::rawToGlass(0, 17, cal).y == 17);

    // Portrait upright: raw passes straight through to the frame.
    CHECK(touchmap::map(10, 20, false, 0, cal).x == 10);
    CHECK(touchmap::map(10, 20, false, 0, cal).y == 20);

    // Rotation 2 (180) is a point reflection, exactly as on the C6.
    CHECK(touchmap::map(10, 20, false, 2, cal).x == SIDE - 1 - 10);
    CHECK(touchmap::map(10, 20, false, 2, cal).y == SIDE - 1 - 20);

    // Structural properties that must hold in every orientation, with this
    // Calibration threaded through instead of the default.
    for (uint8_t orientation = 0; orientation < 8; orientation++) {
      const bool landscape = (orientation & 1) != 0;
      const uint8_t rotation = (uint8_t)(orientation >> 1);
      const bool swapped = touchmap::swapsAxes(landscape, rotation);
      for (int16_t rx = 0; rx < SIDE; rx += 37) {
        for (int16_t ry = 0; ry < SIDE; ry += 41) {
          Point p = touchmap::map(rx, ry, landscape, rotation, cal);
          CHECK(p.x >= 0 && p.x < touchmap::frameWidth(swapped, cal));
          CHECK(p.y >= 0 && p.y < touchmap::frameHeight(swapped, cal));

          // Two more quarter turns is the reflection-through-centre
          // involution, same as the C6.
          Point q = touchmap::map(rx, ry, landscape,
                                  (uint8_t)((rotation + 2) & 3), cal);
          CHECK(q.x == touchmap::frameWidth(swapped, cal) - 1 - p.x);
          CHECK(q.y == touchmap::frameHeight(swapped, cal) - 1 - p.y);

          // A portrait quarter turn is the landscape transform - only the
          // total quadrant matters.
          Point viaLandscape = touchmap::map(rx, ry, true, rotation, cal);
          Point viaRotation =
              touchmap::map(rx, ry, false, (uint8_t)((rotation + 1) & 3), cal);
          CHECK(viaLandscape.x == viaRotation.x);
          CHECK(viaLandscape.y == viaRotation.y);
        }
      }
    }

    // Clamping still holds under this Calibration's dimensions.
    CHECK(touchmap::clampToFrame({-5, -5}, false, cal).x == 0);
    CHECK(touchmap::clampToFrame({9999, 9999}, false, cal).x == SIDE - 1);
    CHECK(touchmap::clampToFrame({9999, 9999}, false, cal).y == SIDE - 1);

    // Passing no Calibration at all must still mean the C6's - the default
    // argument is what lets every existing call site ignore this parameter.
    CHECK(touchmap::map(touchmap::PANEL_SHORT - 1, 0, false, 0).x == 0);
  }

  // --- touch gestures ------------------------------------------------------
  // Gesture timing is close to impossible to check by hand on a device and
  // trivial to check here, which is the whole reason the classifier takes a
  // caller-supplied timestamp instead of calling millis() itself.
  {
    using touchgesture::Gesture;
    using touchgesture::Tracker;

    // A quick press that barely moves is a tap.
    {
      Tracker t;
      auto down = t.onReport(true, 50, 60, 1000);
      CHECK(down.pressStarted);
      CHECK(down.gesture == Gesture::None);  // not known until release
      CHECK(down.startX == 50 && down.startY == 60);
      CHECK(t.pressActive());
      auto up = t.onReport(false, 0, 0, 1100);
      CHECK(up.gesture == Gesture::Tap);
      CHECK(!up.pressStarted);
      CHECK(up.startX == 50 && up.startY == 60);  // reports where it began
      CHECK(!t.pressActive());
    }

    // Only the first report of a press sets pressStarted, or a caller reacting
    // to touch-down would fire repeatedly while the finger sat still.
    {
      Tracker t;
      CHECK(t.onReport(true, 10, 10, 0).pressStarted);
      CHECK(!t.onReport(true, 11, 10, 20).pressStarted);
      CHECK(!t.onReport(true, 12, 10, 40).pressStarted);
    }

    // Held too long to be a tap, but not far enough to be a swipe: None. A
    // resting finger must not fire whatever a tap is wired to.
    {
      Tracker held;
      held.onReport(true, 50, 60, 0);
      CHECK(held.onReport(false, 0, 0, touchgesture::TAP_MAX_MS + 1).gesture ==
            Gesture::None);
      // Right at the boundary it is still a tap.
      Tracker boundary;
      boundary.onReport(true, 50, 60, 0);
      CHECK(boundary.onReport(false, 0, 0, touchgesture::TAP_MAX_MS).gesture ==
            Gesture::Tap);
    }

    // All four directions, in framebuffer terms, so they mean what the user saw.
    {
      const int16_t far = touchgesture::SWIPE_MIN_PX + 5;
      struct {
        int16_t dx, dy;
        Gesture want;
      } cases[] = {
          {(int16_t)-far, 0, Gesture::SwipeLeft},
          {far, 0, Gesture::SwipeRight},
          {0, (int16_t)-far, Gesture::SwipeUp},
          {0, far, Gesture::SwipeDown},
      };
      for (auto &c : cases) {
        Tracker t;
        t.onReport(true, 100, 100, 0);
        t.onReport(true, (int16_t)(100 + c.dx), (int16_t)(100 + c.dy), 50);
        CHECK(t.onReport(false, 0, 0, 100).gesture == c.want);
      }
    }

    // The dominant axis decides, so a sloppy diagonal still resolves.
    {
      Tracker t;
      t.onReport(true, 100, 100, 0);
      t.onReport(true, (int16_t)(100 + touchgesture::SWIPE_MIN_PX + 10),
                 (int16_t)(100 + touchgesture::SWIPE_MIN_PX - 5), 50);
      CHECK(t.onReport(false, 0, 0, 100).gesture == Gesture::SwipeRight);
    }

    // Distance decides a swipe, not speed: a slow drag is still a swipe, or the
    // gesture would depend on how fast the user happened to move.
    {
      Tracker t;
      t.onReport(true, 100, 100, 0);
      t.onReport(true, (int16_t)(100 + touchgesture::SWIPE_MIN_PX), 100, 3000);
      CHECK(t.onReport(false, 0, 0, 4000).gesture == Gesture::SwipeRight);
    }

    // The dead band between "tap" and "swipe" resolves to nothing, rather than
    // guessing between two actions on an ambiguous smudge.
    {
      Tracker t;
      t.onReport(true, 100, 100, 0);
      t.onReport(true, (int16_t)(100 + touchgesture::TAP_MAX_MOVE_PX + 1), 100,
                 20);
      CHECK(t.onReport(false, 0, 0, 40).gesture == Gesture::None);
    }

    // A release with no press is ignored, not classified.
    {
      Tracker t;
      auto e = t.onReport(false, 0, 0, 500);
      CHECK(e.gesture == Gesture::None);
      CHECK(!e.pressStarted);
    }

    // A press left open by a dropped release report is abandoned, so the next
    // real touch is a fresh press rather than a continuation of a stale one.
    {
      Tracker t;
      t.onReport(true, 10, 10, 0);
      auto later = t.onReport(true, 200, 200, touchgesture::PRESS_MAX_MS + 1);
      CHECK(later.pressStarted);
      CHECK(later.startX == 200 && later.startY == 200);
    }

    // reset() drops an in-flight press.
    {
      Tracker t;
      t.onReport(true, 10, 10, 0);
      CHECK(t.pressActive());
      t.reset();
      CHECK(!t.pressActive());
      CHECK(t.onReport(false, 0, 0, 50).gesture == Gesture::None);
    }

    // --- Long press --------------------------------------------------------
    //
    // The one gesture that fires while the finger is still down, which is why it
    // comes from tick() rather than from a release. Reports arrive only on
    // controller interrupts, so a still finger produces none and the tick is the
    // only thing that can notice the threshold passing.

    // Held past the threshold and barely moved: fires from the tick, with the
    // finger still down.
    {
      Tracker t;
      t.onReport(true, 80, 90, 0);
      CHECK(t.tick(touchgesture::LONG_PRESS_MS - 1).gesture == Gesture::None);
      auto held = t.tick(touchgesture::LONG_PRESS_MS);
      CHECK(held.gesture == Gesture::LongPress);
      CHECK(held.startX == 80 && held.startY == 90);
      CHECK(t.pressActive());  // still down: this is not a release
    }

    // Fires once. Ticking every loop would otherwise repeat it forever, and a
    // gesture bound to it would run tens of times per hold.
    {
      Tracker t;
      t.onReport(true, 80, 90, 0);
      CHECK(t.tick(touchgesture::LONG_PRESS_MS).gesture == Gesture::LongPress);
      CHECK(t.tick(touchgesture::LONG_PRESS_MS + 1).gesture == Gesture::None);
      CHECK(t.tick(touchgesture::LONG_PRESS_MS + 5000).gesture == Gesture::None);
    }

    // The release after a long press reports nothing: the press is spent, and
    // classifying it as well would send a second gesture for one finger.
    {
      Tracker t;
      t.onReport(true, 80, 90, 0);
      CHECK(t.tick(touchgesture::LONG_PRESS_MS).gesture == Gesture::LongPress);
      CHECK(t.onReport(false, 0, 0, touchgesture::LONG_PRESS_MS + 100).gesture ==
            Gesture::None);
    }

    // A finger that wandered beyond tap slop is on its way to a swipe, so it is
    // not a hold however long it rests there. Without this, dragging slowly
    // would fire a long press mid-swipe and then the swipe would be swallowed.
    {
      Tracker t;
      t.onReport(true, 100, 100, 0);
      t.onReport(true, (int16_t)(100 + touchgesture::TAP_MAX_MOVE_PX + 1), 100, 10);
      CHECK(t.tick(touchgesture::LONG_PRESS_MS + 100).gesture == Gesture::None);
      // And the swipe it becomes still arrives.
      t.onReport(true, (int16_t)(100 + touchgesture::SWIPE_MIN_PX), 100, 200);
      CHECK(t.onReport(false, 0, 0, 300).gesture == Gesture::SwipeRight);
    }

    // Ticking with no press does nothing, so the tick is safe to call every loop.
    {
      Tracker t;
      CHECK(t.tick(999999).gesture == Gesture::None);
    }

    // A tap is still a tap: the thresholds do not overlap, so a quick press
    // cannot be caught by the hold path on its way past.
    {
      Tracker t;
      t.onReport(true, 50, 50, 0);
      CHECK(t.tick(touchgesture::TAP_MAX_MS).gesture == Gesture::None);
      CHECK(t.onReport(false, 0, 0, touchgesture::TAP_MAX_MS).gesture ==
            Gesture::Tap);
    }
    CHECK(touchgesture::LONG_PRESS_MS > touchgesture::TAP_MAX_MS);

    // An abandoned press does not leave the fired flag set, or the first hold
    // after one would be swallowed.
    {
      Tracker t;
      t.onReport(true, 10, 10, 0);
      t.tick(touchgesture::LONG_PRESS_MS);
      t.onReport(true, 10, 10, touchgesture::PRESS_MAX_MS + 1);  // fresh press
      CHECK(t.tick(touchgesture::PRESS_MAX_MS + 1 + touchgesture::LONG_PRESS_MS)
                .gesture == Gesture::LongPress);
    }

    // reset() clears it too, so a re-init mid-hold cannot strand the flag.
    {
      Tracker t;
      t.onReport(true, 10, 10, 0);
      t.tick(touchgesture::LONG_PRESS_MS);
      t.reset();
      t.onReport(true, 10, 10, 0);
      CHECK(t.tick(touchgesture::LONG_PRESS_MS).gesture == Gesture::LongPress);
    }

    CHECK(strcmp(touchgesture::gestureName(Gesture::Tap), "tap") == 0);
    CHECK(strcmp(touchgesture::gestureName(Gesture::SwipeLeft), "swipe-left") == 0);
    CHECK(strcmp(touchgesture::gestureName(Gesture::None), "none") == 0);
    CHECK(strcmp(touchgesture::gestureName(Gesture::LongPress), "long-press") == 0);
  }

  // --- ETCH touch events on the wire ---------------------------------------
  {
    uint8_t packet[deviceproto::TOUCH_PACKET_BYTES] = {0};
    CHECK(deviceproto::writeTouch(packet, deviceproto::TouchGesture::SwipeLeft,
                                  0x1234, 300, 150,
                                  deviceproto::TOUCH_FLAG_LANDSCAPE) == 14);
    const uint8_t expected[14] = {0x45, 0x54, 0x43, 0x48, 0x01, 0x02, 0x34, 0x12,
                                  0x2c, 0x01, 0x96, 0x00, 0x01, 0x00};
    CHECK(memcmp(packet, expected, sizeof(expected)) == 0);

    deviceproto::TouchEvent parsed;
    CHECK(deviceproto::parseTouch(packet, sizeof(packet), parsed));
    CHECK(parsed.gesture == deviceproto::TouchGesture::SwipeLeft);
    CHECK(parsed.sequence == 0x1234);
    CHECK(parsed.x == 300);
    CHECK(parsed.y == 150);
    CHECK((parsed.flags & deviceproto::TOUCH_FLAG_LANDSCAPE) != 0);

    // Round-trip every gesture, so no value is unrepresentable on the wire.
    for (uint8_t raw = (uint8_t)deviceproto::TouchGesture::Tap;
         raw <= (uint8_t)deviceproto::TouchGesture::LongPress; raw++) {
      uint8_t buf[deviceproto::TOUCH_PACKET_BYTES] = {0};
      deviceproto::writeTouch(buf, (deviceproto::TouchGesture)raw, raw, 1, 2, 0);
      deviceproto::TouchEvent got;
      CHECK(deviceproto::parseTouch(buf, sizeof(buf), got));
      CHECK((uint8_t)got.gesture == raw);
      CHECK(got.sequence == raw);
      CHECK(got.flags == 0);
    }

    // Malformed input is refused rather than half-accepted.
    deviceproto::TouchEvent ignored;
    CHECK(!deviceproto::parseTouch(packet, sizeof(packet) - 1, ignored));
    uint8_t badMagic[deviceproto::TOUCH_PACKET_BYTES];
    memcpy(badMagic, packet, sizeof(badMagic));
    badMagic[0] = 'X';
    CHECK(!deviceproto::parseTouch(badMagic, sizeof(badMagic), ignored));
    uint8_t badVersion[deviceproto::TOUCH_PACKET_BYTES];
    memcpy(badVersion, packet, sizeof(badVersion));
    badVersion[4] = 99;
    CHECK(!deviceproto::parseTouch(badVersion, sizeof(badVersion), ignored));
    // Gesture 0 and anything past the last one are not gestures.
    uint8_t badGesture[deviceproto::TOUCH_PACKET_BYTES];
    memcpy(badGesture, packet, sizeof(badGesture));
    badGesture[5] = 0;
    CHECK(!deviceproto::parseTouch(badGesture, sizeof(badGesture), ignored));
    badGesture[5] = (uint8_t)deviceproto::TouchGesture::LongPress + 1;
    CHECK(!deviceproto::parseTouch(badGesture, sizeof(badGesture), ignored));

    // CAP_TOUCH must not collide with an existing capability bit.
    CHECK(deviceproto::CAP_TOUCH == 1u << 9);
    CHECK((deviceproto::CAP_TOUCH & deviceproto::CAP_IDLE_TEXT) == 0);
    CHECK((deviceproto::CAP_TOUCH & deviceproto::CAP_BRIGHTNESS_LEVEL) == 0);
  }

  // --- EBAT battery reports on the wire ------------------------------------
  {
    uint8_t packet[deviceproto::BATTERY_PACKET_BYTES] = {0};
    const uint8_t flags = deviceproto::BATTERY_FLAG_PRESENT |
                          deviceproto::BATTERY_FLAG_EXTERNAL_POWER;
    CHECK(deviceproto::writeBattery(packet, flags, 87,
                                    deviceproto::ChargeState::Charging,
                                    4012) == 12);
    // 4012mV is 0x0FAC, little-endian, and the last two bytes are reserved.
    const uint8_t expected[12] = {0x45, 0x42, 0x41, 0x54, 0x01, 0x03,
                                  0x57, 0x01, 0xac, 0x0f, 0x00, 0x00};
    CHECK(memcmp(packet, expected, sizeof(expected)) == 0);

    deviceproto::BatteryStatus parsed;
    CHECK(deviceproto::parseBattery(packet, sizeof(packet), parsed));
    CHECK(parsed.present);
    CHECK(parsed.externalPower);
    CHECK(parsed.percent == 87);
    CHECK(parsed.state == deviceproto::ChargeState::Charging);
    CHECK(parsed.millivolts == 4012);

    // No battery attached, gauge with no opinion: the 0xFF sentinel survives
    // the round trip rather than arriving as a plausible level.
    uint8_t unknown[deviceproto::BATTERY_PACKET_BYTES] = {0};
    CHECK(deviceproto::writeBattery(unknown, 0,
                                    deviceproto::BATTERY_PERCENT_UNKNOWN,
                                    deviceproto::ChargeState::Unknown, 0) == 12);
    const uint8_t expectedUnknown[12] = {0x45, 0x42, 0x41, 0x54, 0x01, 0x00,
                                         0xff, 0x00, 0x00, 0x00, 0x00, 0x00};
    CHECK(memcmp(unknown, expectedUnknown, sizeof(expectedUnknown)) == 0);
    CHECK(deviceproto::parseBattery(unknown, sizeof(unknown), parsed));
    CHECK(!parsed.present);
    CHECK(!parsed.externalPower);
    CHECK(parsed.percent == deviceproto::BATTERY_PERCENT_UNKNOWN);
    CHECK(parsed.state == deviceproto::ChargeState::Unknown);
    CHECK(parsed.millivolts == 0);

    // Every charge state is representable, so none of them has to be faked.
    for (uint8_t raw = (uint8_t)deviceproto::ChargeState::Unknown;
         raw <= (uint8_t)deviceproto::ChargeState::Standby; raw++) {
      uint8_t buf[deviceproto::BATTERY_PACKET_BYTES] = {0};
      deviceproto::writeBattery(buf, deviceproto::BATTERY_FLAG_PRESENT, raw,
                                (deviceproto::ChargeState)raw, 3700);
      deviceproto::BatteryStatus got;
      CHECK(deviceproto::parseBattery(buf, sizeof(buf), got));
      CHECK((uint8_t)got.state == raw);
      CHECK(got.percent == raw);
      CHECK(got.millivolts == 3700);
      CHECK(got.present);
      CHECK(!got.externalPower);
    }

    // Percent boundaries: 100 is full, 101 is not a percentage.
    deviceproto::BatteryStatus ignored;
    uint8_t percent[deviceproto::BATTERY_PACKET_BYTES];
    memcpy(percent, packet, sizeof(percent));
    percent[6] = 100;
    CHECK(deviceproto::parseBattery(percent, sizeof(percent), ignored));
    percent[6] = 101;
    CHECK(!deviceproto::parseBattery(percent, sizeof(percent), ignored));
    percent[6] = 254;
    CHECK(!deviceproto::parseBattery(percent, sizeof(percent), ignored));

    // Malformed input is refused rather than half-accepted.
    uint8_t badMagic[deviceproto::BATTERY_PACKET_BYTES];
    memcpy(badMagic, packet, sizeof(badMagic));
    badMagic[0] = 'X';
    CHECK(!deviceproto::parseBattery(badMagic, sizeof(badMagic), ignored));
    uint8_t badVersion[deviceproto::BATTERY_PACKET_BYTES];
    memcpy(badVersion, packet, sizeof(badVersion));
    badVersion[4] = 99;
    CHECK(!deviceproto::parseBattery(badVersion, sizeof(badVersion), ignored));
    // State 4 does not exist; an unknown state is refused rather than guessed.
    uint8_t badState[deviceproto::BATTERY_PACKET_BYTES];
    memcpy(badState, packet, sizeof(badState));
    badState[7] = (uint8_t)deviceproto::ChargeState::Standby + 1;
    CHECK(!deviceproto::parseBattery(badState, sizeof(badState), ignored));
    // Short, and one byte too long - the fixed length is the trailing-byte test.
    CHECK(!deviceproto::parseBattery(packet, sizeof(packet) - 1, ignored));
    uint8_t trailing[deviceproto::BATTERY_PACKET_BYTES + 1] = {0};
    memcpy(trailing, packet, sizeof(packet));
    CHECK(!deviceproto::parseBattery(trailing, sizeof(trailing), ignored));

    // The reserved bytes are ignored on purpose, so a later firmware can put
    // something there without this parser refusing every packet.
    uint8_t reserved[deviceproto::BATTERY_PACKET_BYTES];
    memcpy(reserved, packet, sizeof(reserved));
    reserved[10] = 0x5A;
    reserved[11] = 0xA5;
    CHECK(deviceproto::parseBattery(reserved, sizeof(reserved), ignored));
    CHECK(ignored.percent == 87);

    // No other parser may claim an EBAT packet: the sender tells inbound
    // datagrams apart by trial-parsing, so whichever ran first would swallow it.
    deviceproto::ControlCommand notAControl;
    deviceproto::TouchEvent notATouch;
    deviceproto::IdleTextMessage notIdleText;
    CHECK(!deviceproto::parseControl(packet, sizeof(packet), notAControl));
    CHECK(!deviceproto::parseTouch(packet, sizeof(packet), notATouch));
    CHECK(!deviceproto::parseIdleText(packet, sizeof(packet), notIdleText));

    // CAP_BATTERY must not collide with an existing capability bit.
    CHECK(deviceproto::CAP_BATTERY == 1u << 11);
    CHECK((deviceproto::CAP_BATTERY & deviceproto::CAP_TOUCH) == 0);
    CHECK((deviceproto::CAP_BATTERY & deviceproto::CAP_TOUCH_LONGPRESS) == 0);
    CHECK((deviceproto::CAP_BATTERY & deviceproto::CAP_TELEMETRY) == 0);
  }

  // --- a reading has an age ceiling, on both sides ---------------------------
  //
  // A failed sample deliberately leaves the previous reading standing, which
  // beats reporting zeros, but nothing aged it out: a PMU that answered once at
  // boot and then died kept its percentage on the 5s serial line, in CFGSHOW's
  // bat= and in the sender's row indefinitely. Those are the three places whose
  // whole purpose is to tell the truth about the cell.
  {
    // Four missed samples at the 10s poll. The Swift side spells the same number
    // out by hand (DeviceProtocol.batteryMaxAge = 45 seconds) so both sides call
    // a reading stale at the same moment; a panel and a manager disagreeing about
    // that would be worse than either rule alone.
    CHECK(deviceproto::BATTERY_MAX_AGE_MS == 45000);

    // Fresh, and the boundary either side of it. Inclusive at the ceiling, so a
    // single transient I2C failure or one dropped datagram cannot blank a row.
    CHECK(deviceproto::batteryReadingCurrent(1000, 1000));
    CHECK(deviceproto::batteryReadingCurrent(1000 + 44999, 1000));
    CHECK(deviceproto::batteryReadingCurrent(1000 + 45000, 1000));
    CHECK(!deviceproto::batteryReadingCurrent(1000 + 45001, 1000));
    CHECK(!deviceproto::batteryReadingCurrent(1000 + 3600000, 1000));

    // Swept across the boundary rather than sampled at it.
    for (uint32_t age = 0; age <= 90000; age += 250) {
      CHECK(deviceproto::batteryReadingCurrent(500000 + age, 500000) ==
            (age <= deviceproto::BATTERY_MAX_AGE_MS));
    }

    // millis() wraps after ~49 days. Unsigned arithmetic gives the right small
    // difference across the wrap; the wrong answer would be to declare a reading
    // taken seconds ago stale for the next 49 days.
    const uint32_t justBeforeWrap = 0xFFFFFF00u;
    CHECK(deviceproto::batteryReadingCurrent(justBeforeWrap + 1000,
                                             justBeforeWrap));
    CHECK(deviceproto::batteryReadingCurrent(0x00000100u, justBeforeWrap));
    CHECK(!deviceproto::batteryReadingCurrent(0x0000C000u, justBeforeWrap));

    // A reading taken at time zero is not treated as ancient by a panel that has
    // only just booted: the first sample lands within the first seconds of
    // uptime, and it must be reportable.
    CHECK(deviceproto::batteryReadingCurrent(0, 0));
    CHECK(deviceproto::batteryReadingCurrent(10000, 0));
  }

  {
    // CAP_OTA was reserved when this protocol was written and is only now in
    // use. Its value is pinned here because the Swift side spells the same
    // number out by hand (DeviceProtocol.Capabilities.ota), and a panel that
    // shifted the bit would silently advertise something else entirely.
    CHECK(deviceproto::CAP_OTA == 1u << 4);
    CHECK((deviceproto::CAP_OTA & deviceproto::CAP_RESTART) == 0);
    CHECK((deviceproto::CAP_OTA & deviceproto::CAP_SLEEP_SYNC) == 0);
    CHECK((deviceproto::CAP_OTA & deviceproto::CAP_BATTERY) == 0);

    // It is a runtime capability, not one every panel has: a panel with no OTA
    // password does not listen, so the bit must be absent from any set of
    // always-present capabilities. Written as the same composition the firmware
    // uses for BASE_CAPABILITIES so the two cannot quietly disagree.
    const uint32_t base = deviceproto::CAP_BRIGHTNESS |
                          deviceproto::CAP_BRIGHTNESS_LEVEL |
                          deviceproto::CAP_FLIP | deviceproto::CAP_IDENTIFY |
                          deviceproto::CAP_RESTART |
                          deviceproto::CAP_SLEEP_SYNC |
                          deviceproto::CAP_TELEMETRY |
                          deviceproto::CAP_IDLE_TEXT;
    CHECK((base & deviceproto::CAP_OTA) == 0);
    CHECK((base & deviceproto::CAP_TOUCH) == 0);
    CHECK((base & deviceproto::CAP_BATTERY) == 0);

    // And the exact bytes an OTA-capable panel puts on the wire. The capability
    // field is a u32 LE at offset 8, so a panel advertising everything a board
    // always has plus OTA sends 0x000001FF there. Spelled out as bytes for the
    // same reason the rest of this file does: the Swift side reads them back
    // from an independent implementation.
    CHECK(base == 0x1EFu);
    uint8_t packet[deviceproto::INFO_PREFIX_BYTES + 8];
    const uint8_t id[6] = {0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF};
    const size_t written =
        deviceproto::writeInfo(packet, sizeof(packet), 0,
                               base | deviceproto::CAP_OTA, 1234, -55, 128, id,
                               "p", "1.2.0");
    CHECK(written == deviceproto::INFO_PREFIX_BYTES + 6);
    CHECK(packet[8] == 0xFF);
    CHECK(packet[9] == 0x01);
    CHECK(packet[10] == 0x00);
    CHECK(packet[11] == 0x00);
  }

  // --- CFGOTAPW argument: the off switch must never be read as a password
  {
    CHECK(otapolicy::classifyArgument("clear") == otapolicy::Argument::Clear);

    // Exact match only. Every one of these is a password payload, not the off
    // switch, because a panel that turned OTA off when the user fat-fingered
    // the case would be worse than one that refused the line.
    CHECK(otapolicy::classifyArgument("Clear") == otapolicy::Argument::Payload);
    CHECK(otapolicy::classifyArgument("CLEAR") == otapolicy::Argument::Payload);
    CHECK(otapolicy::classifyArgument("clear ") == otapolicy::Argument::Payload);
    CHECK(otapolicy::classifyArgument(" clear") == otapolicy::Argument::Payload);
    CHECK(otapolicy::classifyArgument("clearclear") ==
          otapolicy::Argument::Payload);
    CHECK(otapolicy::classifyArgument("clea") == otapolicy::Argument::Payload);
    CHECK(otapolicy::classifyArgument("") == otapolicy::Argument::Payload);

    // A realistic base64 password is a payload, including one that happens to
    // contain the token.
    CHECK(otapolicy::classifyArgument("cGFzc3dvcmQxMjM=") ==
          otapolicy::Argument::Payload);
    CHECK(otapolicy::classifyArgument("Y2xlYXI=") ==
          otapolicy::Argument::Payload);

    // Nothing to classify is not the off switch either: clearing a password is
    // destructive enough that it should need to be asked for.
    CHECK(otapolicy::classifyArgument(nullptr) == otapolicy::Argument::Payload);

    // The sketch used to justify the token by claiming five characters can
    // never be valid base64. That is a claim about decoders, not about the
    // string: every character of "clear" is in the base64 alphabet, so a
    // decoder lenient about padding could well decode it. Pinned here so the
    // reasoning cannot quietly come back.
    auto inBase64Alphabet = [](char c) {
      return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
             (c >= '0' && c <= '9') || c == '+' || c == '/' || c == '=';
    };
    for (const char *c = otapolicy::CLEAR_TOKEN; *c; c++) {
      CHECK(inBase64Alphabet(*c));
    }

    // What saves it is the ordering - the literal is decided before any decode.
    // And even if that ever broke, five base64 characters carry at most 30 bits,
    // so no reading of them reaches the floor; the token would be refused as a
    // password rather than accepted as one.
    const unsigned char five[] = {'c', 'l', 'e', 'a', 'r'};
    CHECK(otapolicy::verifyPassword(true, five, 3) ==
          otapolicy::Verdict::TooShort);
    CHECK(otapolicy::verifyPassword(true, five, 4) ==
          otapolicy::Verdict::TooShort);
  }

  // --- a decoded password with a 0x00 in it must be refused, not stored
  //
  // The floor below is judged on the decoded bytes, but everything underneath
  // stores and uses the password as a C string: Preferences::putString ->
  // nvs_set_str keeps up to the terminator, ArduinoOTA::setPassword hashes a
  // const char *, and espota passes it in argv. So an accepted password with an
  // embedded 0x00 would be stored truncated and the floor would stop describing
  // the secret the panel listens with. Refusing it is the only outcome that
  // keeps the floor's promise.
  {
    // A full-length password whose fourth byte is zero: exactly what
    // `CFGOTAPW $(head -c 16 /dev/urandom | base64)` produces about 6% of the
    // time, and the case the floor alone does not catch - 16 bytes is
    // comfortably inside the accept window, so only the NUL check refuses it.
    const unsigned char withNul[16] = {'s', 'e', 'c', 0,   'r', 'e', 't', '!',
                                       'p', 'a', 's', 's', 'w', 'o', 'r', 'd'};
    CHECK(otapolicy::verifyPassword(true, withNul, sizeof(withNul)) ==
          otapolicy::Verdict::EmbeddedNul);
    // What would have been stored instead, had it been accepted: 3 bytes, which
    // the floor exists to forbid. Asserted so the reason the refusal matters is
    // pinned next to the refusal itself.
    CHECK(strlen((const char *)withNul) == 3);
    CHECK(otapolicy::verifyPassword(true, withNul,
                                    strlen((const char *)withNul)) ==
          otapolicy::Verdict::TooShort);

    // Every position matters, not just the middle: leading, trailing, and each
    // interior byte. A trailing 0x00 truncates to a 15-byte password, which the
    // floor would happily accept while the user believes they set 16 bytes.
    for (size_t at = 0; at < sizeof(withNul); at++) {
      unsigned char probe[sizeof(withNul)];
      memcpy(probe, "0123456789abcdef", sizeof(probe));
      probe[at] = 0;
      CHECK(otapolicy::verifyPassword(true, probe, sizeof(probe)) ==
            otapolicy::Verdict::EmbeddedNul);
    }

    // The ordinary path is untouched: no zero byte, still judged on length
    // alone, and the accepted set is still exactly the closed interval.
    const unsigned char clean[64] = {
        'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm',
        'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
        'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
        'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
        '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '+', '/'};
    CHECK(otapolicy::verifyPassword(true, clean, 7) ==
          otapolicy::Verdict::TooShort);
    CHECK(otapolicy::verifyPassword(true, clean, 8) ==
          otapolicy::Verdict::Accept);
    CHECK(otapolicy::verifyPassword(true, clean, 64) ==
          otapolicy::Verdict::Accept);

    // High bytes are not the problem and must not be treated as one - the whole
    // reason the argument is base64 is that a password may be arbitrary bytes.
    const unsigned char highBytes[8] = {0x80, 0xFF, 0x01, 0x7F,
                                        0xC3, 0xA9, 0x20, 0x0A};
    CHECK(otapolicy::verifyPassword(true, highBytes, sizeof(highBytes)) ==
          otapolicy::Verdict::Accept);

    // A failed decode still outranks everything, whatever the buffer holds.
    CHECK(otapolicy::verifyPassword(false, withNul, sizeof(withNul)) ==
          otapolicy::Verdict::NotBase64);
    // And no bytes to inspect while claiming a length is not talked into an
    // accept: it is a decode this cannot vouch for.
    CHECK(otapolicy::verifyPassword(true, nullptr, 16) ==
          otapolicy::Verdict::NotBase64);
    CHECK(otapolicy::verifyPassword(true, nullptr, 0) ==
          otapolicy::Verdict::TooShort);
  }

  // --- the 8-byte floor, which is the only thing between the LAN and a
  //     firmware write, and the ceiling above it
  {
    CHECK(otapolicy::PASSWORD_MIN_BYTES == 8);
    CHECK(otapolicy::PASSWORD_MAX_BYTES == 64);

    // 200 non-zero bytes, so the length under test is the only thing varying.
    unsigned char buf[200];
    for (size_t i = 0; i < sizeof(buf); i++) {
      buf[i] = (unsigned char)(1 + (i % 255));
      CHECK(buf[i] != 0);
    }

    // A failed decode is refused as such, whatever length came back with it. A
    // decoder may or may not write an out-length when it returns an error, so
    // the verdict deliberately does not depend on that: no accompanying length
    // can talk a failure into an accept.
    CHECK(otapolicy::verifyPassword(false, buf, 0) ==
          otapolicy::Verdict::NotBase64);
    CHECK(otapolicy::verifyPassword(false, buf, 8) ==
          otapolicy::Verdict::NotBase64);
    CHECK(otapolicy::verifyPassword(false, buf, 32) ==
          otapolicy::Verdict::NotBase64);

    // The boundary, both sides of it. 7 bytes is refused, 8 is accepted.
    CHECK(otapolicy::verifyPassword(true, buf, 0) ==
          otapolicy::Verdict::TooShort);
    CHECK(otapolicy::verifyPassword(true, buf, 1) ==
          otapolicy::Verdict::TooShort);
    CHECK(otapolicy::verifyPassword(true, buf, 7) ==
          otapolicy::Verdict::TooShort);
    CHECK(otapolicy::verifyPassword(true, buf, 8) == otapolicy::Verdict::Accept);
    CHECK(otapolicy::verifyPassword(true, buf, 9) == otapolicy::Verdict::Accept);

    // And the other boundary: 64 accepted, 65 refused.
    CHECK(otapolicy::verifyPassword(true, buf, 63) ==
          otapolicy::Verdict::Accept);
    CHECK(otapolicy::verifyPassword(true, buf, 64) ==
          otapolicy::Verdict::Accept);
    CHECK(otapolicy::verifyPassword(true, buf, 65) ==
          otapolicy::Verdict::TooLong);
    CHECK(otapolicy::verifyPassword(true, buf, 185) ==
          otapolicy::Verdict::TooLong);

    // Swept rather than sampled, so the accept window is exactly the closed
    // interval and there is no gap either side of it.
    for (size_t len = 0; len <= 128; len++) {
      const otapolicy::Verdict verdict =
          otapolicy::verifyPassword(true, buf, len);
      const bool shouldAccept = len >= otapolicy::PASSWORD_MIN_BYTES &&
                                len <= otapolicy::PASSWORD_MAX_BYTES;
      CHECK((verdict == otapolicy::Verdict::Accept) == shouldAccept);
      if (!shouldAccept) {
        CHECK(verdict == (len < otapolicy::PASSWORD_MIN_BYTES
                              ? otapolicy::Verdict::TooShort
                              : otapolicy::Verdict::TooLong));
      }
      // A refusal is never silently downgraded by length.
      CHECK(otapolicy::verifyPassword(false, buf, len) ==
            otapolicy::Verdict::NotBase64);
      // Nor is the storability check: one zero byte anywhere in the same window
      // is refused at every length that would otherwise be accepted.
      if (len > 0) {
        unsigned char probe[128];
        memcpy(probe, buf, len);
        probe[len - 1] = 0;
        CHECK(otapolicy::verifyPassword(true, probe, len) ==
              otapolicy::Verdict::EmbeddedNul);
      }
    }
  }

  // --- the three-valued OTA status, and the capability bit that follows it
  {
    CHECK(otapolicy::status(false, false) == otapolicy::Status::Off);
    CHECK(otapolicy::status(false, true) == otapolicy::Status::Pending);
    CHECK(otapolicy::status(true, true) == otapolicy::Status::On);
    // Listening outranks the bookkeeping: the sketch cannot start OTA without a
    // stored password, but if that implication ever broke, the state that
    // matters is that something is accepting firmware.
    CHECK(otapolicy::status(true, false) == otapolicy::Status::On);

    CHECK(strcmp(otapolicy::statusToken(otapolicy::Status::Off), "off") == 0);
    CHECK(strcmp(otapolicy::statusToken(otapolicy::Status::Pending),
                 "pending") == 0);
    CHECK(strcmp(otapolicy::statusToken(otapolicy::Status::On), "on") == 0);

    // "pending" is the whole point of three values: a panel with a password
    // whose radio was not up when it booted is configured and waiting, and
    // reporting that as "off" would look like the password never took.
    CHECK(strcmp(otapolicy::statusToken(otapolicy::status(false, true)),
                 "pending") == 0);
    CHECK(strcmp(otapolicy::statusToken(otapolicy::status(false, false)),
                 "off") == 0);

    // But it must NOT advertise: the bit tells a sender it may push, and a
    // pending panel has nothing listening to accept the push.
    CHECK(otapolicy::advertisesCapability(otapolicy::Status::On));
    CHECK(!otapolicy::advertisesCapability(otapolicy::Status::Pending));
    CHECK(!otapolicy::advertisesCapability(otapolicy::Status::Off));

    // Composed the way deviceCapabilities() does it, so the bit pinned above is
    // tied to the decision that actually sets it rather than standing alone.
    const uint32_t base = deviceproto::CAP_BRIGHTNESS |
                          deviceproto::CAP_BRIGHTNESS_LEVEL |
                          deviceproto::CAP_FLIP | deviceproto::CAP_IDENTIFY |
                          deviceproto::CAP_RESTART |
                          deviceproto::CAP_SLEEP_SYNC |
                          deviceproto::CAP_TELEMETRY |
                          deviceproto::CAP_IDLE_TEXT;
    auto advertised = [&](bool active, bool configured) {
      const otapolicy::Status status = otapolicy::status(active, configured);
      return base | (otapolicy::advertisesCapability(status)
                         ? deviceproto::CAP_OTA
                         : 0u);
    };
    CHECK(advertised(true, true) == (base | deviceproto::CAP_OTA));
    CHECK(advertised(true, true) == 0x1FFu);
    CHECK(advertised(false, true) == base);
    CHECK((advertised(false, true) & deviceproto::CAP_OTA) == 0);
    CHECK(advertised(false, false) == base);
    CHECK((advertised(false, false) & deviceproto::CAP_OTA) == 0);
  }
  // --- the panel state an update borrows, and the unauthenticated wake that
  //     putting it back without checking used to allow
  {
    // THE CASE THIS TYPE EXISTS FOR. A panel the Mac has put to sleep, and an
    // error callback with no matching onStart - which is every wrong-password
    // push, since the core answers those out of OTA_WAITAUTH long before
    // _start_callback. take() must refuse and leave the panel alone. Restoring
    // unconditionally wrote false/false and re-applied the backlight, so
    // anything on the LAN could wake a sleeping panel without the password.
    {
      otapolicy::SavedPanelState fresh;
      bool sleeping = true, idle = true;
      CHECK(!fresh.take(sleeping, idle));
      CHECK(sleeping);  // still asleep
      CHECK(idle);
    }
    // The same with the panel awake: nothing owed means nothing written, in
    // either direction. A restore that happened to agree would not be a pass.
    {
      otapolicy::SavedPanelState fresh;
      bool sleeping = false, idle = false;
      CHECK(!fresh.take(sleeping, idle));
      CHECK(!sleeping);
      CHECK(!idle);
    }
    // The path that does owe something: onStart saved, so a failure puts it back.
    {
      otapolicy::SavedPanelState saved;
      bool sleeping = true, idle = true;
      saved.save(sleeping, idle);
      // onStart then clears both, so the update is visible whatever state the
      // panel was in.
      sleeping = false;
      idle = false;
      CHECK(saved.take(sleeping, idle));
      CHECK(sleeping);
      CHECK(idle);
    }
    // Every combination round-trips, so neither field can be dropped or swapped.
    for (int bits = 0; bits < 4; bits++) {
      const bool wasSleeping = (bits & 1) != 0;
      const bool wasIdle = (bits & 2) != 0;
      otapolicy::SavedPanelState saved;
      saved.save(wasSleeping, wasIdle);
      bool sleeping = !wasSleeping, idle = !wasIdle;
      CHECK(saved.take(sleeping, idle));
      CHECK(sleeping == wasSleeping);
      CHECK(idle == wasIdle);
      // Consumed: a second error for the same push restores nothing and leaves
      // the caller's values where they are.
      bool againSleeping = sleeping, againIdle = idle;
      CHECK(!saved.take(againSleeping, againIdle));
      CHECK(againSleeping == sleeping);
      CHECK(againIdle == idle);
    }
    // A second push saves over the first rather than stacking, so what comes
    // back is the state the panel was in when THIS update started.
    {
      otapolicy::SavedPanelState saved;
      saved.save(true, true);
      saved.save(false, true);
      bool sleeping = true, idle = false;
      CHECK(saved.take(sleeping, idle));
      CHECK(!sleeping);
      CHECK(idle);
    }
    // And a save after a take is honoured: a panel that failed one push still
    // gets its state back after the next one.
    {
      otapolicy::SavedPanelState saved;
      bool sleeping = true, idle = false;
      saved.save(sleeping, idle);
      CHECK(saved.take(sleeping, idle));
      CHECK(!saved.take(sleeping, idle));
      saved.save(false, true);
      bool nextSleeping = true, nextIdle = false;
      CHECK(saved.take(nextSleeping, nextIdle));
      CHECK(!nextSleeping);
      CHECK(nextIdle);
    }
    // THE SUCCESS HALF. onEnd owes the panel nothing - the board reboots and the
    // sender re-establishes both flags - so it discards instead of restoring, and
    // afterwards the state is indistinguishable from one that was never saved.
    // Without this the invariant "nothing saved crosses a push" would rest on
    // ESP.restart() happening, i.e. on _rebootOnSuccess still being true, which
    // nothing but a comment records.
    {
      otapolicy::SavedPanelState saved;
      saved.save(true, true);
      saved.discard();
      bool sleeping = false, idle = false;
      CHECK(!saved.take(sleeping, idle));
      CHECK(!sleeping);  // untouched, exactly as for a fresh instance
      CHECK(!idle);
    }
    // Idempotent, harmless with nothing held, and not a one-way door: a panel
    // whose push completed still gets its state back if a later one fails.
    {
      otapolicy::SavedPanelState saved;
      saved.discard();  // nothing held; not an error
      saved.save(true, false);
      saved.discard();
      saved.discard();
      bool sleeping = false, idle = true;
      CHECK(!saved.take(sleeping, idle));
      CHECK(!sleeping);
      CHECK(idle);
      saved.save(true, false);
      bool nextSleeping = false, nextIdle = true;
      CHECK(saved.take(nextSleeping, nextIdle));
      CHECK(nextSleeping);
      CHECK(!nextIdle);
    }
    // discard() and take() agree about what "nothing owed" means, from every
    // saved combination and against a panel in either state - so a pass cannot
    // come from the discarded values happening to match what the caller holds.
    for (int bits = 0; bits < 4; bits++) {
      const bool wasSleeping = (bits & 1) != 0;
      const bool wasIdle = (bits & 2) != 0;
      otapolicy::SavedPanelState discarded;
      discarded.save(wasSleeping, wasIdle);
      discarded.discard();
      bool sleeping = wasSleeping, idle = wasIdle;
      CHECK(!discarded.take(sleeping, idle));
      CHECK(sleeping == wasSleeping);
      CHECK(idle == wasIdle);
      bool flipped = !wasSleeping, flippedIdle = !wasIdle;
      CHECK(!discarded.take(flipped, flippedIdle));
      CHECK(flipped == !wasSleeping);
      CHECK(flippedIdle == !wasIdle);
    }
  }

  // --- chip identity: which image out of a firmware bundle belongs to this
  // panel. The token goes out as the `chip=` TXT record, and the app refuses a
  // definite mismatch on it, so the wrong string here means the wrong image
  // offered for a panel.
  //
  // Every literal below is written out by hand from tools/espdisp.py BOARDS
  // (chip="esp32c6", chip="esp32s3") rather than taken from the header, for the
  // same reason firmware/test and Tests/SenderProtocolTests assert the same band
  // bytes independently: the CLI and the Swift app cannot be recompiled from
  // here, so a token that drifts has to fail a test rather than silently agree
  // with itself.
  //
  // WHAT THIS PROVES AND WHAT IT CANNOT. The ladder takes its inputs as
  // arguments, so all four of its rungs are reachable here. The #if wiring that
  // feeds it cannot be: a translation unit has one preprocessor state, and on
  // the host it is the state of a build with no ESP macros at all. That half is
  // checked where it is real instead - chip_identity.h static_asserts that
  // CONFIG_IDF_TARGET and the fallback token agree, and that the token is not
  // "unknown", both of which are compiled for the C6 and the S3 on every build.
  {
    // The host is a build that cannot name its chip, and that is the branch
    // being exercised: the answer is the defined "unknown" token, not an empty
    // string and not a crash. A reader treats this as "I could not tell".
    CHECK(chipidentity::chipToken() != nullptr);
    CHECK(strcmp(chipidentity::chipToken(), "unknown") == 0);
    // The host's preprocessor state, stated rather than left implied: it is what
    // makes "unknown" the right expectation above, and it is the reason the
    // other branches of the wiring are checked by the firmware compile instead
    // of here. If a stray sdkconfig.h ever landed on the host include path these
    // fail first, which is a much clearer report than the token assertion above.
    CHECK(chipidentity::buildIdfTarget() == nullptr);
    CHECK(!chipidentity::buildTargetsEsp32C6());
    CHECK(!chipidentity::buildTargetsEsp32S3());

    // The IDF's own string, which is what a real build supplies. Verified on
    // disk for core 3.3.11: CONFIG_IDF_TARGET is "esp32c6" at
    // esp32c6-libs/3.3.11/qio_qspi/include/sdkconfig.h:429 and "esp32s3" at
    // esp32s3-libs/3.3.11/*/include/sdkconfig.h:394.
    CHECK(strcmp(chipidentity::selectToken("esp32c6", false, false),
                 "esp32c6") == 0);
    CHECK(strcmp(chipidentity::selectToken("esp32s3", false, false),
                 "esp32s3") == 0);
    // Passed straight through, so a chip this file has never heard of is
    // advertised accurately rather than as "unknown". An app comparing tokens
    // then correctly finds no matching image instead of offering one.
    CHECK(strcmp(chipidentity::selectToken("esp32p4", false, false),
                 "esp32p4") == 0);

    // The fallback rungs, for a build where the string is missing but the
    // per-chip flag is not. Asserted in both directions: a C6 build must not
    // answer with the S3 token, which is the mistake that would put an S3 image
    // on a C6 panel.
    CHECK(strcmp(chipidentity::selectToken(nullptr, true, false), "esp32c6") ==
          0);
    CHECK(strcmp(chipidentity::selectToken(nullptr, true, false), "esp32s3") !=
          0);
    CHECK(strcmp(chipidentity::selectToken(nullptr, false, true), "esp32s3") ==
          0);
    CHECK(strcmp(chipidentity::selectToken(nullptr, false, true), "esp32c6") !=
          0);
    // Neither flag: the last rung, and the only input that may answer "unknown".
    CHECK(strcmp(chipidentity::selectToken(nullptr, false, false), "unknown") ==
          0);

    // The IDF's string outranks the flags, so the answer stays the IDF's even if
    // a future core defines a flag this file misreads. Fed a deliberately
    // contradictory pair, which a real build never produces - chip_identity.h
    // static_asserts that it cannot - to pin which side wins.
    CHECK(strcmp(chipidentity::selectToken("esp32s3", true, false),
                 "esp32s3") == 0);
    CHECK(strcmp(chipidentity::selectToken("esp32c6", false, true),
                 "esp32c6") == 0);

    // An empty string counts as absent rather than as a chip named "". Left as
    // a token it would read to the app as a definite mismatch with every image
    // in a bundle, i.e. as knowledge, when it is the opposite.
    CHECK(strcmp(chipidentity::selectToken("", false, false), "unknown") == 0);
    CHECK(strcmp(chipidentity::selectToken("", true, false), "esp32c6") == 0);
    CHECK(strcmp(chipidentity::selectToken("", false, true), "esp32s3") == 0);

    // Both flags at once cannot happen either, but it must still produce one
    // token rather than falling through to "unknown" - the rungs are ordered,
    // not exclusive.
    CHECK(strcmp(chipidentity::selectToken(nullptr, true, true), "esp32c6") ==
          0);

    // The three answers are distinct, so a swapped pair of rungs cannot pass by
    // two tokens happening to be equal.
    CHECK(strcmp(chipidentity::selectToken(nullptr, true, false),
                 chipidentity::selectToken(nullptr, false, true)) != 0);
    CHECK(strcmp(chipidentity::selectToken(nullptr, true, false),
                 chipidentity::selectToken(nullptr, false, false)) != 0);
    CHECK(strcmp(chipidentity::selectToken(nullptr, false, true),
                 chipidentity::selectToken(nullptr, false, false)) != 0);

    // And the header's own tokens are the strings the CLI writes into a bundle
    // manifest. This is the assertion that fails if someone renames a token to
    // something tidier - "c6", say - which would compile, advertise, and match
    // nothing.
    CHECK(strcmp(chipidentity::TOKEN_ESP32C6, "esp32c6") == 0);
    CHECK(strcmp(chipidentity::TOKEN_ESP32S3, "esp32s3") == 0);
    CHECK(strcmp(chipidentity::TOKEN_UNKNOWN, "unknown") == 0);

    // sameToken is what the compile-time cross-checks are built out of, so it
    // gets its own coverage: a false positive there would silently disarm them.
    CHECK(chipidentity::sameToken("esp32c6", "esp32c6"));
    CHECK(!chipidentity::sameToken("esp32c6", "esp32s3"));
    CHECK(!chipidentity::sameToken("esp32c6", "esp32c"));   // prefix, shorter
    CHECK(!chipidentity::sameToken("esp32c", "esp32c6"));   // prefix, longer
    CHECK(!chipidentity::sameToken("esp32c6", ""));
    CHECK(chipidentity::sameToken("", ""));
    CHECK(chipidentity::sameToken(nullptr, nullptr));
    CHECK(!chipidentity::sameToken(nullptr, "esp32c6"));
    CHECK(!chipidentity::sameToken("esp32c6", nullptr));
    // Constant-evaluable, which is the property the static_asserts need and the
    // one a later edit could take away without any warning.
    static_assert(chipidentity::sameToken("esp32c6",
                                          chipidentity::TOKEN_ESP32C6),
                  "sameToken must be usable in a constant expression");
    static_assert(chipidentity::sameToken(
                      chipidentity::selectToken(nullptr, false, true),
                      "esp32s3"),
                  "selectToken must be usable in a constant expression");
  }

  // --- rle565: the wire codec for compressed band records ------------------
  // Byte-for-byte vectors written out by hand from the format comment in
  // band_compress.h, deliberately NOT shared with the Swift suite - each side
  // asserts the wire independently, so a codec change that breaks
  // interoperability fails a test rather than updating a fixture.
  {
    // One repeat run: 4x the pixel 0x2104 (big-endian on the wire).
    // control = 0x80 + (4 - 2) = 0x82.
    const uint8_t raw[] = {0x21, 0x04, 0x21, 0x04, 0x21, 0x04, 0x21, 0x04};
    uint8_t enc[16];
    size_t n = rle565::encode(raw, sizeof(raw), enc, sizeof(enc));
    CHECK(n == 3);
    CHECK(enc[0] == 0x82 && enc[1] == 0x21 && enc[2] == 0x04);
    uint8_t dec[8];
    CHECK(rle565::decode(enc, n, dec, sizeof(dec)));
    CHECK(memcmp(dec, raw, sizeof(raw)) == 0);
  }
  {
    // Pure literal: three distinct pixels. control = count - 1 = 0x02.
    const uint8_t raw[] = {0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF};
    uint8_t enc[16];
    size_t n = rle565::encode(raw, sizeof(raw), enc, sizeof(enc));
    CHECK(n == 7);
    CHECK(enc[0] == 0x02);
    CHECK(memcmp(enc + 1, raw, 6) == 0);
    uint8_t dec[6];
    CHECK(rle565::decode(enc, n, dec, sizeof(dec)));
    CHECK(memcmp(dec, raw, sizeof(raw)) == 0);
  }
  {
    // Mixed: literal [1122 3344], run 3x[5566], literal [7788].
    const uint8_t raw[] = {0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x55, 0x66,
                           0x55, 0x66, 0x77, 0x88};
    const uint8_t expect[] = {0x01, 0x11, 0x22, 0x33, 0x44,  // literal x2
                              0x81, 0x55, 0x66,              // run x3
                              0x00, 0x77, 0x88};             // literal x1
    uint8_t enc[32];
    size_t n = rle565::encode(raw, sizeof(raw), enc, sizeof(enc));
    CHECK(n == sizeof(expect));
    CHECK(memcmp(enc, expect, n) == 0);
    uint8_t dec[12];
    CHECK(rle565::decode(enc, n, dec, sizeof(dec)));
    CHECK(memcmp(dec, raw, sizeof(raw)) == 0);
  }
  {
    // Run-length limits: 129 identical pixels fit one control byte (0xFF); a
    // 130th starts a second chunk. Literal limit is 128 (control 0x7F).
    uint8_t raw[130 * 2];
    for (size_t i = 0; i < sizeof(raw); i += 2) { raw[i] = 0x12; raw[i + 1] = 0x34; }
    uint8_t enc[16];
    CHECK(rle565::encode(raw, 129 * 2, enc, sizeof(enc)) == 3);
    CHECK(enc[0] == 0xFF);
    size_t n = rle565::encode(raw, 130 * 2, enc, sizeof(enc));
    CHECK(n == 6);
    CHECK(enc[0] == 0xFF);           // 129 pixels...
    CHECK(enc[3] == 0x00);           // ...then a 1-pixel literal
    uint8_t dec[130 * 2];
    CHECK(rle565::decode(enc, n, dec, sizeof(dec)));
    CHECK(memcmp(dec, raw, sizeof(dec)) == 0);
  }
  {
    // Worst case (no two adjacent pixels equal) stays within maxEncodedBytes,
    // and round-trips. 466px is the S3's row; 172px the C6's portrait row.
    for (size_t pixels : {(size_t)172, (size_t)466, (size_t)697}) {
      std::vector<uint8_t> raw(pixels * 2);
      for (size_t i = 0; i < pixels; i++) {
        raw[i * 2] = (uint8_t)(i >> 8);
        raw[i * 2 + 1] = (uint8_t)(i & 0xFF);  // all distinct: worst case
      }
      std::vector<uint8_t> enc(rle565::maxEncodedBytes(raw.size()));
      size_t n = rle565::encode(raw.data(), raw.size(), enc.data(), enc.size());
      CHECK(n > 0);
      CHECK(n <= rle565::maxEncodedBytes(raw.size()));
      CHECK(n == raw.size() + (pixels + 127) / 128);  // exactly the bound
      std::vector<uint8_t> dec(raw.size());
      CHECK(rle565::decode(enc.data(), n, dec.data(), dec.size()));
      CHECK(memcmp(dec.data(), raw.data(), raw.size()) == 0);
    }
    // A flat band (idle screen, letterbox bars) collapses to a few bytes.
    std::vector<uint8_t> raw(466 * 2, 0x00);
    uint8_t enc[16];
    size_t n = rle565::encode(raw.data(), raw.size(), enc, sizeof(enc));
    CHECK(n == 12);  // ceil(466/129) = 4 runs x 3 bytes
  }
  {
    // Deterministic pseudo-random round-trips, spanning run/literal mixes.
    uint32_t seed = 0x1234567;
    for (int trial = 0; trial < 50; trial++) {
      size_t pixels = 1 + (seed % 700);
      std::vector<uint8_t> raw(pixels * 2);
      for (size_t i = 0; i < pixels; i++) {
        seed = seed * 1664525u + 1013904223u;
        // Small palette so runs actually occur.
        uint16_t px = (uint16_t)((seed >> 16) % 5 * 0x1111);
        raw[i * 2] = (uint8_t)(px >> 8);
        raw[i * 2 + 1] = (uint8_t)px;
      }
      std::vector<uint8_t> enc(rle565::maxEncodedBytes(raw.size()));
      size_t n = rle565::encode(raw.data(), raw.size(), enc.data(), enc.size());
      CHECK(n > 0 && n <= rle565::maxEncodedBytes(raw.size()));
      std::vector<uint8_t> dec(raw.size());
      CHECK(rle565::decode(enc.data(), n, dec.data(), dec.size()));
      CHECK(memcmp(dec.data(), raw.data(), raw.size()) == 0);
    }
  }
  {
    // Encoder refuses what it cannot represent: empty and odd-length input,
    // and output that does not fit.
    uint8_t buf[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    uint8_t enc[16];
    CHECK(rle565::encode(buf, 0, enc, sizeof(enc)) == 0);
    CHECK(rle565::encode(buf, 3, enc, sizeof(enc)) == 0);
    CHECK(rle565::encode(buf, 8, enc, 2) == 0);  // 4 literal pixels need 9B
  }
  {
    // SECURITY: the decoder must refuse malformed input and never read or
    // write outside the buffers it was given, because it writes into the
    // frame buffer from an unauthenticated datagram. Source and destination
    // are heap allocations of EXACTLY the claimed sizes: run_tests.sh builds
    // with AddressSanitizer non-recovering, so one stray byte in either
    // direction aborts the suite. A wider scratch buffer here would hide an
    // off-by-one inside its slack - which is exactly how the first version of
    // this test let a removed bounds check survive mutation testing.
    auto refused = [](std::vector<uint8_t> src, size_t dstLen) {
      std::vector<uint8_t> dst(dstLen, 0xA5);
      return !rle565::decode(src.data(), src.size(), dst.data(), dstLen);
    };
    // Truncated literal: control claims 2 pixels, only 1 follows.
    CHECK(refused({0x01, 0x11, 0x22}, 8));
    // Truncated repeat: control with no pixel bytes / one pixel byte.
    CHECK(refused({0x82}, 8));
    CHECK(refused({0x82, 0x11}, 8));
    // Overrun: a run of 4 pixels into a 3-pixel (6-byte) band.
    CHECK(refused({0x82, 0x11, 0x22, 0x80, 0x33, 0x44}, 6));
    // A literal of 4 pixels into the same 6-byte band.
    CHECK(refused({0x03, 1, 2, 3, 4, 5, 6, 7, 8}, 6));
    // Overrun by exactly ONE byte, pinned tight against the true boundary: a
    // run of 4 pixels (8 bytes) into a dst one byte short of that. A margin
    // of two or more bytes here (as above) leaves slack for an off-by-one in
    // the bounds check (`> dstLen` vs `>= dstLen`, or `dstLen` vs `dstLen+1`)
    // to still be caught by luck; this vector fails only if the check is
    // exact, so a one-byte-loose check writes into ASan's redzone and aborts
    // rather than merely returning the wrong bool.
    CHECK(refused({0x82, 0x11, 0x22}, 7));
    // Same one-byte-tight pin for a literal chunk.
    CHECK(refused({0x03, 1, 2, 3, 4, 5, 6, 7, 8}, 7));
    // Short: decodes cleanly but to fewer bytes than the band needs.
    CHECK(refused({0x81, 0x11, 0x22}, 8));
    // Empty input never fills a band.
    CHECK(refused({}, 8));
    // Exact fill succeeds - the "short" vector against its true size.
    {
      const uint8_t exact[] = {0x81, 0x11, 0x22};
      std::vector<uint8_t> dst(6, 0xA5);
      CHECK(rle565::decode(exact, sizeof(exact), dst.data(), dst.size()));
      CHECK(dst[0] == 0x11 && dst[5] == 0x22);
    }
  }

  // --- packed band packets: header flag bits and the record walker ---------
  {
    // Old-format headers are untouched by the new fields: bit 15 clear means
    // not packed, and every index below MAX_BANDS has reserved bits clear.
    const uint8_t classic[] = {0x07, 0x00, 0xFF, 0x01, 0xD2, 0x81};
    Header h = parseHeader(classic);
    CHECK(!h.packed);
    CHECK(!h.reservedBitsSet);
    CHECK(h.frameId == 7 && h.bandIndex == 511 && h.dirtyCount == 466);
    CHECK(h.landscape);

    // Packed flag: band_index 0x8005 = packed, first band 5.
    const uint8_t packed[] = {0x07, 0x00, 0x05, 0x80, 0xD2, 0x01};
    h = parseHeader(packed);
    CHECK(h.packed);
    CHECK(!h.reservedBitsSet);
    CHECK(h.bandIndex == 5);
    CHECK(!h.landscape);

    // Reserved bits 14..10: any of them set flags the header for rejection.
    const uint8_t reserved[] = {0x07, 0x00, 0x05, 0x84, 0xD2, 0x01};
    h = parseHeader(reserved);
    CHECK(h.packed);
    CHECK(h.reservedBitsSet);
    const uint8_t reservedLow[] = {0x07, 0x00, 0x05, 0x04, 0xD2, 0x01};
    h = parseHeader(reservedLow);
    CHECK(!h.packed);
    CHECK(h.reservedBitsSet);
  }
  {
    // Record walker: two records built by hand, byte for byte.
    //   band 5, compressed, 3 bytes: run 4x 0x2104
    //   band 9, raw, 4 bytes
    const uint8_t payload[] = {
        0x05, 0x00, 0x03, 0x80, 0x82, 0x21, 0x04,        // band 5 compressed
        0x09, 0x00, 0x04, 0x00, 0xDE, 0xAD, 0xBE, 0xEF,  // band 9 raw
    };
    struct Seen { uint16_t band; bool compressed; size_t len; uint8_t first; };
    std::vector<Seen> seen;
    bool ok = forEachPackedRecord(
        payload, sizeof(payload),
        [&](uint16_t band, bool compressed, const uint8_t *p, size_t n) {
          seen.push_back({band, compressed, n, p[0]});
          return true;
        });
    CHECK(ok);
    CHECK(seen.size() == 2);
    CHECK(seen[0].band == 5 && seen[0].compressed && seen[0].len == 3 &&
          seen[0].first == 0x82);
    CHECK(seen[1].band == 9 && !seen[1].compressed && seen[1].len == 4 &&
          seen[1].first == 0xDE);
  }
  {
    // Walker structural refusals: empty payload, truncated record header,
    // record body past the end, zero-length body, reserved band bits set,
    // and a callback veto (which must abort the walk). Payloads are heap
    // allocations of exactly the length passed, so under the sanitizer a
    // walker that reads one byte past what it was given aborts the suite -
    // the walker is the network path's parser.
    auto accept = [](uint16_t, bool, const uint8_t *, size_t) { return true; };
    auto walks = [&](std::vector<uint8_t> payload) {
      return forEachPackedRecord(payload.data(), payload.size(), accept);
    };
    CHECK(walks({0x05, 0x00, 0x01, 0x00, 0xAA}));
    CHECK(!walks({}));                                  // empty
    CHECK(!walks({0x05, 0x00, 0x01}));                  // short header
    CHECK(!walks({0x05, 0x00, 0x01, 0x00}));            // body missing
    CHECK(!walks({0x05, 0x00, 0x00, 0x00}));            // zero-length body
    CHECK(!walks({0x05, 0x80, 0x01, 0x00, 0xAA}));      // bit 15 in band
    CHECK(!walks({0x05, 0x04, 0x01, 0x00, 0xAA}));      // bit 10 in band
    // Trailing garbage shorter than a record header after a good record.
    CHECK(!walks({0x05, 0x00, 0x01, 0x00, 0xAA, 0x01, 0x02}));
    // Callback veto aborts: the second record is never visited.
    int visits = 0;
    const uint8_t two[] = {0x05, 0x00, 0x01, 0x00, 0xAA,
                           0x06, 0x00, 0x01, 0x00, 0xBB};
    CHECK(!forEachPackedRecord(
        two, sizeof(two),
        [&](uint16_t, bool, const uint8_t *, size_t) {
          visits++;
          return false;
        }));
    CHECK(visits == 1);
  }
  {
    // The packed budget and record framing constants are wire facts the Swift
    // side mirrors; pin them so neither end can drift alone.
    CHECK(MAX_PACKED_PACKET_BYTES == 1472);
    CHECK(RECORD_HEADER_BYTES == 4);
    CHECK(BAND_INDEX_PACKED == 0x8000);
    CHECK(BAND_INDEX_RESERVED_MASK == 0x7C00);
    CHECK(BAND_INDEX_VALUE_MASK == 0x03FF);
    CHECK(RECORD_COMPRESSED == 0x8000);
    CHECK(RECORD_LENGTH_MASK == 0x7FFF);
    // MAX_BANDS fits the 10-bit index field with the flag and reserved bits.
    CHECK(MAX_BANDS - 1 <= BAND_INDEX_VALUE_MASK);
    // The packed budget really holds a worst-case S3 row as one raw record.
    CHECK(HEADER_BYTES + RECORD_HEADER_BYTES + 932 <= MAX_PACKED_PACKET_BYTES);
  }

  printf("OK: %d checks passed\n", checks);
  return 0;
}
