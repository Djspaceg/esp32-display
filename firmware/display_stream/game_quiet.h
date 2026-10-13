// Quiet mode (CFGQUIET 0|1): Doom and Quake boot with no sound at all, for
// benchmark and demo runs at a desk. Both games start their audio through
// doom_audio_begin() (display_stream/doom_audio.cpp), which declines while
// this is on, so neither engine mixes a sample and the codec and amplifier
// stay off. Streaming audio from the Mac does not read it.
#pragma once

#include <Preferences.h>

// A bool in the "espdisp" namespace; absent means off.
#define GAME_QUIET_KEY "quiet"

inline bool gameQuietEnabled() {
  Preferences prefs;
  if (!prefs.begin("espdisp", true)) return false;
  const bool quiet = prefs.getBool(GAME_QUIET_KEY, false);
  prefs.end();
  return quiet;
}
