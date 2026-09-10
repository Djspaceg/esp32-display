#include "prefs_store.h"

#include <Arduino.h>
#include <Preferences.h>

#include "app_state.h"
#include "control_apply.h"
#include "device_protocol.h"
#include "display_power.h"
#include "orientation.h"

// NVS. This is what actually bounds flash wear for a template built from
// live tokens ({uptime}, {rssi}) - see saveIdleTextPrefsIfChanged's comment
// for why a reactive, push-triggered check cannot. One minute is short
// enough that a genuinely new template (the case this whole mechanism
// exists for) is saved promptly, and long enough that a template ticking
// with every 2-second EINF still costs at most one write a minute rather
// than one every few seconds.
const uint32_t IDLE_TEXT_SAVE_INTERVAL_MS = 60000;

static void wifiPresetKey(uint8_t slot, char key[6]) {
  snprintf(key, 6, "wfp%02u", (unsigned)slot);
}

static bool loadWifiPreset(Preferences &prefs, uint8_t slot,
                           wifipresets::Credentials &credentials) {
  if (!wifipresets::validSlot(slot)) return false;
  char key[6];
  wifiPresetKey(slot, key);
  if (!prefs.isKey(key)) return false;
  const size_t length = prefs.getBytesLength(key);
  if (length == 0 || length > wifipresets::RECORD_MAX_BYTES) return false;
  uint8_t record[wifipresets::RECORD_MAX_BYTES];
  if (prefs.getBytes(key, record, sizeof(record)) != length) return false;
  return wifipresets::decodeRecord(record, length, credentials) ==
         wifipresets::RecordStatus::Valid;
}

static uint8_t activeWifiPresetSlot(Preferences &prefs) {
  const uint8_t selector =
      prefs.getUChar("wfactive", wifipresets::ACTIVE_DIRECT);
  wifipresets::Credentials credentials;
  return wifipresets::effectiveActiveSlot(
      selector, loadWifiPreset(prefs, selector, credentials));
}

bool loadWifiPreset(uint8_t slot, wifipresets::Credentials &credentials) {
  Preferences prefs;
  if (!prefs.begin("espdisp", true /* read-only */)) return false;
  const bool loaded = loadWifiPreset(prefs, slot, credentials);
  prefs.end();
  return loaded;
}

uint16_t validWifiPresetMask() {
  Preferences prefs;
  if (!prefs.begin("espdisp", true /* read-only */)) return 0;
  uint16_t mask = 0;
  for (uint8_t slot = wifipresets::SLOT_MIN;
       slot <= wifipresets::SLOT_MAX; ++slot) {
    wifipresets::Credentials credentials;
    if (loadWifiPreset(prefs, slot, credentials)) {
      mask |= wifipresets::slotMask(slot);
    }
  }
  prefs.end();
  return mask;
}

uint8_t activeWifiPresetSlot() {
  Preferences prefs;
  if (!prefs.begin("espdisp", true /* read-only */)) return 0;
  const uint8_t slot = activeWifiPresetSlot(prefs);
  prefs.end();
  return slot;
}

WifiStoreResult saveWifiPreset(
    uint8_t slot, const wifipresets::Credentials &credentials) {
  WifiStoreResult result;
  if (!wifipresets::validSlot(slot)) return result;

  uint8_t record[wifipresets::RECORD_MAX_BYTES];
  const size_t recordLength =
      wifipresets::encodeRecord(credentials, record, sizeof(record));
  if (recordLength == 0) return result;

  Preferences prefs;
  if (!prefs.begin("espdisp", false)) return result;
  const uint8_t selector =
      prefs.getUChar("wfactive", wifipresets::ACTIVE_DIRECT);
  result.activeSlot = activeWifiPresetSlot(prefs);
  if (wifipresets::slotMutationNeedsDirect(selector, slot)) {
    if (prefs.putUChar("wfactive", wifipresets::ACTIVE_DIRECT) != 1) {
      prefs.end();
      return result;
    }
    result.activeSlot = 0;
  }

  char key[6];
  wifiPresetKey(slot, key);
  if (prefs.putBytes(key, record, recordLength) == recordLength) {
    result.status = WifiStoreStatus::Ok;
  }
  prefs.end();
  return result;
}

WifiStoreResult clearWifiPreset(uint8_t slot) {
  WifiStoreResult result;
  if (!wifipresets::validSlot(slot)) return result;

  Preferences prefs;
  if (!prefs.begin("espdisp", false)) return result;
  const uint8_t selector =
      prefs.getUChar("wfactive", wifipresets::ACTIVE_DIRECT);
  result.activeSlot = activeWifiPresetSlot(prefs);
  if (wifipresets::slotMutationNeedsDirect(selector, slot)) {
    if (prefs.putUChar("wfactive", wifipresets::ACTIVE_DIRECT) != 1) {
      prefs.end();
      return result;
    }
    result.activeSlot = 0;
  }

  char key[6];
  wifiPresetKey(slot, key);
  const bool removed = !prefs.isKey(key) || prefs.remove(key);
  if (removed) result.status = WifiStoreStatus::Ok;
  prefs.end();
  return result;
}

WifiStoreStatus selectWifiPreset(uint8_t slot) {
  if (!wifipresets::validSlot(slot)) return WifiStoreStatus::Unavailable;
  Preferences prefs;
  if (!prefs.begin("espdisp", false)) return WifiStoreStatus::SaveFailed;
  wifipresets::Credentials credentials;
  if (!loadWifiPreset(prefs, slot, credentials)) {
    prefs.end();
    return WifiStoreStatus::Unavailable;
  }
  const bool saved = prefs.putUChar("wfactive", slot) == 1;
  prefs.end();
  return saved ? WifiStoreStatus::Ok : WifiStoreStatus::SaveFailed;
}

