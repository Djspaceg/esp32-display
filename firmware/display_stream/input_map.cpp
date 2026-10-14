#include "input_map.h"

#include <Arduino.h>
#include <Preferences.h>
#include <string.h>

#include "app_state.h"
#include "boot_menu.h"
#include "device_protocol.h"
#include "net_link.h"

static deviceproto::InputMap activeMap;
static deviceproto::InputMap defaultMap;
static deviceproto::InputMap pendingMap;
static bool pendingMapReady = false;
// The sender endpoint the last EMAP came from. The stored map is in force
// only with no sender at all or for that one: a sender that never sends EMAP
// (one that predates maps) gets the defaults, today's behaviour.
static uint32_t mapSenderIp = 0;
static uint16_t mapSenderPort = 0;
static portMUX_TYPE inputMapMux = portMUX_INITIALIZER_UNLOCKED;

static const char INPUT_MAP_KEY[] = "inmap";
// Inputs 1..INPUT_COUNT, then the map's flags.
static const size_t INPUT_MAP_RECORD_BYTES = deviceproto::INPUT_COUNT + 1;

static bool boardHasKnob() { return bcfg != nullptr && bcfg->hasEncoder(); }

// The status screen and WiFi selector do not fit the compact C3 framebuffer.
static bool boardHasScreens() {
#if defined(CONFIG_IDF_TARGET_ESP32C3)
  return false;
#else
  return true;
#endif
}

void loadInputMap() {
  defaultMap = deviceproto::defaultInputMap(
      boardHasKnob(), bootMenuMayOfferGames(), boardHasScreens());
  activeMap = defaultMap;
  Preferences prefs;
  if (prefs.begin("espdisp", true /* read-only */)) {
    uint8_t stored[INPUT_MAP_RECORD_BYTES];
    if (prefs.getBytesLength(INPUT_MAP_KEY) == sizeof(stored) &&
        prefs.getBytes(INPUT_MAP_KEY, stored, sizeof(stored)) == sizeof(stored)) {
      bool valid = true;
      for (size_t i = 0; i < deviceproto::INPUT_COUNT; ++i) {
        valid = valid && deviceproto::validInputFunction(stored[i]);
      }
      if (valid) {
        memcpy(activeMap.functions + 1, stored, deviceproto::INPUT_COUNT);
        activeMap.flags =
            stored[deviceproto::INPUT_COUNT] & deviceproto::INPUT_MAP_FLAGS_KNOWN;
      }
    }
    prefs.end();
  }
  char line[64];
  formatInputMap(line, sizeof(line));
  Serial.printf("input map: %s%s\n", line,
                memcmp(&activeMap, &defaultMap, sizeof(activeMap)) == 0
                    ? " (defaults)" : " (saved)");
}

static bool storedMapInForce() {
  const uint16_t port = hbPort;
  if (port == 0) return true;
  const uint32_t ip = hbIp;
  portENTER_CRITICAL(&inputMapMux);
  const bool sentByThisSender = mapSenderPort == port && mapSenderIp == ip;
  portEXIT_CRITICAL(&inputMapMux);
  return sentByThisSender;
}

static const deviceproto::InputMap &mapInForce() {
  return storedMapInForce() ? activeMap : defaultMap;
}

uint8_t inputFunctionFor(uint8_t input) {
  if (input == 0 || input > deviceproto::INPUT_COUNT) {
    return (uint8_t)deviceproto::InputFunction::Nothing;
  }
  return mapInForce().functions[input];
}

bool bootShortPressesAsDefault() {
  return deviceproto::shortPressesAsDefault(mapInForce(), defaultMap,
                                            boardHasKnob());
}

uint8_t highestBoundBootTier() {
  using deviceproto::TouchGesture;
  const uint8_t nothing = (uint8_t)deviceproto::InputFunction::Nothing;
  const deviceproto::InputMap &map = mapInForce();
  if (map.functions[(uint8_t)TouchGesture::BootTriplePress] != nothing) {
    return 3;
  }
  if (map.functions[(uint8_t)TouchGesture::BootDoublePress] != nothing) {
    return 2;
  }
  return 1;
}

bool offerInputMap(const uint8_t *data, size_t len) {
  deviceproto::InputMap parsed;
  if (!deviceproto::parseInputMap(data, len, defaultMap, parsed)) return false;
  // Called after handleInbound() took this packet's sender as the reply
  // endpoint, so hbIp/hbPort are the sender that sent it.
  portENTER_CRITICAL(&inputMapMux);
  pendingMap = parsed;
  pendingMapReady = true;
  mapSenderIp = hbIp;
  mapSenderPort = hbPort;
  portEXIT_CRITICAL(&inputMapMux);
  return true;
}

// The sender repeats EMAP until EINP shows it applied, and only while the two
// differ, so a write here happens once per real change.
bool applyPendingInputMap() {
  deviceproto::InputMap next;
  portENTER_CRITICAL(&inputMapMux);
  const bool ready = pendingMapReady;
  pendingMapReady = false;
  if (ready) next = pendingMap;
  portEXIT_CRITICAL(&inputMapMux);
  if (!ready || memcmp(&next, &activeMap, sizeof(next)) == 0) return true;
  activeMap = next;
  Preferences prefs;
  bool saved = false;
  if (prefs.begin("espdisp", false)) {
    // The defaults are stored as no map at all, so a later firmware's
    // defaults reach a board that never chose anything else.
    if (memcmp(&activeMap, &defaultMap, sizeof(activeMap)) == 0) {
      prefs.remove(INPUT_MAP_KEY);
      saved = true;
    } else {
      uint8_t record[INPUT_MAP_RECORD_BYTES];
      memcpy(record, activeMap.functions + 1, deviceproto::INPUT_COUNT);
      record[deviceproto::INPUT_COUNT] = activeMap.flags;
      saved = prefs.putBytes(INPUT_MAP_KEY, record, sizeof(record)) ==
              sizeof(record);
    }
    prefs.end();
  }
  char line[64];
  formatInputMap(line, sizeof(line));
  Serial.printf("input map: %s flags=%u from sender (%s)\n", line,
                (unsigned)activeMap.flags, saved ? "saved" : "NOT saved");
  return saved;
}

void sendInputReport(bool powerKey) {
  if (hbPort == 0) return;
  const uint32_t inputs = deviceproto::inputMask(
      touchAvailable, boardHasKnob(), bcfg != nullptr && bcfg->hasBootButton(),
      powerKey);
  const uint32_t functions =
      deviceproto::functionMask(boardHasScreens(), bootMenuMayOfferGames());
  uint8_t packet[deviceproto::INPUT_REPORT_HEADER_BYTES +
                 2 * deviceproto::INPUT_COUNT];
  const size_t len = deviceproto::writeInputReport(
      packet, sizeof(packet), inputs, functions, activeMap, defaultMap,
      storedMapInForce() ? deviceproto::INPUT_REPORT_STATUS_MAP_IN_FORCE : 0);
  if (len > 0) sendToSender(packet, len);
}

void formatInputMap(char *out, size_t capacity) {
  if (capacity == 0) return;
  size_t offset = 0;
  for (uint8_t id = 1; id <= deviceproto::INPUT_COUNT && offset + 1 < capacity;
       ++id) {
    out[offset++] = (char)('0' + activeMap.functions[id]);
  }
  out[offset] = '\0';
}
