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
static portMUX_TYPE inputMapMux = portMUX_INITIALIZER_UNLOCKED;

static const char INPUT_MAP_KEY[] = "inmap";

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
    uint8_t stored[deviceproto::INPUT_COUNT];
    if (prefs.getBytesLength(INPUT_MAP_KEY) == sizeof(stored) &&
        prefs.getBytes(INPUT_MAP_KEY, stored, sizeof(stored)) == sizeof(stored)) {
      bool valid = true;
      for (uint8_t function : stored) {
        valid = valid && deviceproto::validInputFunction(function);
      }
      if (valid) memcpy(activeMap.functions + 1, stored, sizeof(stored));
    }
    prefs.end();
  }
  char line[64];
  formatInputMap(line, sizeof(line));
  Serial.printf("input map: %s%s\n", line,
                memcmp(&activeMap, &defaultMap, sizeof(activeMap)) == 0
                    ? " (defaults)" : " (saved)");
}

uint8_t inputFunctionFor(uint8_t input) {
  if (input == 0 || input > deviceproto::INPUT_COUNT) {
    return (uint8_t)deviceproto::InputFunction::Nothing;
  }
  return activeMap.functions[input];
}

bool bootShortPressesAsDefault() {
  return deviceproto::shortPressesAsDefault(activeMap, defaultMap,
                                            boardHasKnob());
}

uint8_t highestBoundBootTier() {
  using deviceproto::TouchGesture;
  const uint8_t nothing = (uint8_t)deviceproto::InputFunction::Nothing;
  if (activeMap.functions[(uint8_t)TouchGesture::BootTriplePress] != nothing) {
    return 3;
  }
  if (activeMap.functions[(uint8_t)TouchGesture::BootDoublePress] != nothing) {
    return 2;
  }
  return 1;
}

bool offerInputMap(const uint8_t *data, size_t len) {
  deviceproto::InputMap parsed;
  if (!deviceproto::parseInputMap(data, len, defaultMap, parsed)) return false;
  portENTER_CRITICAL(&inputMapMux);
  pendingMap = parsed;
  pendingMapReady = true;
  portEXIT_CRITICAL(&inputMapMux);
  return true;
}

// The sender repeats EMAP until EINP shows it applied, and only while the two
// differ, so a write here happens once per real change.
void applyPendingInputMap() {
  deviceproto::InputMap next;
  portENTER_CRITICAL(&inputMapMux);
  const bool ready = pendingMapReady;
  pendingMapReady = false;
  if (ready) next = pendingMap;
  portEXIT_CRITICAL(&inputMapMux);
  if (!ready || memcmp(&next, &activeMap, sizeof(next)) == 0) return;
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
      saved = prefs.putBytes(INPUT_MAP_KEY, activeMap.functions + 1,
                             deviceproto::INPUT_COUNT) ==
              deviceproto::INPUT_COUNT;
    }
    prefs.end();
  }
  char line[64];
  formatInputMap(line, sizeof(line));
  Serial.printf("input map: %s from sender (%s)\n", line,
                saved ? "saved" : "NOT saved");
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
      packet, sizeof(packet), inputs, functions, activeMap, defaultMap);
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
