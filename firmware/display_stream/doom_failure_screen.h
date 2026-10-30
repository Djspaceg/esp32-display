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

// The legacy compact cards use fixed character columns. Keep that layout
// unchanged on their existing small displays.
inline int wrapTextToColumns(const char *text, int columns,
                             char lines[][LINE_CAP], int maxLines) {
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

// Greedy word wrap into at most maxLines measured lines. A word longer than a
// line is broken; text that does not fit is dropped and the last line ends in
// "..." so a cut reason never reads as complete.
inline int wrapText(const char *text, int maxWidth, TextStyle style,
                    char lines[][LINE_CAP], int maxLines) {
  if (maxWidth <= ::textWidth("...", style) || maxLines <= 0) return 0;
  int count = 0;
  const char *p = text;
  while (*p != 0 && count < maxLines) {
    while (*p == ' ') p++;
    if (*p == 0) break;

    char candidate[LINE_CAP];
    int take = 0;
    int lastBreak = 0;
    for (; p[take] != 0 && take < LINE_CAP - 1; take++) {
      candidate[take] = p[take];
      candidate[take + 1] = 0;
      if (::textWidth(candidate, style) > maxWidth) break;
      if (p[take] == ' ') {
        lastBreak = take + 1;
      }
    }
    if (take == 0) {
      // Preserve the previous behavior for a single glyph too wide for a
      // particularly narrow panel: make forward progress by splitting it.
      take = 1;
    } else if (p[take] != 0 && lastBreak > 0) {
      take = lastBreak;
    }
    while (take > 0 && p[take - 1] == ' ') take--;
    memcpy(lines[count], p, (size_t)take);
    lines[count][take] = 0;
    p += take;
    count++;
  }
  while (*p == ' ') p++;
  if (*p != 0 && count > 0) {
    char *last = lines[count - 1];
    int len = (int)strlen(last);
    const int textLimit = maxWidth - ::textWidth("...", style);
    while (len > 0 && ::textWidth(last, style) > textLimit) {
      last[--len] = 0;
    }
    memcpy(last + len, "...", 4);
  }
  return count;
}

// Compose the card into an RGB565 big-endian buffer of width x height. Quake's
// boot shows the same card under its own headline.
inline void compose(uint8_t *buf, int width, int height, bool roundDisplay,
                    const char *reason, const char *headline = HEADLINE,
                    uint16_t diagonalTenthsMm = 0) {
  const uint8_t hi = BACKGROUND >> 8, lo = BACKGROUND & 0xFF;
  const size_t bytes = (size_t)width * (size_t)height * 2;
  for (size_t i = 0; i < bytes; i += 2) {
    buf[i] = hi;
    buf[i + 1] = lo;
  }

  const int margin = textMargin(width, height, roundDisplay);
  const int textWidth = width - 2 * margin;
  const TextStyle style =
      smallTextStyle(width, height, diagonalTenthsMm);

  char lines[MAX_REASON_LINES][LINE_CAP];
  const char *failureReason = reason != nullptr ? reason : "";
  int reasonLines;
  int lineH;
  if (useLargerHighDensityText(width, height, diagonalTenthsMm)) {
    // drawOutlinedText extends one pixel on both sides of the measured glyph
    // box, so reserve those pixels before wrapping to the panel's safe area.
    reasonLines =
        wrapText(failureReason, textWidth - 2, style, lines, MAX_REASON_LINES);
    lineH = textLineHeight(style);
  } else {
    int scale = 2;
    if ((int)strlen(headline) * 6 * scale > textWidth) scale = 1;
    reasonLines = wrapTextToColumns(
        failureReason, textWidth / (scale == 1 ? 8 : 12), lines,
        MAX_REASON_LINES);
    lineH = 9 * scale;
  }

  // Headline, a blank line, the reason, a blank line, the footer.
  const int blockH = lineH * (reasonLines + 4);
  int y = (height - blockH) / 2;
  if (y < margin) y = margin;

  auto centered = [&](const char *text, int atY) {
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