bool selectDirectWifiCredentials() {
  Preferences prefs;
  if (!prefs.begin("espdisp", false)) return false;
  const bool saved =
      prefs.putUChar("wfactive", wifipresets::ACTIVE_DIRECT) == 1;
  prefs.end();
  return saved;
}

WifiCredentialLoadResult loadEffectiveWifiCredentials(
    const char *fallbackSsid, const char *fallbackPassword, String &ssid,
    String &password) {
  WifiCredentialLoadResult result;
  ssid = fallbackSsid;
  password = fallbackPassword;

  Preferences prefs;
  if (!prefs.begin("espdisp", true /* read-only */)) return result;
  const bool legacySsidStored = prefs.isKey("ssid");
  const uint8_t selector =
      prefs.getUChar("wfactive", wifipresets::ACTIVE_DIRECT);
  wifipresets::Credentials credentials;
  const bool presetValid = loadWifiPreset(prefs, selector, credentials);
  if (wifipresets::effectiveOrigin(selector, presetValid, legacySsidStored) ==
      wifipresets::EffectiveOrigin::Preset) {
    ssid = String(credentials.ssid, credentials.ssidLength);
    password = String(credentials.password, credentials.passwordLength);
    result.activeSlot = selector;
    result.ssidFromNvs = true;
  } else {
    ssid = prefs.getString("ssid", fallbackSsid);
    password = prefs.getString("pass", fallbackPassword);
    result.ssidFromNvs = legacySsidStored;
  }
  prefs.end();
  return result;
}

bool mirrorEffectiveWifiToLegacyAfterConnection() {
  if (wifiCredentialPresetSlot == 0) return true;

  Preferences prefs;
  if (!prefs.begin("espdisp", false)) return false;
  const String legacySsid = prefs.getString("ssid", "");
  const String legacyPassword = prefs.getString("pass", "");
  wifipresets::Credentials effective = {};
  effective.ssidLength = (uint8_t)cfgSsid.length();
  effective.passwordLength = (uint8_t)cfgPass.length();
  memcpy(effective.ssid, cfgSsid.c_str(), effective.ssidLength);
  memcpy(effective.password, cfgPass.c_str(), effective.passwordLength);
  if (!wifipresets::mirrorNeeded(
          effective, (const uint8_t *)legacySsid.c_str(), legacySsid.length(),
          (const uint8_t *)legacyPassword.c_str(), legacyPassword.length())) {
    prefs.end();
    return true;
  }

  prefs.putString("ssid", cfgSsid);
  prefs.putString("pass", cfgPass);
  const bool mirrored = prefs.getString("ssid", "") == cfgSsid &&
                        prefs.getString("pass", "") == cfgPass;
  prefs.end();
  return mirrored;
}

// Persist the physical-mounting settings. Only written on a button press or an
// explicit command, so NVS wear is a non-issue.
void saveDisplayPrefs() {
  Preferences prefs;
  prefs.begin("espdisp", false);
  // "rot" supersedes the old "flip" bool (flip true == rot 2). setup() still
  // reads "flip" when no "rot" exists, so a panel upgraded in place keeps its
  // mounting; the old key is left alone rather than deleted, so a downgrade
  // to older firmware also keeps the 180 the two encodings agree on.
  prefs.putUChar("rot", panelRotation);
  prefs.putBool("mirrorx", panelMirrorX);
  prefs.putUChar("bllevel", userBlLevel);
  prefs.putUChar("blfixed", fixedBlLevel);
  prefs.putBool("pwroff", panelManuallyOff);
  prefs.end();
}

// If the idle text held in RAM differs from what NVS last had, write it.
// Called from loop() on IDLE_TEXT_SAVE_INTERVAL_MS, never from the network
// path: see the comment in the ETXT branch of handleInbound for why a
// template built from live tokens ({uptime}, {rssi}) needs a time-bounded
// check rather than a reactive one to keep flash wear bounded at all - the
// EXPANDED TEXT legitimately changes on nearly every push for exactly the
// templates most likely to be in real use, so "did the content change"
// alone does not throttle anything for those.
//
// A device that reboots between checks loses at most one interval's worth of
// freshness in the saved copy - the same trade every polled-write scheme
// like this makes, and cheap next to what it buys: a screensaver template
// that used to vanish on every reboot now needs a genuinely unlucky timing
// window (a change landing in the last IDLE_TEXT_SAVE_INTERVAL_MS before a
// crash) to lose anything at all.
void saveIdleTextPrefsIfChanged() {
  deviceproto::IdleTextMessage snapshot;
  portENTER_CRITICAL(&controlMux);
  snapshot = idleText;
  portEXIT_CRITICAL(&controlMux);

  if (deviceproto::idleTextEqual(snapshot, lastSavedIdleText)) return;

  char encoded[deviceproto::IDLE_TEXT_MAX_BYTES];
  size_t n = deviceproto::encodeIdleTextForStorage(
      snapshot, encoded, sizeof(encoded));
  // A message that could not be encoded (should not happen: the buffer is
  // sized for the protocol's own maximum) is left as whatever NVS already
  // held rather than saving something truncated. lastSavedIdleText is
  // deliberately NOT updated here, so the next check retries rather than
  // treating a failed encode as if it had succeeded.
  if (n == 0 && snapshot.lineCount > 0) return;

  Preferences prefs;
  prefs.begin("espdisp", false);
  prefs.putString("idletxt", encoded);
  prefs.end();
  lastSavedIdleText = snapshot;
  Serial.printf("idle text saved to NVS (%u lines, %u bytes)\n",
                (unsigned)snapshot.lineCount, (unsigned)n);
}
