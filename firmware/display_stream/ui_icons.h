// Compact anti-aliased status and affordance icons, built from ui_primitives.
#pragma once

#include "ui_primitives.h"

namespace uiicons {

inline void wifi(uint8_t *buf, int w, int h, int cx, int cy, int size,
                 uint16_t color, uint8_t bars) {
  for (int bar = 0; bar < 3; ++bar) {
    if (bar >= bars) continue;
    const int r = size - bar * size / 4;
    for (int y = cy - r; y <= cy; ++y) {
      for (int x = cx - r; x <= cx + r; ++x) {
        const int dx = x - cx, dy = y - cy;
        const int d2 = dx * dx + dy * dy;
        const int outer = r * r, inner = (r - 1) * (r - 1);
        if (dy <= 0 && d2 <= outer && d2 >= inner) {
          uiprim::put(buf, w, h, x, y, color, 220);
        }
      }
    }
  }
  if (bars) uiprim::fillCircle(buf, w, h, cx, cy, size / 8 + 1, color);
}

inline void battery(uint8_t *buf, int w, int h, int x, int y, int width,
                    int height, uint16_t color, uint8_t percent) {
  uiprim::Rect body = {x, y, width - 2, height};
  uiprim::strokeRoundedRect(buf, w, h, body, 2, 1, color);
  uiprim::fillRoundedRect(buf, w, h, {x + width - 2, y + height / 3, 2,
                                       height / 3}, 1, color);
  const int fill = (width - 6) * percent / 100;
  if (fill > 0) uiprim::fillRoundedRect(buf, w, h, {x + 2, y + 2, fill,
                                                     height - 4}, 1, color);
}

inline void check(uint8_t *buf, int w, int h, int x, int y, int size,
                  uint16_t color) {
  for (int i = 0; i < size / 2; ++i) {
    uiprim::fillCircle(buf, w, h, x + i, y + size / 2 + i / 2, 1, color);
    uiprim::fillCircle(buf, w, h, x + size / 2 + i, y + size - i, 1, color);
  }
}

inline void chevron(uint8_t *buf, int w, int h, int x, int y, int size,
                    uint16_t color, bool right = true) {
  for (int i = 0; i < size / 2; ++i) {
    const int dx = right ? i : -i;
    uiprim::fillCircle(buf, w, h, x + dx, y + i, 1, color);
    uiprim::fillCircle(buf, w, h, x + dx, y + size - i, 1, color);
  }
}

inline void pressHint(uint8_t *buf, int w, int h, int x, int y,
                      uint16_t color) {
  uiprim::strokeRoundedRect(buf, w, h, {x, y, 10, 8}, 3, 1, color);
  uiprim::fillCircle(buf, w, h, x + 5, y + 4, 1, color);
}

}  // namespace uiicons
