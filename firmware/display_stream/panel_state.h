// Panel state that is pure arithmetic: what the backlight should be, and how
// the device's state packs into the flags byte the sender reads.
//
// Both were inline in the sketch, where they could only be verified by watching
// a panel. The backlight one in particular now has three inputs and a priority
// order between them, and it is consulted from eight places.
#pragma once

#include <stdint.h>

namespace panelstate {

/// What the backlight PWM should be set to.
///
/// Priority matters: sleep beats idle beats the user's level. The Mac's screens
/// being asleep is the strongest signal there is nothing worth lighting, and the
/// idle card is deliberately dim whatever brightness the user picked.
inline uint8_t backlightLevel(bool sleeping, bool idle, uint8_t userLevel,
                              uint8_t idleLevel) {
  if (sleeping) return 0;
  if (idle) return idleLevel;
  return userLevel;
}

/// Bit 0 of the reported flags: whether the level counts as "high".
///
/// With any level now reachable the flag has to be derived rather than stored,
/// or the high/low toggle in the UI would disagree with the actual brightness.
inline bool brightnessIsHigh(uint8_t userLevel, uint8_t lowLevel) {
  return userLevel > lowLevel;
}

/// Pack device state into the EINF/EACK flags byte.
inline uint8_t deviceFlags(bool brightnessHigh, bool flipped, bool sleeping,
                           bool idle, bool wifiConnected) {
  uint8_t flags = 0;
  if (brightnessHigh) flags |= 0x01;
  if (flipped) flags |= 0x02;
  if (sleeping) flags |= 0x04;
  if (idle) flags |= 0x08;
  if (wifiConnected) flags |= 0x10;
  return flags;
}

}  // namespace panelstate
