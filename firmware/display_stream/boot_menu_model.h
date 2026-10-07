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
  CancelOnly,  // stopped the countdown, or was spent on doing so; nothing else
  Act,         // moves or chooses as usual
};

// Where a press came from. A cancelling press is matched by source as well as
// time: BOOT, touch and knob are stamped at different moments, so two of them
// can share a millisecond.
enum class PressSource : uint8_t {
  Boot,
  Touch,
  Knob,
};

// Detents closer together than this are one knob gesture (a flick), even when
// they arrive over several loop passes.
static const uint32_t KNOB_GESTURE_MS = 250;

// How far before the menu a press can have gone down. Setup reaches the menu
// well inside this; past it the before-open test is switched off for good, so
// a menu left open for weeks cannot read a press as one from before it.
static const uint32_t BEFORE_OPEN_HORIZON_MS = 600000;

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
// caller must not mix in another. tick() must be called as the menu runs.
class Countdown {
 public:
  void start(uint32_t now, Opening how) {
    openedAt_ = now;
    counting_ = how == Opening::Timed;
    cancelPending_ = false;
    turnSpentAt_ = 0;
    turnSpent_ = false;
    beforeOpenPossible_ = true;
  }

  // Called every pass. Retires the before-open test once no press stamped
  // before the menu can still arrive.
  void tick(uint32_t now) {
    if (beforeOpenPossible_ && now - openedAt_ >= BEFORE_OPEN_HORIZON_MS) {
      beforeOpenPossible_ = false;
    }
  }

  // A press went down at `at`. Stops a running countdown at once.
  PressEffect onPressDown(uint32_t at, PressSource source) {
    if (beganBeforeOpen(at)) return PressEffect::Ignore;
    // A new press from this source means its earlier one has ended.
    if (cancelPending_ && cancelSource_ == source && at != cancelledAt_) {
      cancelPending_ = false;
    }
    if (counting_) {
      counting_ = false;
      cancelPending_ = true;
      cancelledAt_ = at;
      cancelSource_ = source;
      return PressEffect::CancelOnly;
    }
    return PressEffect::Act;
  }

  // A press that went down at pressStartedAt completed (released, or held long
  // enough to choose). The press whose down stopped the countdown is spent on
  // that and does nothing more. A completion whose down was never reported
  // still stops the countdown rather than acting.
  PressEffect onPress(uint32_t pressStartedAt, PressSource source) {
    if (beganBeforeOpen(pressStartedAt)) return PressEffect::Ignore;
    if (isCancellingPress(pressStartedAt, source)) {
      cancelPending_ = false;
      return PressEffect::CancelOnly;
    }
    if (counting_) {
      counting_ = false;
      return PressEffect::CancelOnly;
    }
    return PressEffect::Act;
  }

  // A knob turn at `at`, down and completed at once. Spent, not acted on, while
  // it continues a flick that stopped the countdown, or while the BOOT or touch
  // press that stopped it is still down (press-and-turn is one gesture).
  // pressHeld says whether a BOOT or touch press is physically down now: a press
  // that ended without completing on the menu (released after a turn, or a
  // touch held too long to be a tap) never reports its end here, so the pending
  // cancel alone cannot say it is still held.
  PressEffect onTurn(uint32_t at, bool pressHeld) {
    if (beganBeforeOpen(at)) return PressEffect::Ignore;
    if (turnSpent_ && at - turnSpentAt_ < KNOB_GESTURE_MS) {
      turnSpentAt_ = at;  // the flick goes on
      return PressEffect::CancelOnly;
    }
    turnSpent_ = false;
    if (cancelPending_) {
      if (pressHeld) return PressEffect::CancelOnly;
      cancelPending_ = false;  // that press has ended
    }
    if (counting_) {
      counting_ = false;
      turnSpent_ = true;
      turnSpentAt_ = at;
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
    if (!counting_ || expired(now)) return 0;
    return (TIMED_WINDOW_MS - (now - openedAt_) + 999) / 1000;
  }

 private:
  // Up to BEFORE_OPEN_HORIZON_MS before the opening, and only while that test
  // is still live. Unsigned throughout, so it holds across clock wrap.
  bool beganBeforeOpen(uint32_t at) const {
    if (!beforeOpenPossible_) return false;
    const uint32_t ahead = openedAt_ - at;  // how far before opening, if any
    return ahead != 0 && ahead <= BEFORE_OPEN_HORIZON_MS;
  }

  bool isCancellingPress(uint32_t at, PressSource source) const {
    return cancelPending_ && cancelSource_ == source && cancelledAt_ == at;
  }

  uint32_t openedAt_ = 0;
  uint32_t cancelledAt_ = 0;
  uint32_t turnSpentAt_ = 0;
  PressSource cancelSource_ = PressSource::Boot;
  bool counting_ = false;
  bool cancelPending_ = false;
  bool turnSpent_ = false;
  bool beforeOpenPossible_ = true;
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
