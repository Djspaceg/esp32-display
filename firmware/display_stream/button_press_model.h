#pragma once

#include <stdint.h>

namespace buttonpress {

enum class ShortPressEffect : uint8_t {
  Preview,
  Commit,
  Revert,
  Double,
};

struct ShortPressDecision {
  ShortPressEffect effects[3];
  uint8_t count = 0;

  void add(ShortPressEffect effect) {
    if (count < sizeof(effects) / sizeof(effects[0])) {
      effects[count++] = effect;
    }
  }
};

// Models the ordered effects of completed short presses. A first release can
// preview immediately, then commits only after the double-press window closes.
// Unsigned subtraction keeps that window valid across clock wrap.
class DoublePressTracker {
 public:
  ShortPressDecision record(uint32_t releasedAt, uint32_t windowMs,
                            bool previewEnabled) {
    ShortPressDecision decision;
    if (armed_ && releasedAt - lastReleaseAt_ <= windowMs) {
      armed_ = false;
      if (pendingPreview_) {
        decision.add(ShortPressEffect::Revert);
      }
      pendingPreview_ = false;
      decision.add(ShortPressEffect::Double);
      return decision;
    }
    if (armed_ && pendingPreview_) {
      decision.add(ShortPressEffect::Commit);
    }
    armed_ = true;
    lastReleaseAt_ = releasedAt;
    pendingPreview_ = previewEnabled;
    if (previewEnabled) {
      decision.add(ShortPressEffect::Preview);
    }
    return decision;
  }

  ShortPressDecision resolve(uint32_t now, uint32_t windowMs) {
    ShortPressDecision decision;
    if (armed_ && now - lastReleaseAt_ > windowMs) {
      armed_ = false;
      if (pendingPreview_) {
        decision.add(ShortPressEffect::Commit);
      }
      pendingPreview_ = false;
    }
    return decision;
  }

  ShortPressDecision flush() {
    ShortPressDecision decision;
    armed_ = false;
    if (pendingPreview_) {
      decision.add(ShortPressEffect::Commit);
    }
    pendingPreview_ = false;
    return decision;
  }

 private:
  bool armed_ = false;
  bool pendingPreview_ = false;
  uint32_t lastReleaseAt_ = 0;
};

}  // namespace buttonpress
