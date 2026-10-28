// Text rasterization over a caller-supplied RGB565 big-endian buffer.
//
// The colour panels use anti-aliased, generated atlases from the embedded OFL
// fonts. The 72x40 SSD1315 OLED deliberately keeps its sharp 5x7 font: it
// converts RGB565 to one bit and turns soft coverage into muddy noise.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "font5x7.h"  // classic 5x7 ASCII font (Adafruit GFX, BSD license)
#include "panel_fonts.h"

enum class TextFamily : uint8_t {
  Classic,
  Small,
  Mono,
  Large,
};

struct TextStyle {
  TextFamily family;
  uint8_t pixels;
};

inline bool useClassicText(int width, int height) {
  return width <= 72 || height <= 40;
}

inline TextStyle smallTextStyle(int width, int height) {
  if (useClassicText(width, height)) return {TextFamily::Classic, 1};
  const int side = width < height ? width : height;
  return {TextFamily::Small, (uint8_t)(side < 170 ? 9 : side < 400 ? 13 : 18)};
}

inline TextStyle monoTextStyle(int width, int height) {
  if (useClassicText(width, height)) return {TextFamily::Classic, 1};
  const int side = width < height ? width : height;
  return {TextFamily::Mono, (uint8_t)(side < 170 ? 12 : side < 400 ? 24 : 40)};
}

inline TextStyle largeTextStyle(int width, int height) {
  if (useClassicText(width, height)) return {TextFamily::Classic, 1};
  const int side = width < height ? width : height;
  return {TextFamily::Large, (uint8_t)(side < 170 ? 16 : side < 400 ? 24 : 40)};
}

inline const panelfonts::Face &faceFor(TextStyle style) {
  switch (style.family) {
    case TextFamily::Small:
      if (style.pixels <= 9) return panelfonts::SMALL_9;
      if (style.pixels <= 13) return panelfonts::SMALL_13;
      return panelfonts::SMALL_18;
    case TextFamily::Mono:
      if (style.pixels <= 12) return panelfonts::MONO_12;
      if (style.pixels <= 24) return panelfonts::MONO_24;
      return panelfonts::MONO_40;
    case TextFamily::Large:
      if (style.pixels <= 16) return panelfonts::LARGE_16;
      if (style.pixels <= 24) return panelfonts::LARGE_24;
      return panelfonts::LARGE_40;
    case TextFamily::Classic:
      return panelfonts::SMALL_9;  // unused; keeps this switch total
  }
  return panelfonts::SMALL_9;
}

inline int textHeight(TextStyle style) {
  if (style.family == TextFamily::Classic) return 7 * style.pixels;
  const panelfonts::Face &face = faceFor(style);
  return face.ascent + face.descent;
}

inline int textLineHeight(TextStyle style) {
  if (style.family == TextFamily::Classic) return 9 * style.pixels;
  const panelfonts::Face &face = faceFor(style);
  return face.ascent + face.descent + (face.leading > 1 ? face.leading : 1);
}

inline int textWidth(const char *s, TextStyle style) {
  if (s == nullptr || *s == 0) return 0;
  if (style.family == TextFamily::Classic) {
    int count = 0;
    for (; *s; ++s) ++count;
    return count * 6 * style.pixels - style.pixels;
  }
  const panelfonts::Face &face = faceFor(style);
  int width = 0;
  for (; *s; ++s) {
    uint8_t c = (uint8_t)*s;
    if (c < panelfonts::FIRST || c > panelfonts::LAST) c = '?';
    width += face.glyphs[c - panelfonts::FIRST].advance;
  }
  return width;
}

inline uint16_t blend565(uint16_t background, uint16_t foreground,
                         uint8_t alpha) {
  if (alpha == 0) return background;
  if (alpha == 255) return foreground;
  const int inv = 255 - alpha;
  const int br = (background >> 11) & 0x1F;
  const int bg = (background >> 5) & 0x3F;
  const int bb = background & 0x1F;
  const int fr = (foreground >> 11) & 0x1F;
  const int fg = (foreground >> 5) & 0x3F;
  const int fb = foreground & 0x1F;
  return (uint16_t)((((br * inv + fr * alpha + 127) / 255) << 11) |
                    (((bg * inv + fg * alpha + 127) / 255) << 5) |
                    ((bb * inv + fb * alpha + 127) / 255));
}

