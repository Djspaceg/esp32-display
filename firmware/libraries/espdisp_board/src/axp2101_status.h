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

}  // namespace axp2101
