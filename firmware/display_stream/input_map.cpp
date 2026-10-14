#include "input_map.h"

#include <Arduino.h>
#include <Preferences.h>
#include <esp_system.h>
#include <string.h>

#include "app_state.h"
#include "boot_menu.h"
#include "device_protocol.h"
#include "net_link.h"

static deviceproto::InputMap activeMap;
static deviceproto::InputMap defaultMap;
static deviceproto::InputMap pendingMap;
static bool pendingMapReady = false;
static uint32_t pendingSenderIp = 0;
static uint16_t pendingSenderPort = 0;
// The sender endpoint the last EMAP came from. The stored map is in force
// only with no sender at all or for that one: a sender that never sends EMAP
// (one that predates maps) gets the defaults, today's behaviour.
static uint32_t mapSenderIp = 0;
static uint16_t mapSenderPort = 0;
static portMUX_TYPE inputMapMux = portMUX_INITIALIZER_UNLOCKED;

// A changed map is used and saved at once, so the newest map is what a
// restart comes back to. Only when the change comes from a different sender
// than the last save, inside this interval, is the save held back: two
// senders trading maps on one board would otherwise write NVS on every
// switch. A held-back save is made when the interval passes, or before a
// deliberate restart (flushInputMapOnRestart).
static const uint32_t INPUT_MAP_SAVE_INTERVAL_MS = 30000;
static bool mapNeedsSave = false;
static bool mapSavedSinceBoot = false;
static uint32_t lastMapSaveAt = 0;
// Senders by address and port, as storedMapInForce() tells them apart: two
// apps on one Mac are two senders. The same app back on a new port after a
// reconnect waits out the interval once (it re-sends its map anyway).
static uint32_t changeSenderIp = 0;
static uint16_t changeSenderPort = 0;
static uint32_t savedSenderIp = 0;
static uint16_t savedSenderPort = 0;
// One save at a time: the restart flush can run on another task (the P4's
// coprocessor update), and a save that took its copy first must finish
// first, or an older map could be written over a newer one.
static bool saveInProgress = false;
// A change from another sender was held back since the last save, so the
// next change saves on the interval too, whoever sends it.
static bool mapHeldBackSinceSave = false;
static bool lastSaveFailed = false;

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

static bool saveInputMap(bool onlyIfNeeded = false);

// esp_restart() runs shutdown handlers first, so every deliberate restart -
// the boot menu, a WiFi switch, an update, a restart command - saves a
// held-back map before the chip resets. A crash or a power cut does not; a
// connected sender then re-sends its map, which differs from the board's.
static void flushInputMapOnRestart() { saveInputMap(true); }

static void registerInputMapShutdownFlush() {
  static bool registered = false;
  if (registered) return;
  registered = esp_register_shutdown_handler(flushInputMapOnRestart) == 0;
}

void loadInputMap() {
  defaultMap = deviceproto::defaultInputMap(
      boardHasKnob(), bootMenuMayOfferGames(), boardHasScreens());
  activeMap = defaultMap;
  mapNeedsSave = false;
  mapSavedSinceBoot = false;
  mapHeldBackSinceSave = false;
  lastSaveFailed = false;
  registerInputMapShutdownFlush();
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
  // A board on its defaults runs them for everyone; nothing to confirm.
  if (memcmp(&activeMap, &defaultMap, sizeof(activeMap)) == 0) return true;
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
  pendingSenderIp = hbIp;
  pendingSenderPort = hbPort;
  portEXIT_CRITICAL(&inputMapMux);
  return true;
}