inline void putBlended565(uint8_t *buf, int bufW, int bufH, int x, int y,
                          uint16_t color, uint8_t alpha) {
  if (x < 0 || y < 0 || x >= bufW || y >= bufH || alpha == 0) return;
  const size_t off = ((size_t)y * bufW + x) * 2;
  const uint16_t background = (uint16_t)((buf[off] << 8) | buf[off + 1]);
  const uint16_t mixed = blend565(background, color, alpha);
  buf[off] = mixed >> 8;
  buf[off + 1] = mixed & 0xFF;
}

inline void drawClassicText(uint8_t *buf, int bufW, int bufH, int x, int y,
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

inline void drawText(uint8_t *buf, int bufW, int bufH, int x, int y,
                     const char *s, uint16_t color, TextStyle style) {
  if (s == nullptr || *s == 0) return;
  if (style.family == TextFamily::Classic) {
    drawClassicText(buf, bufW, bufH, x, y, s, color, style.pixels);
    return;
  }
  const panelfonts::Face &face = faceFor(style);
  for (; *s; ++s) {
    uint8_t c = (uint8_t)*s;
    if (c < panelfonts::FIRST || c > panelfonts::LAST) c = '?';
    const panelfonts::Glyph &glyph = face.glyphs[c - panelfonts::FIRST];
    for (int gy = 0; gy < glyph.height; ++gy) {
      for (int gx = 0; gx < glyph.width; ++gx) {
        putBlended565(buf, bufW, bufH, x + glyph.xOffset + gx,
                      y + glyph.yOffset + gy, color,
                      face.alpha[glyph.offset + (size_t)gy * glyph.width + gx]);
      }
    }
    x += glyph.advance;
  }
}

// Draw inside a text row's visible span. Used for the WiFi survey's marquee:
// an SSID is never shortened, but no moving glyph can enter a round panel's
// bezel or an adjacent row.
inline void drawTextClipped(uint8_t *buf, int bufW, int bufH, int x, int y,
                            const char *s, uint16_t color, TextStyle style,
                            int clipX, int clipY, int clipW, int clipH) {
  if (s == nullptr || *s == 0 || clipW <= 0 || clipH <= 0) return;
  const int clipX1 = clipX + clipW;
  const int clipY1 = clipY + clipH;
  if (style.family == TextFamily::Classic) {
    for (; *s; ++s) {
      for (int col = 0; col < 5; ++col) {
        const uint8_t bits = font[(size_t)(unsigned char)*s * 5 + col];
        for (int row = 0; row < 7; ++row) {
          if (!(bits & (1 << row))) continue;
          for (int sy = 0; sy < style.pixels; ++sy) {
            for (int sx = 0; sx < style.pixels; ++sx) {
              const int px = x + col * style.pixels + sx;
              const int py = y + row * style.pixels + sy;
              if (px >= clipX && px < clipX1 && py >= clipY && py < clipY1) {
                putBlended565(buf, bufW, bufH, px, py, color, 255);
              }
            }
          }
        }
      }
      x += 6 * style.pixels;
    }
    return;
  }
  const panelfonts::Face &face = faceFor(style);
  for (; *s; ++s) {
    uint8_t c = (uint8_t)*s;
    if (c < panelfonts::FIRST || c > panelfonts::LAST) c = '?';
    const panelfonts::Glyph &glyph = face.glyphs[c - panelfonts::FIRST];
    for (int gy = 0; gy < glyph.height; ++gy) {
      for (int gx = 0; gx < glyph.width; ++gx) {
        const int px = x + glyph.xOffset + gx;
        const int py = y + glyph.yOffset + gy;
        if (px >= clipX && px < clipX1 && py >= clipY && py < clipY1) {
          putBlended565(buf, bufW, bufH, px, py, color,
                        face.alpha[glyph.offset + (size_t)gy * glyph.width + gx]);
        }
      }
    }
    x += glyph.advance;
  }
}

// White text with a 1px black outline so it reads over any frame content.
inline void drawOutlinedText(uint8_t *buf, int bufW, int bufH, int x, int y,
                             const char *s, TextStyle style) {
  for (int dy = -1; dy <= 1; dy++) {
    for (int dx = -1; dx <= 1; dx++) {
      if (dx || dy) {
        drawText(buf, bufW, bufH, x + dx, y + dy, s, 0x0000, style);
      }
    }
  }
  drawText(buf, bufW, bufH, x, y, s, 0xFFFF, style);
}

