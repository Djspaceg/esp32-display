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

// What a counted press run settled to: `expired` is a run whose window had
// already closed when this press came (normally resolve() took it first), and
// `now` a run this press completed by reaching the highest tier bound.
struct PressCounts {
  uint8_t expired = 0;
  uint8_t now = 0;
};

// Counts short presses into singles, doubles and triples for an input map
// whose short tiers are no longer today's, where a single cannot be undone
// by the double after it. A run acts once its window closes, or at once when
// it reaches `maxCount`, the highest tier with a function, so a single with
// no double or triple bound still costs no latency. Unsigned subtraction
// keeps the window valid across clock wrap.
class PressCounter {
 public:
  PressCounts record(uint32_t releasedAt, uint32_t windowMs, uint8_t maxCount) {
    PressCounts counts;
    if (count_ != 0 && releasedAt - lastReleaseAt_ > windowMs) {
      counts.expired = count_;
      count_ = 0;
    }
    count_++;
    lastReleaseAt_ = releasedAt;
    if (count_ >= maxCount) {
      counts.now = count_;
      count_ = 0;
    }
    return counts;
  }

  // The run whose window has closed by `now`, or 0.
  uint8_t resolve(uint32_t now, uint32_t windowMs) {
    if (count_ == 0 || now - lastReleaseAt_ <= windowMs) return 0;
    return settle();
  }

  // Ends the run now and returns its count, or 0 if none is open.
  uint8_t settle() {
    const uint8_t pending = count_;
    count_ = 0;
    return pending;
  }

 private:
  uint8_t count_ = 0;
  uint32_t lastReleaseAt_ = 0;
};

// A second key's two inputs, the PWR key's: a press, reported on release, and
// a long press, reported once while it is still held at `longMs`, after which
// its release reports nothing. Fed the key's level on every poll; a level
// counts once it has held for `debounceMs`. Unsigned subtraction keeps the
// timing valid across clock wrap.
enum class KeyEvent : uint8_t { None, Press, LongPress };

class KeyTracker {
 public:
  KeyEvent update(uint32_t now, bool down, uint32_t debounceMs,
                  uint32_t longMs) {
    if (down != candidate_) {
      candidate_ = down;
      candidateSince_ = now;
    }
    if (candidate_ != stable_ && now - candidateSince_ >= debounceMs) {
      stable_ = candidate_;
      if (stable_) {
        downAt_ = candidateSince_;
        longFired_ = false;
      } else if (!longFired_) {
        return KeyEvent::Press;
      }
    }
    if (stable_ && !longFired_ && now - downAt_ >= longMs) {
      longFired_ = true;
      return KeyEvent::LongPress;
    }
    return KeyEvent::None;
  }

 private:
  bool candidate_ = false;
  bool stable_ = false;
  bool longFired_ = false;
  uint32_t candidateSince_ = 0;
  uint32_t downAt_ = 0;
};

}  // namespace buttonpress
