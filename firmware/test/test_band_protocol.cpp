// Host-side unit tests for the band protocol logic. Every rule in here
// corresponds to a failure observed on real hardware/WiFi. Build and run:
//   firmware/test/run_tests.sh
#include <cassert>
#include <cstdio>
#include <utility>
#include <vector>

#include "../display_stream/band_protocol.h"
#include "../display_stream/control_queue.h"
#include "../display_stream/device_protocol.h"
#include "../display_stream/panel_state.h"

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

    // Opcode 6 does not exist yet; the range check has to still reject it.
    uint8_t future[12] = {
        0x45, 0x43, 0x54, 0x4c, 0x01, 0x06, 0x34, 0x12,
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

  // --- backlight priority: sleep beats idle beats the user's level
  {
    CHECK(panelstate::backlightLevel(false, false, 128, 10) == 128);
    CHECK(panelstate::backlightLevel(false, true, 128, 10) == 10);
    CHECK(panelstate::backlightLevel(true, false, 128, 10) == 0);
    // Asleep wins even while idle: the Mac's screens being off is the
    // strongest signal there is nothing worth lighting.
    CHECK(panelstate::backlightLevel(true, true, 128, 10) == 0);
    // The user's level is honoured exactly, not rounded to high/low.
    CHECK(panelstate::backlightLevel(false, false, 1, 10) == 1);
    CHECK(panelstate::backlightLevel(false, false, 255, 10) == 255);
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
    CHECK(panelstate::deviceFlags(false, false, false, false, false) == 0x00);
    CHECK(panelstate::deviceFlags(true, false, false, false, false) == 0x01);
    CHECK(panelstate::deviceFlags(false, true, false, false, false) == 0x02);
    CHECK(panelstate::deviceFlags(false, false, true, false, false) == 0x04);
    CHECK(panelstate::deviceFlags(false, false, false, true, false) == 0x08);
    CHECK(panelstate::deviceFlags(false, false, false, false, true) == 0x10);
    CHECK(panelstate::deviceFlags(true, true, false, false, true) == 0x13);
    CHECK(panelstate::deviceFlags(true, true, true, true, true) == 0x1F);
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

  printf("OK: %d checks passed\n", checks);
  return 0;
}
