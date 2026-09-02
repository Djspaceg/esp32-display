// NVS persistence for the physical-mounting settings (rotation, backlight
// level, manual power) and the pushed idle-text template.
#pragma once

#include <stdint.h>

// How often loop() checks whether the idle-text template needs saving; the
// bound on flash wear for templates built from live tokens (see
// saveIdleTextPrefsIfChanged in prefs_store.cpp).
extern const uint32_t IDLE_TEXT_SAVE_INTERVAL_MS;

void saveDisplayPrefs();
void saveIdleTextPrefsIfChanged();
