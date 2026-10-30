// Hardware-free half of the boot screen (boot_screen.cpp): where the image,
// progress bar and status line go on a given screen, what each boot stage says,
// and the pixels of any run of rows. Host tested by
// firmware/test/test_boot_screen.cpp.
//
// The image is always drawn at its native size, never scaled. A screen at least
// twice the image's height puts the bar and status line at its centre (lifted
// just clear of the image where it would touch it) and the image at its bottom
// centre, round glass included (the bust's cut-off bottom meets the edge of the
// glass). A smaller one centres the image and puts the
// status line and bar in the margins above and below it.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "boot_image.h"
#include "glyph_draw.h"

namespace bootscreenmodel {

// The static UI's flat blue-grey. boot_image.h is composited over it, so the
// two must agree.
inline constexpr uint16_t BACKGROUND = 0x10C4;
static_assert(bootimage::BACKGROUND == BACKGROUND,
              "rerun tools/generate_boot_image.py --background with this colour");

inline constexpr uint16_t TEXT_COLOR = 0xFFFF;
inline constexpr uint16_t GRID_DOT = 0x2126;
inline constexpr uint16_t BAR_BORDER = 0x214A;
inline constexpr uint16_t BAR_TRACK = 0x18E6;
inline constexpr uint16_t BAR_PROGRESS = 0x3C7F;
inline constexpr uint16_t BAR_READY = 0x2EB4;
inline constexpr uint16_t BAR_FAILED = 0xFA27;

// The longest status line the layout makes room for at full size. Longer text
// is still drawn, clipped by the screen.
inline constexpr size_t MAX_STATUS_CHARS = 12;

enum class Stage : uint8_t {
  Starting,     // the panel is up; nothing else is yet
  Preparing,    // frame buffers
  Sensors,      // touch, battery and motion
  WifiLink,     // the P4's link to its C6 radio
  JoiningWifi,  // waiting for the access point
  Audio,
  Services,     // OTA, mDNS and the stream socket
  Ready,
  NoWifi,       // ready, but the join timed out
  Failed,       // setup stopped; the text says where
};

struct StageView {
  const char *text;
  uint16_t permille;
  uint16_t barColor;
};

// What a stage shows. JoiningWifi's bar moves on from its start value with
// joiningPermille(); Failed's text is supplied by the caller.
inline StageView viewFor(Stage stage) {
  switch (stage) {
    case Stage::Starting: return {"starting", 50, BAR_PROGRESS};
    case Stage::Preparing: return {"preparing", 150, BAR_PROGRESS};
    case Stage::Sensors: return {"sensors", 250, BAR_PROGRESS};
    case Stage::WifiLink: return {"WiFi link", 300, BAR_PROGRESS};
    case Stage::JoiningWifi: return {"joining WiFi", 350, BAR_PROGRESS};
    case Stage::Audio: return {"audio", 800, BAR_PROGRESS};
    case Stage::Services: return {"services", 900, BAR_PROGRESS};
    case Stage::Ready: return {"ready", 1000, BAR_READY};
    case Stage::NoWifi: return {"no WiFi", 1000, BAR_FAILED};
    case Stage::Failed: return {"failed", 1000, BAR_FAILED};
  }
  return {"", 0, BAR_PROGRESS};
}

// The bar during the WiFi wait: from JoiningWifi's start to just short of
// Audio's, in step with the bounded wait's own deadline.
inline uint16_t joiningPermille(uint32_t elapsedMs, uint32_t timeoutMs) {
  const uint32_t from = viewFor(Stage::JoiningWifi).permille;
  const uint32_t to = viewFor(Stage::Audio).permille - 50;
  if (timeoutMs == 0 || elapsedMs >= timeoutMs) return (uint16_t)to;
  return (uint16_t)(from + (uint64_t)(to - from) * elapsedMs / timeoutMs);
}

struct Rect {
  int16_t x;
  int16_t y;
  int16_t w;
  int16_t h;
};

struct Layout {
  int16_t width;
  int16_t height;
  bool round;
  uint16_t diagonalTenthsMm;
  // Image centred on the screen, status line and bar in its margins.
  bool compact;
  Rect image;
  Rect bar;
  int16_t textY;
  uint8_t textScale;
  // Drawn over the image with an outline: a margin too thin for the text.
  bool textOverImage;
};

// Width of a string of n glyphs at this scale, without the trailing gap.
inline int textWidth(size_t chars, int scale) {
  return chars == 0 ? 0 : (int)chars * 6 * scale - scale;
}

// Half the width of the glass on rows [y0, y1): the narrowest row's half chord
// on round glass, half the width otherwise.
inline int halfWidthAcross(const Layout &l, int y0, int y1) {
  if (!l.round) return l.width / 2;
  const int64_t r2 = (int64_t)l.width * l.width;  // (2r)^2, in doubled units
  int64_t worst = 0;
  const int rowsAtEnds[2] = {y0, y1};
  for (int y : rowsAtEnds) {
    const int64_t dy = 2 * (int64_t)y - l.height;  // doubled distance from centre
    const int64_t d2 = dy * dy;
    if (d2 > worst) worst = d2;
  }
  if (worst >= r2) return 0;
  // Integer square root of r^2 - dy^2, in doubled units, halved back.
  const int64_t v = r2 - worst;
  int64_t s = 0;
  while ((s + 1) * (s + 1) <= v) ++s;
  return (int)(s / 2);
}

inline Layout layout(int width, int height, bool round,
                     uint16_t diagonalTenthsMm = 0) {
  Layout l = {};
  l.width = (int16_t)width;
  l.height = (int16_t)height;
  l.round = round;
  l.diagonalTenthsMm = diagonalTenthsMm;
  if (width <= 96 || height <= 54) {
    // The 72x40 OLED and 96x54 colour XIAO cannot hold the 120x120 boot
    // image. Keep useful boot state: one sharp status line and a bottom
    // progress bar, rather than drawing unrecognizable cropped artwork.
    l.compact = true;
    l.image = {0, 0, 0, 0};
    l.textScale = 1;
    l.textY = 1;
    l.textOverImage = false;
    const int barW = width * 3 / 5;
    l.bar = {(int16_t)((width - barW) / 2), (int16_t)(height - 5),
             (int16_t)barW, 4};
    return l;
  }
  const int imageW = bootimage::WIDTH;
  const int imageH = bootimage::HEIGHT;
  l.compact = height < 2 * imageH || width < imageW;
  l.image.w = (int16_t)imageW;
  l.image.h = (int16_t)imageH;
  l.image.x = (int16_t)((width - imageW) / 2);
  l.image.y = (int16_t)(l.compact ? (height - imageH) / 2 : height - imageH);

  const int shortSide = width < height ? width : height;
  int scaleCap = shortSide / 80;
  if (scaleCap < 1) scaleCap = 1;
  if (scaleCap > 4) scaleCap = 4;
  int barW = width * 3 / 5;

  if (!l.compact) {
    // Bar centred on the screen; the status line above it. The largest text
    // that fits the glass at its own rows wins.
    for (int scale = scaleCap; scale >= 1; --scale) {
      const int barH = 2 * scale + 2;
      // On a screen exactly twice the image's height the centred bar would
      // cover the top of the head; it rises just clear of it instead.
      int barY = height / 2 - barH / 2;
      if (barY + barH > l.image.y) barY = l.image.y - barH;
      l.bar = {(int16_t)((width - barW) / 2), (int16_t)barY, (int16_t)barW,
               (int16_t)barH};
      l.textScale = (uint8_t)scale;
      l.textY = (int16_t)(l.bar.y - 3 * scale - 7 * scale);
      const int half = halfWidthAcross(l, l.textY, l.textY + 7 * scale);
      if (textWidth(MAX_STATUS_CHARS, scale) + 8 * scale <= 2 * half) break;
    }
    return l;
  }

  const TextStyle statusStyle =
      smallTextStyle(width, height, diagonalTenthsMm);
  const int statusHeight = textHeight(statusStyle);
  // A 128px panel cannot hold the 120px illustration, a status row and a
  // progress bar without overlap. Put the status on clean background first;
  // the artwork may finish below the framebuffer, but the state remains
  // readable rather than being drawn over the image.
  if (height < imageH + statusHeight + 8) {
    l.textScale = 1;
    l.textOverImage = false;
    l.textY = 1;
    l.image.y = (int16_t)(statusHeight + 4);
    const int barH = 4;
    l.bar = {(int16_t)((width - barW) / 2), (int16_t)(height - barH - 1),
             (int16_t)barW, (int16_t)barH};
    return l;
  }

  // Compact: the margins the centred image leaves.
  const int top = l.image.y;
  const int bottom = height - (l.image.y + imageH);
  l.textScale = 1;
  l.textOverImage = true;
  l.textY = 1;
  for (int scale = scaleCap; scale >= 1; --scale) {
    if (7 * scale + 2 <= top && textWidth(MAX_STATUS_CHARS, scale) + 8 <= width) {
      l.textScale = (uint8_t)scale;
      l.textOverImage = false;
      l.textY = (int16_t)((top - 7 * scale) / 2);
      break;
    }
  }
  int barH = 2 * l.textScale + 2;
  int barY;
  if (bottom >= 4) {
    if (barH > bottom - 2) barH = bottom - 2;
    barY = l.image.y + imageH + (bottom - barH) / 2;
  } else {
    barH = 3;
    barY = height - barH - 1;
  }
  l.bar = {(int16_t)((width - barW) / 2), (int16_t)barY, (int16_t)barW,
           (int16_t)barH};
  return l;
}

// Rows a change of status text repaints, and rows a change of bar repaints.
inline void textRows(const Layout &l, int &y0, int &y1) {
  const TextStyle style =
      smallTextStyle(l.width, l.height, l.diagonalTenthsMm);
  y0 = l.textY - 1;
  y1 = l.textY + textHeight(style) + 1;
  if (y0 < 0) y0 = 0;
  if (y1 > l.height) y1 = l.height;
}

inline void barRows(const Layout &l, int &y0, int &y1) {
  y0 = l.bar.y;
  y1 = l.bar.y + l.bar.h;
  if (y0 < 0) y0 = 0;
  if (y1 > l.height) y1 = l.height;
}

// The bar's filled width in pixels, inside its border when it has one.
inline int barFill(const Layout &l, uint16_t permille) {
  const int inner = l.bar.h >= 4 ? l.bar.w - 2 : l.bar.w;
  if (permille > 1000) permille = 1000;
  return inner * permille / 1000;
}

inline void put565(uint8_t *px, uint16_t c) {
  px[0] = (uint8_t)(c >> 8);
  px[1] = (uint8_t)(c & 0xFF);
}

// Compose rows [y0, y0 + rows) of the whole screen into dst (width * rows
// RGB565 pixels, high byte first): background, image, bar, status line.
inline void composeRows(uint8_t *dst, const Layout &l, const char *text,
                        uint16_t permille, uint16_t barColor, int y0,
                        int rows) {
  const int w = l.width;
  if (rows <= 0) return;
  for (int r = 0; r < rows; ++r) {
    for (int x = 0; x < w; ++x) {
      const bool dot = x % 18 == 9 && (y0 + r) % 18 == 9;
      put565(dst + ((size_t)r * w + x) * 2, dot ? GRID_DOT : BACKGROUND);
    }
  }

  if (l.image.w > 0 && l.image.h > 0) {
    for (int r = 0; r < rows; ++r) {
      const int iy = y0 + r - l.image.y;
      if (iy < 0 || iy >= bootimage::HEIGHT) continue;
      uint8_t *row = dst + (size_t)r * w * 2;
      for (uint16_t i = bootimage::ROW_RUNS[iy];
           i < bootimage::ROW_RUNS[iy + 1]; ++i) {
        const bootimage::Run &run = bootimage::RUNS[i];
        for (int k = 0; k < run.length; ++k) {
          const int x = l.image.x + run.x + k;
          if (x < 0 || x >= w) continue;
          put565(row + 2 * x, bootimage::pixelAt(run.pixel + k));
        }
      }
    }
  }

  const bool bordered = l.bar.h >= 4;
  const int fill = barFill(l, permille);
  for (int r = 0; r < rows; ++r) {
    const int by = y0 + r - l.bar.y;
    if (by < 0 || by >= l.bar.h) continue;
    uint8_t *row = dst + (size_t)r * w * 2;
    const bool edgeRow = bordered && (by == 0 || by == l.bar.h - 1);
    for (int bx = 0; bx < l.bar.w; ++bx) {
      const int x = l.bar.x + bx;
      if (x < 0 || x >= w) continue;
      uint16_t c;
      if (edgeRow || (bordered && (bx == 0 || bx == l.bar.w - 1))) {
        c = BAR_BORDER;
      } else {
        c = (bx - (bordered ? 1 : 0)) < fill ? barColor : BAR_TRACK;
      }
      put565(row + 2 * x, c);
    }
  }

  const TextStyle style =
      smallTextStyle(l.width, l.height, l.diagonalTenthsMm);
  const bool textHere =
      y0 < l.textY + textHeight(style) + 1 && y0 + rows > l.textY - 1;
  if (textHere && text != nullptr && *text != 0) {
    const int x = (w - ::textWidth(text, style)) / 2;
    if (l.textOverImage) {
      drawOutlinedText(dst, w, rows, x, l.textY - y0, text, style);
    } else {
      drawText(dst, w, rows, x, l.textY - y0, text, TEXT_COLOR, style);
    }
  }
}

}  // namespace bootscreenmodel
