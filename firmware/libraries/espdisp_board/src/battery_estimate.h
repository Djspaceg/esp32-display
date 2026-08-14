// Pure battery-voltage helpers shared by the C6 ADC reader and host tests.
#pragma once

#include <stddef.h>
#include <stdint.h>

namespace batteryestimate {

// Below this, the divided input is noise or an absent cell rather than a LiPo
// that can safely run the board.
static const uint16_t PRESENT_MILLIVOLTS = 2500;

struct CurvePoint {
  uint16_t millivolts;
  uint8_t percent;
};

// A conservative one-cell LiPo open-circuit curve. The C6 has no fuel gauge,
// so this is necessarily an estimate and intentionally avoids claiming the
// linear 3.3-4.2V mapping that overstates the long voltage plateau.
static const CurvePoint CURVE[] = {
    {3300, 0}, {3500, 5}, {3600, 10}, {3700, 20}, {3750, 35},
    {3800, 50}, {3850, 65}, {3900, 75}, {4000, 85}, {4100, 95},
    {4200, 100},
};

inline bool cellPresent(uint16_t millivolts) {
  return millivolts >= PRESENT_MILLIVOLTS;
}

inline uint8_t percentFromMillivolts(uint16_t millivolts) {
  if (millivolts <= CURVE[0].millivolts) return CURVE[0].percent;
  const size_t count = sizeof(CURVE) / sizeof(CURVE[0]);
  for (size_t i = 1; i < count; i++) {
    if (millivolts <= CURVE[i].millivolts) {
      const CurvePoint &a = CURVE[i - 1];
      const CurvePoint &b = CURVE[i];
      const uint32_t numerator =
          (uint32_t)(millivolts - a.millivolts) * (b.percent - a.percent);
      return (uint8_t)(a.percent + numerator / (b.millivolts - a.millivolts));
    }
  }
  return 100;
}

}  // namespace batteryestimate
