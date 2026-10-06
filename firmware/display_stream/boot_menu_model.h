// Hardware-free choices, timing, and triple-press detection for the early
// boot-mode menu. The menu reuses the WiFi selector's layout and hit testing
// (wifi_selector_model.h); this header only decides what it offers, whether it
// opens, and when it gives up and starts streaming.
#pragma once

#include <stddef.h>
#include <stdint.h>

namespace bootmenu {

// Streaming is first and is the default: the highlight starts on it, and an
// expired countdown starts it whatever is highlighted.
enum class Mode : uint8_t {
  Streaming = 0,
  Doom,
  Quake,
};

static const size_t MODE_MAX = 3;

// What this image, this resolved board, and this flash can run. A game is
// offered only when all of them hold. Doom also needs a WAD that passes the
// Doom boot's own check, which only a full USB flash writes. No Quake runtime
// exists yet, so nothing sets quakeBuild; a Quake runtime supplies its own
// build flag, board predicate, and data check here.
struct Capabilities {
  bool doomBuild = false;
  bool doomBoard = false;
  bool doomWadReady = false;
  bool quakeBuild = false;
  bool quakeBoard = false;
};

struct Choices {
  Mode modes[MODE_MAX] = {Mode::Streaming, Mode::Streaming, Mode::Streaming};
  size_t count = 0;
};

// Whether this image and board carry any game at all, ignoring whether its data
// is present. Gates the triple press and the decision to read that data. A
// Quake runtime adds its pair here, and nowhere else.
inline bool anyGameBuilt(const Capabilities &caps) {
  return (caps.doomBuild && caps.doomBoard) ||
         (caps.quakeBuild && caps.quakeBoard);
}

inline Choices offeredModes(const Capabilities &caps) {
  Choices choices;
  choices.modes[choices.count++] = Mode::Streaming;
  if (caps.doomBuild && caps.doomBoard && caps.doomWadReady) {
    choices.modes[choices.count++] = Mode::Doom;
  }
  if (caps.quakeBuild && caps.quakeBoard) {
    choices.modes[choices.count++] = Mode::Quake;
  }
  return choices;
}

inline const char *modeLabel(Mode mode) {
  switch (mode) {
    case Mode::Streaming:
      return "STREAMING";
    case Mode::Doom:
      return "DOOM";
    case Mode::Quake:
      return "QUAKE";
  }
  return "?";
}

// Why the chip last reset, reduced to the one fact the menu needs. A person
// powering or resetting the board is there to see the menu. The firmware's own
// restarts (a game exiting, a WiFi switch, OTA) and crash or watchdog resets
// are not, and must recover straight back into streaming.
enum class ResetKind : uint8_t {
  User,
  Automatic,
};

enum class Opening : uint8_t {
  None,
  Timed,      // after a user reset: a short countdown, then streaming
  Requested,  // after a triple press: a longer countdown, then streaming
};

inline Opening opening(ResetKind reset, bool requested, size_t offeredCount,
                       bool hasInput, bool panelManuallyOff) {
  // One choice is no choice, and a board with neither touch nor BOOT could
  // never leave the default anyway.
  if (offeredCount < 2 || !hasInput) return Opening::None;
  if (requested) return Opening::Requested;
  // A panel the user turned off stays dark through a reboot; lighting it for a
  // menu nobody asked for would break that standing instruction.
  if (reset == ResetKind::User && !panelManuallyOff) return Opening::Timed;
  return Opening::None;
}

static const uint32_t TIMED_WINDOW_MS = 3000;
static const uint32_t IDLE_WINDOW_MS = 15000;
// A ceiling on the whole menu, independent of input. Streaming is the default,
// and the default has to be reachable without a person present: a case pressing
// the glass, a noisy touch controller, or a sticky BOOT button would otherwise
// extend the idle window forever and the board would never stream. Generous
// next to the seconds a real choice takes.
static const uint32_t MAX_OPEN_MS = 60000;

// Counts down to streaming. Input restarts it at the idle window, so a person
// reading the menu is not cut off and a menu walked away from mid-way still ends
// up streaming - but never past MAX_OPEN_MS from the moment it opened. Unsigned
// subtraction keeps both deadlines valid across wrap.
class Countdown {
 public:
  void start(uint32_t now, Opening how) {
    openedAt_ = now;
    startedAt_ = now;
    windowMs_ = how == Opening::Requested ? IDLE_WINDOW_MS : TIMED_WINDOW_MS;
  }

  void noteInput(uint32_t now) {
    startedAt_ = now;
    windowMs_ = IDLE_WINDOW_MS;
  }

  bool expired(uint32_t now) const {
    return now - startedAt_ >= windowMs_ || now - openedAt_ >= MAX_OPEN_MS;
  }

  // Whole seconds left on whichever deadline falls first, rounded up, so the
  // display never reads 0 while the menu is still up and never promises time
  // the ceiling will not give.
  uint32_t secondsLeft(uint32_t now) const {
    if (expired(now)) return 0;
    const uint32_t idleLeft = windowMs_ - (now - startedAt_);
    const uint32_t ceilingLeft = MAX_OPEN_MS - (now - openedAt_);
    const uint32_t left = idleLeft < ceilingLeft ? idleLeft : ceilingLeft;
    return (left + 999) / 1000;
  }

 private:
  uint32_t openedAt_ = 0;
  uint32_t startedAt_ = 0;
  uint32_t windowMs_ = TIMED_WINDOW_MS;
};

// Three short BOOT releases inside the window request the menu from a running
// board. Formerly Doom's own entry gesture (doom_check_triple_tap).
static const uint32_t TRIPLE_PRESS_WINDOW_MS = 800;

class TriplePress {
 public:
  bool record(uint32_t releasedAt) {
    if (count_ == 0 || releasedAt - firstAt_ > TRIPLE_PRESS_WINDOW_MS) {
      firstAt_ = releasedAt;
      count_ = 1;
      return false;
    }
    if (++count_ < 3) return false;
    count_ = 0;
    return true;
  }

 private:
  uint32_t firstAt_ = 0;
  uint8_t count_ = 0;
};

}  // namespace bootmenu
