// Small anti-aliased RGB565 drawing primitives for the panel UI.
#pragma once

#include <stdint.h>
#include <math.h>

#include "glyph_draw.h"

namespace uiprim {

struct Rect {
  int x, y, width, height;
};

inline int clamp(int value, int low, int high) {
  return value < low ? low : value > high ? high : value;
}

inline uint16_t mix565(uint16_t from, uint16_t to, int amount, int scale) {
  if (amount <= 0) return from;
  if (amount >= scale) return to;
  const int fr = (from >> 11) & 31, fg = (from >> 5) & 63, fb = from & 31;
  const int tr = (to >> 11) & 31, tg = (to >> 5) & 63, tb = to & 31;
  return (uint16_t)((((fr * (scale - amount) + tr * amount) / scale) << 11) |
                    (((fg * (scale - amount) + tg * amount) / scale) << 5) |
                    ((fb * (scale - amount) + tb * amount) / scale));
}

inline void put(uint8_t *buf, int width, int height, int x, int y,
                uint16_t color, uint8_t alpha = 255) {
  putBlended565(buf, width, height, x, y, color, alpha);
}

// Signed distance coverage for a circular corner, scaled to an 8-bit alpha.
// The integer square root is deliberately avoided: comparing squared distance
// makes the edge a short, ordered coverage ramp and is fast on ESP targets.
inline uint8_t circleCoverage(int dx, int dy, int radius) {
  const int d2 = dx * dx + dy * dy;
  const int inner = (radius - 1) * (radius - 1);
  const int outer = (radius + 1) * (radius + 1);
  if (d2 <= inner) return 255;
  if (d2 >= outer) return 0;
  return (uint8_t)((outer - d2) * 255 / (outer - inner));
}

inline uint8_t roundedCoverage(const Rect &rect, int radius, int x, int y) {
  if (x < rect.x || y < rect.y || x >= rect.x + rect.width ||
      y >= rect.y + rect.height) {
    return 0;
  }
  radius = clamp(radius, 0, (rect.width < rect.height ? rect.width : rect.height) / 2);
  if (radius == 0 || (x >= rect.x + radius && x < rect.x + rect.width - radius) ||
      (y >= rect.y + radius && y < rect.y + rect.height - radius)) {
    return 255;
  }
  const int cx = x < rect.x + radius ? rect.x + radius - 1
                                     : rect.x + rect.width - radius;
  const int cy = y < rect.y + radius ? rect.y + radius - 1
                                     : rect.y + rect.height - radius;
  return circleCoverage(x - cx, y - cy, radius);
}

inline void fillRoundedRect(uint8_t *buf, int width, int height, Rect rect,
                            int radius, uint16_t color) {
  for (int y = rect.y; y < rect.y + rect.height; ++y) {
    for (int x = rect.x; x < rect.x + rect.width; ++x) {
      put(buf, width, height, x, y, color, roundedCoverage(rect, radius, x, y));
    }
  }
}

inline void strokeRoundedRect(uint8_t *buf, int width, int height, Rect rect,
                              int radius, int stroke, uint16_t color) {
  if (stroke <= 0) return;
  Rect inner = {rect.x + stroke, rect.y + stroke, rect.width - 2 * stroke,
                rect.height - 2 * stroke};
  for (int y = rect.y; y < rect.y + rect.height; ++y) {
    for (int x = rect.x; x < rect.x + rect.width; ++x) {
      const uint8_t outer = roundedCoverage(rect, radius, x, y);
      const uint8_t inside = inner.width > 0 && inner.height > 0
                                 ? roundedCoverage(inner, radius - stroke, x, y)
                                 : 0;
      if (outer > inside) put(buf, width, height, x, y, color, outer - inside);
    }
  }
}

inline void fillCircle(uint8_t *buf, int width, int height, int cx, int cy,
                       int radius, uint16_t color) {
  Rect bounds = {cx - radius, cy - radius, 2 * radius + 1, 2 * radius + 1};
  for (int y = bounds.y; y < bounds.y + bounds.height; ++y) {
    for (int x = bounds.x; x < bounds.x + bounds.width; ++x) {
      put(buf, width, height, x, y, color, circleCoverage(x - cx, y - cy, radius));
    }
  }
}

inline void strokeArc(uint8_t *buf, int width, int height, int cx, int cy,
                      int radius, float startDegrees, float sweepDegrees,
                      int stroke, uint16_t color) {
  if (radius < 1 || stroke < 1) return;
  const int steps = (int)(fabsf(sweepDegrees) * radius / 18.0f) + 1;
  for (int step = 0; step <= steps; ++step) {
    const float degrees = startDegrees + sweepDegrees * step / steps;
    const float radians = degrees * 0.01745329252f;
    const int x = cx + (int)(cosf(radians) * radius);
    const int y = cy + (int)(sinf(radians) * radius);
    fillCircle(buf, width, height, x, y, stroke / 2 + 1, color);
  }
}

inline void fillVerticalGradient(uint8_t *buf, int width, int height, Rect rect,
                                 uint16_t top, uint16_t bottom) {
  static const uint8_t BAYER_4X4[16] = {0, 8, 2, 10, 12, 4, 14, 6,
                                         3, 11, 1, 9, 15, 7, 13, 5};
  const int denominator = rect.height > 1 ? rect.height - 1 : 1;
  for (int y = rect.y; y < rect.y + rect.height; ++y) {
    const int row = clamp(y - rect.y, 0, denominator);
    for (int x = rect.x; x < rect.x + rect.width; ++x) {
      int amount = row * 16 + BAYER_4X4[((y & 3) << 2) | (x & 3)] - 8;
      amount = clamp(amount, 0, denominator * 16);
      put(buf, width, height, x, y, mix565(top, bottom, amount,
                                            denominator * 16));
    }
  }
}

inline void fillRadialGradient(uint8_t *buf, int width, int height, Rect rect,
                               int cx, int cy, int radius,
                               uint16_t center, uint16_t edge) {
  if (radius < 1) radius = 1;
  const int radius2 = radius * radius;
  for (int y = rect.y; y < rect.y + rect.height; ++y) {
    for (int x = rect.x; x < rect.x + rect.width; ++x) {
      const int dx = x - cx, dy = y - cy;
      const int distance2 = dx * dx + dy * dy;
      put(buf, width, height, x, y, mix565(center, edge,
                                            clamp(distance2, 0, radius2),
                                            radius2));
    }
  }
}

inline void softGlow(uint8_t *buf, int width, int height, int cx, int cy,
                     int radius, uint16_t color) {
  for (int r = radius + 3; r >= radius; --r) {
    const uint8_t alpha = (uint8_t)(18 + (radius + 3 - r) * 22);
    for (int y = cy - r; y <= cy + r; ++y) {
      for (int x = cx - r; x <= cx + r; ++x) {
        const uint8_t coverage = circleCoverage(x - cx, y - cy, r);
        if (coverage < 255) put(buf, width, height, x, y, color,
                                 (uint8_t)(coverage * alpha / 255));
      }
    }
  }
}

}  // namespace uiprim
