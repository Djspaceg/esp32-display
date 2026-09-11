#pragma once

#include <stdint.h>

namespace buttonpress {

enum class ShortPressResult : uint8_t {
  Single,
  Double,
};

// Classifies completed short presses without treating the first press after
// boot as a double. Unsigned subtraction keeps the window valid across wrap.
class DoublePressTracker {
 public:
  ShortPressResult record(uint32_t releasedAt, uint32_t windowMs) {
    if (armed_ && releasedAt - lastReleaseAt_ <= windowMs) {
      armed_ = false;
      return ShortPressResult::Double;
    }
    armed_ = true;
    lastReleaseAt_ = releasedAt;
    return ShortPressResult::Single;
  }

  void reset() { armed_ = false; }

 private:
  bool armed_ = false;
  uint32_t lastReleaseAt_ = 0;
};

}  // namespace buttonpress
