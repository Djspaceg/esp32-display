// Hardware-independent renderers for the panel's non-streaming screens.
// Firmware supplies live state; the host preview supplies representative state.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "glyph_draw.h"
#include "ui_icons.h"
#include "ui_theme.h"
#include "wifi_selector_model.h"
#include "wifi_status_model.h"

namespace staticui {

struct Panel {
  uint8_t *pixels;
  int width;
  int height;
  bool round;
  uint16_t diagonalTenthsMm = 0;
};

inline void maskOutsideRoundPanel(const Panel &panel) {
  if (!panel.round) return;
  const int side = panel.width < panel.height ? panel.width : panel.height;
  const long radius2 = (long)side * side;
  for (int y = 0; y < panel.height; ++y) {
    for (int x = 0; x < panel.width; ++x) {
      const long dx = 2L * x + 1 - panel.width;
      const long dy = 2L * y + 1 - panel.height;
      if (dx * dx + dy * dy <= radius2) continue;
      const size_t at = ((size_t)y * panel.width + x) * 2;
      panel.pixels[at] = 0;
      panel.pixels[at + 1] = 0;
    }
  }
}

inline TextStyle styleToFit(int width, int height, uint16_t diagonalTenthsMm,
                            int availableWidth, int availableHeight,
                            const char *text, bool heading) {
  TextStyle style = heading ? largeTextStyle(width, height, diagonalTenthsMm)
                            : smallTextStyle(width, height, diagonalTenthsMm);
  while (textWidth(text, style) > availableWidth - 4 ||
         textHeight(style) > availableHeight - 4) {
    if (style.family == TextFamily::Large && style.pixels > 24) {
      style = {TextFamily::Large, 24};
    } else if (style.family == TextFamily::Large) {
      style = smallTextStyle(width, height, diagonalTenthsMm);
    } else if (style.family == TextFamily::Small && style.pixels > 18) {
      style = {TextFamily::Small, 18};
    } else if (style.family == TextFamily::Small && style.pixels > 13) {
      style = {TextFamily::Small, 13};
    } else if (style.family == TextFamily::Small && style.pixels > 9) {
      style = {TextFamily::Small, 9};
    } else {
      style = {TextFamily::Classic, 1};
      break;
    }
  }
  if (textWidth(text, style) > availableWidth - 2 ||
      textHeight(style) > availableHeight - 2) {
    style = {TextFamily::Classic, 1};
  }
  return style;
}

inline int textVisualCenterOffset(TextStyle style) {
  if (style.family == TextFamily::Classic) return 3 * style.pixels;
#if !defined(CONFIG_IDF_TARGET_ESP32C6)
  const panelfonts::Glyph &xGlyph =
      faceFor(style).glyphs['x' - panelfonts::FIRST];
  return xGlyph.yOffset + xGlyph.height / 2;
#else
  return 3 * style.pixels;
#endif
}

inline void textInRect(const Panel &panel, const wifiselector::Rect &rect,
                       const char *text, bool heading, uint16_t color,
                       bool centred = true) {
  const TextStyle style = styleToFit(
      panel.width, panel.height, panel.diagonalTenthsMm, rect.width,
      rect.height, text, heading);
  const int x = centred ? rect.x + (rect.width - textWidth(text, style)) / 2
                        : rect.x;
  const int y = rect.y + rect.height / 2 - textVisualCenterOffset(style);
  drawTextClipped(panel.pixels, panel.width, panel.height, x, y, text, color,
                  style, rect.x, rect.y, rect.width, rect.height);
}

inline void truncateToWidth(const char *text, TextStyle style, int maxWidth,
                            char *out, size_t outSize);

inline void centredText(const Panel &panel, int y, const char *text,
                        TextStyle style, uint16_t color) {
  drawText(panel.pixels, panel.width, panel.height,
           (panel.width - textWidth(text, style)) / 2, y, text, color, style);
}

inline void monoCentredText(const Panel &panel, int y, const char *text) {
  const TextStyle style = {TextFamily::Classic, 1};
  centredText(panel, y, text, style, uitheme::CURRENT.primary);
}

inline void drawButton(const Panel &panel, const wifiselector::Rect &rect,
                       const char *label, bool selected, bool enabled = true) {
  const uint16_t color = selected && enabled ? uitheme::CURRENT.primary
                                             : uitheme::CURRENT.secondary;
  uitheme::card(panel.pixels, panel.width, panel.height,
                {rect.x, rect.y, rect.width, rect.height}, selected && enabled);
  textInRect(panel, rect, label, false, color);
}

struct HintLayout {
  TextStyle style;
  bool stacked;
};

inline int hintInlineWidth(TextStyle style, int height, const char *first,
                           const char *second) {
  const int icon = height >= 34 ? 10 : 8;
  const int edge = height >= 34 ? 14 : 7;
  const int gap = icon;
  return 2 * edge + 2 * icon + 3 * gap + 4 +
         textWidth(first, style) + textWidth(second, style);
}

inline int hintStackedWidth(TextStyle style, int height, const char *first,
                            const char *second) {
  const int icon = height >= 34 ? 10 : 8;
  const int gap = icon;
  const int firstWidth = icon + gap + textWidth(first, style);
  const int secondWidth = 7 + gap + textWidth(second, style);
  return firstWidth > secondWidth ? firstWidth : secondWidth;
}

inline TextStyle hintStyleToFit(const Panel &panel, int width, int height,
                                const char *first, const char *second) {
  TextStyle style =
      smallTextStyle(panel.width, panel.height, panel.diagonalTenthsMm);
  while (hintInlineWidth(style, height, first, second) > width) {
    if (style.family == TextFamily::Small && style.pixels > 18) {
      style = {TextFamily::Small, 18};
    } else if (style.family == TextFamily::Small && style.pixels > 13) {
      style = {TextFamily::Small, 13};
    } else if (style.family == TextFamily::Small && style.pixels > 9) {
      style = {TextFamily::Small, 9};
    } else {
      return {TextFamily::Classic, 1};
    }
  }
  return style;
}

inline HintLayout hintLayout(const Panel &panel, int width, int height,
                             int availableHeight, const char *first,
                             const char *second) {
  const TextStyle preferred =
      smallTextStyle(panel.width, panel.height, panel.diagonalTenthsMm);
  if (hintInlineWidth(preferred, height, first, second) <= width) {
    return {preferred, false};
  }
  TextStyle stacked = preferred;
  while (hintStackedWidth(stacked, height, first, second) > width) {
    if (stacked.family == TextFamily::Small && stacked.pixels > 18) {
      stacked = {TextFamily::Small, 18};
    } else if (stacked.family == TextFamily::Small && stacked.pixels > 13) {
      stacked = {TextFamily::Small, 13};
    } else if (stacked.family == TextFamily::Small && stacked.pixels > 9) {
      stacked = {TextFamily::Small, 9};
    } else {
      break;
    }
  }
  const int stackedHeight = 2 * textLineHeight(stacked) + 8;
  if (hintStackedWidth(stacked, height, first, second) <= width &&
      stackedHeight <= availableHeight) {
    return {stacked, true};
  }
  return {hintStyleToFit(panel, width, height, first, second), false};
}

inline void drawHint(const Panel &panel, const wifiselector::Rect &rect,
                     const char *first, const char *second,
                     const HintLayout &layout) {
  uitheme::card(panel.pixels, panel.width, panel.height,
                {rect.x, rect.y, rect.width, rect.height}, false);
  const int icon = rect.height >= 34 ? 10 : 8;
  const int left = rect.x + (rect.width > 120 ? 14 : 7);
  const int gap = icon;
  const TextStyle style = layout.style;
  if (layout.stacked) {
    const int firstWidth = icon + gap + textWidth(first, style);
    const int secondWidth = 7 + gap + textWidth(second, style);
    const int lineHeight = textLineHeight(style);
    const int firstX = rect.x + (rect.width - firstWidth) / 2;
    const int secondX = rect.x + (rect.width - secondWidth) / 2;
    const int firstY = rect.y + rect.height / 2 - lineHeight / 2 -
                       textVisualCenterOffset(style);
    const int secondY = firstY + lineHeight;
    uiicons::pressHint(panel.pixels, panel.width, panel.height, firstX,
                       firstY + textVisualCenterOffset(style) - 4,
                       uitheme::CURRENT.secondary);
    drawText(panel.pixels, panel.width, panel.height, firstX + icon + gap,
             firstY, first,
             uitheme::CURRENT.secondary, style);
    uiprim::fillCircle(panel.pixels, panel.width, panel.height, secondX + 3,
                       secondY + textVisualCenterOffset(style), 3,
                       uitheme::CURRENT.secondary);
    drawText(panel.pixels, panel.width, panel.height, secondX + 7 + gap,
             secondY, second,
             uitheme::CURRENT.secondary, style);
    return;
  }
  const int textY = rect.y + rect.height / 2 - textVisualCenterOffset(style);
  uiicons::pressHint(panel.pixels, panel.width, panel.height, left,
                     rect.y + rect.height / 2 - 4,
                     uitheme::CURRENT.secondary);
  const int firstX = left + icon + gap / 2;
  const int secondIconX = firstX + textWidth(first, style) + gap;
  const int secondX = secondIconX + 4 + gap / 2;
  uiprim::fillCircle(panel.pixels, panel.width, panel.height, secondIconX,
                     rect.y + rect.height / 2, 3,
                     uitheme::CURRENT.secondary);
  drawText(panel.pixels, panel.width, panel.height, firstX,
           textY, first,
           uitheme::CURRENT.secondary, style);
  drawText(panel.pixels, panel.width, panel.height,
           secondX,
           textY, second,
           uitheme::CURRENT.secondary, style);
}

inline void drawListRow(const Panel &panel, const wifiselector::Rect &rect,
                        const char *label, unsigned index, bool selected,
                        bool active, bool bootMenu) {
  uitheme::card(panel.pixels, panel.width, panel.height,
                {rect.x, rect.y, rect.width, rect.height}, selected);
  const uint16_t foreground =
      selected ? uitheme::CURRENT.primary : uitheme::CURRENT.secondary;
  const int iconSize = rect.height > 34 ? 16 : 10;
  const int left = rect.x + (rect.height > 34 ? 14 : 7);
  const int centreY = rect.y + rect.height / 2;

  char number[4];
  snprintf(number, sizeof(number), "%02u", index);
  const TextStyle indexStyle =
      monoTextStyle(panel.width, panel.height, panel.diagonalTenthsMm);
  const int indexWidth = textWidth(number, indexStyle);
  const int indexX = rect.x + rect.width - indexWidth -
                     (rect.height > 34 ? 14 : 7);
  const int labelX = left + iconSize * 2;
  const wifiselector::Rect labelRect = {
      (int16_t)labelX, rect.y,
      (int16_t)(indexX - labelX - (rect.height > 34 ? 10 : 5)),
      rect.height};
  const TextStyle labelStyle = styleToFit(
      panel.width, panel.height, panel.diagonalTenthsMm, labelRect.width,
      labelRect.height, "...", false);
  char labelText[33];
  truncateToWidth(label, labelStyle, labelRect.width, labelText,
                  sizeof(labelText));

  if (bootMenu && index == 1) {
    uiicons::screen(panel.pixels, panel.width, panel.height, left,
                    centreY - iconSize * 3 / 8 - 1, iconSize, foreground);
  } else if (bootMenu && index == 2) {
    uiicons::target(panel.pixels, panel.width, panel.height,
                    left + iconSize / 2, centreY, iconSize, foreground);
  } else if (active) {
    uiicons::check(panel.pixels, panel.width, panel.height, left,
                   centreY - iconSize * 3 / 4, iconSize, foreground);
  } else {
    uiicons::wifi(panel.pixels, panel.width, panel.height,
                  left + iconSize / 2, centreY + iconSize / 2 - 1, iconSize,
                  foreground, 2);
  }

  drawText(panel.pixels, panel.width, panel.height, indexX,
           rect.y + rect.height / 2 - textVisualCenterOffset(indexStyle),
           number,
           foreground, indexStyle);
  drawTextClipped(panel.pixels, panel.width, panel.height, labelRect.x,
                  labelRect.y + labelRect.height / 2 -
                      textVisualCenterOffset(labelStyle),
                  labelText, foreground, labelStyle, labelRect.x,
                  labelRect.y, labelRect.width, labelRect.height);
}

inline void drawSelector(const Panel &panel, const char *title,
                         const char *const *labels, const uint8_t *indices,
                         size_t count, size_t selected, int activeIndex,
                         bool touch, bool bootMenu = false,
                         const char *message = nullptr) {
  uitheme::background(panel.pixels, panel.width, panel.height);
  uitheme::ticks(panel.pixels, panel.width, panel.height, panel.round);
  if (useClassicText(panel.width, panel.height)) {
    monoCentredText(panel, 1, bootMenu ? "Mode" : "WiFi");
    if (message != nullptr && message[0] != 0) {
      monoCentredText(panel, 12, message);
    } else {
      for (size_t row = 0; row < count && row < 2; ++row) {
        monoCentredText(panel, 12 + (int)row * 9, labels[row]);
      }
    }
    monoCentredText(panel, 31, touch ? "Tap: use" : "Next / start");
    return;
  }
  const wifiselector::SelectorLayout layout = wifiselector::selectorLayout(
      panel.width, panel.height, panel.round, count, selected);
  const wifiselector::Rect titleRect = {
      layout.back.x, layout.back.y,
      (int16_t)(layout.title.x + layout.title.width - layout.back.x),
      layout.back.height};
  textInRect(panel, titleRect, title, true, uitheme::CURRENT.primary);

  if (message != nullptr && message[0] != 0) {
    const wifiselector::Rect text = {
        (int16_t)wifiselector::safeMargin(panel.width, panel.height, panel.round),
        (int16_t)(panel.height / 2 - layout.rowHeight / 2),
        (int16_t)(panel.width - 2 * wifiselector::safeMargin(
                                  panel.width, panel.height, panel.round)),
        layout.rowHeight};
    textInRect(panel, text, message, false, uitheme::CURRENT.secondary);
  } else {
    for (size_t row = 0; row < layout.visibleCount; ++row) {
      const size_t i = layout.firstVisible + row;
      if (i >= count) break;
      drawListRow(panel, layout.rowRect(row), labels[i],
                  indices == nullptr ? (unsigned)(i + 1) : indices[i],
                  i == selected, (int)i == activeIndex, bootMenu);
    }
  }

  wifiselector::Rect hint = touch
                                 ? wifiselector::Rect{
                                       layout.previous.x, layout.previous.y,
                                       (int16_t)(layout.next.x +
                                                 layout.next.width -
                                                 layout.previous.x),
                                       layout.previous.height}
                                 : wifiselector::Rect{
                                       layout.previous.x, layout.previous.y,
                                       (int16_t)(layout.connect.x +
                                                 layout.connect.width -
                                                 layout.previous.x),
                                       layout.previous.height};
  const int rowsBottom =
      layout.rowsY + (int)layout.visibleCount * layout.rowHeight + 4;
  const int availableHintHeight = hint.y + hint.height - rowsBottom;
  const HintLayout hintLayout = staticui::hintLayout(
      panel, hint.width, hint.height, availableHintHeight, "next",
      bootMenu ? "hold: start" : "hold: use");
  if (hintLayout.stacked) {
    hint.height = (int16_t)(2 * textLineHeight(hintLayout.style) + 8);
    hint.y = (int16_t)(hint.y + layout.previous.height - hint.height);
  }
  drawHint(panel, hint, "next", bootMenu ? "hold: start" : "hold: use",
           hintLayout);
  if (touch) {
    drawButton(panel, layout.connect, bootMenu ? "Start" : "Connect", false,
               count > 0);
  }
  maskOutsideRoundPanel(panel);
}

inline void drawTonalInformationCard(const Panel &panel,
                                     const wifiselector::Rect &rect,
                                     const char *caption, const char *value) {
  uitheme::card(panel.pixels, panel.width, panel.height,
                {rect.x, rect.y, rect.width, rect.height}, false);
  TextStyle captionStyle =
      smallTextStyle(panel.width, panel.height, panel.diagonalTenthsMm);
  TextStyle valueStyle =
      monoTextStyle(panel.width, panel.height, panel.diagonalTenthsMm);
  if (textWidth(value, valueStyle) > rect.width - 8 ||
      textHeight(valueStyle) > rect.height / 2) {
    valueStyle =
        smallTextStyle(panel.width, panel.height, panel.diagonalTenthsMm);
  }
  const int captionY = rect.y + (rect.height - textHeight(captionStyle) -
                                 textHeight(valueStyle)) /
                                    2;
  const int valueY = captionY + textHeight(captionStyle);
  const wifiselector::Rect captionRect = {
      rect.x, (int16_t)captionY, rect.width, (int16_t)textHeight(captionStyle)};
  const wifiselector::Rect valueRect = {
      rect.x, (int16_t)valueY, rect.width, (int16_t)textHeight(valueStyle)};
  textInRect(panel, captionRect, caption, false, uitheme::CURRENT.tertiary);
  textInRect(panel, valueRect, value, false, uitheme::CURRENT.secondary);
}

inline int wrappedLineCount(const char *text, TextStyle style, int width) {
  if (text == nullptr || *text == 0 || width <= 0) return 0;
  int lines = 1;
  int used = 0;
  for (const char *at = text; *at;) {
    while (*at == ' ') ++at;
    if (*at == 0) break;
    int wordWidth = 0;
    const char *word = at;
    while (*at != 0 && *at != ' ') {
      const char glyph[2] = {*at++, 0};
      wordWidth += style.family == TextFamily::Classic
                       ? 6 * style.pixels
                       : textWidth(glyph, style);
    }
    if (wordWidth > width) {
      if (used > 0) {
        ++lines;
        used = 0;
      }
      for (const char *letter = word; letter < at; ++letter) {
        const char glyph[2] = {*letter, 0};
        const int advance = style.family == TextFamily::Classic
                                ? 6 * style.pixels
                                : textWidth(glyph, style);
        if (used > 0 && used + advance > width) {
          ++lines;
          used = 0;
        }
        used += advance;
      }
      continue;
    }
    const int gap = used == 0 ? 0 : textWidth(" ", style);
    if (used > 0 && used + gap + wordWidth > width) {
      ++lines;
      used = 0;
    }
    used += (used == 0 ? 0 : textWidth(" ", style)) + wordWidth;
  }
  return lines;
}

inline TextStyle wrappedStyle(const Panel &panel, const char *text, int width,
                              TextStyle preferred, int &lineCount) {
  const TextStyle candidates[] = {
      preferred, smallTextStyle(panel.width, panel.height,
                                panel.diagonalTenthsMm),
      {TextFamily::Small, 9}, {TextFamily::Classic, 1},
  };
  for (TextStyle style : candidates) {
    const int lines = wrappedLineCount(text, style, width);
    if (lines <= 2 || style.family == TextFamily::Classic) {
      lineCount = lines;
      return style;
    }
  }
  lineCount = 1;
  return {TextFamily::Classic, 1};
}

inline void drawWrappedText(const Panel &panel, int x, int y, int width,
                            const char *text, TextStyle style,
                            uint16_t color) {
  char line[33] = {};
  int count = 0;
  int used = 0;
  for (const char *at = text; at != nullptr && *at;) {
    while (*at == ' ') ++at;
    if (*at == 0) break;
    const char *word = at;
    int wordWidth = 0;
    while (*at != 0 && *at != ' ') {
      const char glyph[2] = {*at++, 0};
      wordWidth += style.family == TextFamily::Classic
                       ? 6 * style.pixels
                       : textWidth(glyph, style);
    }
    const int gap = count == 0 ? 0 : textWidth(" ", style);
    if (count > 0 && used + gap + wordWidth > width) {
      line[count] = 0;
      drawText(panel.pixels, panel.width, panel.height,
               x + (width - used) / 2, y, line, color, style);
      y += textLineHeight(style);
      count = 0;
      used = 0;
    }
    if (count > 0 && count < (int)sizeof(line) - 1) {
      line[count++] = ' ';
      used += textWidth(" ", style);
    }
    for (const char *letter = word; letter < at; ++letter) {
      const char glyph[2] = {*letter, 0};
      const int advance = style.family == TextFamily::Classic
                              ? 6 * style.pixels
                              : textWidth(glyph, style);
      if (count > 0 && used + advance > width) {
        line[count] = 0;
        drawText(panel.pixels, panel.width, panel.height,
                 x + (width - used) / 2, y, line, color, style);
        y += textLineHeight(style);
        count = 0;
        used = 0;
      }
      if (count == (int)sizeof(line) - 1) {
        line[count] = 0;
        drawText(panel.pixels, panel.width, panel.height,
                 x + (width - used) / 2, y, line, color, style);
        y += textLineHeight(style);
        count = 0;
        used = 0;
      }
      line[count++] = *letter;
      used += advance;
    }
  }
  if (count > 0) {
    line[count] = 0;
    drawText(panel.pixels, panel.width, panel.height, x + (width - used) / 2,
             y, line, color, style);
  }
}

inline int batteryPercent(const char *battery) {
  if (battery == nullptr) return -1;
  for (const char *at = battery; *at; ++at) {
    if (*at < '0' || *at > '9') continue;
    int value = 0;
    while (*at >= '0' && *at <= '9') {
      value = value * 10 + (*at - '0');
      ++at;
    }
    return value > 100 ? 100 : value;
  }
  return -1;
}

inline void truncateToWidth(const char *text, TextStyle style, int maxWidth,
                            char *out, size_t outSize) {
  if (out == nullptr || outSize == 0) return;
  out[0] = 0;
  if (text == nullptr || maxWidth <= 0) return;
  if (textWidth(text, style) <= maxWidth) {
    strncpy(out, text, outSize - 1);
    out[outSize - 1] = 0;
    return;
  }
  const int ellipsisWidth = textWidth("...", style);
  int used = 0;
  size_t count = 0;
  while (text[count] != 0 && count + 4 <= outSize) {
    const char glyph[2] = {text[count], 0};
    const int advance = style.family == TextFamily::Classic
                            ? 6 * style.pixels
                            : textWidth(glyph, style);
    if (used + advance + ellipsisWidth > maxWidth) break;
    out[count] = text[count];
    used += advance;
    ++count;
  }
  if (ellipsisWidth <= maxWidth && count + 4 <= outSize) {
    memcpy(out + count, "...", 4);
  }
}

inline void drawSurvey(const Panel &panel, const char *network, int rssi,
                       const char *quality, const char *address,
                       const char *firmware, const char *battery,
                       const char *hint, bool touch) {
  uitheme::background(panel.pixels, panel.width, panel.height);
  uitheme::ticks(panel.pixels, panel.width, panel.height, panel.round);
  if (useClassicText(panel.width, panel.height)) {
    char signal[16];
    snprintf(signal, sizeof(signal), "%s %d dBm", "WiFi", rssi);
    monoCentredText(panel, 1, signal);
    monoCentredText(panel, 11, network);
    monoCentredText(panel, 21, quality);
    monoCentredText(panel, 31, touch ? "Tap: presets" : "Press: close");
    return;
  }
  const uint16_t rimColor =
      rssi == 0 ? uitheme::CURRENT.tertiary
                : uitheme::signalColorForRssi(rssi);

  const int margin =
      wifiselector::safeMargin(panel.width, panel.height, panel.round);
  int control = wifiselector::controlHeight(panel.height);
  if (panel.width < 170 && panel.height < 170) control = 18;
  const int bottom = panel.height - margin - control;
  const int wide = panel.width - 2 * margin;
  TextStyle labelStyle =
      smallTextStyle(panel.width, panel.height, panel.diagonalTenthsMm);
  const int percent = batteryPercent(battery);
  char percentText[5] = {};
  if (percent >= 0) snprintf(percentText, sizeof(percentText), "%d%%", percent);
  const int batteryWidth =
      percent >= 0 && panel.width >= 170
          ? 20 + textWidth(percentText, labelStyle)
          : 0;
  const int wifiIconSize = panel.height >= 240 ? 14 : 9;
  const int iconGap = panel.width >= 240 ? 10 : 5;
  const int networkX = margin + 2 * wifiIconSize + iconGap;
  const int batteryX = margin + wide - batteryWidth;
  const int networkRight =
      batteryWidth > 0 ? batteryX - iconGap : margin + wide;
  const int networkWidth = networkRight - networkX;
  TextStyle networkStyle = styleToFit(
      panel.width, panel.height, panel.diagonalTenthsMm, networkWidth,
      panel.height, "...", true);
  if (networkStyle.family == TextFamily::Large && networkStyle.pixels > 24) {
    networkStyle = {TextFamily::Large, 24};
  }
  char networkLabel[33];
  truncateToWidth(network, networkStyle, networkWidth, networkLabel,
                  sizeof(networkLabel));
  TextStyle meterStyle =
      monoTextStyle(panel.width, panel.height, panel.diagonalTenthsMm);
  if (panel.height >= 96 && panel.width >= 96 && panel.height < 170) {
    meterStyle = {TextFamily::Mono, 24};
  } else if (panel.height < 96 || panel.width < 96) {
    meterStyle = {TextFamily::Mono, 12};
  }
  const int titleY = margin + 2;
  const int networkH = textLineHeight(networkStyle);
  const int meterY = titleY + networkH + (panel.height >= 240 ? 8 : 4);
  const int qualityY = meterY + textHeight(meterStyle) + 2;
  const int cardsY = qualityY + textHeight(labelStyle) + (panel.height >= 240 ? 10 : 5);
  int cardsH = panel.height >= 400 ? 62
               : panel.height >= 240 ? 54
               : (panel.height >= 170 ? 36 : 22);
  if (cardsY + cardsH + 4 > bottom) cardsH = bottom - cardsY - 4;
  if (cardsH < 12) cardsH = 12;
  const int gap = panel.width >= 240 ? 8 : 4;
  const int cardW = (wide - gap) / 2;
  const wifiselector::Rect networkRect = {
      (int16_t)networkX, (int16_t)titleY, (int16_t)networkWidth,
      (int16_t)networkH};
  uiicons::wifi(panel.pixels, panel.width, panel.height,
                margin + wifiIconSize,
                titleY + textVisualCenterOffset(networkStyle) +
                    wifiIconSize / 2 - 1,
                wifiIconSize, uitheme::CURRENT.secondary, 3);
  drawTextClipped(panel.pixels, panel.width, panel.height, networkRect.x,
                  networkRect.y, networkLabel, uitheme::CURRENT.secondary,
                  networkStyle, networkRect.x, networkRect.y,
                  networkRect.width, networkRect.height);
  if (percent >= 0 && batteryWidth > 0) {
    const int batteryX = margin + wide - batteryWidth;
    const int batteryY =
        titleY + textVisualCenterOffset(networkStyle) -
        textVisualCenterOffset(labelStyle);
    uiicons::battery(panel.pixels, panel.width, panel.height, batteryX,
                     batteryY + textVisualCenterOffset(labelStyle) - 4, 16,
                     8,
                     uitheme::CURRENT.teal, percent);
    drawText(panel.pixels, panel.width, panel.height, batteryX + 20,
             batteryY, percentText,
             uitheme::CURRENT.secondary, labelStyle);
  }

  char signal[8];
  if (rssi == 0) {
    snprintf(signal, sizeof(signal), "--");
  } else {
    snprintf(signal, sizeof(signal), "%d", rssi);
  }
  centredText(panel, meterY, signal, meterStyle,
              rssi == 0 ? uitheme::CURRENT.secondary : rimColor);
  char qualityLine[32];
  snprintf(qualityLine, sizeof(qualityLine), "%s \xB7 dBm", quality);
  const int dotX =
      (panel.width - textWidth(qualityLine, labelStyle)) / 2 - 7;
  uiprim::fillCircle(panel.pixels, panel.width, panel.height, dotX,
                     qualityY + textHeight(labelStyle) / 2, 3, rimColor);
  centredText(panel, qualityY, qualityLine, labelStyle,
              uitheme::CURRENT.secondary);

  if (panel.width < 170 && panel.height < 170) {
    const wifiselector::Rect details = {
        (int16_t)margin, (int16_t)cardsY, (int16_t)wide,
        (int16_t)(bottom - cardsY - 4)};
    uitheme::card(panel.pixels, panel.width, panel.height,
                  {details.x, details.y, details.width, details.height}, false);
    char ipLine[32];
    char firmwareLine[32];
    snprintf(ipLine, sizeof(ipLine), "IP %s", address);
    snprintf(firmwareLine, sizeof(firmwareLine), "Firmware %s", firmware);
    const int firstY = details.y + 1;
    drawText(panel.pixels, panel.width, panel.height, details.x + 4, firstY,
             ipLine, uitheme::CURRENT.secondary, labelStyle);
    drawText(panel.pixels, panel.width, panel.height, details.x + 4,
             firstY + textLineHeight(labelStyle), firmwareLine,
             uitheme::CURRENT.secondary, labelStyle);
  } else {
    const wifiselector::Rect ipCard = {(int16_t)margin, (int16_t)cardsY,
                                       (int16_t)cardW, (int16_t)cardsH};
    const wifiselector::Rect fwCard = {(int16_t)(margin + cardW + gap),
                                       (int16_t)cardsY, (int16_t)cardW,
                                       (int16_t)cardsH};
    drawTonalInformationCard(panel, ipCard, "IP", address);
    drawTonalInformationCard(panel, fwCard, "Firmware", firmware);
  }

  const wifiselector::Rect action = {
      (int16_t)margin, (int16_t)(panel.height - margin - control),
      (int16_t)wide, (int16_t)control};
  if (touch) {
    drawButton(panel, action, "WiFi presets", true);
  } else {
    const HintLayout hintLayout =
        staticui::hintLayout(panel, action.width, action.height,
                             action.height, "next",
                             hint == nullptr ? "close" : hint);
    drawHint(panel, action, "next", hint == nullptr ? "close" : hint,
             hintLayout);
  }
  maskOutsideRoundPanel(panel);
}

inline void drawIdle(const Panel &panel, const char *const *lines,
                     size_t count) {
  uitheme::background(panel.pixels, panel.width, panel.height);
  uitheme::ticks(panel.pixels, panel.width, panel.height, panel.round);
  if (useClassicText(panel.width, panel.height)) {
    for (size_t i = 0; i < count && i < 4; ++i) {
      monoCentredText(panel, 2 + (int)i * 9, lines[i]);
    }
    return;
  }
  const int margin =
      wifiselector::safeMargin(panel.width, panel.height, panel.round);
  TextStyle body =
      smallTextStyle(panel.width, panel.height, panel.diagonalTenthsMm);
  TextStyle heading =
      largeTextStyle(panel.width, panel.height, panel.diagonalTenthsMm);
  const int lineH = textHeight(body);
  const int contentH =
      count == 0 ? 0 : textHeight(heading) + (int)(count - 1) * lineH;
  const int cardH = contentH + (panel.height >= 240 ? 32 : 18);
  const int maxH = panel.height - 2 * margin;
  const wifiselector::Rect card = {
      (int16_t)margin, (int16_t)((panel.height - (cardH < maxH ? cardH : maxH)) / 2),
      (int16_t)(panel.width - 2 * margin), (int16_t)(cardH < maxH ? cardH : maxH)};
  uitheme::card(panel.pixels, panel.width, panel.height,
                {card.x, card.y, card.width, card.height}, false);
  int y = card.y + (card.height - contentH) / 2;
  for (size_t i = 0; i < count; ++i) {
    const TextStyle style = i == 0 ? heading : body;
    const wifiselector::Rect line = {(int16_t)(card.x + 8), (int16_t)y,
                                     (int16_t)(card.width - 16),
                                     (int16_t)textHeight(style)};
    textInRect(panel, line, lines[i], i == 0,
               i == 0 ? uitheme::CURRENT.primary : uitheme::CURRENT.secondary);
    y += textHeight(style);
  }
  maskOutsideRoundPanel(panel);
}

inline void drawInfoCard(const Panel &panel, const char *status,
                         const char *battery) {
  uitheme::background(panel.pixels, panel.width, panel.height);
  uitheme::ticks(panel.pixels, panel.width, panel.height, panel.round);
  const int margin =
      wifiselector::safeMargin(panel.width, panel.height, panel.round);
  const int cardH = panel.height >= 240 ? 120 : (panel.height >= 170 ? 80 : 56);
  const wifiselector::Rect card = {
      (int16_t)margin, (int16_t)((panel.height - cardH) / 2),
      (int16_t)(panel.width - 2 * margin), (int16_t)cardH};
  uitheme::card(panel.pixels, panel.width, panel.height,
                {card.x, card.y, card.width, card.height}, true);
  const TextStyle title = styleToFit(
      panel.width, panel.height, panel.diagonalTenthsMm, card.width - 16,
      card.height / 2, status, true);
  centredText(panel, card.y + card.height / 5, status, title,
              uitheme::CURRENT.primary);
  if (battery != nullptr && battery[0] != 0) {
    const wifiselector::Rect line = {
        (int16_t)(card.x + 10), (int16_t)(card.y + card.height * 3 / 5),
        (int16_t)(card.width - 20), (int16_t)(card.height / 4)};
    uiicons::battery(panel.pixels, panel.width, panel.height, line.x,
                     line.y + (line.height - 8) / 2, 16, 8,
                     uitheme::CURRENT.teal, 82);
    wifiselector::Rect label = {(int16_t)(line.x + 23), line.y,
                                (int16_t)(line.width - 23), line.height};
    textInRect(panel, label, battery, false, uitheme::CURRENT.primary, false);
  }
  maskOutsideRoundPanel(panel);
}

inline void drawStatusPill(const Panel &panel, const wifiselector::Rect &rect,
                           const char *status, const char *battery) {
  if (useClassicText(panel.width, panel.height)) {
    monoCentredText(panel, rect.y, status);
    monoCentredText(panel, rect.y + 10, battery == nullptr ? "" : battery);
    return;
  }
  uitheme::card(panel.pixels, panel.width, panel.height,
                {rect.x, rect.y, rect.width, rect.height}, true);
  if (panel.width < 170) {
    const TextStyle style =
        smallTextStyle(panel.width, panel.height, panel.diagonalTenthsMm);
    centredText(panel, rect.y + 3, status, style, uitheme::CURRENT.primary);
    if (battery != nullptr && battery[0] != 0) {
      centredText(panel, rect.y + rect.height - textHeight(style) - 3, battery,
                  style, uitheme::CURRENT.primary);
    }
    return;
  }
  const int middle = rect.y + rect.height / 2;
  const TextStyle statusStyle = styleToFit(
      panel.width, panel.height, panel.diagonalTenthsMm, rect.width / 2,
      rect.height - 6, status, false);
  drawText(panel.pixels, panel.width, panel.height, rect.x + 8,
           middle - textVisualCenterOffset(statusStyle), status,
           uitheme::CURRENT.primary, statusStyle);
  if (battery != nullptr && battery[0] != 0) {
    const TextStyle batteryStyle = styleToFit(
        panel.width, panel.height, panel.diagonalTenthsMm,
        rect.width / 2 - 28, rect.height - 6, battery, false);
    const int batteryWidth = textWidth(battery, batteryStyle);
    const int batteryX = rect.x + rect.width - batteryWidth - 8;
    uiicons::battery(panel.pixels, panel.width, panel.height, batteryX - 20,
                     middle - 4, 16, 8, uitheme::CURRENT.teal, 82);
    drawText(panel.pixels, panel.width, panel.height, batteryX,
             middle - textVisualCenterOffset(batteryStyle), battery,
             uitheme::CURRENT.primary, batteryStyle);
  }
}

}  // namespace staticui
