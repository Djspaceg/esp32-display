// Hardware-free GT911 report parsing for host tests and board_touch.h.
#pragma once
#include <stddef.h>
#include <stdint.h>

namespace gt911proto {
static const uint8_t ADDRESS_PRIMARY = 0x5D;
static const uint8_t ADDRESS_BACKUP = 0x14;
static const uint16_t REGISTER_PRODUCT_ID = 0x8140;
static const uint16_t REGISTER_STATUS = 0x814E;
// Point records begin with the track ID at 0x814F. X begins at 0x8150;
// starting a record there shifts every coordinate field by one byte.
static const uint16_t REGISTER_POINT1 = 0x814F;
static const uint8_t STATUS_READY = 0x80;
static const uint8_t STATUS_POINTS = 0x0F;
static const size_t POINT_BYTES = 8;

inline bool parseReport(uint8_t status, const uint8_t *point, size_t pointLen,
                        bool &pressed, uint16_t &x, uint16_t &y,
                        uint8_t &points) {
  if ((status & STATUS_READY) == 0) return false;
  points = status & STATUS_POINTS;
  if (points == 0) {
    pressed = false;
    return true;
  }
  if (point == nullptr || pointLen < POINT_BYTES) return false;
  if (points > 5) points = 5;
  x = (uint16_t)point[1] | ((uint16_t)point[2] << 8);
  y = (uint16_t)point[3] | ((uint16_t)point[4] << 8);
  pressed = true;
  return true;
}
}  // namespace gt911proto
