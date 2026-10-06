// Early boot-mode menu: Streaming (the default), Doom, and a slot for Quake.
// Runs inside setup() after the panel, touch, and BOOT input are up and before
// WiFi starts. Driven by touch and by BOOT the same way as the WiFi selector:
// tap or short press moves, START or a BOOT hold chooses. A game is entered
// through its existing one-shot flag and a restart, so it still owns the panel
// and PSRAM alone, and a failed or missing game boots back into streaming.
#pragma once

#include <stdint.h>

// Compiled only into images that carry a game runtime. A C6 or C3 image runs
// none, so its menu could only ever offer Streaming; leaving the screen, the
// loop, and the model out of those builds keeps them off an image that is
// already near its flash limit.
//
// A Quake runtime adds its flag to this condition AND its build/board pair to
// builtCapabilities() in boot_menu.cpp, which bootmenu::anyGameBuilt() reads.
// This marker alone would compile the menu in without offering anything.
#if defined(ESPDISP_DOOM_RUNTIME)
#define ESPDISP_BOOT_MENU_RUNTIME 1
#endif

#if defined(ESPDISP_BOOT_MENU_RUNTIME)

// Consumes the one-shot menu request a triple press saved. Call once, early in
// setup(), before anything fallible, so a request can never repeat.
bool takeBootMenuRequest();

// Whether this image and resolved board run any game at all, ignoring whether
// its data is present. Cheap; gates the triple press so boards with nothing to
// offer keep ordinary presses, and gates the flash read that checks the data.
bool bootMenuMayOfferGames();

// Whether the menu would offer anything besides streaming right now, checking
// each game's data. When it would not, *refusal (if given) names why.
bool bootMenuOffered(const char **refusal);

// Saves the one-shot request and restarts into the menu. Returns only if the
// request could not be saved.
void requestBootMenuAndRestart();

// Shows the menu if this boot should, and returns once streaming is chosen or
// the countdown runs out. Returns whether the menu was opened, so the caller
// knows to repaint what it drew over. A game choice restarts and never returns.
bool runBootMenuIfDue(bool requested);

// While true, handleButton() and serviceTouch() route input here.
extern bool bootMenuActive;
void moveBootMenu(int direction);
void activateBootMenu();
void handleBootMenuTap(int16_t x, int16_t y);

#else

// No game in this image: every caller compiles unchanged and the menu is gone.
inline bool takeBootMenuRequest() { return false; }
inline bool bootMenuMayOfferGames() { return false; }
inline bool bootMenuOffered(const char **refusal) {
  if (refusal != nullptr) *refusal = nullptr;
  return false;
}
inline void requestBootMenuAndRestart() {}
inline bool runBootMenuIfDue(bool) { return false; }
inline constexpr bool bootMenuActive = false;
inline void moveBootMenu(int) {}
inline void activateBootMenu() {}
inline void handleBootMenuTap(int16_t, int16_t) {}

#endif
