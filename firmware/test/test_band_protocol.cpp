// Host-side unit tests for the band protocol logic. Every rule in here
// corresponds to a failure observed on real hardware/WiFi. Build and run:
//   firmware/test/run_tests.sh
#include <array>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <utility>
#include <vector>

#include "../display_stream/band_compress.h"
#include "../display_stream/band_protocol.h"
#include "../display_stream/bc1.h"
#include "../display_stream/button_press_model.h"
#include "../display_stream/chip_identity.h"
#include "../display_stream/control_queue.h"
#include "../display_stream/device_protocol.h"
#include "../display_stream/glyph_draw.h"
#include "../display_stream/large_tile_protocol.h"
#include "../display_stream/ota_policy.h"
#include "../display_stream/panel_state.h"
#include "../display_stream/serial_config_protocol.h"
#include "../display_stream/tile_protocol.h"
#include "../display_stream/wifi_presets.h"
#include "../display_stream/wifi_selector_model.h"
#include "../doom/src/platform/doom_runtime_policy.h"
#include "../libraries/espdisp_board/src/battery_estimate.h"
#include "../libraries/espdisp_board/src/board_config.h"
#include "../libraries/espdisp_board/src/gt911_protocol.h"
#include "../libraries/espdisp_board/src/motion_orientation.h"
#include "../libraries/espdisp_board/src/panel_transfer_plan.h"
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

