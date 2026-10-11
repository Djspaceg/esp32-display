#pragma once

#include <stdint.h>

namespace buttonpress {

enum class HoldTier : uint8_t {
  Short,
  Long,
  ExtraLong,
};

enum class Action : uint8_t {
  None,
  Short,
  Rotate,
  Power,
};

inline HoldTier holdTier(uint32_t heldMs, uint32_t longPressMs,
                         uint32_t extraLongPressMs) {
  if (heldMs >= extraLongPressMs) return HoldTier::ExtraLong;
  if (heldMs >= longPressMs) return HoldTier::Long;
  return HoldTier::Short;
}

inline Action normalAction(uint32_t heldMs, bool released,
                           uint32_t debounceMs, uint32_t longPressMs,
                           uint32_t extraLongPressMs) {
  switch (holdTier(heldMs, longPressMs, extraLongPressMs)) {
    case HoldTier::ExtraLong:
      return Action::Power;
    case HoldTier::Long:
      return released ? Action::Rotate : Action::None;
    case HoldTier::Short:
      return released && heldMs >= debounceMs ? Action::Short : Action::None;
  }
  return Action::None;
}

enum class ShortPressEffect : uint8_t {
  Single,  // a release that is not the second of a double: acts at once
  Undo,    // the second release of a double takes the first one's act back
  Double,  // then acts as the double
};

struct ShortPressDecision {
  ShortPressEffect effects[2];
  uint8_t count = 0;

  void add(ShortPressEffect effect) {
    if (count < sizeof(effects) / sizeof(effects[0])) {
      effects[count++] = effect;
    }
  }
};

// Models the ordered effects of completed short presses. A first release acts
// at once rather than waiting out the double-press window, so a single press
// costs no latency; a second release inside the window undoes it and acts as
// the double instead. Nothing is deferred to the window's end, so nothing is
// owed when it closes. Unsigned subtraction keeps the window valid across
// clock wrap.
class DoublePressTracker {
 public:
  ShortPressDecision record(uint32_t releasedAt, uint32_t windowMs) {
    ShortPressDecision decision;
    if (armed_ && releasedAt - lastReleaseAt_ <= windowMs) {
      armed_ = false;
      decision.add(ShortPressEffect::Undo);
      decision.add(ShortPressEffect::Double);
      return decision;
    }
    armed_ = true;
    lastReleaseAt_ = releasedAt;
    decision.add(ShortPressEffect::Single);
    return decision;
  }

  // Disarms once the window has closed, so a press long after cannot pair with
  // one from before a clock wrap.
  void resolve(uint32_t now, uint32_t windowMs) {
    if (armed_ && now - lastReleaseAt_ > windowMs) armed_ = false;
  }

  // Disarms now: the next release is a single whatever its timing.
  void flush() { armed_ = false; }

 private:
  bool armed_ = false;
  uint32_t lastReleaseAt_ = 0;
};

}  // namespace buttonpress
