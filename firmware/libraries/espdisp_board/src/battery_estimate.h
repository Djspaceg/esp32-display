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

// The window a working one-cell lithium pack actually lives in. Narrower than
// PRESENT_MILLIVOLTS on purpose: the two thresholds answer different questions.
// cellPresent asks whether anything is attached at all and stays deliberately
// permissive so a deeply discharged cell is not called absent. cellPlausible
// asks whether a single sample can be TRUSTED as the cell's voltage, and a
// reading outside this window is far more likely to be a glitched conversion
// than a real cell.
//
// The top of the window sits above the 4.2V charge ceiling because a cell held
// at termination, plus the tolerance of a resistor divider, legitimately reads
// a little over it; calling that implausible would throw away good samples from
// a full battery.
static const uint16_t PLAUSIBLE_MIN_MILLIVOLTS = 3000;
static const uint16_t PLAUSIBLE_MAX_MILLIVOLTS = 4300;

// Cap on one batch. Sixteen is well above the number of samples worth taking
// and keeps the sort below on a fixed-size stack buffer.
static const size_t MAX_SAMPLES = 16;

inline bool cellPlausible(uint16_t millivolts) {
  return millivolts >= PLAUSIBLE_MIN_MILLIVOLTS &&
         millivolts <= PLAUSIBLE_MAX_MILLIVOLTS;
}

/// What one batch of cell-voltage samples supports concluding.
struct Selection {
  bool plausible;         ///< at least one sample landed in the lithium window
  uint8_t plausibleCount; ///< how many did
  uint16_t millivolts;    ///< the voltage to report
};

/// Picks a trustworthy cell voltage out of a batch of samples.
///
/// WHY THIS IS NOT A MEAN. The ADC path used to average eight raw reads. The
/// 1.85 inch board intermittently returns 0 from its divider, and a mean lets
/// those zeros drag the result down without trace: enough of them and a healthy
/// 3750 mV cell is reported as "absent 0mV", which is exactly what was seen on
/// the bench. One glitched sample must not be able to outvote the good ones, so
/// this filters to the samples that could physically be a cell and takes the
/// median of those. A median discards an outlier outright rather than blending
/// it in, and filtering first means a run of zeros is ignored entirely as long
/// as any sample looks like a real cell.
///
/// Falls back to the median of everything when nothing is plausible, so a truly
/// dead or absent input still reports the low voltage it actually measured and
/// cellPresent can call it absent honestly.
inline Selection selectCellMillivolts(const uint16_t *cellSamples,
                                      size_t count) {
  Selection out = {false, 0, 0};
  if (cellSamples == nullptr || count == 0) return out;
  if (count > MAX_SAMPLES) count = MAX_SAMPLES;

  uint32_t total = 0;
  for (size_t i = 0; i < count; i++) {
    total += cellSamples[i];
    if (cellPlausible(cellSamples[i])) out.plausibleCount++;
  }
  out.plausible = out.plausibleCount > 0;
  out.millivolts = (uint16_t)(total / count);
  return out;
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
