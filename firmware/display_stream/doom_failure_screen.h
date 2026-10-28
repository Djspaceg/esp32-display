// The card a Doom boot that cannot start shows before it restarts into the
// normal firmware: a headline, the reason, and "Restarting". Without it the
// panel just goes back to the normal firmware and the reason is visible only
// to whoever has a serial monitor attached.
//
// Hardware-free and unit tested on the host (firmware/test/
// test_doom_failure_screen.cpp); doom_bridge.cpp is its only firmware caller.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "glyph_draw.h"

namespace doomfail {

static const uint16_t BACKGROUND = 0x6000;  // very dark red, Doom's splash
static const char HEADLINE[] = "Doom could not start";
static const char FOOTER[] = "Restarting";
static const int MAX_REASON_LINES = 4;
static const int LINE_CAP = 64;

// Round glass hides the framebuffer corners, so text stays visibly clear of
// the bezel by using the same 18% inset as the other panel UI.
inline int textMargin(int width, int height, bool roundDisplay) {
  int margin = 4;
  if (roundDisplay) {
    const int d = width < height ? width : height;
    margin += d * 18 / 100;
  }
  return margin;
}

// Greedy word wrap into at most maxLines lines of at most columns characters.
// A word longer than a line is broken; text that does not fit is dropped and
// the last line ends in "..." so a cut reason never reads as complete.
inline int wrapText(const char *text, int columns, char lines[][LINE_CAP],
                    int maxLines) {
  if (columns > LINE_CAP - 1) columns = LINE_CAP - 1;
  if (columns < 4 || maxLines <= 0) return 0;
  int count = 0;
  const char *p = text;
  while (*p != 0 && count < maxLines) {
    while (*p == ' ') p++;
    if (*p == 0) break;
    int len = (int)strlen(p);
    int take = len;
    if (len > columns) {
      take = columns;
      for (int i = columns; i > 0; i--) {
        if (p[i] == ' ') {
          take = i;
          break;
        }
      }
    }
    memcpy(lines[count], p, (size_t)take);
    lines[count][take] = 0;
    p += take;
    count++;
  }
  while (*p == ' ') p++;
  if (*p != 0 && count > 0) {
    char *last = lines[count - 1];
    int len = (int)strlen(last);
    if (len > columns - 3) len = columns - 3;
    memcpy(last + len, "...", 4);
  }
  return count;
}

// Compose the card into an RGB565 big-endian buffer of width x height. Quake's
// boot shows the same card under its own headline.
inline void compose(uint8_t *buf, int width, int height, bool roundDisplay,
                    const char *reason, const char *headline = HEADLINE) {
  const uint8_t hi = BACKGROUND >> 8, lo = BACKGROUND & 0xFF;
  const size_t bytes = (size_t)width * (size_t)height * 2;
  for (size_t i = 0; i < bytes; i += 2) {
    buf[i] = hi;
    buf[i + 1] = lo;
  }

  const int margin = textMargin(width, height, roundDisplay);
  const int textWidth = width - 2 * margin;
  int scale = 2;
  if ((int)strlen(headline) * 6 * scale > textWidth) scale = 1;
  // IBM Plex Sans has proportional widths. A conservative average keeps a
  // word-wrapped reason inside this card; final placement still uses the
  // renderer's measured width below.
  const int columns = textWidth / (scale == 1 ? 8 : 12);

  char lines[MAX_REASON_LINES][LINE_CAP];
  const int reasonLines =
      wrapText(reason != nullptr ? reason : "", columns, lines,
               MAX_REASON_LINES);

  // Headline, a blank line, the reason, a blank line, the footer.
  const int lineH = 9 * scale;
  const int blockH = lineH * (reasonLines + 4);
  int y = (height - blockH) / 2;
  if (y < margin) y = margin;

  auto centered = [&](const char *text, int atY) {
    const TextStyle style = smallTextStyle(width, height);
    const int x = (width - ::textWidth(text, style)) / 2;
    drawOutlinedText(buf, width, height, x, atY, text, style);
  };
  centered(headline, y);
  y += lineH * 2;
  for (int i = 0; i < reasonLines; i++) {
    centered(lines[i], y);
    y += lineH;
  }
  y += lineH;
  centered(FOOTER, y);
}

}  // namespace doomfail
