// What the AXP2101's two status registers mean, as pure functions.
//
// WHY THIS IS NOT IN board_power.h. That file needs Arduino.h and Wire.h, so
// nothing in it can be reached from the host test suite, and the consequence
// showed up on the bench: a plugged-in board reported "discharging 3844mV
// vbus=0" for as long as this decode has existed, and no test could have caught
// it because no test could call it. The register reads stay in board_power.h;
// the decisions taken from the bytes live here, where they are testable.
//
// Register semantics: X-Powers AXP2101 datasheet,
// files.waveshare.com/wiki/common/X-power-AXP2101_SWcharge_V1.0.pdf,
// cross-checked against XPowersLib's AXP2101Constants.h and
// XPowersAXP2101.tpp (github.com/lewisxhe/XPowersLib).
#pragma once

#include <stdint.h>

namespace axp2101 {

// REG 00, STATUS1.
static const uint8_t STATUS1_VBUS_GOOD = 1u << 5;
static const uint8_t STATUS1_BATTERY_PRESENT = 1u << 3;

// REG 01, STATUS2, bit 3: VINDPM status.
//
// THIS BIT WAS MISNAMED. It used to be called STATUS2_VBUS_NOT_IN and was
// ANDed into the external-power answer as though a 1 here meant "no input".
// It does not. VINDPM is the charger's input dynamic power management loop: the
// bit asserts when the input voltage has sagged to the VINDPM threshold and the
// charger is throttling how much current it draws so the supply does not
// collapse further. That can only happen while an input is connected and
// supplying the board. So the old test read the strongest possible evidence of
// external power as proof of its absence, and it did so exactly in the case
// that provokes it: a long or weak cable feeding a hungry board.
static const uint8_t STATUS2_VINDPM = 1u << 3;

// REG 01, STATUS2, bits 6:5: which way current is moving at the cell.
static const uint8_t STATUS2_CHARGE_DIRECTION_SHIFT = 5;
static const uint8_t STATUS2_CHARGE_DIRECTION_MASK = 0x03;

// Direction codes carried in those two bits.
static const uint8_t DIRECTION_STANDBY = 0;
static const uint8_t DIRECTION_CHARGING = 1;
static const uint8_t DIRECTION_DISCHARGING = 2;

/// Whether external power is supplying the board, as a THREE-valued answer.
///
/// Unknown is the point of the type. A board with no path to the question - the
/// ADC-divider boards, whose charger status output drives only an LED - must be
/// able to say so rather than assert Absent, because a consumer has to be able
/// to tell "nothing is plugged in" apart from "this board cannot tell you".
/// That is already how charge state is handled, and for the same reason.
enum class External : uint8_t { Unknown = 0, Absent = 1, Present = 2 };

inline bool batteryPresent(uint8_t status1) {
  return (status1 & STATUS1_BATTERY_PRESENT) != 0;
}

/// Decide external power from the two status bytes.
///
/// Never returns Unknown: a part that answers this question at all answers it
/// definitively. Unknown belongs to the boards that have no AXP2101.
/// status2 is accepted and deliberately unused. It is what the old test ANDed
/// in, and taking it keeps the call site reading as "decide from both status
/// registers" so a future field that genuinely lives in STATUS2 has somewhere
/// to go. Nothing in STATUS2 bears on whether an input is present.
inline External externalFromStatus(uint8_t status1, uint8_t status2) {
  (void)status2;
  return (status1 & STATUS1_VBUS_GOOD) != 0 ? External::Present
                                            : External::Absent;
}

/// The raw two-bit current direction from STATUS2.
inline uint8_t chargeDirection(uint8_t status2) {
  return (uint8_t)((status2 >> STATUS2_CHARGE_DIRECTION_SHIFT) &
                   STATUS2_CHARGE_DIRECTION_MASK);
}

// REG 16 bits 2:0: the VBUS input current limit (XPowersLib's
// xpowers_axp2101_vbus_cur_limit_t: 100, 500, 900, 1000, 1500, 2000 mA).
static const uint8_t INPUT_LIMIT_MASK = 0x07;
static const uint8_t INPUT_LIMIT_1500MA = 0x04;

/// The limit a REG 16 value sets, in mA; 0 for the reserved codes 6 and 7.
inline int inputLimitMilliamps(uint8_t reg16) {
  static const int MILLIAMPS[] = {100, 500, 900, 1000, 1500, 2000};
  const uint8_t code = reg16 & INPUT_LIMIT_MASK;
  return code < 6 ? MILLIAMPS[code] : 0;
}

/// REG 16 with the limit raised to 1500 mA when it is lower (or reserved),
/// and the other bits kept. A 2000 mA setting is left alone.
inline uint8_t raisedInputLimit(uint8_t reg16) {
  if (inputLimitMilliamps(reg16) >= 1500) return reg16;
  return (uint8_t)((reg16 & (uint8_t)~INPUT_LIMIT_MASK) | INPUT_LIMIT_1500MA);
}

// REG 41H (INTEN2) and REG 49H (INTSTS2): the PWR key's interrupts. Bit 2 is
// a long press (held past REG 27H's IRQ time), bit 3 a short press, bit 1 the
// key's negative edge and bit 0 its positive edge (XPowersLib
// XPowersParams.hpp, "IRQ2 REG 41H": PKEY_POSITIVE_IRQ = _BV(8),
// PKEY_NEGATIVE_IRQ = _BV(9), PKEY_LONG_IRQ = _BV(10), PKEY_SHORT_IRQ =
// _BV(11), byte 1 of the mask). PWRON idles high and the key pulls it to
// ground, so the negative edge is the key going down and the positive edge
// it coming back up: the edges are what let a holder see the key held, where
// the short-press bit only says a press has finished. A status bit is cleared
// by writing 1 to it. Enabling these changes nothing about how a long hold
// powers the board off: that is REG 22H and REG 27H.
static const uint8_t IRQ2_PKEY_UP = 1u << 0;
static const uint8_t IRQ2_PKEY_DOWN = 1u << 1;
static const uint8_t IRQ2_PKEY_LONG = 1u << 2;
static const uint8_t IRQ2_PKEY_SHORT = 1u << 3;
static const uint8_t IRQ2_PKEY_ALL =
    IRQ2_PKEY_UP | IRQ2_PKEY_DOWN | IRQ2_PKEY_LONG | IRQ2_PKEY_SHORT;

struct PowerKeyEvents {
  bool shortPress = false;
  bool longPress = false;
  bool down = false;  ///< the key went down since the last read
  bool up = false;    ///< the key came back up since the last read
};

/// REG 41H with the PWR key's four interrupts enabled and every other bit
/// kept.
inline uint8_t powerKeyIrqEnable(uint8_t inten2) {
  return (uint8_t)(inten2 | IRQ2_PKEY_ALL);
}

inline PowerKeyEvents powerKeyEvents(uint8_t intsts2) {
  PowerKeyEvents events;
  events.shortPress = (intsts2 & IRQ2_PKEY_SHORT) != 0;
  events.longPress = (intsts2 & IRQ2_PKEY_LONG) != 0;
  events.down = (intsts2 & IRQ2_PKEY_DOWN) != 0;
  events.up = (intsts2 & IRQ2_PKEY_UP) != 0;
  return events;
}

/// What to write to REG 49H to clear the PWR key bits it reported, and only
/// those: the other interrupts' status is not this reader's to clear.
inline uint8_t powerKeyClear(uint8_t intsts2) {
  return (uint8_t)(intsts2 & IRQ2_PKEY_ALL);
}

// REG 22H bit 1: holding the key past REG 27H's off time switches the PMU
// off (XPowersLib enableLongPressShutdown); bit 0 makes that a restart
// instead (setLongPressRestart). REG 27H bits 3:2 are that off time, 4, 6, 8
// or 10 s (setPowerKeyPressOffTime), and bits 5:4 the long-press IRQ time,
// 1, 1.5, 2 or 2.5 s (setIrqLevelTime). This firmware only reads them.
static const uint8_t PWROFF_EN_LONG_PRESS = 1u << 1;
static const uint8_t PWROFF_EN_RESTART = 1u << 0;

/// How long a hold switches the board off (or restarts it), in seconds.
inline int powerKeyOffSeconds(uint8_t reg27) {
  return 4 + 2 * ((reg27 >> 2) & 0x03);
}

/// How long a hold takes to raise the long-press interrupt, in ms.
inline int powerKeyLongPressMillis(uint8_t reg27) {
  return 1000 + 500 * ((reg27 >> 4) & 0x03);
}

/// What a hold past the off time does, as a word for the boot log.
inline const char *powerKeyHoldAction(uint8_t reg22) {
  if ((reg22 & PWROFF_EN_LONG_PRESS) == 0) return "nothing";
  return (reg22 & PWROFF_EN_RESTART) != 0 ? "restart" : "power off";
}

}  // namespace axp2101
