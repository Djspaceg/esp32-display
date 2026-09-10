// NVS persistence for the physical-mounting settings (rotation, backlight
// level, manual power) and the pushed idle-text template.
#pragma once

#include <Arduino.h>
#include <stdint.h>

#include "wifi_presets.h"

// How often loop() checks whether the idle-text template needs saving; the
// bound on flash wear for templates built from live tokens (see
// saveIdleTextPrefsIfChanged in prefs_store.cpp).
extern const uint32_t IDLE_TEXT_SAVE_INTERVAL_MS;

enum class WifiStoreStatus : uint8_t {
  Ok,
  Unavailable,
  SaveFailed,
};

struct WifiStoreResult {
  WifiStoreStatus status = WifiStoreStatus::SaveFailed;
  uint8_t activeSlot = 0;
};

struct WifiCredentialLoadResult {
  uint8_t activeSlot = 0;
  bool ssidFromNvs = false;
};

bool loadWifiPreset(uint8_t slot, wifipresets::Credentials &credentials);
uint16_t validWifiPresetMask();
uint8_t activeWifiPresetSlot();
WifiStoreResult saveWifiPreset(
    uint8_t slot, const wifipresets::Credentials &credentials);
WifiStoreResult clearWifiPreset(uint8_t slot);
WifiStoreStatus selectWifiPreset(uint8_t slot);
bool selectDirectWifiCredentials();
WifiCredentialLoadResult loadEffectiveWifiCredentials(
    const char *fallbackSsid, const char *fallbackPassword, String &ssid,
    String &password);
bool mirrorEffectiveWifiToLegacyAfterConnection();

void saveDisplayPrefs();
void saveIdleTextPrefsIfChanged();
