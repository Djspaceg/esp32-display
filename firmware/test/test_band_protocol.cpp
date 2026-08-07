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
#include "../libraries/espdisp_board/src/board_config.h"
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
    CHECK(panelstate::backlightLevel(false, false, false, 128, 10) == 128);
    CHECK(panelstate::backlightLevel(false, true, false, 128, 10) == 10);
    CHECK(panelstate::backlightLevel(true, false, false, 128, 10) == 0);
    // Asleep wins even while idle: the Mac's screens being off is the
    // strongest signal there is nothing worth lighting.
    CHECK(panelstate::backlightLevel(true, true, false, 128, 10) == 0);
    // The user's level is honoured exactly, not rounded to high/low.
    CHECK(panelstate::backlightLevel(false, false, false, 1, 10) == 1);
    CHECK(panelstate::backlightLevel(false, false, false, 255, 10) == 255);

    // A finger outranks everything: someone touching a dark panel is asking
    // whether it is alive, and the answer has to be visible. This is what lets
    // tap-to-wake work from both the idle card and the Mac's display sleep,
    // without the panel having to contradict the Mac about sleep state.
    CHECK(panelstate::backlightLevel(false, true, true, 128, 10) == 128);
    CHECK(panelstate::backlightLevel(true, false, true, 128, 10) == 128);
    CHECK(panelstate::backlightLevel(true, true, true, 128, 10) == 128);
    // ...and it wakes to the level the user chose, not to full blast.
    CHECK(panelstate::backlightLevel(true, true, true, 40, 10) == 40);
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
    CHECK(strcmp(board::variantToken(Variant::Unknown), "auto") == 0);
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
    CHECK(touchmap::map(SHORT - 1, 0, false, false).x == 0);
    CHECK(touchmap::map(SHORT - 1, 0, false, false).y == 0);
    CHECK(touchmap::map(0, LONG - 1, false, false).x == SHORT - 1);
    CHECK(touchmap::map(0, LONG - 1, false, false).y == LONG - 1);

    // The 180 flip is a point reflection, so the same finger position must map
    // to the opposite corner.
    CHECK(touchmap::map(SHORT - 1, 0, false, true).x == SHORT - 1);
    CHECK(touchmap::map(SHORT - 1, 0, false, true).y == LONG - 1);
    CHECK(touchmap::map(0, LONG - 1, false, true).x == 0);
    CHECK(touchmap::map(0, LONG - 1, false, true).y == 0);

    // Landscape swaps the axes: the long panel axis becomes framebuffer X, so a
    // touch at one end of it must land at a framebuffer X extreme, never beyond.
    CHECK(touchmap::map(SHORT - 1, 0, true, false).x == 0);
    CHECK(touchmap::map(SHORT - 1, LONG - 1, true, false).x == LONG - 1);

    // Structural properties that must hold in every orientation, checked over
    // the whole coordinate space rather than at hand-picked points. A transform
    // that is wrong by one reflection still satisfies these, which is why the
    // corner assertions above exist too - but an off-by-one or a swapped axis
    // that overruns the framebuffer does not.
    for (int16_t ry = 0; ry < LONG; ry += 7) {
      for (int16_t rx = 0; rx < SHORT; rx += 5) {
        for (int orientation = 0; orientation < 4; orientation++) {
          const bool landscape = (orientation & 1) != 0;
          const bool flip = (orientation & 2) != 0;
          Point p = touchmap::map(rx, ry, landscape, flip);
          // In range, always.
          CHECK(p.x >= 0 && p.x < touchmap::frameWidth(landscape));
          CHECK(p.y >= 0 && p.y < touchmap::frameHeight(landscape));
          // Flipping is an involution: flipping twice is the identity, so the
          // flipped point must be the unflipped one reflected through the centre.
          Point q = touchmap::map(rx, ry, landscape, !flip);
          CHECK(q.x == touchmap::frameWidth(landscape) - 1 - p.x);
          CHECK(q.y == touchmap::frameHeight(landscape) - 1 - p.y);
        }
      }
    }

    // The mapping must be injective within an orientation, or two different
    // finger positions would be indistinguishable after transform.
    CHECK(touchmap::map(10, 20, false, false).x != touchmap::map(11, 20, false, false).x);
    CHECK(touchmap::map(10, 20, false, false).y != touchmap::map(10, 21, false, false).y);
    CHECK(touchmap::map(10, 20, true, false).y != touchmap::map(11, 20, true, false).y);
    CHECK(touchmap::map(10, 20, true, false).x != touchmap::map(10, 21, true, false).x);

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
    CHECK(touchmap::map(9999, 9999, false, false).x >= 0);
    CHECK(touchmap::map(9999, 9999, false, false).y <= LONG - 1);
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

    CHECK(strcmp(touchgesture::gestureName(Gesture::Tap), "tap") == 0);
    CHECK(strcmp(touchgesture::gestureName(Gesture::SwipeLeft), "swipe-left") == 0);
    CHECK(strcmp(touchgesture::gestureName(Gesture::None), "none") == 0);
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
         raw <= (uint8_t)deviceproto::TouchGesture::SwipeDown; raw++) {
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
    badGesture[5] = (uint8_t)deviceproto::TouchGesture::SwipeDown + 1;
    CHECK(!deviceproto::parseTouch(badGesture, sizeof(badGesture), ignored));

    // CAP_TOUCH must not collide with an existing capability bit.
    CHECK(deviceproto::CAP_TOUCH == 1u << 9);
    CHECK((deviceproto::CAP_TOUCH & deviceproto::CAP_IDLE_TEXT) == 0);
    CHECK((deviceproto::CAP_TOUCH & deviceproto::CAP_BRIGHTNESS_LEVEL) == 0);
  }

  printf("OK: %d checks passed\n", checks);
  return 0;
}
