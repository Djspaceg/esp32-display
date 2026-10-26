// Hardware-free FT6336U report parsing for host tests and board_touch.h.
//
// Register map from SensorLib's TouchDrvFT6X36, the driver LilyGO's own
// T-Watch-S3 code runs:
// https://github.com/lewisxhe/SensorLib/blob/dff98e79753dedd7ba709d1e92d71b4353c55005/src/touch/TouchDrvFT6X36.hpp#L207-L240
// TD_STATUS (02H) low nibble is the point count; point 1 follows as XH, XL,
// YH, YL, each high byte carrying the coordinate's top four bits, and XH
// bits 7:6 the event flag (0 press down, 1 lift up, 2 contact, 3 none), as
// TouchDrvFT6X36::getTouchPoints reads them
// (src/touch/TouchDrvFT6X36.cpp#L40-L76 at that commit).
#pragma once
#include <stddef.h>
#include <stdint.h>

namespace ft6336proto {
static const uint8_t ADDRESS = 0x38;
static const uint8_t REGISTER_STATUS = 0x02;
static const uint8_t REGISTER_INT_MODE = 0xA4;
static const uint8_t REGISTER_CHIP_ID = 0xA3;
static const uint8_t REGISTER_FIRMWARE = 0xA6;
static const uint8_t REGISTER_VENDOR_ID = 0xA8;
/// A4H = 1: INT pulses once per report (SensorLib interruptTrigger()).
static const uint8_t INT_TRIGGER = 0x01;
static const uint8_t MAX_POINTS = 2;
static const size_t REPORT_BYTES = 5;  // TD_STATUS + point 1
static const uint8_t EVENT_LIFT_UP = 1;
static const uint8_t EVENT_NONE = 3;

/// Decode TD_STATUS plus point 1. No points, more than the part's two (what
/// an idle or settling controller can return), or a point whose event flag
/// says it lifted or carries no event, is a release.
inline bool parseReport(const uint8_t *data, size_t len, bool &pressed,
                        uint16_t &x, uint16_t &y, uint8_t &points) {
  if (data == nullptr || len != REPORT_BYTES) return false;
  const uint8_t count = data[0] & 0x0F;
  const uint8_t event = (uint8_t)(data[1] >> 6);
  if (count == 0 || count > MAX_POINTS || event == EVENT_LIFT_UP ||
      event == EVENT_NONE) {
    pressed = false;
    points = 0;
    return true;
  }
  x = (uint16_t)(((data[1] & 0x0F) << 8) | data[2]);
  y = (uint16_t)(((data[3] & 0x0F) << 8) | data[4]);
  points = count;
  pressed = true;
  return true;
}
}  // namespace ft6336proto
