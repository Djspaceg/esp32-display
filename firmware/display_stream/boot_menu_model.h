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
  Timed,      // after a user reset: a 5 s countdown, then streaming
  Requested,  // after a triple press: no countdown; stays until chosen
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

// The power-on countdown, shown on the title counting down to streaming. Long
// enough to read the menu and reach for it: the first version was 3 s and was
// gone before a person could use it.
static const uint32_t TIMED_WINDOW_MS = 5000;

// What one press on the menu does.
enum class PressEffect : uint8_t {
  Ignore,      // began before the menu opened: not this menu's press
  CancelOnly,  // stopped the countdown and did nothing else
  Act,         // moves or chooses as usual
};

// The menu's clock. A power-on menu counts down TIMED_WINDOW_MS to streaming,
// so a board nobody touches comes up streaming. A press stops that countdown
// the moment it goes down - not when it is released, or a press made late in
// the countdown would still be down when it ran out and its release would land
// on the streaming firmware as a rotate or power press. That press does nothing
// else, so stopping the clock is never also a selection; from then on the menu
// stays until something is chosen. A menu asked for by a triple press never
// counts down, so its first press acts. A press that went down before the menu
// opened (one made during boot) is ignored outright.
//
// Every time here is from one clock, the one BOOT edges are stamped with; the
// caller must not mix in another. Signed differences keep every comparison
// valid across wrap.
class Countdown {
 public:
  void start(uint32_t now, Opening how) {
    openedAt_ = now;
    counting_ = how == Opening::Timed;
    cancelPending_ = false;
  }

  // A press went down at `at`. Stops a running countdown at once.
  PressEffect onPressDown(uint32_t at) {
    if (beganBeforeOpen(at)) return PressEffect::Ignore;
    if (counting_) {
      counting_ = false;
      cancelPending_ = true;
      cancelledAt_ = at;
      return PressEffect::CancelOnly;
    }
    return PressEffect::Act;
  }

  // A press that went down at pressStartedAt completed (released, or held long
  // enough to choose). The press whose down stopped the countdown is spent on
  // that and does nothing more. A completion whose down was never reported
  // still stops the countdown rather than acting.
  PressEffect onPress(uint32_t pressStartedAt) {
    if (beganBeforeOpen(pressStartedAt)) return PressEffect::Ignore;
    if (cancelPending_ && pressStartedAt == cancelledAt_) {
      cancelPending_ = false;
      return PressEffect::CancelOnly;
    }
    if (counting_) {
      counting_ = false;
      return PressEffect::CancelOnly;
    }
    return PressEffect::Act;
  }

  bool counting() const { return counting_; }

  bool expired(uint32_t now) const {
    return counting_ && now - openedAt_ >= TIMED_WINDOW_MS;
  }

  // Whole seconds left, rounded up, so the title never reads 0 while the menu
  // is still up. Zero once the countdown has stopped or run out.
  uint32_t secondsLeft(uint32_t now) const {
    if (expired(now) || !counting_) return 0;
    return (TIMED_WINDOW_MS - (now - openedAt_) + 999) / 1000;
  }

 private:
  bool beganBeforeOpen(uint32_t at) const {
    return (int32_t)(at - openedAt_) < 0;
  }

  uint32_t openedAt_ = 0;
  uint32_t cancelledAt_ = 0;
  bool counting_ = false;
  bool cancelPending_ = false;
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