// Saves the active map. Also run from the shutdown handler, which on the P4
// can be the coprocessor-update task rather than loop(), so the map is copied
// under the lock that loop() changes it under.
// `onlyIfNeeded`: return without writing when, once this save has its turn,
// there is nothing left to save (another save just wrote it).
static bool saveInputMap(bool onlyIfNeeded) {
  deviceproto::InputMap snapshot;
  for (;;) {
    portENTER_CRITICAL(&inputMapMux);
    if (!saveInProgress) break;  // leaves the lock held
    portEXIT_CRITICAL(&inputMapMux);
    delay(1);
  }
  if (onlyIfNeeded && !mapNeedsSave) {
    portEXIT_CRITICAL(&inputMapMux);
    return true;
  }
  saveInProgress = true;
  snapshot = activeMap;
  const uint32_t senderIp = changeSenderIp;
  const uint16_t senderPort = changeSenderPort;
  mapNeedsSave = false;
  portEXIT_CRITICAL(&inputMapMux);
  lastMapSaveAt = millis();
  Preferences prefs;
  bool saved = false;
  if (prefs.begin("espdisp", false)) {
    // The defaults are stored as no map at all, so a later firmware's
    // defaults reach a board that never chose anything else.
    if (memcmp(&snapshot, &defaultMap, sizeof(snapshot)) == 0) {
      prefs.remove(INPUT_MAP_KEY);
      saved = true;
    } else {
      uint8_t record[INPUT_MAP_RECORD_BYTES];
      memcpy(record, snapshot.functions + 1, deviceproto::INPUT_COUNT);
      record[deviceproto::INPUT_COUNT] = snapshot.flags;
      saved = prefs.putBytes(INPUT_MAP_KEY, record, sizeof(record)) ==
              sizeof(record);
    }
    prefs.end();
  }
  if (saved) {
    mapSavedSinceBoot = true;
    savedSenderIp = senderIp;
    savedSenderPort = senderPort;
    mapHeldBackSinceSave = false;
    lastSaveFailed = false;
  } else {
    // Tried again once the interval has passed, not on every loop pass.
    portENTER_CRITICAL(&inputMapMux);
    mapNeedsSave = true;
    portEXIT_CRITICAL(&inputMapMux);
    lastSaveFailed = true;
  }
  portENTER_CRITICAL(&inputMapMux);
  saveInProgress = false;
  portEXIT_CRITICAL(&inputMapMux);
  Serial.printf("input map: %s\n", saved ? "saved" : "NOT saved");
  return saved;
}

// The sender repeats EMAP until EINP shows it applied, and only while the two
// differ or the map is not yet in force for it, so a change is rare.
bool applyPendingInputMap(bool saveNow) {
  deviceproto::InputMap next;
  uint32_t senderIp = 0;
  uint16_t senderPort = 0;
  bool changed = false;
  portENTER_CRITICAL(&inputMapMux);
  if (pendingMapReady) {
    pendingMapReady = false;
    next = pendingMap;
    senderIp = pendingSenderIp;
    senderPort = pendingSenderPort;
    changed = memcmp(&next, &activeMap, sizeof(next)) != 0;
    if (changed) {
      activeMap = next;
      mapNeedsSave = true;
      changeSenderIp = senderIp;
      changeSenderPort = senderPort;
    }
  }
  const bool needsSave = mapNeedsSave;
  portEXIT_CRITICAL(&inputMapMux);
  if (changed) {
    char line[64];
    formatInputMap(line, sizeof(line));
    Serial.printf("input map: %s flags=%u from sender\n", line,
                  (unsigned)next.flags);
  }
  if (!needsSave) return true;
  // The same sender as the last save saves at once - unless another
  // sender's change has been held back since, which is the two-apps case the
  // interval is for.
  const bool sameSender = changeSenderIp == savedSenderIp &&
                          changeSenderPort == savedSenderPort &&
                          !mapHeldBackSinceSave && !lastSaveFailed;
  if (saveNow || (!mapSavedSinceBoot && !lastSaveFailed) || sameSender ||
      millis() - lastMapSaveAt >= INPUT_MAP_SAVE_INTERVAL_MS) {
    return saveInputMap();
  }
  if (changed) mapHeldBackSinceSave = true;
  return true;
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
