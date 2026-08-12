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
/// Priority matters: a manual "off" beats a finger beats sleep beats idle
/// beats the user's level.
///
/// manuallyOff is the user's own standing instruction (ControlOpcode::Power),
/// not a state the panel or the Mac arrives at on its own the way sleeping
/// and idle do - and it is the one thing a finger must NOT override. Every
/// other dimmed state exists to save the panel from showing something stale
/// or wasteful, and a touch answering "is this thing on?" is exactly the
/// right response to those; a touch answering the same question about a
/// display the user explicitly turned off would just turn it back on
/// without asking, which is not what "off" means.
///
/// Below that: the Mac's screens being asleep is the strongest remaining
/// signal there is nothing worth lighting, and the idle card is deliberately
/// dim whatever brightness the user picked - but someone physically touching
/// the panel outranks both. touchWake is time-bounded by the caller and
/// never tells the Mac anything, so it lights the panel without
/// contradicting the Mac's own idea of whether its displays are asleep.
inline uint8_t backlightLevel(bool manuallyOff, bool sleeping, bool idle,
                              bool touchWake, uint8_t userLevel,
                              uint8_t idleLevel) {
  if (manuallyOff) return 0;
  if (touchWake) return userLevel;
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
///
/// rotation is the user's mounting rotation in clockwise quarter turns, 0-3.
/// It occupies two places at once, deliberately:
///
///   bit 1    the historical "flipped" flag, set exactly when rotation == 2.
///            Old senders read this bit as "rotated 180" and must keep
///            getting the truth: a quarter turn (1 or 3) is NOT a 180 flip,
///            so the bit stays clear there rather than rounding to it.
///   bits 5-6 the full rotation, for senders that know Rotate. Bits 0-4 were
///            already taken (brightness, flipped, sleeping, idle, wifi), and
///            an old sender masks the bits it knows, so these read as zero
///            noise to it.
///   bit 7    the user's standing "display off" instruction
///            (ControlOpcode::Power), independent of sleeping/idle - those
///            are transient states the panel or the Mac arrives at and
///            clears on the next drawn frame, while this one persists until
///            the user turns it back on. A sender needs both: "sleeping"
///            answers "is the Mac's own display state driving this dark
///            right now", "manuallyOff" answers "did the user ask for this
///            panel specifically to stay dark".
///
/// Derived from one input rather than passed as two, so the pair cannot
/// disagree - a flags byte claiming "flipped" with rotation bits saying 1
/// is unrepresentable here.
inline uint8_t deviceFlags(bool brightnessHigh, uint8_t rotation, bool sleeping,
                           bool idle, bool wifiConnected, bool manuallyOff) {
  uint8_t flags = 0;
  if (brightnessHigh) flags |= 0x01;
  if ((rotation & 3) == 2) flags |= 0x02;
  if (sleeping) flags |= 0x04;
  if (idle) flags |= 0x08;
  if (wifiConnected) flags |= 0x10;
  flags |= (uint8_t)((rotation & 3) << 5);
  if (manuallyOff) flags |= 0x80;
  return flags;
}

/// The idle card's default status lines: name, address, wifi, and - only for a
/// board with a PMU and a current reading - battery.
///
/// Extracted from drawIdleScreen() so the decision of which lines to show and
/// in what order is host-testable; drawIdleScreen() itself cannot be, since it
/// touches the framebuffer and WiFi. This only decides *whether* the battery
/// line appears, not its text - the caller formats "batt 84%" or similar and
/// passes the finished C string in, because formatting needs snprintf and a
/// charge-state word this header does not have.
///
/// hasBattery is the board fact (bcfg->hasBattery()); readingCurrent is
/// whether the last PMU sample has not aged out (batteryReadingCurrent()). A
/// board with a PMU whose reading has gone stale shows no line rather than a
/// frozen number - the same reasoning CFGSHOW and the serial report already
/// apply to the reading itself, now applied to whether it appears on glass at
/// all.
inline bool shouldShowBatteryLine(bool hasBattery, bool readingCurrent) {
  return hasBattery && readingCurrent;
}

}  // namespace panelstate
