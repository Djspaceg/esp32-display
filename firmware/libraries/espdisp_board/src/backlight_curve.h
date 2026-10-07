// Backlight level (0..255) to PWM duty, for glass that stays dark below some
// duty (Config::backlightFloorPermille). Host-testable: no hardware headers.
#pragma once

#include <stdint.h>

namespace backlightcurve {

/// Level 0 is off. Every other level gets the linear duty it always had, but
/// never less than the floor: a level the glass already showed keeps its
/// duty (and its current draw), and one that left it black - the dimmed
/// status card on a P4 - lights at the floor instead.
inline uint32_t duty(uint8_t level, uint16_t floorPermille, uint32_t fullDuty) {
  if (level == 0) return 0;
  const uint32_t linear = ((uint32_t)level * fullDuty) / 255u;
  if (floorPermille > 1000) floorPermille = 1000;
  const uint32_t floorDuty =
      ((uint32_t)floorPermille * fullDuty + 999u) / 1000u;
  return linear < floorDuty ? floorDuty : linear;
}

}  // namespace backlightcurve
