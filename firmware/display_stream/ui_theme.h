// Central visual tuning table for static panel UI. Keep values here so a
// future review changes one palette/radius set rather than individual screens.
#pragma once

#include "ui_primitives.h"

namespace uitheme {

struct Theme {
  uint16_t background = 0x10C4;        // #141a26
  uint16_t primary = 0xFFFF;
  uint16_t secondary = 0x9D98;         // #9fb0c8
  uint16_t tertiary = 0x73F2;          // #6f7c92
  uint16_t accent = 0x3C7F;            // #3d8fff
  uint16_t teal = 0x2EB4;              // #2fd6a0
  uint16_t blue = 0x4D5F;              // #4aa8ff
  uint8_t rowRadiusPercent = 37;
  uint8_t rimWidth = 5;
};

inline constexpr Theme CURRENT = {};

inline uint16_t signalColorForRssi(int rssi, const Theme &theme = CURRENT) {
  if (rssi >= -70) return theme.teal;
  if (rssi >= -75) return 0xFCE1;  // #FF9F0A
  return 0xFA27;                   // #FF453A
}

inline void background(uint8_t *buf, int width, int height,
                       const Theme &theme = CURRENT) {
  uiprim::fillRoundedRect(buf, width, height, {0, 0, width, height}, 0,
                          theme.background);
  for (int y = 9; y < height; y += 18) {
    for (int x = 9; x < width; x += 18) {
      uiprim::put(buf, width, height, x, y, theme.primary, 13);
    }
  }
}

inline void ticks(uint8_t *buf, int width, int height, bool round,
                  const Theme &theme = CURRENT) {
  if (!round) return;
  const int side = width < height ? width : height;
  const int offsetX = (width - side) / 2;
  const int offsetY = (height - side) / 2;
  const uint16_t color =
      uiprim::mix565(theme.background, theme.primary, 3, 16);
  struct Tick {
    uint16_t x;
    uint16_t y;
    int8_t dx;
    int8_t dy;
  };
  static constexpr Tick marks[] = {
      {500, 55, 0, 1},   {255, 122, 1, 1},  {745, 122, -1, 1},
      {105, 310, 1, 1},  {895, 310, -1, 1}, {105, 690, 1, -1},
      {895, 690, -1, -1}, {255, 878, 1, -1}, {745, 878, -1, -1},
      {500, 945, 0, -1},
  };
  if (side < 170) return;
  const int length = side / 70;
  const int thickness = side >= 400 ? 2 : 1;
  for (const Tick &mark : marks) {
    const int x = offsetX + (int)mark.x * side / 1000;
    const int y = offsetY + (int)mark.y * side / 1000;
    for (int step = 0; step < length; ++step) {
      uiprim::fillCircle(buf, width, height, x + mark.dx * step,
                         y + mark.dy * step, thickness, color);
    }
  }
}

inline void card(uint8_t *buf, int width, int height, uiprim::Rect rect,
                 bool selected, const Theme &theme = CURRENT) {
  const int radius = rect.height * theme.rowRadiusPercent / 100;
  if (selected) {
    uiprim::fillRoundedRect(buf, width, height, rect, radius, theme.accent);
    uiprim::strokeRoundedRect(buf, width, height, rect, radius, 1,
                              theme.blue);
  } else {
    uiprim::fillRoundedRect(buf, width, height, rect, radius,
                            uiprim::mix565(theme.background, theme.primary,
                                           1, 16));
    uiprim::strokeRoundedRect(buf, width, height, rect, radius, 1,
                              uiprim::mix565(theme.background,
                                             theme.primary, 2, 16));
  }
}

}  // namespace uitheme
