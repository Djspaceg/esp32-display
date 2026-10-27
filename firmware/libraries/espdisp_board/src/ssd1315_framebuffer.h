// RGB565BE-to-monochrome framebuffer used by the SSD1315 72x40 OLED backend.
//
// Kept hardware-free so the pixel conversion and page layout are covered by
// host tests. SSD1315 pages pack eight vertical pixels, least-significant bit
// first, as the controller's GDDRAM expects.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace ssd1315 {

static constexpr uint8_t WIDTH = 72;
static constexpr uint8_t HEIGHT = 40;
static constexpr uint8_t PAGES = HEIGHT / 8;
static constexpr size_t FRAME_BYTES = (size_t)WIDTH * PAGES;

inline uint8_t lumaFromRgb565Be(const uint8_t *pixel) {
  const uint8_t hi = pixel[0];
  const uint8_t lo = pixel[1];
  const uint8_t red = hi & 0xF8;
  const uint8_t green6 = (uint8_t)(((hi & 0x07) << 3) | (lo >> 5));
  const uint8_t green = (uint8_t)((green6 << 2) | (green6 >> 4));
  const uint8_t blue5 = lo & 0x1F;
  const uint8_t blue = (uint8_t)((blue5 << 3) | (blue5 >> 2));
  return (uint8_t)((77u * red + 150u * green + 29u * blue) >> 8);
}

inline bool copyRgb565Be(uint8_t *framebuffer, int x0, int y0, int x1,
                         int y1, const void *pixels) {
  if (framebuffer == nullptr || pixels == nullptr || x0 < 0 || y0 < 0 ||
      x1 <= x0 || y1 <= y0 || x1 > WIDTH || y1 > HEIGHT) {
    return false;
  }
  const uint8_t *source = static_cast<const uint8_t *>(pixels);
  const int sourceWidth = x1 - x0;
  for (int y = y0; y < y1; ++y) {
    const uint8_t bit = (uint8_t)(1u << (y & 7));
    uint8_t *row = framebuffer + (size_t)(y >> 3) * WIDTH;
    const uint8_t *pixelsInRow =
        source + (size_t)(y - y0) * sourceWidth * 2;
    for (int x = x0; x < x1; ++x) {
      const bool white =
          lumaFromRgb565Be(pixelsInRow + (size_t)(x - x0) * 2) >= 128;
      if (white) {
        row[x] |= bit;
      } else {
        row[x] &= (uint8_t)~bit;
      }
    }
  }
  return true;
}

inline void clear(uint8_t *framebuffer) {
  if (framebuffer != nullptr) memset(framebuffer, 0, FRAME_BYTES);
}

}  // namespace ssd1315
