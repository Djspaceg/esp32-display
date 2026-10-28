// Hardware-free layout for the WiFi status screen (the signal survey): which
// rows a panel shows, at what glyph scale, and where, for every panel shape
// from the 128 px square to the 800 px round. Host tested in
// firmware/test/test_band_protocol.cpp; drawSurveyScreen() is its only
// firmware consumer.
//
// Top to bottom: the network's name, the RSSI large (the meter a panel is
// carried around the room by), a word for what that signal is worth, a rule,
// then the panel's address, name, firmware and battery, and how to close the
// screen. The WIFI PRESETS control sits under all of it
// (wifiselector::surveyPresetButton()).
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "glyph_draw.h"
#include "wifi_selector_model.h"

namespace wifistatus {

enum Row : uint8_t {
  ROW_NETWORK,
  ROW_SIGNAL,
  ROW_QUALITY,
  ROW_ADDRESS,
  ROW_NAME,
  ROW_FIRMWARE,
  ROW_BATTERY,
  ROW_HINT,
  ROW_COUNT,
};

// Where each row goes. A row with scale 0 is not drawn. A row's text is drawn
// centred on centreX, and fits in maxChars(row) characters at its scale (the
// caller shortens anything longer).
struct Layout {
  uint8_t scale[ROW_COUNT] = {};
  TextStyle style[ROW_COUNT] = {};
  int16_t rowHeight[ROW_COUNT] = {};
  int16_t y[ROW_COUNT] = {};
  int16_t spanX[ROW_COUNT] = {};
  int16_t spanWidth[ROW_COUNT] = {};
  int16_t centreX = 0;
  // The rule between the meter and the details; dividerWidth 0 draws none.
  int16_t dividerX = 0;
  int16_t dividerY = 0;
  int16_t dividerWidth = 0;
  int16_t top = 0;
  int16_t bottom = 0;
  bool fits = false;
  bool marquee[ROW_COUNT] = {};

