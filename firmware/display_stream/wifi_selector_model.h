// Hardware-free selection and label helpers for the on-device WiFi preset UI.
#pragma once

#include <stddef.h>
#include <stdint.h>

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
    margin += diameter * 1465 / 10000;
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
  int connectWidth = contentWidth / 2;
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

inline size_t displaySsid(const wifipresets::Credentials &credentials,
                          char *output, size_t capacity) {
  if (output == nullptr || capacity == 0) return 0;
  const size_t available = capacity - 1;
  size_t copied = credentials.ssidLength;
  if (copied > available) copied = available;
  for (size_t i = 0; i < copied; ++i) {
    const uint8_t byte = credentials.ssid[i];
    output[i] = byte >= 0x20 && byte <= 0x7E ? (char)byte : '?';
  }
  if (credentials.ssidLength > copied && copied >= 3) {
    output[copied - 3] = '.';
    output[copied - 2] = '.';
    output[copied - 1] = '.';
  }
  output[copied] = 0;
  return copied;
}

}  // namespace wifiselector
