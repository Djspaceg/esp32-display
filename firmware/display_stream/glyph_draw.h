// Pure 5x7 glyph rasterization over a caller-supplied RGB565 big-endian
// buffer. Hardware-free and unit tested on the host (firmware/test/
// run_tests.sh); the on-device screens in ui_screens.cpp are its only
// firmware consumer.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "font5x7.h"  // classic 5x7 ASCII font (Adafruit GFX, BSD license)

// Draw scaled 5x7 text into an RGB565 big-endian buffer of bufW x bufH.
inline void drawText(uint8_t *buf, int bufW, int bufH, int x, int y,
                     const char *s, uint16_t color, int scale) {
  for (; *s; s++) {
    for (int col = 0; col < 5; col++) {
      uint8_t bits = font[(size_t)(unsigned char)*s * 5 + col];
      for (int row = 0; row < 7; row++) {
        if (!(bits & (1 << row))) {
          continue;
        }
        for (int sy = 0; sy < scale; sy++) {
          for (int sx = 0; sx < scale; sx++) {
            int px = x + col * scale + sx;
            int py = y + row * scale + sy;
            if (px < 0 || py < 0 || px >= bufW || py >= bufH) {
              continue;
            }
            size_t off = ((size_t)py * bufW + px) * 2;
            buf[off] = color >> 8;
            buf[off + 1] = color & 0xFF;
          }
        }
      }
    }
    x += 6 * scale;
  }
}

// White text with a 1px black outline so it reads over any frame content.
inline void drawOutlinedText(uint8_t *buf, int bufW, int bufH, int x, int y,
                             const char *s, int scale) {
  for (int dy = -1; dy <= 1; dy++) {
    for (int dx = -1; dx <= 1; dx++) {
      if (dx || dy) {
        drawText(buf, bufW, bufH, x + dx, y + dy, s, 0x0000, scale);
      }
    }
  }
  drawText(buf, bufW, bufH, x, y, s, 0xFFFF, scale);
}

