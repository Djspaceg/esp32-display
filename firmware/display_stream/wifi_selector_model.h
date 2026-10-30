// Hardware-free selection and label helpers for the on-device WiFi preset UI.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "wifi_presets.h"

namespace wifiselector {

struct Rect {
  int16_t x = 0;
  int16_t y = 0;
  int16_t width = 0;
  int16_t height = 0;

  bool contains(int16_t px, int16_t py) const {
    return px >= x && py >= y && px < x + width && py < y + height;
  }
};

enum class HitTarget : uint8_t {
  None = 0,
  Back,
  Previous,
  Next,
  Connect,
  Row,
};

struct Hit {
  HitTarget target = HitTarget::None;
  size_t rowIndex = 0;
};

struct SelectorLayout {
  Rect back;
  Rect title;
  Rect previous;
  Rect next;
  Rect connect;
  int16_t rowsY = 0;
  int16_t rowHeight = 0;
  int16_t rowX = 0;
  int16_t rowWidth = 0;
  size_t visibleCount = 0;
  size_t firstVisible = 0;

  Rect rowRect(size_t visibleRow) const {
    return {rowX, (int16_t)(rowsY + visibleRow * rowHeight), rowWidth,
            rowHeight};
  }
};

inline int safeMargin(int width, int height, bool roundDisplay) {
  int margin = 4;
  if (roundDisplay) {
    const int diameter = width < height ? width : height;
    // 18% leaves every corner of a control rectangle visibly inside the
    // circle. The mathematical inscribed-square inset is 14.65%, but its
    // border pixels lie on the bezel and were visibly cut on 1.85" glass.
    margin += diameter * 18 / 100;
  }
  return margin;
}

inline int controlHeight(int height) {
  if (height >= 400) return 44;
  if (height >= 300) return 40;
  if (height >= 240) return 34;
  return 24;
}

inline Rect surveyPresetButton(int width, int height, bool roundDisplay) {
  const int margin = safeMargin(width, height, roundDisplay);
  const int buttonHeight = controlHeight(height);
  return {(int16_t)margin, (int16_t)(height - margin - buttonHeight),
          (int16_t)(width - 2 * margin), (int16_t)buttonHeight};
}

// Whether a selector with no BACK control (no touch) has been left alone long
// enough to close. Never while a chosen network's restart is pending, and
// never under a held press: closing mid-hold would turn the hold that was
// choosing a network into a normal BOOT long press. Unsigned subtraction keeps
// it right across clock wrap.
inline bool idleTimedOut(uint32_t now, uint32_t lastInputAt, uint32_t idleMs,
                         bool touch, bool restartPending, bool pressHeld) {
  if (touch || restartPending || pressHeld) return false;
  return now - lastInputAt >= idleMs;
}

inline size_t initialIndex(const uint8_t *slots, size_t count,
                           uint8_t activeSlot) {
  if (slots == nullptr || count == 0) return 0;
  for (size_t i = 0; i < count; ++i) {
    if (slots[i] == activeSlot) return i;
  }
  return 0;
}

inline size_t movedIndex(size_t current, size_t count, int direction) {
  if (count == 0) return 0;
  current %= count;
  if (direction < 0) return current == 0 ? count - 1 : current - 1;
  if (direction > 0) return current + 1 == count ? 0 : current + 1;
  return current;
}

inline size_t windowStart(size_t current, size_t count, size_t visibleCount) {
  if (count == 0 || visibleCount == 0 || visibleCount >= count) return 0;
  current %= count;
  size_t first = current > visibleCount / 2 ? current - visibleCount / 2 : 0;
  const size_t lastStart = count - visibleCount;
  if (first > lastStart) first = lastStart;
  return first;
}

inline SelectorLayout selectorLayout(int width, int height, bool roundDisplay,
                                     size_t count, size_t selectedIndex) {
  SelectorLayout layout;
  const int margin = safeMargin(width, height, roundDisplay);
  const int gap = height >= 240 ? 6 : 4;
  const int buttonHeight = controlHeight(height);
  const int contentWidth = width - 2 * margin;

  int backWidth = width >= 240 ? 72 : 48;
  if (backWidth > contentWidth / 2) backWidth = contentWidth / 2;
  layout.back = {(int16_t)margin, (int16_t)margin, (int16_t)backWidth,
                 (int16_t)buttonHeight};
  layout.title = {
      (int16_t)(margin + backWidth + gap), (int16_t)margin,
      (int16_t)(contentWidth - backWidth - gap), (int16_t)buttonHeight};

  const int footerY = height - margin - buttonHeight;
  // The navigation hint spans Previous and Next. Giving Connect one third of
  // the footer preserves a usable combined hint rectangle on 240px touch
  // screens without encoding a board-specific layout.
  int connectWidth = contentWidth / 3;
  int navWidth = (contentWidth - connectWidth - 2 * gap) / 2;
  if (navWidth < 1) navWidth = 1;
  connectWidth = contentWidth - 2 * navWidth - 2 * gap;
  layout.previous = {(int16_t)margin, (int16_t)footerY, (int16_t)navWidth,
                     (int16_t)buttonHeight};
  layout.next = {(int16_t)(margin + navWidth + gap), (int16_t)footerY,
                 (int16_t)navWidth, (int16_t)buttonHeight};
  layout.connect = {
      (int16_t)(margin + 2 * navWidth + 2 * gap), (int16_t)footerY,
      (int16_t)connectWidth, (int16_t)buttonHeight};

  const int listTop = margin + buttonHeight + gap;
  const int listBottom = footerY - gap;
  const int listHeight = listBottom > listTop ? listBottom - listTop : 1;
  int rowHeight =
      height >= 400 ? 48 : (height >= 300 ? 44 : (height >= 240 ? 34 : 26));
  if (rowHeight > listHeight) rowHeight = listHeight;
  size_t visibleCount = rowHeight > 0 ? (size_t)(listHeight / rowHeight) : 0;
  if (visibleCount == 0 && count > 0) visibleCount = 1;
  if (visibleCount > count) visibleCount = count;

  layout.rowHeight = (int16_t)rowHeight;
  layout.rowX = (int16_t)margin;
  layout.rowWidth = (int16_t)contentWidth;
  layout.visibleCount = visibleCount;
  layout.firstVisible = windowStart(selectedIndex, count, visibleCount);
  const int rowsHeight = (int)visibleCount * rowHeight;
  layout.rowsY = (int16_t)(listTop + (listHeight - rowsHeight) / 2);
  return layout;
}

inline Hit selectorHitTest(const SelectorLayout &layout, size_t count,
                           int16_t x, int16_t y) {
  if (layout.back.contains(x, y)) return {HitTarget::Back, 0};
  if (layout.previous.contains(x, y)) return {HitTarget::Previous, 0};
  if (layout.next.contains(x, y)) return {HitTarget::Next, 0};
  if (layout.connect.contains(x, y)) return {HitTarget::Connect, 0};
  for (size_t row = 0; row < layout.visibleCount; ++row) {
    if (!layout.rowRect(row).contains(x, y)) continue;
    const size_t index = layout.firstVisible + row;
    if (index < count) return {HitTarget::Row, index};
  }
  return {};
}

// The panel font is ASCII. An SSID or a name is bytes, usually UTF-8, so
// each character is shown in its closest ASCII form: a Latin letter with an
// accent as its base letter, typographic quotes and dashes as plain ones, and
// anything else (CJK, emoji, a byte that is not UTF-8) as one '?' per
// character, not one per byte. Writes at most capacity - 1 characters and a
// NUL; returns how many characters the whole text needs.
inline char panelCharFor(uint32_t codePoint) {
  // U+00C0..U+00FF and U+0100..U+017F, folded to their base letters.
  static const char LATIN1[] =
      "AAAAAAACEEEEIIIIDNOOOOOxOUUUUYTsaaaaaaaceeeeiiiidnooooo/ouuuuyty";
  static const char EXTENDED_A[] =
      "AaAaAaCcCcCcCcDdDdEeEeEeEeEeGgGgGgGgHhHhIiIiIiIiIiIiJjKkkLlLlLlLlLl"
      "NnNnNnnNnOoOoOoOoRrRrRrSsSsSsSsTtTtTtUuUuUuUuUuUuWwYyYZzZzZzs";
  if (codePoint >= 0x20 && codePoint <= 0x7E) return (char)codePoint;
  if (codePoint == 0xA0) return ' ';
  if (codePoint >= 0xC0 && codePoint <= 0xFF) return LATIN1[codePoint - 0xC0];
  if (codePoint >= 0x100 && codePoint <= 0x17F) {
    return EXTENDED_A[codePoint - 0x100];
  }
  switch (codePoint) {
    case 0x2018:
    case 0x2019:
      return '\'';
    case 0x201C:
    case 0x201D:
      return '"';
    case 0x2010:
    case 0x2011:
    case 0x2013:
    case 0x2014:
      return '-';
    default:
      return '?';
  }
}

inline size_t panelText(const uint8_t *input, size_t length, char *output,
                        size_t capacity) {
  size_t produced = 0;
  size_t i = 0;
  while (i < length) {
    const uint8_t lead = input[i];
    size_t extra = 0;
    uint32_t codePoint = lead;
    if (lead >= 0xC2 && lead <= 0xDF) {
      extra = 1;
      codePoint = lead & 0x1F;
    } else if (lead >= 0xE0 && lead <= 0xEF) {
      extra = 2;
      codePoint = lead & 0x0F;
    } else if (lead >= 0xF0 && lead <= 0xF4) {
      extra = 3;
      codePoint = lead & 0x07;
    } else if (lead >= 0x80) {
      codePoint = 0xFFFD;  // a continuation or invalid lead byte on its own
    }
    size_t used = 1;
    for (size_t k = 1; k <= extra; ++k) {
      if (i + k >= length || (input[i + k] & 0xC0) != 0x80) {
        codePoint = 0xFFFD;  // cut off, or not followed by continuations
        break;
      }
      codePoint = (codePoint << 6) | (input[i + k] & 0x3F);
      used = k + 1;
    }
    if (codePoint == 0xFFFD && extra > 0) {
      // A broken sequence is one character; skip its continuations.
      while (used < extra + 1 && i + used < length &&
             (input[i + used] & 0xC0) == 0x80) {
        ++used;
      }
    }
    i += used;
    if (output != nullptr && produced + 1 < capacity) {
      output[produced] = panelCharFor(codePoint);
      output[produced + 1] = 0;
    }
    ++produced;
  }
  if (output != nullptr && capacity > 0 && produced == 0) output[0] = 0;
  return produced;
}

inline size_t displaySsid(const wifipresets::Credentials &credentials,
                          char *output, size_t capacity) {
  if (output == nullptr || capacity == 0) return 0;
  const size_t available = capacity - 1;
  char text[33];
  size_t length = panelText(credentials.ssid, credentials.ssidLength, text,
                            sizeof(text));
  if (length > sizeof(text) - 1) length = sizeof(text) - 1;
  size_t copied = length;
  if (copied > available) copied = available;
  memcpy(output, text, copied);
  if (length > copied && copied >= 3) {
    output[copied - 3] = '.';
    output[copied - 2] = '.';
    output[copied - 1] = '.';
  }
  output[copied] = 0;
  return copied;
}

}  // namespace wifiselector
