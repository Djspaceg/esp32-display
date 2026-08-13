// Panel state that is pure arithmetic: what the backlight should be, and how
// the device's state packs into the flags byte the sender reads.
//
// Both were inline in the sketch, where they could only be verified by watching
// a panel. The backlight one in particular now has three inputs and a priority
// order between them, and it is consulted from eight places.
#pragma once

#include <stdint.h>
#include <stdio.h>

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

/// The charge word this project uses everywhere a battery reading is shown to
/// a person: the serial status line (batteryChargeWord() in display_stream.ino,
/// which now just forwards here), the idle card, and CFGSHOW's prose. One
/// word per charge state, kept in one place so the on-device card and the
/// serial line cannot drift into disagreeing about what "Standby" is called.
enum class Charge : uint8_t { Unknown, Charging, Discharging, Standby };

inline const char *chargeWord(Charge charge) {
  switch (charge) {
    case Charge::Charging:
      return "charging";
    case Charge::Discharging:
      return "discharging";
    case Charge::Standby:
      return "standby";
    default:
      return "unknown";
  }
}

/// Format the idle card's battery line, the on-device text a person actually
/// sees - as opposed to shouldShowBatteryLine(), which only decides whether a
/// battery line appears at all.
///
/// Extracted for the same reason shouldShowBatteryLine() was: drawIdleScreen()
/// touches the framebuffer and cannot be host-tested, but the three-way
/// decision of what the line SAYS has no hardware dependency and is exactly
/// the kind of branching most likely to be gotten wrong by inspection alone.
///
/// Before this, the on-device card only ever said "batt NN% chg" or
/// "batt NN%" - Discharging and Standby were indistinguishable on the glass,
/// even though the wire protocol (deviceproto::ChargeState) and the Mac app's
/// battery description have always carried the full three-way state. This is
/// the fix for that gap: the on-device word now matches chargeWord() above,
/// so a person looking at the panel gets the same distinction the app already
/// shows, not merely "is it charging or not".
///
/// externalPower means the board is on USB power; present means the AXP2101
/// can actually see a cell. A board on USB power with no cell attached says
/// so plainly rather than reporting a percentage that does not exist -
/// drawIdleScreen already special-cased this before percentKnown/charge
/// mattered, so the case is preserved rather than folded into a charge word
/// that presumes a battery is there to have a state at all.
///
/// out must be at least 24 bytes, matching drawIdleScreen()'s lineBattery
/// buffer; this only formats into a caller-supplied buffer rather than
/// returning a std::string because the sketch has none of <string>'s
/// allocator wired up and every other line here is a stack char[].
inline void formatBatteryLine(char *out, size_t outLen, bool externalPower,
                              bool present, bool percentKnown, uint8_t percent,
                              Charge charge) {
  if (externalPower && !present) {
    snprintf(out, outLen, "usb power");
  } else if (percentKnown) {
    snprintf(out, outLen, "batt %u%% %s", (unsigned)percent, chargeWord(charge));
  } else {
    snprintf(out, outLen, "batt --");
  }
}

/// The idle card's WiFi status line, extracted from drawIdleScreen() for the
/// same reason formatBatteryLine() was: pure text formatting with no
/// hardware dependency, and the second caller (the quick-tap info bar) needs
/// the exact same line rather than a second, possibly-drifting copy of the
/// same snprintf.
inline void formatWifiLine(char *out, size_t outLen, bool connected,
                           int rssiDbm) {
  if (connected) {
    snprintf(out, outLen, "wifi %d dBm", rssiDbm);
  } else {
    snprintf(out, outLen, "wifi down");
  }
}

/// The quick info bar's row range for a panel of the given dimensions and
/// glass shape.
///
/// On round glass a bar starting at row 0 would have its ends clipped by the
/// bezel - the topmost point of a circle is a single pixel wide, not a full
/// row - so it needs the same inset the idle card already applies for
/// exactly that reason (see drawIdleScreen()'s margin computation, which
/// this mirrors rather than duplicates a second definition of). Rectangular
/// panels get the plain 4px margin every other on-glass text already uses.
inline void infoBarRowRange(int frameWidth, int frameHeight, bool roundDisplay,
                            int lineHeight, int &y0, int &y1) {
  int marginTop = 4;
  if (roundDisplay) {
    int d = frameWidth < frameHeight ? frameWidth : frameHeight;
    marginTop += (int)(0.1465f * (float)d);
  }
  y0 = marginTop;
  y1 = marginTop + lineHeight;
  if (y1 > frameHeight) y1 = frameHeight;
}

/// Elapsed time since `last`, clamped to zero rather than propagating an
/// unsigned wraparound.
///
/// `now - last` is only safe when `last` was captured strictly before `now`
/// was measured. `lastSenderPacketAt` in display_stream.ino is a volatile
/// written by a different, higher-priority receive task every time a packet
/// arrives; loop() reads `millis()` for `now` and then reads that volatile
/// as `last` in two separate steps, so a packet landing in between can leave
/// `last` newer than the `now` already captured. `now - last` then
/// underflows a uint32_t to roughly UINT32_MAX - about 4294967 seconds, and
/// is exactly what put "sender silent 4294967s" in the serial log while the
/// sender was actively streaming (heavier traffic means more chances for
/// the race to land in that window, which is why it got worse "when the
/// device is overwhelmed with frames").
///
/// A `last` newer than `now` is, if anything, evidence of MORE recent
/// activity than the caller already knew about - not less - so clamping to
/// zero elapsed time is the correct answer for this race, not merely a safe
/// fallback: a real 45-second silence can never produce `last > now`, so
/// this can only fire on the race itself, and firing on it means "not
/// silent" rather than "silent for 4.9 million seconds", which is what
/// caused idleActive to flash on for one loop iteration and off the next -
/// the flashing To-do item 13 describes.
inline uint32_t millisSince(uint32_t now, uint32_t last) {
  return (int32_t)(now - last) < 0 ? 0 : now - last;
}

/// Whether two row ranges [aStart, aEnd) and [bStart, bEnd) share any row.
///
/// This is what decides whether a newly-arrived frame band needs the info
/// bar redrawn on top of it: the streaming path memcpy's fresh pixel data
/// into every dirty run regardless of what is currently on the glass, so any
/// run whose rows overlap the bar's would silently erase it without this
/// check gating a redraw.
inline bool rowRangeOverlaps(int aStart, int aEnd, int bStart, int bEnd) {
  return aStart < bEnd && bStart < aEnd;
}

/// The left edge for a string of the given pixel width centred in a
/// container of containerWidth pixels, never negative - a string wider than
/// its container (an unusually long custom line) starts flush left rather
/// than at a negative x that would clip its start off the buffer's edge.
inline int centeredX(int containerWidth, int textWidthPx) {
  int x = (containerWidth - textWidthPx) / 2;
  return x < 0 ? 0 : x;
}

}  // namespace panelstate