  size_t maxChars(Row row) const {
    if (scale[row] == 0) return 0;
    // A compatibility helper for callers choosing among fixed hint strings.
    // Actual layout below always uses textWidth() rather than this estimate.
    return (size_t)(spanWidth[row] / 3);
  }
};

inline int isqrt(int value) {
  if (value <= 0) return 0;
  int root = 0;
  while ((root + 1) * (root + 1) <= value) ++root;
  return root;
}

// The horizontal span a text row [y0, y1) may use. Rectangular glass keeps
// the plain margin. On round glass a row keeps to the chord, at its end
// farther from the centre, of a circle 88% of the glass's: the bezel hides the
// outermost pixels, and text that only just fits the full circle read as
// running off it on the 1.75" round.
inline void rowSpan(int width, int height, bool roundDisplay, int y0, int y1,
                    int &x, int &spanWidth) {
  const int margin = wifiselector::safeMargin(width, height, roundDisplay);
  x = margin;
  spanWidth = width - 2 * margin;
  if (!roundDisplay) return;
  const int radius = (width < height ? width : height) / 2 * 88 / 100;
  const int centreX = width / 2;
  const int centreY = height / 2;
  const int above = centreY - y0;
  const int below = y1 - centreY;
  const int farthest = above > below ? above : below;
  if (farthest >= radius) {
    x = centreX;
    spanWidth = 0;
    return;
  }
  const int pad = 4 + radius / 20;
  int half = isqrt(radius * radius - farthest * farthest) - pad;
  if (half < 0) half = 0;
  x = centreX - half;
  spanWidth = 2 * half;
}

inline TextStyle styleFor(Row row, int width, int height, int scale) {
  if (useClassicText(width, height)) return {TextFamily::Classic, 1};
  if (row == ROW_SIGNAL) {
    if (scale >= 8) return {TextFamily::Mono, 40};
    if (scale >= 3) return {TextFamily::Mono, 24};
    return {TextFamily::Mono, 12};
  }
  if (scale >= 3) return {TextFamily::Small, 18};
  if (scale >= 2) return {TextFamily::Small, 13};
  return {TextFamily::Small, 9};
}

// Every row's actual text. Network and name rows may marquee where a legal
// SSID or panel name is wider than even the smallest embedded face; no bytes
// are dropped or replaced with an ellipsis.
inline Layout layout(int width, int height, bool roundDisplay,
                     const char *const text[ROW_COUNT]) {
  const int margin = wifiselector::safeMargin(width, height, roundDisplay);
  const wifiselector::Rect button =
      wifiselector::surveyPresetButton(width, height, roundDisplay);
  const int top = margin;
  const int bottom = button.y - (height >= 240 ? 8 : 4);
  const int shortSide = width < height ? width : height;
  // Glyphs grow with the glass: 2x is the idle card's size on the 240 px
  // panels, and the 466 px AMOLED and the P4's 720/800 px panels pack their
  // pixels far denser than that, so 2x there would be a few millimetres tall.
  int detail = shortSide >= 600 ? 4
               : shortSide >= 400 ? 3
               : shortSide >= 240 ? 2
                                  : 1;
  int signal = 4 * detail;
  bool hint = text[ROW_HINT] != nullptr && text[ROW_HINT][0] != 0;
  bool quality = text[ROW_QUALITY] != nullptr && text[ROW_QUALITY][0] != 0;
  bool battery = text[ROW_BATTERY] != nullptr && text[ROW_BATTERY][0] != 0;
  bool firmware = text[ROW_FIRMWARE] != nullptr && text[ROW_FIRMWARE][0] != 0;
  bool name = text[ROW_NAME] != nullptr && text[ROW_NAME][0] != 0;
  bool address = text[ROW_ADDRESS] != nullptr && text[ROW_ADDRESS][0] != 0;
  // Shrinks only, so this ends: each pass either fits or gives something up.
  for (;;) {
    uint8_t want[ROW_COUNT] = {};
    for (int row = 0; row < ROW_COUNT; ++row) {
      if (text[row] != nullptr && text[row][0] != 0) {
        want[row] = (uint8_t)detail;
      }
    }
    want[ROW_SIGNAL] =
        text[ROW_SIGNAL] != nullptr && text[ROW_SIGNAL][0] != 0
            ? (uint8_t)signal
            : 0;
    if (!battery) want[ROW_BATTERY] = 0;
    if (!firmware) want[ROW_FIRMWARE] = 0;
    if (!name) want[ROW_NAME] = 0;
    if (!address) want[ROW_ADDRESS] = 0;
    if (!quality) want[ROW_QUALITY] = 0;
    want[ROW_HINT] = hint ? (uint8_t)(detail > 1 ? detail - 1 : 1) : 0;

    Layout result;
    result.top = (int16_t)top;
    result.bottom = (int16_t)bottom;
    result.centreX = (int16_t)(width / 2);
    // A row too wide for its span drops a scale and the column is placed
    // again; rows only ever shrink, so this settles.
    for (int pass = 0; pass < 64; ++pass) {
      // A third of a detail glyph's height between rows, and never under
      // 4 px: at 1 px per glyph scale the 1.75" round's lines ran together.
      const TextStyle detailStyle =
          styleFor(ROW_ADDRESS, width, height, detail);
      int gap = textHeight(detailStyle) / 3;
      if (gap < 4) gap = 4;
      const bool divider = want[ROW_ADDRESS] > 0 &&
                           (want[ROW_SIGNAL] > 0 || want[ROW_QUALITY] > 0);
      int total = 0;
      int rows = 0;
      for (int row = 0; row < ROW_COUNT; ++row) {
        if (want[row] == 0) continue;
        total += textHeight(styleFor((Row)row, width, height, want[row]));
        ++rows;
      }
      if (rows > 1) total += gap * (rows - 1);
      // The rule takes its own gap on each side of a one-pixel line.
      if (divider) total += gap + 1;
      result.fits = total <= bottom - top;
      int y = top + (bottom - top - total) / 2;
      if (y < top) y = top;
      bool shrank = false;
      for (int row = 0; row < ROW_COUNT; ++row) {
        result.scale[row] = want[row];
        if (want[row] == 0) continue;
        result.style[row] = styleFor((Row)row, width, height, want[row]);
        if (divider && row == ROW_ADDRESS) {
          result.dividerY = (int16_t)y;
          int x = 0, span = 0;
          rowSpan(width, height, roundDisplay, result.dividerY,
                  result.dividerY + 1, x, span);
          result.dividerX = (int16_t)(x + span / 6);
          result.dividerWidth = (int16_t)(span - 2 * (span / 6));
          y += gap + 1;
        }
        const int rowHeight = textHeight(result.style[row]);
        int x = 0, span = 0;
        rowSpan(width, height, roundDisplay, y, y + rowHeight, x, span);
        result.y[row] = (int16_t)y;
        result.rowHeight[row] = (int16_t)rowHeight;
        result.spanX[row] = (int16_t)x;
        result.spanWidth[row] = (int16_t)span;
        const int needed = textWidth(text[row], result.style[row]);
        if (needed > span && want[row] > 1) {
          --want[row];
          shrank = true;
        }
        result.marquee[row] = needed > span &&
                              (row == ROW_NETWORK || row == ROW_NAME);
        y += rowHeight + gap;
      }
      if (!shrank) break;
    }
    if (result.fits) return result;
    // The meter gives way first, then the detail rows, and how to close the
    // screen goes only when nothing else can.
    if (battery) {
      // The battery line is valuable but optional. On 128px glass it yields
      // before the network, live meter, address, and identity rather than
      // squeezing those rows into unreadable overlap.
      battery = false;
    } else if (hint) {
      hint = false;
    } else if (quality) {
      quality = false;
    } else if (firmware) {
      firmware = false;
    } else if (name) {
      name = false;
    } else if (address) {
      address = false;
    } else if (signal > 2 * detail && signal > 3) {
      --signal;
    } else if (detail > 1) {
      --detail;
    } else if (signal > 2) {
      --signal;
    } else {
      return result;
    }
  }
}

// Kept for the host tests and callers that only have bounded lengths. Actual
// firmware uses the text overload above, so it measures the real glyphs.
inline Layout layout(int width, int height, bool roundDisplay,
                     const size_t lengths[ROW_COUNT]) {
  char values[ROW_COUNT][33] = {};
  const char *text[ROW_COUNT] = {};
  for (int row = 0; row < ROW_COUNT; ++row) {
    const size_t length = lengths[row] > 32 ? 32 : lengths[row];
    for (size_t i = 0; i < length; ++i) values[row][i] = 'W';
    text[row] = values[row];
  }
  return layout(width, height, roundDisplay, text);
}

}  // namespace wifistatus
