// Each board's touch calibration, from its own descriptor (boards/*.toml
// [touch]: panel_short, panel_long, raw_x_mirrored, raw_y_mirrored,
// rotate_clockwise), so no caller keeps a per-board list or falls back to
// another board's numbers. Hardware-free, like touch_map.h.
#pragma once

#include "board_config.h"
#include "touch_map.h"

namespace board {

/// The calibration a board's descriptor states. A variant with none (Unknown)
/// gets its resolved config's panel extents, unmirrored.
inline touchmap::Calibration touchCalibrationFor(Variant variant) {
  const GeneratedTouchCalibration *facts = generatedTouchCalibration(variant);
  if (facts != nullptr) {
    return touchmap::Calibration{facts->panelShort, facts->panelLong,
                                 facts->rawXMirrored, facts->rawYMirrored,
                                 facts->rotateClockwise};
  }
  const Config &cfg = configFor(variant);
  const int16_t w = (int16_t)cfg.panel->width;
  const int16_t h = (int16_t)cfg.panel->height;
  return touchmap::Calibration{w < h ? w : h, w < h ? h : w, false, false,
                               true};
}

}  // namespace board