static std::string readTextFile(const std::string &path) {
  std::ifstream input(path);
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

static std::string firmwareSourcePath(const char *relative) {
  std::string testFile = __FILE__;
  const size_t slash = testFile.find_last_of('/');
  const std::string testDir =
      slash == std::string::npos ? "." : testFile.substr(0, slash);
  return testDir + "/../display_stream/" + relative;
}

int main() {
  bool dropped;

  // --- bounded S3 panel DMA staging --------------------------------------
  {
    constexpr size_t stagingBytes = paneltransfer::STAGING_BYTES;
    constexpr size_t st77916FrameBytes = (size_t)360 * 360 * 2;
    // The observation's highest aggregate internal-free reading is already an
    // upper bound on its largest INTERNAL|DMA block. The old direct PSRAM
    // transfer therefore cannot allocate its full-frame private bounce buffer.
    constexpr size_t observedInternalFreeUpperBound = 134556;
    const size_t oldPrivateDmaRequest = st77916FrameBytes;
    if (getenv("ESPDISP_TEST_OLD_SPI_DMA") != nullptr) {
      printf("RED: old S3 policy requests %zu private DMA bytes with at most "
             "%zu internal bytes free\n",
             oldPrivateDmaRequest, observedInternalFreeUpperBound);
      CHECK(oldPrivateDmaRequest <= observedInternalFreeUpperBound);
    }
    CHECK(oldPrivateDmaRequest > observedInternalFreeUpperBound);

    struct Case {
      int width;
      int height;
      int expectedChunks;
    };
    const Case cases[] = {
        {128, 128, 3},
        {240, 240, 8},
        {360, 360, 18},
        {466, 466, 30},
    };
    for (const Case &test : cases) {
      int rowOffset = 0;
      int chunks = 0;
      size_t totalBytes = 0;
      size_t largestChunk = 0;
      while (rowOffset < test.height) {
        paneltransfer::ChunkPlan chunk;
        CHECK(paneltransfer::planChunk(0, test.height, test.width,
                                       stagingBytes, rowOffset, chunk));
        CHECK(chunk.y0 == rowOffset);
        CHECK(chunk.y1 > chunk.y0);
        CHECK(chunk.sourceOffset == totalBytes);
        CHECK(chunk.byteCount <= stagingBytes);
        if (chunk.byteCount > largestChunk) largestChunk = chunk.byteCount;
        rowOffset += chunk.y1 - chunk.y0;
        totalBytes += chunk.byteCount;
        chunks++;
      }
      CHECK(chunks == test.expectedChunks);
      CHECK(rowOffset == test.height);
      CHECK(totalBytes ==
            (size_t)test.width * test.height *
                paneltransfer::BYTES_PER_PIXEL);
      CHECK(largestChunk <= stagingBytes);
    }

    paneltransfer::ChunkPlan invalid;
    CHECK(!paneltransfer::planChunk(0, 10, 0, stagingBytes, 0, invalid));
    CHECK(!paneltransfer::planChunk(0, 10, 8000, stagingBytes, 0, invalid));
    CHECK(!paneltransfer::planChunk(10, 10, 360, stagingBytes, 0, invalid));
    CHECK(!paneltransfer::planChunk(0, 10, 360, stagingBytes, 10, invalid));

    paneltransfer::ChunkPlan partial;
    CHECK(paneltransfer::planChunk(37, 67, 360, stagingBytes, 0, partial));
    CHECK(partial.y0 == 37 && partial.y1 == 58);
    CHECK(partial.sourceOffset == 0);
    CHECK(paneltransfer::planChunk(37, 67, 360, stagingBytes, 21, partial));
    CHECK(partial.y0 == 58 && partial.y1 == 67);
    CHECK(partial.sourceOffset == (size_t)21 * 360 * 2);
  }

  // The serial configuration surface is user-facing protocol, but its Arduino
  // dispatcher cannot run in this host binary. Keep a runtime contract check
  // here so missing commands or readback fields fail before any hardware build.
  {
    const std::string source =
        readTextFile(firmwareSourcePath("serial_config.cpp")) +
        readTextFile(firmwareSourcePath("serial_config_protocol.h"));
    CHECK(source.find("CFGBRIGHT") != std::string::npos);
    CHECK(source.find("bllevel=") != std::string::npos);
    CHECK(source.find("FW_VERSION") != std::string::npos);
  }

  // --- serial brightness grammar and CFGSHOW extension
  {
    uint8_t level = 77;
    CHECK(serialcfg::parseBrightness("CFGBRIGHT 1", level));
    CHECK(level == 1);
    CHECK(serialcfg::parseBrightness("CFGBRIGHT 255", level));
    CHECK(level == 255);
    CHECK(serialcfg::parseBrightness("CFGBRIGHT 001", level));
    CHECK(level == 1);

    const char *invalid[] = {
        "CFGBRIGHT",       "CFGBRIGHT ",   "CFGBRIGHT 0",
        "CFGBRIGHT 256",   "CFGBRIGHT -1", "CFGBRIGHT +1",
        "CFGBRIGHT 1 ",    "CFGBRIGHT 1x", "CFGBRIGHT 0x10",
        "CFGBRIGHT 999999",
    };
    for (const char *line : invalid) {
      level = 77;
      CHECK(!serialcfg::parseBrightness(line, level));
      CHECK(level == 77);
    }
    CHECK(serialcfg::hasBrightnessVerb("CFGBRIGHT"));
    CHECK(serialcfg::hasBrightnessVerb("CFGBRIGHT 128"));
    CHECK(!serialcfg::hasBrightnessVerb("CFGPOWER 1"));

    char extension[64];
    CHECK(serialcfg::formatShowExtension(
              extension, sizeof(extension), deviceproto::CAP_ROTATE,
              128, "1.5.0") > 0);
    CHECK(strcmp(
              extension,
              " caps=00002000 bllevel=128 fw=1.5.0") == 0);
  }

  const Geometry G172 = GEOMETRY_172X320;

  // --- approved WiFi preset command surface ------------------------------
  {
    using namespace wifipresets;

    CHECK(commandKind("CFGWIFISET 1 VGVzdE5ldA== -") ==
          CommandKind::Set);
    CHECK(commandKind("CFGWIFICLEAR 10") == CommandKind::Clear);
    CHECK(commandKind("CFGWIFIUSE 2") == CommandKind::Use);
    CHECK(commandKind("CFGWIFISHOW") == CommandKind::ShowRoster);
    CHECK(commandKind("CFGWIFISHOW 7") == CommandKind::ShowSlot);
    CHECK(commandKind("CFGWIFI abc") == CommandKind::Unknown);
    CHECK(commandKind("CFGWIFISETX 1 VGVzdA== -") == CommandKind::Unknown);
    CHECK(commandKind(nullptr) == CommandKind::Unknown);

    ParsedCommand parsed =
        parseCommand("CFGWIFISET 10 VGVzdE5ldA== c3ludGhldGlj");
    CHECK(parsed.kind == CommandKind::Set);
    CHECK(parsed.error == CommandError::None);
    CHECK(parsed.slot == 10);
    CHECK(parsed.credentials.ssidLength == 7);
    CHECK(memcmp(parsed.credentials.ssid, "TestNet", 7) == 0);
    CHECK(parsed.credentials.passwordLength == 9);

    parsed = parseCommand("CFGWIFISET 1 VGVzdE5ldA== -");
    CHECK(parsed.error == CommandError::None);
    CHECK(parsed.credentials.passwordLength == 0);

    parsed = parseCommand("CFGWIFISET");
    CHECK(parsed.error == CommandError::ExpectedSet);
    parsed = parseCommand("CFGWIFISET 1 VGVzdE5ldA==");
    CHECK(parsed.error == CommandError::ExpectedSet);
    parsed = parseCommand("CFGWIFISET 1 VGVzdE5ldA== - extra");
    CHECK(parsed.error == CommandError::ExpectedSet);

    parsed = parseCommand("CFGWIFISET 0 VGVzdE5ldA== -");
    CHECK(parsed.error == CommandError::SlotOutOfRange);
    parsed = parseCommand("CFGWIFISET 11 VGVzdE5ldA== -");
    CHECK(parsed.error == CommandError::SlotOutOfRange);
    parsed = parseCommand("CFGWIFICLEAR 0");
    CHECK(parsed.error == CommandError::SlotOutOfRange);
    parsed = parseCommand("CFGWIFIUSE 11");
    CHECK(parsed.error == CommandError::SlotOutOfRange);
    parsed = parseCommand("CFGWIFISHOW nope");
    CHECK(parsed.error == CommandError::SlotOutOfRange);

    parsed = parseCommand("CFGWIFISET 1 !!!= -");
    CHECK(parsed.error == CommandError::BadBase64Ssid);
    parsed = parseCommand("CFGWIFISET 1 VGVzdE5ldA== !!!=");
    CHECK(parsed.error == CommandError::BadBase64Password);
    parsed = parseCommand("CFGWIFISET 1 VGVzdA -");
    CHECK(parsed.error == CommandError::BadBase64Ssid);
    parsed = parseCommand("CFGWIFISET 1 AB== -");
    CHECK(parsed.error == CommandError::BadBase64Ssid);

    parsed = parseCommand("CFGWIFISET 1 AA== -");
    CHECK(parsed.error == CommandError::SsidLengthOrNul);
    parsed = parseCommand("CFGWIFISET 1 VGVzdA== AA==");
    CHECK(parsed.error == CommandError::PasswordLengthOrNul);

    const std::string ssid33(44, 'Q');
    parsed = parseCommand(
        (std::string("CFGWIFISET 1 ") + ssid33 + " -").c_str());
    CHECK(parsed.error == CommandError::SsidLengthOrNul);
    const std::string password65 = std::string(87, 'Q') + "=";
    parsed = parseCommand(
        (std::string("CFGWIFISET 1 VGVzdA== ") + password65).c_str());
    CHECK(parsed.error == CommandError::PasswordLengthOrNul);

    const std::string maxSsid64 = std::string(43, 'Q') + "=";
    const std::string maxPassword64 = std::string(86, 'Q') + "==";
    const std::string maxCommand =
        "CFGWIFISET 10 " + maxSsid64 + " " + maxPassword64;
    CHECK(maxCommand.length() == 147);
    CHECK(255 - maxCommand.length() == 108);
    parsed = parseCommand(maxCommand.c_str());
    CHECK(parsed.error == CommandError::None);
    CHECK(parsed.credentials.ssidLength == 32);
    CHECK(parsed.credentials.passwordLength == 64);

    CHECK(slotMask(0) == 0);
    CHECK(slotMask(1) == 0x001);
    CHECK(slotMask(10) == 0x200);
    CHECK(slotMask(11) == 0);
    CHECK(slotMutationNeedsDirect(1, 1));
    CHECK(slotMutationNeedsDirect(10, 10));
    CHECK(!slotMutationNeedsDirect(1, 2));
    CHECK(!slotMutationNeedsDirect(ACTIVE_DIRECT, 1));
    uint8_t slots[10] = {};
    CHECK(orderedSlots(0x225, slots, 10) == 4);
    CHECK(slots[0] == 1 && slots[1] == 3 && slots[2] == 6 &&
          slots[3] == 10);
    CHECK(orderedSlots(0x3FF, slots, 3) == 10);
    CHECK(slots[0] == 1 && slots[1] == 2 && slots[2] == 3);

    CHECK(strcmp(commandErrorText(CommandError::ExpectedSet),
                 "CFGERR expected: CFGWIFISET <1-10> <base64 ssid> <base64 "
                 "password|->") == 0);
    CHECK(strcmp(commandErrorText(CommandError::SlotOutOfRange),
                 "CFGERR wifi slot out of range (1-10)") == 0);
    CHECK(strcmp(commandErrorText(CommandError::BadBase64Ssid),
                 "CFGERR bad base64 ssid") == 0);
    CHECK(strcmp(commandErrorText(CommandError::BadBase64Password),
                 "CFGERR bad base64 password") == 0);
    CHECK(strcmp(commandErrorText(CommandError::SsidLengthOrNul),
                 "CFGERR ssid must be 1..32 bytes and contain no 0x00") == 0);
    CHECK(strcmp(commandErrorText(CommandError::PasswordLengthOrNul),
                 "CFGERR password must be 0..64 bytes and contain no 0x00") ==
          0);
    CHECK(commandErrorText(CommandError::None) == nullptr);

    char reply[192] = {};
    CHECK(formatSavedReply(reply, sizeof(reply), 10, 32, true, 0));
    CHECK(strcmp(reply,
                 "CFGOK wifi slot=10 saved ssid_bytes=32 pass=set "
                 "active=direct") == 0);
    CHECK(formatSavedReply(reply, sizeof(reply), 2, 7, false, 9));
    CHECK(strcmp(reply,
                 "CFGOK wifi slot=2 saved ssid_bytes=7 pass=open active=9") ==
          0);
    CHECK(formatClearedReply(reply, sizeof(reply), 3, 0));
    CHECK(strcmp(reply, "CFGOK wifi slot=3 cleared active=direct") == 0);
    CHECK(formatClearedReply(reply, sizeof(reply), 3, 8));
    CHECK(strcmp(reply, "CFGOK wifi slot=3 cleared active=8") == 0);
    CHECK(formatSelectedReply(reply, sizeof(reply), 10));
    CHECK(strcmp(reply, "CFGOK wifi slot=10 selected, restarting") == 0);
    CHECK(formatRosterReply(reply, sizeof(reply), 0x225, 0, true));
    CHECK(strcmp(reply,
                 "CFGINFO wifi capacity=10 valid=0x225 active=direct "
                 "mode=direct local=1") == 0);
    CHECK(formatRosterReply(reply, sizeof(reply), 0x3FF, 10, false));
    CHECK(strcmp(reply,
                 "CFGINFO wifi capacity=10 valid=0x3ff active=10 mode=preset "
                 "local=0") == 0);
    CHECK(formatValidSlotReply(reply, sizeof(reply), 4, true, "VGVzdA==",
                               false));
    CHECK(strcmp(reply,
                 "CFGINFO wifi slot=4 valid=1 active=1 ssid64=VGVzdA== "
                 "pass=open") == 0);
    CHECK(formatInvalidSlotReply(reply, sizeof(reply), 6));
    CHECK(strcmp(reply, "CFGINFO wifi slot=6 valid=0 active=0") == 0);
    CHECK(formatUnavailableReply(reply, sizeof(reply), 7));
    CHECK(strcmp(reply, "CFGERR wifi slot=7 unavailable") == 0);
    CHECK(formatSaveFailedReply(reply, sizeof(reply), 7));
    CHECK(strcmp(reply, "CFGERR wifi slot=7 save failed") == 0);
    CHECK(!formatRosterReply(reply, 8, 0, 0, true));
  }

  // --- on-device WiFi selector model -------------------------------------
  {
    using namespace wifiselector;
    const std::string touchSource =
        readTextFile(firmwareSourcePath("input_touch.cpp"));
    CHECK(touchSource.find(
              "handleWifiSelectorTap(event.startX, event.startY)") !=
          std::string::npos);

    const Rect surveyButton = surveyPresetButton(360, 360, true);
    CHECK(surveyButton.x == 56);
    CHECK(surveyButton.y == 264);
    CHECK(surveyButton.width == 248);
    CHECK(surveyButton.height == 40);
    CHECK(surveyButton.contains(180, 284));
    CHECK(!surveyButton.contains(180, 263));

    const SelectorLayout roundLayout =
        selectorLayout(360, 360, true, 10, 5);
    CHECK(roundLayout.visibleCount == 3);
    CHECK(roundLayout.firstVisible == 4);
    CHECK(roundLayout.back.contains(80, 70));
    CHECK(roundLayout.previous.contains(80, 284));
    CHECK(roundLayout.next.contains(145, 284));
    CHECK(roundLayout.connect.contains(245, 284));
    CHECK(selectorHitTest(roundLayout, 10, 80, 70).target ==
          HitTarget::Back);
    CHECK(selectorHitTest(roundLayout, 10, 80, 284).target ==
          HitTarget::Previous);
    CHECK(selectorHitTest(roundLayout, 10, 145, 284).target ==
          HitTarget::Next);
    CHECK(selectorHitTest(roundLayout, 10, 245, 284).target ==
          HitTarget::Connect);
    const Rect firstRow = roundLayout.rowRect(0);
    const Hit firstRowHit = selectorHitTest(
        roundLayout, 10, firstRow.x + 5, firstRow.y + firstRow.height / 2);
    CHECK(firstRowHit.target == HitTarget::Row);
    CHECK(firstRowHit.rowIndex == 4);
    CHECK(selectorHitTest(roundLayout, 10, 180, 100).target ==
          HitTarget::None);

    const SelectorLayout narrowLayout =
        selectorLayout(172, 320, false, 10, 9);
    CHECK(narrowLayout.visibleCount == 5);
    CHECK(narrowLayout.firstVisible == 5);
    CHECK(narrowLayout.rowRect(4).y + narrowLayout.rowRect(4).height <=
          narrowLayout.previous.y);

    const SelectorLayout landscapeLayout =
        selectorLayout(320, 172, false, 10, 9);
    CHECK(landscapeLayout.visibleCount == 4);
    CHECK(landscapeLayout.firstVisible == 6);
    CHECK(landscapeLayout.rowRect(3).y +
              landscapeLayout.rowRect(3).height <=
          landscapeLayout.previous.y);

    const SelectorLayout largeLayout =
        selectorLayout(466, 466, true, 10, 9);
    CHECK(largeLayout.visibleCount == 4);
    CHECK(largeLayout.firstVisible == 6);
    CHECK(largeLayout.rowRect(3).y + largeLayout.rowRect(3).height <=
          largeLayout.previous.y);

    const Rect tinySurveyButton = surveyPresetButton(128, 128, false);
    const SelectorLayout tinyLayout =
        selectorLayout(128, 128, false, 10, 9);
    CHECK(tinySurveyButton.y == 100);
    CHECK(tinyLayout.visibleCount == 2);
    CHECK(tinyLayout.rowRect(1).y + tinyLayout.rowRect(1).height <=
          tinyLayout.previous.y);

    const uint8_t slots[] = {2, 5, 10};
    CHECK(initialIndex(slots, 3, 5) == 1);
    CHECK(initialIndex(slots, 3, 7) == 0);
    CHECK(initialIndex(nullptr, 0, 5) == 0);
    CHECK(movedIndex(0, 3, 1) == 1);
    CHECK(movedIndex(2, 3, 1) == 0);
    CHECK(movedIndex(0, 3, -1) == 2);
    CHECK(movedIndex(1, 3, 0) == 1);
    CHECK(movedIndex(9, 0, 1) == 0);
    CHECK(windowStart(0, 10, 8) == 0);
    CHECK(windowStart(5, 10, 8) == 1);
    CHECK(windowStart(9, 10, 8) == 2);
    CHECK(windowStart(2, 3, 8) == 0);
    CHECK(windowStart(2, 3, 0) == 0);

    wifipresets::Credentials credentials;
    const uint8_t ssid[] = {'L', 'a', 'b', 0xC3, 0xA9, ' ', 'W', 'i',
                            'F', 'i'};
    memcpy(credentials.ssid, ssid, sizeof(ssid));
    credentials.ssidLength = sizeof(ssid);
    char label[16];
    CHECK(displaySsid(credentials, label, sizeof(label)) == sizeof(ssid));
    CHECK(strcmp(label, "Lab?? WiFi") == 0);
    char clipped[7];
    CHECK(displaySsid(credentials, clipped, sizeof(clipped)) == 6);
    CHECK(strcmp(clipped, "Lab...") == 0);
    CHECK(displaySsid(credentials, nullptr, 0) == 0);
  }

  // --- BOOT short/double-press effects -----------------------------------
  {
    using namespace buttonpress;
    DoublePressTracker tracker;
    bool high = true;
    bool originalHigh = high;
    int commits = 0;
    int doubles = 0;
    auto apply = [&](const ShortPressDecision &decision) {
      for (uint8_t i = 0; i < decision.count; ++i) {
        switch (decision.effects[i]) {
          case ShortPressEffect::Preview:
            originalHigh = high;
            high = !high;
            break;
          case ShortPressEffect::Commit:
            commits++;
            break;
          case ShortPressEffect::Revert:
            high = originalHigh;
            break;
          case ShortPressEffect::Double:
            doubles++;
            break;
        }
      }
    };

    apply(tracker.record(100, 800, true));
    apply(tracker.record(900, 800, true));
    CHECK(commits == 0);
    CHECK(high);
    CHECK(doubles == 1);

    apply(tracker.record(1000, 800, true));
    apply(tracker.resolve(1800, 800));
    CHECK(commits == 0);
    apply(tracker.resolve(1801, 800));
    CHECK(commits == 1);
    CHECK(!high);

    tracker.flush();
    high = true;
    originalHigh = high;
    commits = 0;
    doubles = 0;
    apply(tracker.record(UINT32_MAX - 100, 800, true));
    apply(tracker.record(50, 800, true));
    CHECK(commits == 0);
    CHECK(high);
    CHECK(doubles == 1);

    tracker.flush();
    high = true;
    originalHigh = high;
    commits = 0;
    doubles = 0;
    apply(tracker.record(2000, 800, false));
    apply(tracker.record(2100, 800, false));
    CHECK(commits == 0);
    CHECK(high);
    CHECK(doubles == 1);

    tracker.flush();
    high = true;
    originalHigh = high;
    commits = 0;
    doubles = 0;
    apply(tracker.record(3000, 800, true));
    apply(tracker.record(3801, 800, true));
    CHECK(commits == 1);
    CHECK(high);
    CHECK(doubles == 0);
    apply(tracker.flush());
    CHECK(commits == 2);
  }

  // --- WiFi preset records are whole, versioned, and corruption-checked ----
  {
    using namespace wifipresets;
    Credentials credentials = {};
    const uint8_t ssid[] = {'L', 'a', 'b', 0xC3, 0xA9};
    const uint8_t password[] = {0x01, 0x7F, 0x80, 0xFF};
    credentials.ssidLength = sizeof(ssid);
    credentials.passwordLength = sizeof(password);
    memcpy(credentials.ssid, ssid, sizeof(ssid));
    memcpy(credentials.password, password, sizeof(password));

    uint8_t record[RECORD_MAX_BYTES] = {};
    const size_t recordLength =
        encodeRecord(credentials, record, sizeof(record));
    CHECK(recordLength == 16);
    CHECK(crc32((const uint8_t *)"123456789", 9) == 0xCBF43926u);
    CHECK(record[0] == RECORD_VERSION);
    CHECK(record[1] == sizeof(ssid));
    CHECK(record[2] == sizeof(password));
    CHECK(readU32Le(record + recordLength - RECORD_CRC_BYTES) ==
          crc32(record, recordLength - RECORD_CRC_BYTES));

    Credentials decoded = {};
    CHECK(decodeRecord(record, recordLength, decoded) == RecordStatus::Valid);
    CHECK(decoded.ssidLength == sizeof(ssid));
    CHECK(decoded.passwordLength == sizeof(password));
    CHECK(memcmp(decoded.ssid, ssid, sizeof(ssid)) == 0);
    CHECK(memcmp(decoded.password, password, sizeof(password)) == 0);

    for (size_t length = 0; length < recordLength; ++length) {
      Credentials untouched = {};
      untouched.ssidLength = 9;
      CHECK(decodeRecord(record, length, untouched) != RecordStatus::Valid);
      CHECK(untouched.ssidLength == 9);
    }

    uint8_t hostile[RECORD_MAX_BYTES] = {};
    memcpy(hostile, record, recordLength);
    hostile[0] = RECORD_VERSION + 1;
    CHECK(decodeRecord(hostile, recordLength, decoded) ==
          RecordStatus::Version);

    memcpy(hostile, record, recordLength);
    hostile[3] ^= 0x01;
    CHECK(decodeRecord(hostile, recordLength, decoded) == RecordStatus::Crc);

    memcpy(hostile, record, recordLength);
    hostile[1] = (uint8_t)(sizeof(ssid) + 1);
    CHECK(decodeRecord(hostile, recordLength, decoded) == RecordStatus::Length);

    memcpy(hostile, record, recordLength);
    hostile[2] = (uint8_t)(sizeof(password) + 1);
    CHECK(decodeRecord(hostile, recordLength, decoded) == RecordStatus::Length);

    memcpy(hostile, record, recordLength);
    hostile[3] = 0;
    writeU32Le(hostile + recordLength - RECORD_CRC_BYTES,
               crc32(hostile, recordLength - RECORD_CRC_BYTES));
    CHECK(decodeRecord(hostile, recordLength, decoded) ==
          RecordStatus::Credential);

    // Length fields claim 96 payload bytes while the blob only contains one.
    const uint8_t impossible[] = {RECORD_VERSION, 32, 64, 'x', 0, 0, 0, 0};
    CHECK(decodeRecord(impossible, sizeof(impossible), decoded) ==
          RecordStatus::Length);

    Credentials maximum = {};
    maximum.ssidLength = SSID_MAX_BYTES;
    maximum.passwordLength = PASSWORD_MAX_BYTES;
    memset(maximum.ssid, 'S', maximum.ssidLength);
    memset(maximum.password, 'P', maximum.passwordLength);
    CHECK(encodeRecord(maximum, record, sizeof(record)) == RECORD_MAX_BYTES);
    CHECK(decodeRecord(record, sizeof(record), decoded) == RecordStatus::Valid);

    maximum.ssid[31] = 0;
    CHECK(encodeRecord(maximum, record, sizeof(record)) == 0);
    maximum.ssid[31] = 'S';
    maximum.password[63] = 0;
    CHECK(encodeRecord(maximum, record, sizeof(record)) == 0);
    CHECK(encodeRecord(credentials, nullptr, sizeof(record)) == 0);
    CHECK(encodeRecord(credentials, record, recordLength - 1) == 0);
    CHECK(decodeRecord(nullptr, recordLength, decoded) == RecordStatus::Length);
  }

  // --- active selection fails closed and mirroring only writes differences --
  {
    using namespace wifipresets;
    CHECK(effectiveOrigin(3, true, true) == EffectiveOrigin::Preset);
    CHECK(effectiveOrigin(3, false, true) == EffectiveOrigin::Legacy);
    CHECK(effectiveOrigin(3, false, false) == EffectiveOrigin::Compiled);
    CHECK(effectiveOrigin(0, true, true) == EffectiveOrigin::Legacy);
    CHECK(effectiveOrigin(11, true, false) == EffectiveOrigin::Compiled);
    CHECK(effectiveOrigin(ACTIVE_DIRECT, true, true) ==
          EffectiveOrigin::Legacy);
    CHECK(effectiveActiveSlot(7, true) == 7);
    CHECK(effectiveActiveSlot(7, false) == 0);
    CHECK(effectiveActiveSlot(ACTIVE_DIRECT, true) == 0);

    Credentials credentials = {};
    memcpy(credentials.ssid, "Lab", 3);
    credentials.ssidLength = 3;
    memcpy(credentials.password, "synthetic", 9);
    credentials.passwordLength = 9;
    CHECK(!mirrorNeeded(credentials, credentials.ssid, credentials.ssidLength,
                        credentials.password, credentials.passwordLength));
    CHECK(mirrorNeeded(credentials, (const uint8_t *)"Old", 3,
                       credentials.password, credentials.passwordLength));
    CHECK(mirrorNeeded(credentials, credentials.ssid, credentials.ssidLength,
                       nullptr, 0));
  }

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

    // A fixed installation level suppresses idle dimming and touch-wake
    // variation, but host sleep and explicit power-off still go dark.
    CHECK(panelstate::backlightLevel(false, false, false, false,
                                     128, 10, 255) == 255);
    CHECK(panelstate::backlightLevel(false, false, true, false,
                                     128, 10, 255) == 255);
    CHECK(panelstate::backlightLevel(false, true, false, true,
                                     128, 10, 255) == 0);
    CHECK(panelstate::backlightLevel(true, false, false, true,
                                     128, 10, 255) == 0);

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

  // --- idle card battery line TEXT: the full charge word, not just "chg" ---
  // Before this the on-device card only ever said "batt NN%" or "batt NN%
  // chg" - Discharging and Standby were indistinguishable on the glass, even
  // though the wire protocol and the Mac app have always carried all three
  // states. formatBatteryLine is what the card's text now goes through.
  {
    char buf[24];

    // On USB power with no cell: reported plainly, before percent/charge is
    // even consulted.
    panelstate::formatBatteryLine(buf, sizeof(buf), true, false, false, 0,
                                  panelstate::Charge::Unknown);
    CHECK(strcmp(buf, "usb power") == 0);

    // A battery present and charging: the word is "charging", not "chg".
    panelstate::formatBatteryLine(buf, sizeof(buf), true, true, true, 84,
                                  panelstate::Charge::Charging);
    CHECK(strcmp(buf, "batt 84% charging") == 0);

    // Discharging (on battery, no USB): this is the state the old "chg or
    // nothing" line could never say.
    panelstate::formatBatteryLine(buf, sizeof(buf), false, true, true, 61,
                                  panelstate::Charge::Discharging);
    CHECK(strcmp(buf, "batt 61% discharging") == 0);

    // Standby (full and on USB, not actively charging): the other state the
    // old line collapsed into a bare percentage indistinguishable from
    // discharging.
    panelstate::formatBatteryLine(buf, sizeof(buf), true, true, true, 100,
                                  panelstate::Charge::Standby);
    CHECK(strcmp(buf, "batt 100% standby") == 0);

    // Unknown charge state still says its word rather than nothing.
    panelstate::formatBatteryLine(buf, sizeof(buf), false, true, true, 50,
                                  panelstate::Charge::Unknown);
    CHECK(strcmp(buf, "batt 50% unknown") == 0);

    // Present but the gauge has not settled: "batt --", same as before -
    // there is no charge word worth printing next to a percentage that does
    // not exist.
    panelstate::formatBatteryLine(buf, sizeof(buf), false, true, false, 0,
                                  panelstate::Charge::Charging);
    CHECK(strcmp(buf, "batt --") == 0);

    // chargeWord() is what both formatBatteryLine and the serial line's
    // batteryChargeWord() go through - pinned here so the two callers cannot
    // silently diverge on what a charge state is called.
    CHECK(strcmp(panelstate::chargeWord(panelstate::Charge::Charging),
                "charging") == 0);
    CHECK(strcmp(panelstate::chargeWord(panelstate::Charge::Discharging),
                "discharging") == 0);
    CHECK(strcmp(panelstate::chargeWord(panelstate::Charge::Standby),
                "standby") == 0);
    CHECK(strcmp(panelstate::chargeWord(panelstate::Charge::Unknown),
                "unknown") == 0);
  }

  // --- quick info bar: pure arithmetic behind the tap-triggered top bar ----
  // The bar itself (drawing, DMA, redraw-on-overlap) needs a panel and cannot
  // be host-tested; what is pure here is the row-range math, the overlap
  // test that decides whether a streaming redraw must include the bar, and
  // horizontal centring - exactly the kind of arithmetic most likely to be
  // off by one and least likely to be caught by eye on real glass.
  {
    // Rectangular panel (172x320): plain 4px top margin, no round-glass
    // inset.
    int y0 = -1, y1 = -1;
    panelstate::infoBarRowRange(172, 320, false, 9, y0, y1);
    CHECK(y0 == 4 && y1 == 13);

    // Round panel (466x466): the same 14.65%-of-diameter inset the idle card
    // uses, so the bar's ends are not clipped by the bezel.
    panelstate::infoBarRowRange(466, 466, true, 9, y0, y1);
    CHECK(y0 == 4 + (int)(0.1465f * 466.0f));
    CHECK(y1 == y0 + 9);

    // A bar taller than the frame clamps its bottom edge rather than running
    // off the buffer.
    panelstate::infoBarRowRange(172, 10, false, 9, y0, y1);
    CHECK(y0 == 4);
    CHECK(y1 == 10);  // clamped to frameHeight, not 4+9=13

    // Overlap: touching ranges overlap, adjacent (touching-but-not-crossing)
    // ranges do not - the half-open interval convention every band offset in
    // this codebase already uses.
    CHECK(panelstate::rowRangeOverlaps(0, 10, 5, 15));   // straddles
    CHECK(panelstate::rowRangeOverlaps(0, 10, 0, 10));   // identical
    CHECK(panelstate::rowRangeOverlaps(5, 15, 0, 10));   // straddles, swapped args
    CHECK(!panelstate::rowRangeOverlaps(0, 10, 10, 20));  // touching, not overlapping
    CHECK(!panelstate::rowRangeOverlaps(10, 20, 0, 10));  // touching, swapped
    CHECK(!panelstate::rowRangeOverlaps(0, 5, 10, 15));   // disjoint

    // Centring: even and odd leftover space, and the never-negative clamp
    // for a string wider than its container.
    CHECK(panelstate::centeredX(100, 20) == 40);
    CHECK(panelstate::centeredX(101, 20) == 40);  // odd leftover floors down
    CHECK(panelstate::centeredX(20, 100) == 0);   // wider than container: flush left
    CHECK(panelstate::centeredX(50, 50) == 0);    // exact fit
  }

  // --- millisSince: the underflow fix behind "sender silent 4294967s" -----
  // The bug this guards: a plain `now - last` on a volatile written by a
  // different task can see `last` momentarily newer than an already-
  // captured `now`, wrapping a uint32_t subtraction to roughly UINT32_MAX.
  // That corrupted "silence" duration is what flashed the idle screensaver
  // on and off under load - see millisSince's doc comment in panel_state.h.
  {
    // Ordinary case: last strictly before now, behaves like plain subtraction.
    CHECK(panelstate::millisSince(1000, 400) == 600);
    CHECK(panelstate::millisSince(1000, 1000) == 0);  // simultaneous: zero, not wraparound

    // The race itself: last a few ms AHEAD of now. A plain `now - last`
    // would wrap to roughly UINT32_MAX; this clamps to zero instead of
    // reporting billions of seconds of "silence" mid-stream.
    CHECK(panelstate::millisSince(1000, 1005) == 0);
    CHECK(panelstate::millisSince(0, 1) == 0);

    // millis() wraparound (real, not the race): after ~49.7 days millis()
    // itself wraps from UINT32_MAX to 0. now=5 just after the wrap and
    // last=0xFFFFFFF0 (21ms before it) is a genuine 21ms gap spanning the
    // wraparound, and plain unsigned subtraction already gets this right by
    // construction (5 - 0xFFFFFFF0 wraps back around to 21) - this is
    // exactly why the cast checks int32_t sign rather than comparing now and
    // last directly, which would misclassify this legitimate case as the
    // race and clamp a real small gap to zero.
    CHECK(panelstate::millisSince(5, 0xFFFFFFF0u) == 21);

    // A large but legitimate gap (near the SENDER_GONE_MS threshold and
    // beyond) is reported exactly, not clamped - only last > now clamps.
    CHECK(panelstate::millisSince(100000, 50000) == 50000);
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
    // A prism reflection changes framebuffer handedness. On odd quadrants the
    // axes are swapped, so visible left/right moves from MADCTL MX to MY.
    CHECK(mirrorX(0, true) && !panelorient::mirrorY(0, true));
    CHECK(mirrorX(1, true) && panelorient::mirrorY(1, true));
    CHECK(!mirrorX(2, true) && panelorient::mirrorY(2, true));
    CHECK(!mirrorX(3, true) && !panelorient::mirrorY(3, true));
    for (uint8_t q = 0; q < 4; q++) {
      CHECK(mirrorX(q, false) == mirrorX(q));
      CHECK(panelorient::mirrorY(q, false) == mirrorY(q));
    }
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
    CHECK(board::configFor(Variant::Unknown).panel->driver == board::PanelDriver::Jd9853);

    // ...but resolve() must never disturb a verdict we do have.
    CHECK(board::resolve(Variant::LcdSt7789) == Variant::LcdSt7789);
    CHECK(board::resolve(Variant::TouchJd9853) == Variant::TouchJd9853);

    const board::Config &st = board::configFor(Variant::LcdSt7789);
    const board::Config &jd = board::configFor(Variant::TouchJd9853);
    CHECK(st.variant == Variant::LcdSt7789);
    CHECK(jd.variant == Variant::TouchJd9853);
    CHECK(st.panel->driver == board::PanelDriver::St7789);
    CHECK(jd.panel->driver == board::PanelDriver::Jd9853);

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
    CHECK(st.panel->colOffset == 34 && jd.panel->colOffset == 34);
    CHECK(st.panel->invertColor && jd.panel->invertColor);

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
    CHECK(board::variantFromName(board::variantToken(Variant::LcdSt77916)) ==
          Variant::LcdSt77916);
    CHECK(board::variantFromName(board::variantToken(Variant::TouchSt7789)) ==
          Variant::TouchSt7789);
    CHECK(strcmp(board::variantToken(Variant::Unknown), "auto") == 0);

    // Firmware-family identity is deliberately separate from the chip token
    // and physical profile. Every S3 profile reports the same family artifact.
    CHECK(strcmp(board::targetToken(Variant::LcdSt7789), "c6") == 0);
    CHECK(strcmp(board::targetToken(Variant::TouchJd9853), "c6") == 0);
    CHECK(strcmp(board::targetToken(Variant::AmoledCo5300), "s3") == 0);
    CHECK(strcmp(board::targetToken(Variant::LcdSt77916), "s3") == 0);
    CHECK(strcmp(board::targetToken(Variant::LcdGc9107), "s3") == 0);
    CHECK(strcmp(board::targetToken(Variant::TouchSt7789), "s3") == 0);
    CHECK(strcmp(board::targetToken(Variant::Unknown), "unknown") == 0);
    CHECK(strcmp(board::targetToken(Variant::AmoledCo5300),
                 board::targetToken(Variant::LcdSt77916)) == 0);

    // Runtime S3 detection requires exactly one compatible candidate.
    CHECK(board::variantFromS3Probe(8u * 1024u * 1024u, false, false,
                                    false, false) == Variant::LcdGc9107);
    CHECK(board::variantFromS3Probe(16u * 1024u * 1024u, true, false,
                                    false, false) == Variant::AmoledCo5300);
    CHECK(board::variantFromS3Probe(16u * 1024u * 1024u, false, true,
                                    false, false) == Variant::LcdSt77916);
    CHECK(board::variantFromS3Probe(16u * 1024u * 1024u, false, false,
                                    true, false) == Variant::TouchSt7789);
    CHECK(board::variantFromS3Probe(16u * 1024u * 1024u, false, false,
                                    false, false) == Variant::Unknown);
    CHECK(board::variantFromS3Probe(16u * 1024u * 1024u, true, true,
                                    false, false) == Variant::Unknown);
    CHECK(board::variantMatchesPlatform(
        Variant::AmoledCo5300, board::Platform::Esp32S3));
    CHECK(!board::variantMatchesPlatform(
        Variant::TouchJd9853, board::Platform::Esp32S3));

    // Host tests compile without an IDF target, which is the C6 path: the
    // variant is Unknown until the boot probe says otherwise.
    CHECK(board::COMPILED_VARIANT == Variant::Unknown);

    // The C6 boards on the new per-board fields: single-lane SPI with a D/C
    // line and a PWM backlight, 172x320, 80MHz - the pre-AMOLED world exactly.
    for (const board::Config *c : {&st, &jd}) {
      CHECK(c->panel->bus == board::PanelBus::Spi);
      CHECK(!c->isQspi());
      CHECK(c->panel->width == 172 && c->panel->height == 320);
      CHECK(c->panel->pixelClockHz == 80 * 1000 * 1000);
      CHECK(c->panel->spiMode == 0);
      CHECK(c->pinData1 == board::NO_PIN && c->pinData2 == board::NO_PIN &&
            c->pinData3 == board::NO_PIN);
      CHECK(c->pinDc != board::NO_PIN);
      CHECK(c->hasBacklightPin());
    }
    CHECK(st.touch == board::TouchController::None);
    CHECK(st.pinTouchSda == board::NO_PIN && st.pinTouchScl == board::NO_PIN);
    CHECK(jd.touch == board::TouchController::Axs5106l);
    // The plain C6 has no battery or motion source. The touch C6 exposes its
    // cell through a 3:1 divider on GPIO0 and carries a QMI8658 on the shared
    // I2C bus.
    CHECK(st.power == board::PowerController::None);
    CHECK(st.pinBatteryAdc == board::NO_PIN);
    CHECK(st.batteryAdcScale == 0);
    CHECK(!st.hasBattery());
    CHECK(st.motion == board::MotionController::None);
    CHECK(!st.hasMotion());

    CHECK(jd.power == board::PowerController::BatteryAdc);
    CHECK(jd.pinBatteryAdc == 0);
    CHECK(jd.batteryAdcScale == 3);
    CHECK(jd.hasBattery());
    CHECK(jd.motion == board::MotionController::Qmi8658);
    CHECK(jd.motionXAxis == 0 && jd.motionXSign == 1);
    CHECK(jd.motionYAxis == 1 && jd.motionYSign == 1);
    CHECK(jd.hasMotion());

    // Capability predicates must reject incomplete table rows rather than
    // advertise hardware whose pins or calibration cannot be used.
    board::Config invalid = jd;
    invalid.pinBatteryAdc = board::NO_PIN;
    CHECK(!invalid.hasBattery());
    invalid = jd;
    invalid.batteryAdcScale = 0;
    CHECK(!invalid.hasBattery());
    invalid = jd;
    invalid.motion = board::MotionController::None;
    CHECK(!invalid.hasMotion());
    invalid = jd;
    invalid.pinTouchSda = board::NO_PIN;
    CHECK(!invalid.hasMotion());
    invalid = jd;
    invalid.pinTouchScl = board::NO_PIN;
    CHECK(!invalid.hasMotion());
    invalid = jd;
    invalid.motionXAxis = 3;
    CHECK(!invalid.hasMotion());
    invalid = jd;
    invalid.motionYAxis = 3;
    CHECK(!invalid.hasMotion());
    invalid = jd;
    invalid.motionYAxis = invalid.motionXAxis;
    CHECK(!invalid.hasMotion());
    invalid = jd;
    invalid.motionXSign = 0;
    CHECK(!invalid.hasMotion());
    invalid = jd;
    invalid.motionXSign = 2;
    CHECK(!invalid.hasMotion());
    invalid = jd;
    invalid.motionYSign = 0;
    CHECK(!invalid.hasMotion());
    invalid = jd;
    invalid.motionYSign = -2;
    CHECK(!invalid.hasMotion());
    // Touch rides the shared detection bus on the C6 Touch board.
    CHECK(jd.pinTouchSda == board::PIN_PROBE_SDA);
    CHECK(jd.pinTouchScl == board::PIN_PROBE_SCL);
  }

  // --- the S3 AMOLED board entry -------------------------------------------
  {
    using board::Variant;
    const board::Config &am = board::configFor(Variant::AmoledCo5300);

    CHECK(am.variant == Variant::AmoledCo5300);
    CHECK(am.panel->driver == board::PanelDriver::Co5300);
    CHECK(am.panel->bus == board::PanelBus::Qspi);
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

    CHECK(am.panel->width == 466 && am.panel->height == 466);
    CHECK(am.panel->pixelClockHz == 40 * 1000 * 1000);
    CHECK(am.panel->colOffset == 6);
    CHECK(!am.panel->invertColor);
    CHECK(!am.hasRgbLed());

    // Round glass: the idle card must keep inside the inscribed square. The
    // C6 panels are rectangular and keep their full-frame placement.
    CHECK(am.panel->roundDisplay);
    CHECK(!board::configFor(Variant::LcdSt7789).panel->roundDisplay);
    CHECK(!board::configFor(Variant::TouchJd9853).panel->roundDisplay);

    // CST9217 on its own I2C bus; reset shared with the panel, so touch
    // bring-up must never pulse it independently.
    CHECK(am.touch == board::TouchController::Cst9217);
    CHECK(am.hasTouch());
    CHECK(am.pinTouchSda == 15 && am.pinTouchScl == 14);
    CHECK(am.pinTouchInt == 11);
    CHECK(am.pinTouchRst == am.pinRst);

    CHECK(sizeof(board::S3_CO5300_PROBE_ADDRESSES) == 4);
    CHECK(board::S3_CO5300_PROBE_ADDRESSES[0] == 0x5A);
    CHECK(board::S3_CO5300_PROBE_ADDRESSES[1] == 0x34);
    CHECK(board::S3_CO5300_PROBE_ADDRESSES[2] == 0x6A);
    CHECK(board::S3_CO5300_PROBE_ADDRESSES[3] == 0x6B);
    CHECK(sizeof(board::S3_ST77916_PROBE_ADDRESSES) == 2);
    CHECK(board::S3_ST77916_PROBE_ADDRESSES[0] == 0x15);
    CHECK(board::S3_ST77916_PROBE_ADDRESSES[1] == 0x20);
    CHECK(sizeof(board::S3_ST7789_154_PROBE_ADDRESSES) == 3);
    CHECK(board::S3_ST7789_154_PROBE_ADDRESSES[0] == 0x15);
    CHECK(board::S3_ST7789_154_PROBE_ADDRESSES[1] == 0x6A);
    CHECK(board::S3_ST7789_154_PROBE_ADDRESSES[2] == 0x6B);

    // AXP2101 PMU: shares the touch I2C bus. The touch C6 also has battery
    // telemetry, but through its GPIO0 divider rather than this PMU path.
    CHECK(am.power == board::PowerController::Axp2101);
    CHECK(am.pinBatteryAdc == board::NO_PIN);
    CHECK(am.batteryAdcScale == 0);
    CHECK(am.hasBattery());
    CHECK(am.pinTouchSda != board::NO_PIN && am.pinTouchScl != board::NO_PIN);
    CHECK(am.motion == board::MotionController::Qmi8658);
    CHECK(am.motionXAxis == 1 && am.motionXSign == -1);
    // The field calibration keeps the proven swapped in-plane axes and negates
    // both signs to correct the observed 180-degree room-frame error.
    CHECK(am.motionYAxis == 0 && am.motionYSign == 1);
    CHECK(am.hasMotion());
    // Captured during the first half of the continuous diagnostics run while
    // the user held the board vertical with the cable hanging down. The user
    // confirmed by eye that the old mapping held the picture top at 6 o'clock;
    // the corrected calibration shifts that pose's automatic correction by 2.
    const int16_t confirmedCo5300CableDown[3] = {1759, 8396, -644};
    const motionorient::Calibration co5300Calibration = {
        am.motionXAxis, am.motionXSign, am.motionYAxis, am.motionYSign};
    CHECK(motionorient::classify(
              confirmedCo5300CableDown, co5300Calibration, 0,
              motionorient::AutomaticMode::FourWay) == 1);
    // Captured at the midpoint of the same run after the user turned the board
    // one quarter turn clockwise. The user confirmed by eye that the corrected
    // mapping keeps the picture top at 12 o'clock in this pose as well.
    const int16_t confirmedCo5300Clockwise[3] = {1556, -7683, -716};
    CHECK(motionorient::classify(
              confirmedCo5300Clockwise, co5300Calibration, 0,
              motionorient::AutomaticMode::FourWay) == 3);
    CHECK(!board::configFor(Variant::LcdSt7789).hasBattery());
    CHECK(board::configFor(Variant::TouchJd9853).hasBattery());

    board::Config invalid = am;
    invalid.pinTouchSda = board::NO_PIN;
    CHECK(!invalid.hasBattery());
    invalid = am;
    invalid.pinTouchScl = board::NO_PIN;
    CHECK(!invalid.hasBattery());

    // The panel dimensions in the table produce a carryable band geometry -
    // the link between the board table and the wire format.
    const Geometry g = {am.panel->width, am.panel->height};
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

  // --- the S3 1.85-inch LCD board entry -----------------------------------
  {
    using board::Variant;
    const board::Config &lcd = board::configFor(Variant::LcdSt77916);

    CHECK(lcd.variant == Variant::LcdSt77916);
    CHECK(lcd.panel->driver == board::PanelDriver::St77916);
    CHECK(lcd.panel->bus == board::PanelBus::Qspi);
    CHECK(lcd.isQspi());
    CHECK(lcd.panel->width == 360 && lcd.panel->height == 360);
    CHECK(lcd.panel->pixelClockHz == 80 * 1000 * 1000);
    CHECK(lcd.pinSclk == 40);
    CHECK(lcd.pinMosi == 46);
    CHECK(lcd.pinData1 == 45 && lcd.pinData2 == 42 && lcd.pinData3 == 41);
    CHECK(lcd.pinCs == 21 && lcd.pinDc == board::NO_PIN);
    CHECK(lcd.pinRst == board::NO_PIN && lcd.panelResetExio == 2);
    CHECK(lcd.pinBl == 5 && lcd.hasBacklightPin());
    CHECK(lcd.touch == board::TouchController::Cst816);
    CHECK(lcd.pinTouchSda == 11 && lcd.pinTouchScl == 10);
    CHECK(lcd.pinTouchRst == board::NO_PIN && lcd.touchResetExio == 1);
    CHECK(lcd.pinTouchInt == 4 && lcd.hasTouch());
    CHECK(lcd.power == board::PowerController::None && !lcd.hasBattery());
    CHECK(lcd.motion == board::MotionController::None && !lcd.hasMotion());
    CHECK(lcd.panel->colOffset == 0);
    CHECK(lcd.panel->invertColor);
    CHECK(lcd.panel->roundDisplay);
    CHECK(lcd.hasExpanderReset());

    const Geometry geometry = {lcd.panel->width, lcd.panel->height};
    CHECK(geometry.valid());
    CHECK(geometry.bandCount(false) == 360);
    CHECK(geometry.maxBandCount() <= MAX_BANDS);

    CHECK(board::variantFromStored((uint8_t)Variant::LcdSt77916) ==
          Variant::LcdSt77916);
    CHECK(board::variantFromName("st77916") == Variant::LcdSt77916);
    CHECK(strcmp(board::variantToken(Variant::LcdSt77916), "st77916") == 0);
    CHECK(strcmp(board::targetToken(Variant::LcdSt77916), "s3") == 0);
  }

  // --- the S3 1.54-inch ST7789 touch board entry ------------------------
  {
    using board::Variant;
    const board::Config &lcd = board::configFor(Variant::TouchSt7789);

    CHECK(lcd.variant == Variant::TouchSt7789);
    CHECK(lcd.panel->driver == board::PanelDriver::St7789);
    CHECK(lcd.panel->bus == board::PanelBus::Spi && !lcd.isQspi());
    CHECK(lcd.panel->width == 240 && lcd.panel->height == 240);
    CHECK(lcd.panel->pixelClockHz == 40 * 1000 * 1000);
    CHECK(lcd.panel->spiMode == 3);
    CHECK(lcd.pinSclk == 38 && lcd.pinMosi == 39);
    CHECK(lcd.pinData1 == board::NO_PIN && lcd.pinData2 == board::NO_PIN &&
          lcd.pinData3 == board::NO_PIN);
    CHECK(lcd.pinCs == 21 && lcd.pinDc == 45 && lcd.pinRst == 40);
    CHECK(lcd.pinBl == 46 && lcd.hasBacklightPin());
    CHECK(lcd.pinBootButton == 0);
    CHECK(lcd.pinRgbLed == board::NO_PIN && !lcd.hasRgbLed());

    CHECK(lcd.touch == board::TouchController::Cst816 && lcd.hasTouch());
    CHECK(lcd.pinTouchSda == 42 && lcd.pinTouchScl == 41);
    CHECK(lcd.pinTouchRst == 47 && lcd.pinTouchInt == 48);
    CHECK(lcd.touchResetExio == 0);
    CHECK(lcd.motion == board::MotionController::Qmi8658 && lcd.hasMotion());
    CHECK(lcd.motionXAxis == 0 && lcd.motionXSign == 1);
    CHECK(lcd.motionYAxis == 1 && lcd.motionYSign == 1);

    CHECK(lcd.power == board::PowerController::BatteryAdc);
    CHECK(lcd.pinBatteryAdc == 1 && lcd.batteryAdcScale == 3);
    CHECK(lcd.pinBatteryEnable == 2 && lcd.pinChargeStatus == 3);
    CHECK(lcd.hasBattery());

    CHECK(lcd.panel->colOffset == 0 && lcd.panel->rowOffset == 0);
    CHECK(lcd.panel->orientationOffset == 0);
    CHECK(lcd.panel->invertColor && !lcd.panel->roundDisplay);
    CHECK(!lcd.hasExpanderReset());

    const Geometry geometry = {lcd.panel->width, lcd.panel->height};
    CHECK(geometry.valid());
    CHECK(tilesExactly(geometry, false));
    CHECK(tilesExactly(geometry, true));

    const touchmap::Calibration cal = touchmap::CST816_ON_ST7789_240;
    CHECK(cal.panelShort == 240 && cal.panelLong == 240);
    CHECK(!cal.rawXMirrored && !cal.rawYMirrored);
    touchmap::Point p = touchmap::map(12, 34, false, 0, cal);
    CHECK(p.x == 12 && p.y == 34);

    CHECK(board::variantFromStored((uint8_t)Variant::TouchSt7789) ==
          Variant::TouchSt7789);
    CHECK(board::variantFromName("st7789-154") == Variant::TouchSt7789);
    CHECK(strcmp(board::variantToken(Variant::TouchSt7789), "st7789-154") == 0);
    CHECK(strcmp(board::targetToken(Variant::TouchSt7789), "s3") == 0);
    CHECK(board::resolve(Variant::TouchSt7789) == Variant::TouchSt7789);

    // Adding a mode-3 panel must not change any shipped profile's bus mode.
    CHECK(board::configFor(Variant::LcdSt7789).panel->spiMode == 0);
    CHECK(board::configFor(Variant::TouchJd9853).panel->spiMode == 0);
    CHECK(board::configFor(Variant::AmoledCo5300).panel->spiMode == 0);
    CHECK(board::configFor(Variant::LcdSt77916).panel->spiMode == 0);
    CHECK(board::configFor(Variant::LcdGc9107).panel->spiMode == 0);
  }

  // --- the S3 0.85-inch GC9107 board entry --------------------------------
  {
    using board::Variant;
    const board::Config &gc = board::configFor(Variant::LcdGc9107);

    CHECK(gc.variant == Variant::LcdGc9107);
    CHECK(gc.panel->driver == board::PanelDriver::Gc9107);
    // A single-lane SPI panel with a D/C line, unlike the QSPI S3 panels.
    CHECK(gc.panel->bus == board::PanelBus::Spi);
    CHECK(!gc.isQspi());
    CHECK(gc.pinDc == 45);

    // Waveshare's ESP32-S3-LCD-0.85 pin map, pin by pin so a copy-paste
    // between rows cannot pass silently.
    CHECK(gc.pinSclk == 38);
    CHECK(gc.pinMosi == 39);
    CHECK(gc.pinData1 == board::NO_PIN && gc.pinData2 == board::NO_PIN &&
          gc.pinData3 == board::NO_PIN);
    CHECK(gc.pinCs == 21);
    CHECK(gc.pinRst == 40);
    CHECK(gc.pinBl == 46 && gc.hasBacklightPin());
    CHECK(gc.pinBootButton == 0);
    CHECK(gc.pinRgbLed == 48 && gc.hasRgbLed());

    // 128x128 square glass at 40 MHz SPI.
    CHECK(gc.panel->width == 128 && gc.panel->height == 128);
    CHECK(gc.panel->pixelClockHz == 40 * 1000 * 1000);

    // Controller RAM is 128x160: the visible glass starts at column 2, row 1.
    CHECK(gc.panel->colOffset == 2);
    CHECK(gc.panel->rowOffset == 1);

    // Native orientation is two quarter turns; existing boards keep zero.
    CHECK(gc.panel->orientationOffset == 2);
    CHECK(board::configFor(Variant::AmoledCo5300).panel->orientationOffset == 0);
    CHECK(board::configFor(Variant::LcdSt77916).panel->orientationOffset == 0);
    CHECK(board::configFor(Variant::LcdSt7789).panel->orientationOffset == 0);
    CHECK(board::configFor(Variant::TouchJd9853).panel->orientationOffset == 0);
    CHECK(board::configFor(Variant::AmoledCo5300).panel->rowOffset == 0);
    CHECK(board::configFor(Variant::LcdSt77916).panel->rowOffset == 0);
    CHECK(board::configFor(Variant::LcdSt7789).panel->rowOffset == 0);
    CHECK(board::configFor(Variant::TouchJd9853).panel->rowOffset == 0);

    // The orientation composition panel_init.h performs: firmware rotation 0
    // lands on quadrant 2 (MADCTL MX|MY, no axis swap), which is Waveshare's
    // rotation 0 for this glass. Odd quadrants swap the axes, and the gap axis
    // follows: colOffset/rowOffset (2/1) exchange under an odd quadrant.
    {
      const uint8_t q0 = panelorient::quadrant(
          (uint8_t)(0 + gc.panel->orientationOffset), false);
      CHECK(q0 == 2);
      CHECK(!panelorient::swapXY(q0));
      CHECK(panelorient::mirrorX(q0) && panelorient::mirrorY(q0));
      // A quarter turn from there is an odd quadrant: axes swap, so the 2/1
      // gap swaps to 1/2.
      const uint8_t q1 = panelorient::quadrant(
          (uint8_t)(1 + gc.panel->orientationOffset), false);
      CHECK(q1 == 3);
      CHECK(panelorient::swapXY(q1));
    }

    // Square, not round: 128x128 still enables the square-panel quarter turns.
    CHECK(!gc.panel->roundDisplay);
    CHECK(gc.panel->invertColor);

    // No touch and no motion at all.
    CHECK(gc.touch == board::TouchController::None);
    CHECK(!gc.hasTouch());
    CHECK(gc.pinTouchSda == board::NO_PIN && gc.pinTouchScl == board::NO_PIN);
    CHECK(gc.pinTouchRst == board::NO_PIN && gc.pinTouchInt == board::NO_PIN);
    CHECK(gc.motion == board::MotionController::None);
    CHECK(!gc.hasMotion());

    // Battery ADC on GPIO1 through a 3:1 divider, enabled by GPIO2, with an
    // active-low charge-status line on GPIO3. This is not the AXP2101 PMU path.
    CHECK(gc.power == board::PowerController::BatteryAdc);
    CHECK(gc.pinBatteryAdc == 1);
    CHECK(gc.batteryAdcScale == 3);
    CHECK(gc.pinBatteryEnable == 2);
    CHECK(gc.pinChargeStatus == 3);
    CHECK(gc.hasBattery());

    // 128x128 produces a band layout the packed-band wire format carries
    // exactly, in both orientations - the link between the board table and the
    // protocol. (Tile streaming stays limited to the AmoledCo5300 elsewhere, so
    // this board uses the packed-band path.)
    const Geometry g = {gc.panel->width, gc.panel->height};
    CHECK(g.valid());
    CHECK(g.maxBandCount() <= MAX_BANDS);
    CHECK(tilesExactly(g, false));
    CHECK(tilesExactly(g, true));

    // Round-trips for the new variant: NVS byte, CFGBOARD token, and the
    // firmware-image target token that keeps it off the other S3 images.
    CHECK(board::variantFromStored((uint8_t)Variant::LcdGc9107) ==
          Variant::LcdGc9107);
    CHECK(board::variantFromName("gc9107") == Variant::LcdGc9107);
    CHECK(strcmp(board::variantToken(Variant::LcdGc9107), "gc9107") == 0);
    CHECK(strcmp(board::targetToken(Variant::LcdGc9107), "s3") == 0);
    CHECK(strcmp(board::targetToken(Variant::LcdGc9107),
                 board::targetToken(Variant::AmoledCo5300)) == 0);
    CHECK(strcmp(board::targetToken(Variant::LcdGc9107),
                 board::targetToken(Variant::LcdSt77916)) == 0);

    // resolve() never lands on an S3 board from Unknown: an inconclusive C6
    // probe must fall back to a C6 board, and the S3 build never probes.
    CHECK(board::resolve(Variant::Unknown) != Variant::LcdGc9107);
    CHECK(board::resolve(Variant::LcdGc9107) == Variant::LcdGc9107);
  }

  // --- C6 voltage-derived battery estimate -------------------------------
  {
    using batteryestimate::CurvePoint;
    CHECK(batteryestimate::PRESENT_MILLIVOLTS == 2500);
    CHECK(!batteryestimate::cellPresent(2499));
    CHECK(batteryestimate::cellPresent(2500));
    CHECK(batteryestimate::cellPresent(2501));

    static const CurvePoint expected[] = {
        {3300, 0}, {3500, 5}, {3600, 10}, {3700, 20}, {3750, 35},
        {3800, 50}, {3850, 65}, {3900, 75}, {4000, 85}, {4100, 95},
        {4200, 100},
    };
    const size_t count = sizeof(expected) / sizeof(expected[0]);
    CHECK(count == sizeof(batteryestimate::CURVE) /
                       sizeof(batteryestimate::CURVE[0]));
    for (size_t i = 0; i < count; i++) {
      CHECK(batteryestimate::CURVE[i].millivolts == expected[i].millivolts);
      CHECK(batteryestimate::CURVE[i].percent == expected[i].percent);
      CHECK(batteryestimate::percentFromMillivolts(expected[i].millivolts) ==
            expected[i].percent);
      if (i > 0) {
        CHECK(expected[i].millivolts > expected[i - 1].millivolts);
        CHECK(expected[i].percent >= expected[i - 1].percent);
      }
    }

    for (uint16_t mv : {0, 2499, 2500, 3299, 3300}) {
      CHECK(batteryestimate::percentFromMillivolts(mv) == 0);
    }
    CHECK(batteryestimate::percentFromMillivolts(4200) == 100);
    CHECK(batteryestimate::percentFromMillivolts(4201) == 100);
    CHECK(batteryestimate::percentFromMillivolts(UINT16_MAX) == 100);

    static const uint16_t midpointMv[] = {
        3400, 3550, 3650, 3725, 3775, 3825, 3875, 3950, 4050, 4150};
    static const uint8_t midpointPercent[] = {
        2, 7, 15, 27, 42, 57, 70, 80, 90, 97};
    for (size_t i = 0; i < sizeof(midpointMv) / sizeof(midpointMv[0]); i++) {
      CHECK(batteryestimate::percentFromMillivolts(midpointMv[i]) ==
            midpointPercent[i]);
    }
    CHECK(batteryestimate::percentFromMillivolts(3499) == 4);
    CHECK(batteryestimate::percentFromMillivolts(3501) == 5);
  }

  // --- automatic cardinal orientation ------------------------------------
  {
    using motionorient::Calibration;
    using motionorient::AutomaticMode;
    const Calibration identity = {0, 1, 1, 1};
    CHECK(motionorient::INVALID_ROTATION == 0xFF);
    CHECK(motionorient::ENTER_MIN == 5325);
    CHECK(motionorient::HOLD_MIN == 4505);
    CHECK(motionorient::ENTER_DOMINANCE == 1229);
    CHECK(motionorient::HOLD_DOMINANCE == 819);
    CHECK(motionorient::DWELL_MS == 500);
    CHECK(motionorient::automaticModeForPanel(466, 466) ==
          AutomaticMode::FourWay);
    CHECK(motionorient::automaticModeForPanel(172, 320) ==
          AutomaticMode::FlipOnly);

    static const uint8_t composition[4][4] = {
        {0, 1, 2, 3}, {1, 2, 3, 0}, {2, 3, 0, 1}, {3, 0, 1, 2}};
    for (uint8_t manual = 0; manual < 4; manual++) {
      for (uint8_t automatic = 0; automatic < 4; automatic++) {
        CHECK(motionorient::compose(manual, automatic) ==
              composition[manual][automatic]);
      }
    }
    CHECK(motionorient::compose(6, 7) == 1);

    const int16_t upright[3] = {0, 8192, 0};
    const int16_t left[3] = {-8192, 0, 0};
    const int16_t upsideDown[3] = {0, -8192, 0};
    const int16_t right[3] = {8192, 0, 0};
    CHECK(motionorient::cardinalFor(0, 8192) == 0);
    CHECK(motionorient::cardinalFor(-8192, 0) == 1);
    CHECK(motionorient::cardinalFor(0, -8192) == 2);
    CHECK(motionorient::cardinalFor(8192, 0) == 3);
    CHECK(motionorient::classify(
              upright, identity, 2, AutomaticMode::FourWay) == 0);
    CHECK(motionorient::classify(
              left, identity, 0, AutomaticMode::FourWay) == 1);
    CHECK(motionorient::classify(
              upsideDown, identity, 0, AutomaticMode::FourWay) == 2);
    CHECK(motionorient::classify(
              right, identity, 0, AutomaticMode::FourWay) == 3);

    // A rectangular panel's automatic correction is flip-only. Side gravity
    // must not select a quarter turn. It invalidates the sample until gravity
    // settles into an upright or upside-down bucket.
    CHECK(motionorient::classify(
              left, identity, 0, AutomaticMode::FlipOnly) ==
          motionorient::INVALID_ROTATION);
    CHECK(motionorient::classify(
              right, identity, 0, AutomaticMode::FlipOnly) ==
          motionorient::INVALID_ROTATION);
    CHECK(motionorient::classify(
              upright, identity, 2, AutomaticMode::FlipOnly) == 0);
    CHECK(motionorient::classify(
              upsideDown, identity, 0, AutomaticMode::FlipOnly) == 2);

    // The app's manual mounting choice is the base rotation. Automatic
    // correction composes on top instead of replacing that choice.
    CHECK(motionorient::compose(1, 0) == 1);
    CHECK(motionorient::compose(1, 2) == 3);

    const Calibration swapped = {1, -1, 0, 1};
    CHECK(motionorient::classify(
              right, swapped, 2, AutomaticMode::FourWay) == 0);

    const int16_t faceUp[3] = {0, 0, 8192};
    const int16_t belowEntry[3] = {5324, 0, 0};
    const int16_t atEntry[3] = {5325, 0, 0};
    const int16_t diagonal[3] = {5325, 5325, 0};
    const int16_t belowEntryDominance[3] = {5325, 4097, 0};
    const int16_t atEntryDominance[3] = {5325, 4096, 0};
    CHECK(motionorient::classify(
              faceUp, identity, 0, AutomaticMode::FourWay) ==
          motionorient::INVALID_ROTATION);
    CHECK(motionorient::classify(
              belowEntry, identity, 0, AutomaticMode::FourWay) ==
          motionorient::INVALID_ROTATION);
    CHECK(motionorient::classify(
              atEntry, identity, 0, AutomaticMode::FourWay) == 3);
    CHECK(motionorient::classify(
              diagonal, identity, 0, AutomaticMode::FourWay) ==
          motionorient::INVALID_ROTATION);
    CHECK(motionorient::classify(
              belowEntryDominance, identity, 2, AutomaticMode::FourWay) ==
          motionorient::INVALID_ROTATION);
    CHECK(motionorient::classify(
              atEntryDominance, identity, 2, AutomaticMode::FourWay) == 3);

    const int16_t hold0[3] = {0, 4505, 0};
    const int16_t hold1[3] = {-4505, 0, 0};
    const int16_t hold2[3] = {0, -4505, 0};
    const int16_t hold3[3] = {4505, 0, 0};
    CHECK(motionorient::classify(
              hold0, identity, 0, AutomaticMode::FourWay) == 0);
    CHECK(motionorient::classify(
              hold1, identity, 1, AutomaticMode::FourWay) == 1);
    CHECK(motionorient::classify(
              hold2, identity, 2, AutomaticMode::FourWay) == 2);
    CHECK(motionorient::classify(
              hold3, identity, 3, AutomaticMode::FourWay) == 3);
    const int16_t belowHold[3] = {0, 4504, 0};
    const int16_t atHoldDominance[3] = {5324, 4505, 0};
    const int16_t belowHoldDominance[3] = {5323, 4505, 0};
    CHECK(motionorient::classify(
              belowHold, identity, 0, AutomaticMode::FourWay) ==
          motionorient::INVALID_ROTATION);
    CHECK(motionorient::classify(
              atHoldDominance, identity, 0, AutomaticMode::FourWay) == 0);
    CHECK(motionorient::classify(
              belowHoldDominance, identity, 0, AutomaticMode::FourWay) ==
          motionorient::INVALID_ROTATION);
    CHECK(motionorient::classify(
              upsideDown, identity, 0, AutomaticMode::FourWay) == 2);

    motionorient::Tracker dwell;
    CHECK(!dwell.update(left, identity, AutomaticMode::FourWay, 1000));
    CHECK(dwell.candidate() == 1 && dwell.rotation() == 0);
    CHECK(!dwell.update(left, identity, AutomaticMode::FourWay, 1499));
    CHECK(dwell.update(left, identity, AutomaticMode::FourWay, 1500));
    CHECK(dwell.rotation() == 1);
    CHECK(dwell.candidate() == motionorient::INVALID_ROTATION);
    CHECK(!dwell.update(left, identity, AutomaticMode::FourWay, 1501));
    CHECK(dwell.candidate() == motionorient::INVALID_ROTATION);

    motionorient::Tracker rejected;
    CHECK(!rejected.update(left, identity, AutomaticMode::FourWay, 0));
    CHECK(!rejected.update(faceUp, identity, AutomaticMode::FourWay, 499));
    CHECK(rejected.candidate() == motionorient::INVALID_ROTATION);
    CHECK(!rejected.update(left, identity, AutomaticMode::FourWay, 500));
    CHECK(!rejected.update(left, identity, AutomaticMode::FourWay, 999));
    CHECK(rejected.update(left, identity, AutomaticMode::FourWay, 1000));

    motionorient::Tracker changed;
    CHECK(!changed.update(left, identity, AutomaticMode::FourWay, 0));
    CHECK(changed.update(left, identity, AutomaticMode::FourWay, 500));
    CHECK(!changed.update(
        upsideDown, identity, AutomaticMode::FourWay, 501));
    CHECK(!changed.update(
        upsideDown, identity, AutomaticMode::FourWay, 1000));
    CHECK(changed.update(
        upsideDown, identity, AutomaticMode::FourWay, 1001));
    CHECK(changed.rotation() == 2);

    motionorient::Tracker flipOnly;
    CHECK(!flipOnly.update(left, identity, AutomaticMode::FlipOnly, 0));
    CHECK(flipOnly.rotation() == 0);
    CHECK(flipOnly.candidate() == motionorient::INVALID_ROTATION);
    CHECK(!flipOnly.update(
        upsideDown, identity, AutomaticMode::FlipOnly, 100));
    CHECK(!flipOnly.update(
        upsideDown, identity, AutomaticMode::FlipOnly, 599));
    CHECK(flipOnly.update(
        upsideDown, identity, AutomaticMode::FlipOnly, 600));
    CHECK(flipOnly.rotation() == 2);
    CHECK(!flipOnly.update(right, identity, AutomaticMode::FlipOnly, 700));
    CHECK(flipOnly.rotation() == 2);
    CHECK(flipOnly.candidate() == motionorient::INVALID_ROTATION);

    motionorient::Tracker touchBlocked;
    CHECK(!touchBlocked.update(
        left, identity, AutomaticMode::FourWay, 1000));
    CHECK(!touchBlocked.update(
        left, identity, AutomaticMode::FourWay, 1500, false));
    CHECK(touchBlocked.rotation() == 0);
    CHECK(touchBlocked.candidate() == motionorient::INVALID_ROTATION);
    CHECK(!touchBlocked.update(
        left, identity, AutomaticMode::FourWay, 1501));
    CHECK(!touchBlocked.update(
        left, identity, AutomaticMode::FourWay, 2000));
    CHECK(touchBlocked.update(
        left, identity, AutomaticMode::FourWay, 2001));

    motionorient::Tracker rollover;
    CHECK(!rollover.update(
        left, identity, AutomaticMode::FourWay, 0xFFFFFF00u));
    CHECK(!rollover.update(
        left, identity, AutomaticMode::FourWay, 0x000000F3u));
    CHECK(rollover.update(
        left, identity, AutomaticMode::FourWay, 0x000000F4u));
    CHECK(rollover.rotation() == 1);
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
    CHECK(touchmap::mirrorFrameX({7, 9}, false).x == SHORT - 1 - 7);
    CHECK(touchmap::mirrorFrameX({7, 9}, false).y == 9);
    CHECK(touchmap::mirrorFrameX({7, 9}, true).x == LONG - 1 - 7);
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
  // The 1.75C CST9217 is rotated 180 degrees in raw glass space: hardware
  // swipes showed both raw axes running opposite to visible screen directions.
  // The square geometry still collapses frame-shape distinctions, while the
  // structural rotation and landscape composition rules remain unchanged.
  {
    using touchmap::Point;
    const touchmap::Calibration cal = touchmap::CST9217_ON_CO5300;
    const int16_t SIDE = cal.panelShort;
    CHECK(SIDE == 466 && cal.panelLong == 466);
    CHECK(cal.rawXMirrored);
    CHECK(cal.rawYMirrored);
    CHECK(cal.rotateClockwise);

    // Square glass: landscape and portrait share one frame shape.
    CHECK(touchmap::frameWidth(false, cal) == SIDE);
    CHECK(touchmap::frameHeight(false, cal) == SIDE);
    CHECK(touchmap::frameWidth(true, cal) == SIDE);
    CHECK(touchmap::frameHeight(true, cal) == SIDE);

    // Step 1 applies the measured 180-degree raw-to-glass correction.
    CHECK(touchmap::rawToGlass(0, 0, cal).x == SIDE - 1);
    CHECK(touchmap::rawToGlass(0, 0, cal).y == SIDE - 1);
    CHECK(touchmap::rawToGlass(SIDE - 1, 17, cal).x == 0);
    CHECK(touchmap::rawToGlass(SIDE - 1, 17, cal).y == SIDE - 1 - 17);

    // Portrait upright uses the corrected glass point directly.
    CHECK(touchmap::map(10, 20, false, 0, cal).x == SIDE - 1 - 10);
    CHECK(touchmap::map(10, 20, false, 0, cal).y == SIDE - 1 - 20);

    // Rotation 2 cancels the fixed glass-space 180-degree correction.
    CHECK(touchmap::map(10, 20, false, 2, cal).x == 10);
    CHECK(touchmap::map(10, 20, false, 2, cal).y == 20);

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

  // --- bc1: the lossy block codec for tile-stream run payloads -------------
  // Byte-for-byte vectors written out by hand from the format comment in
  // bc1.h, deliberately NOT shared with the Swift suite - each side asserts
  // the wire independently, so a codec change that breaks interoperability
  // fails a test rather than updating a fixture.
  {
    // Encoded size is a pure function of the raster dimensions: fixed-rate,
    // ceil(w/4) x ceil(h/4) blocks of 8 bytes. Pinned over the 466x466 tile
    // grid's real run shapes, including the 2 px edge tiles.
    CHECK(bc1::encodedBytes(4, 4) == 8);
    CHECK(bc1::encodedBytes(16, 16) == 128);       // one interior tile
    CHECK(bc1::encodedBytes(464, 16) == 3712);     // widest full-height run
    CHECK(bc1::encodedBytes(2, 16) == 32);         // right edge column tile
    CHECK(bc1::encodedBytes(16, 2) == 32);         // bottom edge row tile
    CHECK(bc1::encodedBytes(2, 2) == 8);           // the corner tile
    CHECK(bc1::encodedBytes(466, 16) == 3744);     // full-width: 117x4 blocks
    CHECK(bc1::encodedBytes(0, 16) == 0);          // refusals
    CHECK(bc1::encodedBytes(16, 0) == 0);
    CHECK(bc1::encodedBytes(4097, 4) == 0);        // beyond MAX_DIM
  }
  {
    // Palette interpolants, hand-computed per RGB565 channel. c0 = 0xF800
    // (pure red max), c1 = 0x0000 (black): r interpolants are 2*31/3 = 20
    // and 31/3 = 10, so pal[2] = 20 << 11 = 0xA000, pal[3] = 10 << 11 =
    // 0x5000. Integer division truncates - pinned so neither side rounds.
    uint16_t pal[4];
    bc1::palette(0xF800, 0x0000, pal);
    CHECK(pal[0] == 0xF800 && pal[1] == 0x0000);
    CHECK(pal[2] == 0xA000 && pal[3] == 0x5000);
    // A mixed pair: c0 = 0xFFFF (white), c1 = 0x2104 (r=4,g=8,b=4).
    // pal[2]: r=(62+4)/3=22, g=(126+8)/3=44, b=(62+4)/3=22 -> 0xB596.
    // pal[3]: r=(31+8)/3=13, g=(63+16)/3=26, b=(31+8)/3=13 -> 0x6B4D.
    bc1::palette(0xFFFF, 0x2104, pal);
    CHECK(pal[2] == 0xB596);
    CHECK(pal[3] == 0x6B4D);
  }
  {
    // One hand-built block decoded byte for byte: endpoints red/black, index
    // word 0xE4E4E4E4 = rows of indices 0,1,2,3 (LSB-first pairs). Every
    // row must come out [red, black, 0xA000, 0x5000] in big-endian order.
    const uint8_t block[] = {0x00, 0xF8, 0x00, 0x00,   // c0=0xF800 c1=0x0000
                             0xE4, 0xE4, 0xE4, 0xE4};  // 0b11100100 per row
    std::vector<uint8_t> dst(4 * 4 * 2, 0xA5);
    CHECK(bc1::decode(block, sizeof(block), dst.data(), 4, 4));
    for (int row = 0; row < 4; row++) {
      const uint8_t *r = dst.data() + row * 8;
      CHECK(r[0] == 0xF8 && r[1] == 0x00);  // index 0 -> c0
      CHECK(r[2] == 0x00 && r[3] == 0x00);  // index 1 -> c1
      CHECK(r[4] == 0xA0 && r[5] == 0x00);  // index 2 -> 2/3 point
      CHECK(r[6] == 0x50 && r[7] == 0x00);  // index 3 -> 1/3 point
    }
  }
  {
    // Flat rasters round-trip exactly at every tile-grid shape, including
    // the 2 px edges - bounding-box endpoints collapse to the one color.
    const size_t shapes[][2] = {{16, 16}, {2, 16}, {16, 2}, {2, 2}, {48, 16}};
    for (const auto &s : shapes) {
      const size_t w = s[0], h = s[1];
      std::vector<uint8_t> raw(w * h * 2);
      for (size_t i = 0; i < raw.size(); i += 2) {
        raw[i] = 0x2A;
        raw[i + 1] = 0xAA;
      }
      std::vector<uint8_t> enc(bc1::encodedBytes(w, h));
      CHECK(bc1::encode(raw.data(), w, h, enc.data(), enc.size()) ==
            enc.size());
      std::vector<uint8_t> dec(raw.size(), 0xA5);
      CHECK(bc1::decode(enc.data(), enc.size(), dec.data(), w, h));
      CHECK(memcmp(dec.data(), raw.data(), raw.size()) == 0);
    }
  }
  {
    // Two-tone content with channel-wise ordered colors (black-on-white
    // text's shape) round-trips exactly: the bounding box IS the two colors.
    const size_t w = 16, h = 16;
    std::vector<uint8_t> raw(w * h * 2);
    for (size_t i = 0; i < w * h; i++) {
      const bool ink = (i / 3) % 2 == 0;  // stripes, both colors per block
      raw[i * 2] = ink ? 0x00 : 0xFF;
      raw[i * 2 + 1] = ink ? 0x00 : 0xFF;
    }
    std::vector<uint8_t> enc(bc1::encodedBytes(w, h));
    CHECK(bc1::encode(raw.data(), w, h, enc.data(), enc.size()) == enc.size());
    std::vector<uint8_t> dec(raw.size(), 0xA5);
    CHECK(bc1::decode(enc.data(), enc.size(), dec.data(), w, h));
    CHECK(memcmp(dec.data(), raw.data(), raw.size()) == 0);
  }
  {
    // Lossy content: decode(encode(x)) must stay within the block's own
    // color bounding box per channel - BC1 cannot invent colors outside the
    // endpoints it derived. Deterministic pseudo-random rasters.
    uint32_t seed = 0x1234567;
    for (int trial = 0; trial < 20; trial++) {
      const size_t w = 16, h = 16;
      std::vector<uint8_t> raw(w * h * 2);
      for (size_t i = 0; i < w * h; i++) {
        seed = seed * 1664525u + 1013904223u;
        raw[i * 2] = (uint8_t)(seed >> 24);
        raw[i * 2 + 1] = (uint8_t)(seed >> 16);
      }
      std::vector<uint8_t> enc(bc1::encodedBytes(w, h));
      CHECK(bc1::encode(raw.data(), w, h, enc.data(), enc.size()) ==
            enc.size());
      std::vector<uint8_t> dec(raw.size());
      CHECK(bc1::decode(enc.data(), enc.size(), dec.data(), w, h));
      for (size_t by = 0; by < h / 4; by++) {
        for (size_t bx = 0; bx < w / 4; bx++) {
          uint16_t rMin = 0x1F, rMax = 0, gMin = 0x3F, gMax = 0, bMin = 0x1F,
                   bMax = 0;
          for (size_t py = 0; py < 4; py++) {
            for (size_t px = 0; px < 4; px++) {
              const size_t at = ((by * 4 + py) * w + bx * 4 + px) * 2;
              const uint16_t p =
                  (uint16_t)(((uint16_t)raw[at] << 8) | raw[at + 1]);
              const uint16_t r = p >> 11, g = (p >> 5) & 0x3F, b = p & 0x1F;
              if (r < rMin) rMin = r;
              if (r > rMax) rMax = r;
              if (g < gMin) gMin = g;
              if (g > gMax) gMax = g;
              if (b < bMin) bMin = b;
              if (b > bMax) bMax = b;
            }
          }
          for (size_t py = 0; py < 4; py++) {
            for (size_t px = 0; px < 4; px++) {
              const size_t at = ((by * 4 + py) * w + bx * 4 + px) * 2;
              const uint16_t p =
                  (uint16_t)(((uint16_t)dec[at] << 8) | dec[at + 1]);
              const uint16_t r = p >> 11, g = (p >> 5) & 0x3F, b = p & 0x1F;
              CHECK(r >= rMin && r <= rMax);
              CHECK(g >= gMin && g <= gMax);
              CHECK(b >= bMin && b <= bMax);
            }
          }
        }
      }
    }
  }
  {
    // Encoder refusals: zero dimensions, output that does not fit, absurd
    // dimensions. All 0, matching rle565::encode's convention.
    uint8_t raw[16 * 16 * 2] = {0};
    uint8_t enc[256];
    CHECK(bc1::encode(raw, 0, 16, enc, sizeof(enc)) == 0);
    CHECK(bc1::encode(raw, 16, 0, enc, sizeof(enc)) == 0);
    CHECK(bc1::encode(raw, 16, 16, enc, 127) == 0);  // needs exactly 128
    CHECK(bc1::encode(raw, 16, 16, enc, 128) == 128);
    CHECK(bc1::encode(raw, 4097, 4, enc, sizeof(enc)) == 0);
  }
  {
    // SECURITY: the decoder must refuse malformed input and never read or
    // write outside the buffers it was given, because it writes into the
    // frame buffer from an unauthenticated datagram. Source and destination
    // are heap allocations of EXACTLY the claimed sizes, ASan non-recovering
    // (see run_tests.sh), so one stray byte in either direction aborts the
    // suite - the same posture as the rle565 block above. BC1 is fixed-rate,
    // so unlike RLE the whole input-length question is one exact equality:
    // pinned one byte short AND one byte long, both sides of the boundary.
    auto refused = [](size_t srcLen, size_t w, size_t h) {
      std::vector<uint8_t> src(srcLen, 0x5A);
      std::vector<uint8_t> dst(w * h * 2, 0xA5);
      return !bc1::decode(src.data(), src.size(), dst.data(), w, h);
    };
    CHECK(refused(127, 16, 16));  // one byte short of the 128 required
    CHECK(refused(129, 16, 16));  // one byte long
    CHECK(refused(0, 16, 16));    // empty
    CHECK(refused(7, 2, 2));      // corner tile needs exactly one block
    CHECK(refused(9, 2, 2));
    CHECK(refused(8, 0, 4));      // zero dimension never decodes
    CHECK(refused(8, 4, 0));
    CHECK(refused(32, 4097, 4));  // beyond MAX_DIM refused before any math
    // Exact size succeeds - the positive control against the 0xA5 canary,
    // on both the interior path (4x4) and the clipped edge path (2x2: one
    // block, 4 of 16 index writes land, 12 are consumed and discarded).
    {
      const uint8_t block[] = {0x00, 0xF8, 0x00, 0xF8, 0x00, 0x00, 0x00, 0x00};
      std::vector<uint8_t> dst(4 * 4 * 2, 0xA5);
      CHECK(bc1::decode(block, sizeof(block), dst.data(), 4, 4));
      CHECK(dst[0] == 0xF8 && dst[1] == 0x00);
      CHECK(dst[30] == 0xF8 && dst[31] == 0x00);
    }
    {
      // The 2x2 corner tile: dst is EXACTLY 8 bytes on the heap. A decoder
      // that wrote any of the block's 12 padding pixels would land in ASan's
      // redzone one byte past the raster and abort, so this vector pins the
      // edge clip at the true boundary, not merely the return value.
      const uint8_t block[] = {0x00, 0xF8, 0x00, 0xF8, 0x00, 0x00, 0x00, 0x00};
      std::vector<uint8_t> dst(2 * 2 * 2, 0xA5);
      CHECK(bc1::decode(block, sizeof(block), dst.data(), 2, 2));
      for (size_t i = 0; i < dst.size(); i += 2) {
        CHECK(dst[i] == 0xF8 && dst[i + 1] == 0x00);
      }
    }
    {
      // A 6x6 raster: 2x2 blocks, all four clipped (right column and bottom
      // row of each outer block fall outside). Exact-size heap dst again.
      std::vector<uint8_t> src(bc1::encodedBytes(6, 6), 0x00);
      // All-black blocks: endpoints 0, all indices 0.
      std::vector<uint8_t> dst(6 * 6 * 2, 0xA5);
      CHECK(bc1::decode(src.data(), src.size(), dst.data(), 6, 6));
      for (size_t i = 0; i < dst.size(); i++) CHECK(dst[i] == 0x00);
    }
  }
  {
    // Encode reads exactly w*h*2 source bytes: an exact-size heap source
    // with edge-replication padding in play (6x6 needs 4 blocks, 3 of whose
    // 16 gather reads per block would fall outside a naive unclamped read).
    std::vector<uint8_t> raw(6 * 6 * 2, 0x33);
    std::vector<uint8_t> enc(bc1::encodedBytes(6, 6));
    CHECK(bc1::encode(raw.data(), 6, 6, enc.data(), enc.size()) == enc.size());
    std::vector<uint8_t> dec(raw.size());
    CHECK(bc1::decode(enc.data(), enc.size(), dec.data(), 6, 6));
    CHECK(memcmp(dec.data(), raw.data(), raw.size()) == 0);
  }

  // --- tile stream: grid geometry ------------------------------------------
  // The tile grid the 466x466 AMOLED runs, pinned the way G172's band layout
  // is: these numbers ARE the wire format for tile indices and run sizes.
  {
    const tileproto::TileGeometry g = tileproto::GEOMETRY_466X466;
    CHECK(g.valid());
    CHECK(g.tileCols() == 30);
    CHECK(g.tileRows() == 30);
    CHECK(g.tileCount() == 900);
    CHECK(g.frameBytes() == 434312);
    CHECK(g.colWidth(0) == 16);
    CHECK(g.colWidth(28) == 16);
    CHECK(g.colWidth(29) == 2);   // 466 = 29*16 + 2
    CHECK(g.rowHeight(29) == 2);
    CHECK(g.col(899) == 29 && g.row(899) == 29);  // the 2x2 corner tile
    CHECK(g.col(30) == 0 && g.row(30) == 1);      // row-major indexing
  }
  {
    // Other square panels on the roadmap derive sound grids too.
    const tileproto::TileGeometry g480 = {480, 480};
    CHECK(g480.valid());
    CHECK(g480.tileCount() == 900);
    CHECK(g480.colWidth(29) == 16);  // divides evenly: no short edge
    const tileproto::TileGeometry g412 = {412, 412};
    CHECK(g412.valid());
    CHECK(g412.tileCols() == 26);
    CHECK(g412.tileCount() == 676);
    CHECK(g412.colWidth(25) == 12);  // 412 = 25*16 + 12
  }
  {
    // What the protocol cannot carry is refused up front. 511 is the widest
    // valid panel: 32 tile columns (the run-length ceiling) and a full-row
    // raw run of 511*16*2 = 16352 B, one byte under the record length
    // field's 16383. 512 pushes the raw run to 16384 and is refused.
    CHECK(!(tileproto::TileGeometry{0, 0}).valid());
    CHECK(!(tileproto::TileGeometry{466, 0}).valid());
    CHECK((tileproto::TileGeometry{511, 466}).valid());
    CHECK(!(tileproto::TileGeometry{512, 466}).valid());
    CHECK(!(tileproto::TileGeometry{528, 466}).valid());  // 33 columns
  }
  {
    // Run arithmetic: what a record may claim and what it decodes to.
    const tileproto::TileGeometry g = tileproto::GEOMETRY_466X466;
    CHECK(g.runValid(0, 1));
    CHECK(g.runValid(0, 30));            // one full tile-row
    CHECK(!g.runValid(0, 31));           // wider than the grid
    CHECK(!g.runValid(1, 30));           // would cross into row 1
    CHECK(g.runValid(29, 1));            // the short edge column alone
    CHECK(!g.runValid(0, 0));            // zero-length runs are meaningless
    CHECK(!g.runValid(900, 1));          // past the grid
    CHECK(g.runValid(899, 1));           // the corner tile
    CHECK(g.runPixelWidth(0, 30) == 466);
    CHECK(g.runRawBytes(0, 30) == 466 * 16 * 2);     // 14912
    CHECK(g.runPixelWidth(28, 2) == 18);             // 16 + the 2 px edge
    CHECK(g.runRawBytes(28, 2) == 18 * 16 * 2);
    CHECK(g.runRawBytes(899, 1) == 2 * 2 * 2);       // corner: 8 bytes
    CHECK(g.runRawBytes(870, 30) == 466 * 2 * 2);    // bottom row, 2 px tall
  }

  // --- tile stream: packet header ------------------------------------------
  {
    // Little-endian fields; stream flag bit 15 of first_tile; landscape
    // bit 15 of dirty_count. first_tile 0x8385 = flag | tile 901... use
    // tile 5: 0x8005. dirty 0x8050 = landscape | 80 tiles.
    const uint8_t raw[6] = {0x34, 0x12, 0x05, 0x80, 0x50, 0x80};
    tileproto::TileHeader h = tileproto::parseHeader(raw);
    CHECK(h.frameId == 0x1234);
    CHECK(h.streamFlagSet);
    CHECK(!h.reservedBitsSet);
    CHECK(h.firstTile == 5);
    CHECK(h.landscape);
    CHECK(h.dirtyCount == 80);

    // Stream flag clear (a band-shaped packet) is visible to the caller.
    const uint8_t band[6] = {0x34, 0x12, 0x05, 0x00, 0x50, 0x00};
    h = tileproto::parseHeader(band);
    CHECK(!h.streamFlagSet);
    CHECK(!h.landscape);

    // Reserved bits 14..10: any of them set flags the header for rejection.
    const uint8_t reserved[6] = {0x34, 0x12, 0x05, 0x84, 0x50, 0x00};
    h = tileproto::parseHeader(reserved);
    CHECK(h.streamFlagSet);
    CHECK(h.reservedBitsSet);
    CHECK(h.firstTile == 5);
  }

  // --- tile stream: the record walker --------------------------------------
  {
    // Two records built by hand, byte for byte:
    //   tile 5, run 3 (bits 14..10 = 2 -> 0x0805), BC1 (codec 2), 3 bytes
    //     tile field 0x0805 = 05 08; len field 0x8003 = 03 80
    //   tile 40, run 1, raw (codec 0), 4 bytes
    const uint8_t payload[] = {
        0x05, 0x08, 0x03, 0x80, 0xAA, 0xBB, 0xCC,        // tile 5 run 3 bc1
        0x28, 0x00, 0x04, 0x00, 0xDE, 0xAD, 0xBE, 0xEF,  // tile 40 raw
    };
    struct Seen {
      uint16_t tile;
      uint16_t run;
      bool visibleSpans;
      tileproto::TileCodec codec;
      size_t len;
      uint8_t first;
    };
    std::vector<Seen> seen;
    bool ok = tileproto::forEachRecord(
        payload, sizeof(payload),
        [&](uint16_t tile, uint16_t run, bool visibleSpans,
            tileproto::TileCodec codec, const uint8_t *p, size_t n) {
          seen.push_back({tile, run, visibleSpans, codec, n, p[0]});
          return true;
        });
    CHECK(ok);
    CHECK(seen.size() == 2);
    CHECK(seen[0].tile == 5 && seen[0].run == 3);
    CHECK(!seen[0].visibleSpans);
    CHECK(seen[0].codec == tileproto::TileCodec::Bc1);
    CHECK(seen[0].len == 3 && seen[0].first == 0xAA);
    CHECK(seen[1].tile == 40 && seen[1].run == 1);
    CHECK(seen[1].codec == tileproto::TileCodec::Raw);
    CHECK(seen[1].len == 4 && seen[1].first == 0xDE);
  }
  {
    // Codec value 3 reaches fn as HalfBc1 (it was Reserved3 until half-res
    // shipped). Whether to accept it is still fn's business - the walker
    // knows bytes, not codecs - and fn refusing still aborts the walk, which
    // is exactly how firmware without half-res drops such a record.
    const uint8_t payload[] = {0x05, 0x00, 0x01, 0xC0, 0x99};
    bool sawHalf = false;
    bool ok = tileproto::forEachRecord(
        payload, sizeof(payload),
        [&](uint16_t, uint16_t, bool visibleSpans,
            tileproto::TileCodec codec, const uint8_t *, size_t) {
          sawHalf = !visibleSpans && codec == tileproto::TileCodec::HalfBc1;
          return false;
        });
    CHECK(!ok);
    CHECK(sawHalf);
  }
  {
    // Structural refusals, each one byte-tight where a boundary exists.
    auto walks = [](std::vector<uint8_t> payload) {
      return tileproto::forEachRecord(
          payload.data(), payload.size(),
          [](uint16_t, uint16_t, bool, tileproto::TileCodec,
             const uint8_t *, size_t) { return true; });
    };
    CHECK(!walks({}));                          // empty
    CHECK(!walks({0x05, 0x00, 0x01}));          // truncated record header
    CHECK(!walks({0x05, 0x00, 0x00, 0x00}));    // zero-length body
    CHECK(!walks({0x05, 0x00, 0x02, 0x00, 0xAA}));  // body one byte short
    CHECK(walks({0x05, 0x00, 0x02, 0x00, 0xAA, 0xBB}));  // exact fit walks
    CHECK(walks({0x05, 0x80, 0x01, 0x00, 0xAA}));  // visible-span flag
    // A valid record followed by a truncated one refuses the whole packet.
    CHECK(!walks({0x05, 0x00, 0x01, 0x00, 0xAA, 0x06, 0x00, 0x01}));
  }

  // --- tile stream: reassembler - the band matrix, restated per record -----
  {
    // Geometry rejection: bad dirty counts and inexpressible runs.
    const tileproto::TileGeometry g = tileproto::GEOMETRY_466X466;
    auto th = [](uint16_t frame, uint16_t first, uint16_t dirty,
                 bool landscape = false) {
      tileproto::TileHeader h;
      h.frameId = frame;
      h.firstTile = first;
      h.dirtyCount = dirty;
      h.landscape = landscape;
      h.streamFlagSet = true;
      h.reservedBitsSet = false;
      return h;
    };
    using tileproto::RecordAction;
    {
      tileproto::Reassembler r(g);
      CHECK(r.onRecord(th(1, 0, 0), 0, 1, dropped) == RecordAction::Reject);
      CHECK(r.onRecord(th(1, 0, 901), 0, 1, dropped) == RecordAction::Reject);
      CHECK(r.onRecord(th(1, 0, 3), 900, 1, dropped) == RecordAction::Reject);
      CHECK(r.onRecord(th(1, 0, 3), 1, 30, dropped) == RecordAction::Reject);
      CHECK(r.onRecord(th(1, 0, 3), 0, 0, dropped) == RecordAction::Reject);
      // An invalid geometry rejects everything.
      tileproto::Reassembler bad(tileproto::TileGeometry{0, 0});
      CHECK(bad.onRecord(th(1, 0, 1), 0, 1, dropped) == RecordAction::Reject);
    }
    {
      // Full keyframe completes on the last run: 30 rows of 30 tiles.
      tileproto::Reassembler r(g);
      for (uint16_t row = 0; row < 29; row++) {
        CHECK(r.onRecord(th(7, row * 30, 900), row * 30, 30, dropped) ==
              RecordAction::Apply);
      }
      CHECK(r.onRecord(th(7, 870, 900), 870, 30, dropped) ==
            RecordAction::ApplyComplete);
    }
    {
      // Dirty subset completes after dirtyCount tiles, any indices, and a
      // multi-tile run counts every tile it covers.
      tileproto::Reassembler r(g);
      CHECK(r.onRecord(th(9, 5, 5), 5, 3, dropped) == RecordAction::Apply);
      CHECK(r.onRecord(th(9, 42, 5), 42, 1, dropped) == RecordAction::Apply);
      CHECK(r.onRecord(th(9, 100, 5), 100, 1, dropped) ==
            RecordAction::ApplyComplete);
      CHECK(!dropped);
    }
    {
      // Duplicates never complete a frame early; a run that only re-covers
      // already-seen tiles is a Duplicate, and a partially overlapping run
      // counts only its new tiles.
      tileproto::Reassembler r(g);
      CHECK(r.onRecord(th(3, 5, 4), 5, 2, dropped) == RecordAction::Apply);
      CHECK(r.onRecord(th(3, 5, 4), 5, 2, dropped) ==
            RecordAction::Duplicate);
      // Tiles 6,7: overlaps tile 6 (seen), adds tile 7 -> 3 of 4.
      CHECK(r.onRecord(th(3, 6, 4), 6, 2, dropped) == RecordAction::Apply);
      CHECK(r.onRecord(th(3, 8, 4), 8, 1, dropped) ==
            RecordAction::ApplyComplete);
    }
    {
      // Late records of older frames are ignored, current frame unharmed.
      tileproto::Reassembler r(g);
      CHECK(r.onRecord(th(100, 0, 2), 0, 1, dropped) == RecordAction::Apply);
      CHECK(r.onRecord(th(99, 1, 2), 1, 1, dropped) ==
            RecordAction::IgnoreStale);
      CHECK(r.onRecord(th(98, 1, 900), 1, 1, dropped) ==
            RecordAction::IgnoreStale);
      CHECK(r.onRecord(th(100, 1, 2), 1, 1, dropped) ==
            RecordAction::ApplyComplete);
    }
    {
      // A newer frame abandons a partial one and reports the drop.
      tileproto::Reassembler r(g);
      CHECK(r.onRecord(th(10, 0, 3), 0, 1, dropped) == RecordAction::Apply);
      CHECK(r.onRecord(th(11, 0, 2), 0, 1, dropped) == RecordAction::Apply);
      CHECK(dropped);
      CHECK(r.onRecord(th(11, 1, 2), 1, 1, dropped) ==
            RecordAction::ApplyComplete);
      CHECK(!dropped);
    }
    {
      // Frame id wraparound: 0 is newer than 65535.
      tileproto::Reassembler r(g);
      CHECK(r.onRecord(th(65535, 0, 2), 0, 1, dropped) ==
            RecordAction::Apply);
      CHECK(r.onRecord(th(0, 0, 2), 0, 1, dropped) == RecordAction::Apply);
      CHECK(dropped);  // partial 65535 abandoned
      CHECK(r.onRecord(th(0, 1, 2), 1, 1, dropped) ==
            RecordAction::ApplyComplete);
    }
    {
      // Sender restart: persistent stale ids force a resync after two
      // frames' worth of records for this grid - 1800 on 900 tiles.
      tileproto::Reassembler r(g);
      CHECK(r.onRecord(th(30000, 0, 2), 0, 1, dropped) ==
            RecordAction::Apply);
      const int resync = 2 * g.tileCount();
      CHECK(resync == 1800);
      int ignored = 0;
      RecordAction last = RecordAction::Reject;
      for (int i = 0; i < resync + 1; i++) {
        last = r.onRecord(th(2, (uint16_t)(i % 40), 80),
                          (uint16_t)(i % 40), 1, dropped);
        if (last == RecordAction::IgnoreStale) ignored++;
      }
      CHECK(ignored == resync - 1);
      CHECK(last == RecordAction::Apply);  // resynced onto frame 2
    }
    {
      // Orientation adopted per frame - bookkeeping on square glass, but it
      // must track the sender the way the band reassembler does.
      tileproto::Reassembler r(g);
      CHECK(r.onRecord(th(1, 0, 1, true), 0, 1, dropped) ==
            RecordAction::ApplyComplete);
      CHECK(r.landscape() == true);
      CHECK(r.onRecord(th(2, 0, 1, false), 0, 1, dropped) ==
            RecordAction::ApplyComplete);
      CHECK(r.landscape() == false);
    }
  }

  // --- tile stream: row-run coalescing for the draw path -------------------
  {
    const tileproto::TileGeometry g = tileproto::GEOMETRY_466X466;
    auto runs = [&](std::initializer_list<int> setBits) {
      uint8_t bits[tileproto::TILE_BITMAP_BYTES] = {0};
      for (int t : setBits) bits[t >> 3] |= 1 << (t & 7);
      std::vector<std::array<int, 3>> out;
      tileproto::forEachRowRun(bits, g, [&](uint16_t r, uint16_t s,
                                            uint16_t e) {
        out.push_back({(int)r, (int)s, (int)e});
      });
      return out;
    };
    CHECK(runs({}).empty());
    CHECK((runs({0}) == std::vector<std::array<int, 3>>{{0, 0, 1}}));
    // Adjacent tiles in one row merge; a row boundary splits: tile 29 is
    // (row 0, col 29) and tile 30 is (row 1, col 0) - never one rect.
    CHECK((runs({29, 30}) ==
           std::vector<std::array<int, 3>>{{0, 29, 30}, {1, 0, 1}}));
    CHECK((runs({3, 4, 5, 9, 65, 66}) ==
           std::vector<std::array<int, 3>>{
               {0, 3, 6}, {0, 9, 10}, {2, 5, 7}}));
    // A full bitmap coalesces to exactly one run per tile-row.
    uint8_t bits[tileproto::TILE_BITMAP_BYTES];
    memset(bits, 0xFF, sizeof(bits));
    int count = 0;
    tileproto::forEachRowRun(bits, g, [&](uint16_t, uint16_t s, uint16_t e) {
      count++;
      if (s != 0 || e != 30) count = -10000;
    });
    CHECK(count == 30);
  }

  // --- tile stream: the capability bit --------------------------------------
  {
    // Pinned because the Swift side spells the same number out by hand
    // (DeviceProtocol.Capabilities.tileStream).
    CHECK(deviceproto::CAP_TILE_STREAM == 1u << 15);
    CHECK((deviceproto::CAP_TILE_STREAM & deviceproto::CAP_POWER) == 0);
    CHECK((deviceproto::CAP_TILE_STREAM & deviceproto::CAP_COMPRESSED_BANDS) ==
          0);
    // Round glass, the sender's cue to skip the fifth of the framebuffer
    // behind the bezel. Only the CO5300 board entry sets roundDisplay, so
    // only it can advertise this; pinned because the Swift side spells the
    // same number out by hand (DeviceProtocol.Capabilities.roundDisplay).
    CHECK(deviceproto::CAP_ROUND_DISPLAY == 1u << 16);
    CHECK((deviceproto::CAP_ROUND_DISPLAY & deviceproto::CAP_TILE_STREAM) == 0);
    CHECK(board::configFor(board::Variant::AmoledCo5300).panel->roundDisplay);
    CHECK(!board::configFor(board::Variant::LcdSt7789).panel->roundDisplay);
    CHECK(!board::configFor(board::Variant::TouchJd9853).panel->roundDisplay);
    // Half-res BC1 records. Separate from CAP_TILE_STREAM because tile
    // firmware predating codec 3 rejects it, and a rejected record takes its
    // whole datagram down - the sender must be able to tell the two apart.
    CHECK(deviceproto::CAP_TILE_HALFRES == 1u << 17);
    CHECK((deviceproto::CAP_TILE_HALFRES & deviceproto::CAP_TILE_STREAM) == 0);
    CHECK((deviceproto::CAP_TILE_HALFRES & deviceproto::CAP_ROUND_DISPLAY) ==
          0);
    CHECK(deviceproto::CAP_TILE_VISIBLE_SPANS == 1u << 18);
    CHECK((deviceproto::CAP_TILE_VISIBLE_SPANS &
           deviceproto::CAP_TILE_STREAM) == 0);
    CHECK((deviceproto::CAP_TILE_VISIBLE_SPANS &
           deviceproto::CAP_ROUND_DISPLAY) == 0);
    CHECK(tileproto::RECORD_VISIBLE_SPANS == 0x8000);
    CHECK(tileproto::VISIBLE_SPAN_DESCRIPTOR_BYTES == 4);
  }

  // --- tile stream: half-res BC1 (codec 3) ---------------------------------
  {
    using tileproto::halfDim;
    // The one rounding rule both implementations and both suites share.
    CHECK(halfDim(16) == 8);
    CHECK(halfDim(2) == 1);   // the 466 grid's edge tiles
    CHECK(halfDim(1) == 1);   // never zero: a raster always has a pixel
    CHECK(halfDim(466) == 233);
    CHECK(halfDim(3) == 2);   // odd: rounds UP, so doubling covers the raster
    CHECK(halfDim(0) == 0);

    // Codec 3 is now a defined value, no longer reserved.
    CHECK((uint8_t)tileproto::TileCodec::HalfBc1 == 3);

    // pixelDouble replicates each source pixel into a 2x2 destination block.
    // 2x2 -> 4x4 with four distinct colours makes every mapping visible.
    const uint8_t src[] = {
        0xF8, 0x00, 0x07, 0xE0,  // red, green
        0x00, 0x1F, 0xFF, 0xFF,  // blue, white
    };
    uint8_t dst[4 * 4 * 2];
    memset(dst, 0xAA, sizeof(dst));
    CHECK(tileproto::pixelDouble(src, 2, 2, dst, 4, 4));
    for (int y = 0; y < 4; y++) {
      for (int x = 0; x < 4; x++) {
        const uint8_t *s = src + ((y / 2) * 2 + (x / 2)) * 2;
        const uint8_t *d = dst + (y * 4 + x) * 2;
        CHECK(d[0] == s[0] && d[1] == s[1]);
      }
    }

    // Odd destination: the last row/column take the last source pixel, and
    // nothing reads past the source. 3x3 from 2x2.
    uint8_t odd[3 * 3 * 2];
    CHECK(tileproto::pixelDouble(src, 2, 2, odd, 3, 3));
    CHECK(odd[(2 * 3 + 2) * 2] == 0xFF && odd[(2 * 3 + 2) * 2 + 1] == 0xFF);
    CHECK(odd[0] == 0xF8 && odd[1] == 0x00);

    // A 2 px edge tile: 1x1 source fills the whole 2x2 destination.
    const uint8_t one[] = {0x12, 0x34};
    uint8_t two[2 * 2 * 2];
    CHECK(tileproto::pixelDouble(one, 1, 1, two, 2, 2));
    for (int i = 0; i < 4; i++) {
      CHECK(two[i * 2] == 0x12 && two[i * 2 + 1] == 0x34);
    }

    // The dimension relationship is REQUIRED, not assumed: a caller whose
    // half dimensions disagree with halfDim is refused rather than trusted,
    // because on the network path that pair decides how far reads go.
    CHECK(!tileproto::pixelDouble(src, 2, 2, dst, 5, 4));  // halfDim(5) == 3
    CHECK(!tileproto::pixelDouble(src, 2, 2, dst, 4, 5));
    CHECK(!tileproto::pixelDouble(src, 3, 2, dst, 4, 4));  // claimed too wide
    CHECK(!tileproto::pixelDouble(src, 1, 2, dst, 4, 4));  // claimed too narrow
    CHECK(!tileproto::pixelDouble(src, 2, 2, dst, 0, 4));
    CHECK(!tileproto::pixelDouble(src, 2, 2, dst, 4, 0));

    // End to end, the way a record arrives: BC1 at half size, decoded and
    // doubled, must equal the doubling of that BC1's own decode. This is the
    // property the panel relies on - the codec is BC1, the codec-3 part is
    // only the scaling.
    uint8_t half[8 * 8 * 2];
    for (int i = 0; i < 8 * 8; i++) {
      half[i * 2] = (uint8_t)(i * 3);
      half[i * 2 + 1] = (uint8_t)(255 - i);
    }
    uint8_t encoded[bc1::BLOCK_BYTES * 4];
    const size_t n = bc1::encode(half, 8, 8, encoded, sizeof(encoded));
    CHECK(n == bc1::encodedBytes(8, 8));
    CHECK(n == 32);  // vs 128 B at full 16x16: the 4x saving, exactly
    uint8_t viaDecode[8 * 8 * 2];
    CHECK(bc1::decode(encoded, n, viaDecode, 8, 8));
    uint8_t doubled[16 * 16 * 2];
    CHECK(tileproto::pixelDouble(viaDecode, 8, 8, doubled, 16, 16));
    for (int y = 0; y < 16; y++) {
      for (int x = 0; x < 16; x++) {
        const uint8_t *s = viaDecode + ((y / 2) * 8 + (x / 2)) * 2;
        const uint8_t *d = doubled + (y * 16 + x) * 2;
        CHECK(d[0] == s[0] && d[1] == s[1]);
      }
    }

    // Per-record sizes on the real grid, which is what the ladder's
    // estimates and section 16's datagram arithmetic rest on.
    CHECK(bc1::encodedBytes(halfDim(16), halfDim(16)) == 32);
    CHECK(bc1::encodedBytes(16, 16) == 128);
    CHECK(bc1::encodedBytes(halfDim(2), halfDim(16)) == 16);   // edge column
    CHECK(bc1::encodedBytes(halfDim(466), halfDim(16)) == 944);  // full row
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

  // --- ETL1 large-tile wire format --------------------------------------
  {
    using namespace largetileproto;
    const largetileproto::Geometry geometry = {720, 720};
    CHECK(geometry.valid());
    CHECK(geometry.tileCols() == 45);
    CHECK(geometry.tileRows() == 45);
    CHECK(geometry.tileCount() == 2025);
    CHECK(deviceproto::CAP_LARGE_TILE_STREAM == (1u << 19));

    // Hand-authored bytes shared only by specification with the Swift test:
    // ETL1, frame 0x1234, three dirty tiles, landscape, then one raw record.
    const uint8_t packet[] = {
        'E','T','L','1', 0x34,0x12, 0x03,0x00, 0x01,0x00,
        0xD0,0x07, 0x03,0x00, 0x04,0x00, 0xDE,0xAD,0xBE,0xEF};
    largetileproto::Header header;
    CHECK(parseHeader(packet, sizeof(packet), header));
    CHECK(header.frameId == 0x1234 && header.dirtyTileCount == 3);
    CHECK(header.landscape);
    int records = 0;
    uint16_t seenStart = 0;
    uint8_t seenRun = 0;
    Codec seenCodec = Codec::HalfBc1;
    bool seenSpans = true;
    size_t seenLength = 0;
    uint8_t seenFirst = 0;
    CHECK(forEachRecord(packet, sizeof(packet), [&](const Record &record) {
      records++;
      seenStart = record.startTile;
      seenRun = record.runLength;
      seenCodec = record.codec;
      seenSpans = record.visibleSpans;
      seenLength = record.payloadLength;
      seenFirst = record.payload[0];
      return true;
    }));
    CHECK(records == 1);
    CHECK(seenStart == 2000 && seenRun == 3 && seenCodec == Codec::Raw);
    CHECK(!seenSpans && seenLength == 4 && seenFirst == 0xDE);

    std::vector<uint8_t> malformed(packet, packet + sizeof(packet));
    malformed[9] = 1;
    CHECK(!parseHeader(malformed.data(), malformed.size(), header));
    malformed.assign(packet, packet + sizeof(packet));
    malformed[13] = 0x80;
    CHECK(!forEachRecord(malformed.data(), malformed.size(),
                         [](const Record &) { return true; }));
    CHECK(!forEachRecord(packet, sizeof(packet) - 1,
                         [](const Record &) { return true; }));

    largetileproto::Reassembler reassembler(geometry);
    bool dropped = false;
    largetileproto::Header one = {1, 3, false};
    CHECK(reassembler.onRecord(one, 2000, 3, dropped) ==
          Action::ApplyComplete);
    CHECK(!dropped);

    // A record may not overrun the header's promised dirty count, and fields
    // that describe one frame must stay stable across all its datagrams.
    largetileproto::Reassembler hostile(geometry);
    largetileproto::Header two = {2, 2, false};
    CHECK(hostile.onRecord(two, 0, 3, dropped) == Action::Reject);
    CHECK(hostile.onRecord(two, 0, 1, dropped) == Action::Apply);
    largetileproto::Header changedCount = {2, 3, false};
    CHECK(hostile.onRecord(changedCount, 1, 1, dropped) == Action::Reject);
    largetileproto::Header changedOrientation = {2, 2, true};
    CHECK(hostile.onRecord(changedOrientation, 1, 1, dropped) ==
          Action::Reject);
    CHECK(hostile.onRecord(two, 1, 1, dropped) == Action::ApplyComplete);

    // Payload validation is transactional with reassembly. A malformed record
    // must not claim its tile: a corrected retry applies normally and only the
    // subsequent valid tile completes the frame.
    largetileproto::Reassembler transactional(geometry);
    largetileproto::Header retry = {3, 2, false};
    int validations = 0;
    CHECK(transactional.onRecordIfValid(
              retry, 30, 1, [&]() {
                validations++;
                return false;
              }, dropped) == Action::Reject);
    CHECK(validations == 1 && !dropped);
    CHECK(transactional.onRecordIfValid(
              retry, 30, 1, [&]() {
                validations++;
                return true;
              }, dropped) == Action::Apply);
    CHECK(transactional.onRecordIfValid(
              retry, 31, 1, [&]() {
                validations++;
                return true;
              }, dropped) == Action::ApplyComplete);
    CHECK(validations == 3 && !dropped);

    // One missing record cannot freeze received tiles forever. Completion
    // wins immediately; an incomplete frame becomes drawable at the bounded
    // deadline, and a later/key frame is adopted so it can heal missing tiles.
    CHECK(largetileproto::pendingDrawReason(1039, 1000, 0, 0, true, 40) ==
          largetileproto::DrawReason::None);
    CHECK(largetileproto::pendingDrawReason(1040, 1000, 0, 0, true, 40) ==
          largetileproto::DrawReason::Partial);
    CHECK(largetileproto::pendingDrawReason(1001, 1000, 1, 0, true, 40) ==
          largetileproto::DrawReason::Complete);
    CHECK(largetileproto::pendingDrawReason(1100, 1000, 1, 0, false, 40) ==
          largetileproto::DrawReason::None);
    largetileproto::Reassembler healing(geometry);
    largetileproto::Header lostFrame = {10, 2, false};
    CHECK(healing.onRecord(lostFrame, 10, 1, dropped) == Action::Apply);
    largetileproto::Header nextFrame = {11, 1, false};
    CHECK(healing.onRecord(nextFrame, 20, 1, dropped) ==
          Action::ApplyComplete);
    CHECK(dropped);
    largetileproto::Header keyframe = {12, geometry.tileCount(), false};
    for (uint16_t row = 0; row < geometry.tileRows(); ++row) {
      const uint16_t start = row * geometry.tileCols();
      CHECK(healing.onRecord(keyframe, start,
                             (uint8_t)geometry.tileCols(), dropped) ==
            (row + 1 == geometry.tileRows() ? Action::ApplyComplete
                                            : Action::Apply));
    }
  }

  // --- GT911 polling report contract -------------------------------------
  {
    CHECK(gt911proto::ADDRESS_PRIMARY == 0x5D);
    CHECK(gt911proto::ADDRESS_BACKUP == 0x14);
    CHECK(gt911proto::REGISTER_STATUS == 0x814E);
    CHECK(gt911proto::REGISTER_POINT1 == 0x814F);
    const uint8_t point[8] = {1, 0x34, 0x02, 0x78, 0x01, 0, 0, 0};
    bool pressed = false;
    uint16_t x = 0, y = 0;
    uint8_t points = 0;
    CHECK(gt911proto::parseReport(0x81, point, sizeof(point), pressed,
                                  x, y, points));
    CHECK(pressed && points == 1 && x == 0x0234 && y == 0x0178);
    CHECK(gt911proto::parseReport(0x80, nullptr, 0, pressed,
                                  x, y, points));
    CHECK(!pressed && points == 0);  // explicit release
    CHECK(!gt911proto::parseReport(0x01, point, sizeof(point), pressed,
                                   x, y, points));
    CHECK(!gt911proto::parseReport(0x81, point, 4, pressed,
                                   x, y, points));
  }

  // --- Doom runtime geometry and board-neutral touch policy --------------
  {
    const doom_frame_layout_t p4 =
        doom_frame_layout_for_panel(720, 720, false);
    CHECK(p4.panel_width == 720 && p4.panel_height == 720);
    CHECK(p4.scaled_width == 720 && p4.scaled_height == 450);
    CHECK(p4.x_offset == 0 && p4.y_offset == 135);
    CHECK(!p4.round_mask);

    const doom_frame_layout_t wide =
        doom_frame_layout_for_panel(800, 480, false);
    CHECK(wide.scaled_width == 768 && wide.scaled_height == 480);
    CHECK(wide.x_offset == 16 && wide.y_offset == 0);

    CHECK(doom_touch_zone_for_press(
              DOOM_CONTROLS_TOUCH_ONLY, 720, 100) ==
          DOOM_TOUCH_ZONE_MOVE);
    CHECK(doom_touch_zone_for_press(
              DOOM_CONTROLS_TOUCH_ONLY, 720, 359) ==
          DOOM_TOUCH_ZONE_MOVE);
    CHECK(doom_touch_zone_for_press(
              DOOM_CONTROLS_TOUCH_ONLY, 720, 360) ==
          DOOM_TOUCH_ZONE_AIM);
    CHECK(doom_touch_zone_for_press(
              DOOM_CONTROLS_IMU_TOUCH, 466, 100) ==
          DOOM_TOUCH_ZONE_AIM);
    CHECK(doom_touch_axis_delta(100, 100, 24, 1) == 0);
    CHECK(doom_touch_axis_delta(70, 100, 24, 1) == -1);
    CHECK(doom_touch_axis_delta(130, 100, 24, 1) == 1);
  }

  // --- platform/panel/carrier composition for P4 -------------------------
  {
    const board::Config &p4 = board::configFor(board::Variant::P4_4B);
    CHECK(p4.platform == &board::PLATFORM_ESP32_P4);
    CHECK(p4.panel == &board::PANEL_ST7703_720X720);
    CHECK(p4.platform->wifi == board::WifiTopology::HostedCoprocessor);
    CHECK(p4.platform->identity == board::IdentitySource::EfuseBaseMac);
    CHECK(p4.panel->bus == board::PanelBus::MipiDsi);
    CHECK(board::platformSupportsPanel(board::PLATFORM_ESP32_P4,
                                       board::PANEL_ST7703_720X720));
    CHECK(board::platformSupportsPanel(board::PLATFORM_ESP32_P4,
                                       board::PANEL_ST77916_360X360));
    CHECK(!board::platformSupportsPanel(board::PLATFORM_ESP32_S3,
                                        board::PANEL_ST7703_720X720));
    CHECK(p4.panel->dsiDataLanes == 2 && p4.panel->dsiLaneMbps == 480);
    CHECK(p4.panel->supportsCommandRotation);
    CHECK(p4.pinRst == 27 && p4.pinBl == 26 && p4.pinBlEnable == 33);
    CHECK(p4.pinTouchSda == 7 && p4.pinTouchScl == 8);
    CHECK(strcmp(board::variantToken(p4.variant), "st7703-4b") == 0);
    CHECK(strcmp(board::targetToken(p4.variant), "p4") == 0);
    CHECK(strcmp(board::PLATFORM_ESP32_P4.chipToken,
                 p4.platform->chipToken) == 0);
    CHECK(board::supportsDoom(board::Variant::P4_4B));
    CHECK(board::supportsDoom(board::Variant::AmoledCo5300));
    CHECK(!board::supportsDoom(board::Variant::TouchSt7789));
  }

  // --- glyph_draw: the on-device text rasterizer (glyph_draw.h)
  {
    // An exactly sized heap buffer, so the sanitizers prove the clipping:
    // any write outside the declared bufW x bufH raster is a hard failure.
    const int w = 20, h = 12;
    std::vector<uint8_t> buf((size_t)w * h * 2, 0);

    // 'I' at scale 1 lights pixels inside the glyph cell and nowhere else on
    // the empty rows above it. Column 2 of the 5x7 'I' is a full vertical
    // stroke, so (x+2, y..y+6) must all carry the color.
    drawText(buf.data(), w, h, 1, 2, "I", 0xF800, 1);
    auto px = [&](int x, int y) {
      size_t off = ((size_t)y * w + x) * 2;
      return (uint16_t)((buf[off] << 8) | buf[off + 1]);
    };
    for (int row = 0; row < 7; row++) CHECK(px(3, 2 + row) == 0xF800);
    CHECK(px(3, 0) == 0x0000);   // above the glyph: untouched
    CHECK(px(0, 2) == 0x0000);   // left of the glyph: untouched

    // Text hanging past every edge is clipped, not written out of bounds -
    // this ran on the panel's row-range math before it was unit tested, and
    // under ASan an off-by-one here is a hard failure rather than a wrap.
    drawText(buf.data(), w, h, -3, -4, "WWW", 0xFFFF, 2);
    drawText(buf.data(), w, h, w - 2, h - 2, "WWW", 0xFFFF, 3);

    // The outline draw paints the black ring before the white core, so the
    // core must survive: the stroke pixel is white, its outline black.
    std::fill(buf.begin(), buf.end(), 0x55);
    drawOutlinedText(buf.data(), w, h, 4, 3, "I", 1);
    // Probed at the glyph's middle row: the classic 'I' has serifs on its
    // top and bottom rows (columns 1 and 3 carry 0x41), so only the middle
    // rows have a bare stroke with outline directly beside it.
    CHECK(px(6, 6) == 0xFFFF);   // the stroke itself: white core
    CHECK(px(7, 6) == 0x0000);   // right of the stroke: black outline
  }

  printf("OK: %d checks passed\n", checks);
  return 0;
}
