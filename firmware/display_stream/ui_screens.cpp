#include "ui_screens.h"

#include <Arduino.h>
#include <WiFi.h>

#include "esp_lcd_panel_ops.h"
#include "esp_random.h"

#include <board_power.h>

#include "app_state.h"
#include "boot_screen.h"
#include "control_apply.h"
#include "device_protocol.h"
#include "display_power.h"
#include "dma_gate.h"
#include "frame_pipeline.h"
#include "glyph_draw.h"
#include "orientation.h"
#include "panel_transfer.h"
#include "panel_state.h"
#include "prefs_store.h"
#include "telemetry.h"
#include "wifi_selector_model.h"
#include "wifi_status_model.h"
#include "wifi_worker.h"


// ---- Quick info bar (a lit panel only) ---------------------------------
// A plain tap - not a swipe, not a long press, and not the tap that woke a
// dimmed panel - shows a status line across the top of the panel for a few
// seconds without touching the backlight or interrupting streaming: this is
// the fast path to "what's the battery doing right now" that does not
// require waiting for the sender to go quiet and the idle card to appear.
//
// Local and additive, the same way the wake-touch is: sendTouchEvent still
// reports the tap to the sender for its own gesture-preset mapping, so a
// preset bound to Tap (e.g. togglePause) is unaffected by this also showing
// a bar - the two are independent reactions to the same gesture.
static const uint32_t INFO_BAR_MS = 2000;
static uint32_t infoBarUntil = 0;
// The row range currently covered by the bar, in the CURRENT frame
// orientation (see infoBarRows()). Recomputed on every show so a tap that
// lands mid-rotation still gets the right band, and reused by the streaming
// path each loop to know which run(s) to redraw the bar onto instead of
// letting a fresh frame silently erase it (see loop()'s per-run draw path).
int infoBarY0 = 0;
int infoBarY1 = 0;
static char infoBarText[40] = {0};
// The glyph scale the bar's text was last drawn at, so redrawInfoBarOverRun
// (which has to reproduce the exact same draw, not just some legible one)
// never disagrees with showInfoBar about how big the text is - both go
// through infoBarGlyphScale() below rather than each picking their own.
static int infoBarScale = 2;

bool infoBarActive() {
  return infoBarUntil != 0 && (int32_t)(millis() - infoBarUntil) < 0;
}

// The largest legible glyph scale for this text on a panel frameWidth px
// wide: prefer 2x (14px glyphs - drawIdleScreen's own "prefer the larger
// text" default), drop to 1x only if the string would not fit at 2x. A bare
// scale=1 bar reads as an illegible smear of pixels at this panel's size,
// which is what the very first hardware pass of this feature showed - this
// mirrors drawIdleScreen's own scale-fallback exactly rather than inventing
// a second policy for "how big should on-device text be".
static int infoBarGlyphScale(const char *text, int frameWidth) {
  int scale = 2;
  if ((int)strlen(text) * 6 * scale > frameWidth - 2 * 4) {
    scale = 1;
  }
  return scale;
}

// Compose the idle card over the (pristine) last frame in bufA and push it.
// Text position moves on every draw to avoid burn-in.
void drawIdleScreen() {
#if defined(CONFIG_IDF_TARGET_ESP32C3)
  return;
#endif
  bootscreen::release();
  int w = bufLandscape ? PANEL_H : PANEL_W;
  int hgt = bufLandscape ? PANEL_W : PANEL_H;

  // Copy the pushed lines out from under the UDP task before formatting.
  deviceproto::IdleTextMessage pushed;
  uint32_t pushedAt;
  portENTER_CRITICAL(&controlMux);
  pushed = idleText;
  pushedAt = idleTextAt;
  portEXIT_CRITICAL(&controlMux);

  char lineIp[24], lineWifi[24], lineAge[32], lineBattery[24];
  const char *lineName = cfgName.c_str();
  snprintf(lineIp, sizeof(lineIp), "%s", WiFi.localIP().toString().c_str());
  panelstate::formatWifiLine(lineWifi, sizeof(lineWifi),
                             WiFi.status() == WL_CONNECTED, wifiworker::rssi());
  // Only for a board with a battery telemetry source and a reading that has
  // not aged out. A stale reading is worse than none (see
  // panelstate::shouldShowBatteryLine).
  const bool showBattery =
      panelstate::shouldShowBatteryLine(bcfg->hasBattery(), batteryReadingCurrent());
  if (showBattery) {
    // The full charging/discharging/standby distinction, not just a terse
    // "chg" flag - see panelstate::formatBatteryLine's doc comment for why
    // this line used to say less than the protocol and the Mac app already
    // know about this reading.
    panelstate::formatBatteryLine(
        lineBattery, sizeof(lineBattery), externalPowerForDisplay(),
        lastBattery.present, lastBattery.percentKnown, lastBattery.percent,
        toChargeWord(lastBattery.charge));
  }

  // Room for the pushed lines, an age line, and the four status lines.
  const char *lines[deviceproto::IDLE_TEXT_MAX_LINES + 5];
  int lineCount = 0;
  if (pushed.lineCount > 0) {
    for (uint8_t i = 0; i < pushed.lineCount; i++) {
      lines[lineCount++] = pushed.lines[i];
    }
    // Say how stale it is. The panel has no clock, so pushed content silently
    // ageing would be worse than not showing it at all.
    const uint32_t ageSeconds = (millis() - pushedAt) / 1000;
    if (ageSeconds < 60) {
      snprintf(lineAge, sizeof(lineAge), "as of %lus ago",
               (unsigned long)ageSeconds);
    } else if (ageSeconds < 3600) {
      snprintf(lineAge, sizeof(lineAge), "as of %lum ago",
               (unsigned long)(ageSeconds / 60));
    } else {
      snprintf(lineAge, sizeof(lineAge), "as of %luh ago",
               (unsigned long)(ageSeconds / 3600));
    }
    lines[lineCount++] = lineAge;
  } else {
    // Nothing pushed, so draw the card the panel can build by itself. The
    // sender expresses exactly these three lines as its default screensaver
    // template, so a user who edits that template replaces them rather than
    // adding to them - appending them unconditionally used to print the name,
    // address, and signal twice for anyone whose template already had them.
    // Battery is appended rather than folded into the template, because only
    // boards with working telemetry sources have one to report.
    lines[lineCount++] = lineName;
    lines[lineCount++] = lineIp;
    lines[lineCount++] = lineWifi;
    if (showBattery) lines[lineCount++] = lineBattery;
  }

  size_t maxLen = 0;
  for (int i = 0; i < lineCount; i++) {
    size_t n = strlen(lines[i]);
    if (n > maxLen) maxLen = n;
  }
  // On round glass the corners of the framebuffer are not on the panel, so
  // the card keeps to the inscribed square: an extra inset of
  // r*(1 - 1/sqrt(2)) per edge, ~14.6% of the diameter. Rectangular panels
  // keep the original 4px margin exactly.
  int margin = 4;
  if (bcfg->panel->roundDisplay) {
    int d = w < hgt ? w : hgt;
    margin += (int)(0.1465f * (float)d);
  }
  // Prefer the larger text, but drop a size rather than run off the panel:
  // pushed lines can be far longer than the three status lines ever are.
  int scale = 2;
  if ((int)maxLen * 6 * scale > w - 2 * margin ||
      lineCount * 9 * scale > hgt - 2 * margin) {
    scale = 1;
  }
  const int lineH = 9 * scale;  // 7px glyph + spacing
  int blockW = (int)maxLen * 6 * scale;
  int blockH = lineCount * lineH;

  // Pseudo-random position within margins; esp_random is hardware RNG.
  int maxX = w - blockW - margin;
  int maxY = hgt - blockH - margin;
  int x = margin +
          (maxX > margin ? (int)(esp_random() % (uint32_t)(maxX - margin + 1)) : 0);
  int y = margin +
          (maxY > margin ? (int)(esp_random() % (uint32_t)(maxY - margin + 1)) : 0);

  memcpy(bufB, bufA, FRAME_BYTES);  // bufA stays pristine for the overlay
  for (int i = 0; i < lineCount; i++) {
    drawOutlinedText(bufB, w, hgt, x, y + i * lineH, lines[i], scale);
  }

  if (queuePanelBitmap(panel, *bcfg, 0, 0, w, hgt, bufB) != ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
  }
  lastIdleDrawAt = millis();
}

// One word for what an RSSI is worth to THIS project's stream, thresholds
// from the measured sessions: -60s carried 430+ datagrams/s (sections
// 17.2/18.1), -74 carried the 25 fps field result (17.17.1), -78 and worse
// was radio-bound every time it was measured (17.17, 18.5). Not a generic
// WiFi bar - the words answer "will the stream work HERE".
static const char *surveyQualityWord(bool connected, int rssi) {
  if (!connected) return "no wifi";
  if (rssi == 0) return "no reading";  // wifiworker: no current sample
  if (rssi >= -60) return "excellent";
  if (rssi >= -70) return "good";
  if (rssi >= -75) return "fair";
  if (rssi >= -80) return "poor";
  return "unusable";
}

// The same thresholds as a colour for the meter: green where the stream
// works, amber where it is marginal, red where it will not, grey with no
// reading at all.
static uint16_t surveyQualityColor(bool connected, int rssi) {
  if (!connected || rssi == 0) return 0x8410;
  if (rssi >= -70) return 0x07E0;
  if (rssi >= -75) return 0xFFE0;
  if (rssi >= -80) return 0xFD20;
  return 0xF800;
}

// text, cut to maxChars with "..." marking the cut, and with anything the
// 5x7 font cannot show (an SSID is bytes, not ASCII) as '?'.
static void fitStatusText(char *out, size_t capacity, const char *text,
                          size_t maxChars) {
  if (capacity == 0) return;
  size_t length = strlen(text);
  size_t copied = length;
  if (copied > maxChars) copied = maxChars;
  if (copied > capacity - 1) copied = capacity - 1;
  for (size_t i = 0; i < copied; ++i) {
    const uint8_t byte = (uint8_t)text[i];
    out[i] = byte >= 0x20 && byte <= 0x7E ? (char)byte : '?';
  }
  if (length > copied && copied >= 3) memcpy(out + copied - 3, "...", 3);
  out[copied] = 0;
}

bool wifiSelectorActive = false;
static uint8_t wifiSelectorSlots[wifipresets::SLOT_MAX] = {0};
static wifipresets::Credentials
    wifiSelectorCredentials[wifipresets::SLOT_MAX];
static size_t wifiSelectorCount = 0;
static size_t wifiSelectorIndex = 0;
static uint8_t wifiSelectorActiveSlot = 0;
static const char *wifiSelectorMessage = nullptr;
// On glass with no touch the selector has no BACK control, and BOOT only moves
// and chooses there, so a double press could otherwise only be left by
// choosing a network, which restarts the board. Left alone this long, it
// closes back to whatever it covered.
static const uint32_t WIFI_SELECTOR_IDLE_MS = 30000;
static uint32_t wifiSelectorInputAt = 0;

static void fillRect565(uint8_t *buffer, int bufferWidth, int bufferHeight,
                        int x, int y, int width, int height, uint16_t color) {
  const int x0 = x < 0 ? 0 : x;
  const int y0 = y < 0 ? 0 : y;
  const int x1 = x + width > bufferWidth ? bufferWidth : x + width;
  const int y1 = y + height > bufferHeight ? bufferHeight : y + height;
  const uint8_t hi = color >> 8;
  const uint8_t lo = color & 0xFF;
  for (int py = y0; py < y1; ++py) {
    for (int px = x0; px < x1; ++px) {
      const size_t offset =
          ((size_t)py * (size_t)bufferWidth + (size_t)px) * 2;
      buffer[offset] = hi;
      buffer[offset + 1] = lo;
    }
  }
}

static int wifiScreenMargin(int width, int height) {
  return wifiselector::safeMargin(width, height, bcfg->panel->roundDisplay);
}

static void drawCenteredWifiText(int width, int height, int y,
                                 const char *text, int scale) {
  const int textWidth = (int)strlen(text) * 6 * scale;
  drawOutlinedText(bufB, width, height, (width - textWidth) / 2, y, text,
                   scale);
}

static int wifiTextScale(const char *text, const wifiselector::Rect &rect,
                         int preferred) {
  int scale = preferred;
  while (scale > 1 &&
         ((int)strlen(text) * 6 * scale > rect.width - 8 ||
          7 * scale > rect.height - 6)) {
    --scale;
  }
  return scale;
}

static void drawCenteredWifiTextInRect(int width, int height,
                                       const wifiselector::Rect &rect,
                                       const char *text, int preferredScale) {
  const int scale = wifiTextScale(text, rect, preferredScale);
  const int textWidth = (int)strlen(text) * 6 * scale;
  const int textHeight = 7 * scale;
  drawOutlinedText(bufB, width, height,
                   rect.x + (rect.width - textWidth) / 2,
                   rect.y + (rect.height - textHeight) / 2, text, scale);
}

static void drawWifiControl(int width, int height,
                            const wifiselector::Rect &rect, const char *label,
                            bool primary, bool enabled = true) {
  const uint16_t border = enabled ? 0xFFFF : 0x4208;
  const uint16_t fill =
      !enabled ? 0x1082 : (primary ? 0x03EF : 0x2104);
  fillRect565(bufB, width, height, rect.x, rect.y, rect.width, rect.height,
              border);
  if (rect.width > 4 && rect.height > 4) {
    fillRect565(bufB, width, height, rect.x + 2, rect.y + 2, rect.width - 4,
                rect.height - 4, fill);
  }
  drawCenteredWifiTextInRect(width, height, rect, label, 2);
}

void drawWifiSelectorScreen() {
#if defined(CONFIG_IDF_TARGET_ESP32C3)
  return;
#endif
  if (!wifiSelectorActive || bufB == nullptr || panel == nullptr) return;
  if (!waitForDmaIdle(200)) return;
  bootscreen::release();

  const int width = PANEL_GEOMETRY.frameWidth(panelLandscape);
  const int height = PANEL_GEOMETRY.frameHeight(panelLandscape);
  const int margin = wifiScreenMargin(width, height);
  const uint16_t background = 0x0006;
  fillRect565(bufB, width, height, 0, 0, width, height, background);

  const wifiselector::SelectorLayout layout = wifiselector::selectorLayout(
      width, height, bcfg->panel->roundDisplay, wifiSelectorCount,
      wifiSelectorIndex);

  char title[24] = "WIFI PRESETS";
  if (wifiSelectorCount > 0) {
    snprintf(title, sizeof(title), "PRESETS %u/%u",
             (unsigned)(wifiSelectorIndex + 1),
             (unsigned)wifiSelectorCount);
  }
  if (touchAvailable) {
    drawWifiControl(width, height, layout.back, "BACK", false);
    drawCenteredWifiTextInRect(width, height, layout.title, title, 2);
  } else {
    const wifiselector::Rect titleRect = {
        layout.back.x, layout.back.y,
        (int16_t)(layout.title.x + layout.title.width - layout.back.x),
        layout.back.height};
    drawCenteredWifiTextInRect(width, height, titleRect, title, 2);
  }

  if (wifiSelectorMessage != nullptr) {
    int messageScale = 2;
    if ((int)strlen(wifiSelectorMessage) * 6 * messageScale >
        width - 2 * margin) {
      messageScale = 1;
    }
    drawCenteredWifiText(width, height, (height - 9 * messageScale) / 2,
                         wifiSelectorMessage, messageScale);
  } else if (wifiSelectorCount == 0) {
    drawCenteredWifiText(width, height, height / 2 - 12, "NO SAVED PRESETS",
                         1);
    drawCenteredWifiText(width, height, height / 2 + 6, "ADD THEM IN APP",
                         1);
  } else {
    const int listScale = width >= 240 ? 2 : 1;
    for (size_t row = 0; row < layout.visibleCount; ++row) {
      const size_t i = layout.firstVisible + row;
      const bool selected = i == wifiSelectorIndex;
      const bool active = wifiSelectorSlots[i] == wifiSelectorActiveSlot;
      const wifiselector::Rect rowRect = layout.rowRect(row);
      fillRect565(bufB, width, height, rowRect.x, rowRect.y, rowRect.width,
                  rowRect.height, active ? 0x07E0 : 0x4208);
      if (rowRect.width > 4 && rowRect.height > 4) {
        fillRect565(bufB, width, height, rowRect.x + 2, rowRect.y + 2,
                    rowRect.width - 4, rowRect.height - 4,
                    selected ? 0x03EF : 0x1082);
      }

      char ssid[33];
      size_t ssidCapacity = sizeof(ssid);
      const int prefixChars = wifiSelectorSlots[i] >= 10 ? 5 : 4;
      const int maxLabelChars =
          (rowRect.width - 12) / (6 * listScale);
      if (maxLabelChars > prefixChars &&
          (size_t)(maxLabelChars - prefixChars + 1) < ssidCapacity) {
        ssidCapacity = (size_t)(maxLabelChars - prefixChars + 1);
      }
      wifiselector::displaySsid(wifiSelectorCredentials[i], ssid,
                                ssidCapacity);
      char line[48];
      snprintf(line, sizeof(line), "%c%u %s", active ? '*' : ' ',
               (unsigned)wifiSelectorSlots[i], ssid);
      const int textY =
          rowRect.y + (rowRect.height - 7 * listScale) / 2;
      drawOutlinedText(bufB, width, height, rowRect.x + 6, textY, line,
                       listScale);
    }
  }

  if (touchAvailable) {
    drawWifiControl(width, height, layout.previous, "UP", false,
                    wifiSelectorCount > 0);
    drawWifiControl(width, height, layout.next, "DOWN", false,
                    wifiSelectorCount > 0);
    drawWifiControl(width, height, layout.connect, "CONNECT", true,
                    wifiSelectorCount > 0);
  } else {
    const wifiselector::Rect nextHint = {
        layout.previous.x, layout.previous.y,
        (int16_t)(layout.next.x + layout.next.width - layout.previous.x),
        layout.previous.height};
    drawWifiControl(width, height, nextHint, "BOOT NEXT", false,
                    wifiSelectorCount > 0);
    drawWifiControl(width, height, layout.connect, "HOLD USE", true,
                    wifiSelectorCount > 0);
  }

  if (queuePanelBitmap(panel, *bcfg, 0, 0, width, height, bufB) != ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
  }
  driveBrightness(fixedBlLevel != 0 ? fixedBlLevel : BL_SURVEY);
}

#if defined(ESPDISP_BOOT_MENU_RUNTIME)
// The boot-mode menu, drawn with the WiFi selector's layout and controls so the
// two read as one design. The default (STREAMING, row 0) carries the green
// border the selector gives the active preset; the title is the countdown
// ("STREAMING IN 5"), or "CHOOSE A MODE" once it has stopped.
void drawBootMenuScreen(const char *const *labels, size_t count,
                        size_t selected, const char *title,
                        const char *message) {
  // No CONFIG_IDF_TARGET_ESP32C3 guard: a C3 image carries no game, so
  // ESPDISP_BOOT_MENU_RUNTIME is undefined there and this function does not
  // exist to be called.
  if (bufB == nullptr || panel == nullptr || bcfg == nullptr) return;
  if (!waitForDmaIdle(200)) return;
  bootscreen::release();

  const int width = PANEL_GEOMETRY.frameWidth(panelLandscape);
  const int height = PANEL_GEOMETRY.frameHeight(panelLandscape);
  const int margin = wifiScreenMargin(width, height);
  fillRect565(bufB, width, height, 0, 0, width, height, 0x0006);

  const wifiselector::SelectorLayout layout = wifiselector::selectorLayout(
      width, height, bcfg->panel->roundDisplay, count, selected);
  const wifiselector::Rect titleRect = {
      layout.back.x, layout.back.y,
      (int16_t)(layout.title.x + layout.title.width - layout.back.x),
      layout.back.height};
  drawCenteredWifiTextInRect(width, height, titleRect, title, 2);

  if (message != nullptr) {
    int messageScale = 2;
    if ((int)strlen(message) * 6 * messageScale > width - 2 * margin) {
      messageScale = 1;
    }
    drawCenteredWifiText(width, height, (height - 9 * messageScale) / 2,
                         message, messageScale);
  } else {
    for (size_t row = 0; row < layout.visibleCount; ++row) {
      const size_t i = layout.firstVisible + row;
      const wifiselector::Rect rowRect = layout.rowRect(row);
      fillRect565(bufB, width, height, rowRect.x, rowRect.y, rowRect.width,
                  rowRect.height, i == 0 ? 0x07E0 : 0x4208);
      if (rowRect.width > 4 && rowRect.height > 4) {
        fillRect565(bufB, width, height, rowRect.x + 2, rowRect.y + 2,
                    rowRect.width - 4, rowRect.height - 4,
                    i == selected ? 0x03EF : 0x1082);
      }
      drawCenteredWifiTextInRect(width, height, rowRect, labels[i], 2);
    }
  }

  if (touchAvailable) {
    drawWifiControl(width, height, layout.previous, "UP", false);
    drawWifiControl(width, height, layout.next, "DOWN", false);
    drawWifiControl(width, height, layout.connect, "START", true);
  } else {
    const wifiselector::Rect nextHint = {
        layout.previous.x, layout.previous.y,
        (int16_t)(layout.next.x + layout.next.width - layout.previous.x),
        layout.previous.height};
    drawWifiControl(width, height, nextHint, "BOOT NEXT", false);
    drawWifiControl(width, height, layout.connect, "HOLD START", true);
  }

  if (queuePanelBitmap(panel, *bcfg, 0, 0, width, height, bufB) != ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
  }
  driveBrightness(fixedBlLevel != 0 ? fixedBlLevel : BL_SURVEY);
}
#endif  // ESPDISP_BOOT_MENU_RUNTIME

void openWifiSelector() {
#if defined(CONFIG_IDF_TARGET_ESP32C3)
  Serial.println("wifi selector unavailable on compact C3 framebuffer");
  return;
#endif
  wifiSelectorCount = 0;
  const uint16_t mask = validWifiPresetMask();
  const size_t orderedCount = wifipresets::orderedSlots(
      mask, wifiSelectorSlots, sizeof(wifiSelectorSlots));
  for (size_t i = 0;
       i < orderedCount && i < sizeof(wifiSelectorSlots); ++i) {
    wifipresets::Credentials credentials;
    if (!loadWifiPreset(wifiSelectorSlots[i], credentials)) continue;
    wifiSelectorSlots[wifiSelectorCount] = wifiSelectorSlots[i];
    wifiSelectorCredentials[wifiSelectorCount] = credentials;
    ++wifiSelectorCount;
  }
  wifiSelectorActiveSlot = activeWifiPresetSlot();
  wifiSelectorIndex = wifiselector::initialIndex(
      wifiSelectorSlots, wifiSelectorCount, wifiSelectorActiveSlot);
  wifiSelectorMessage = nullptr;
  wifiSelectorActive = true;
  wifiSelectorInputAt = millis();
  surveyActive = true;
  infoBarUntil = 0;
  Serial.printf("wifi selector: opened with %u saved presets\n",
                (unsigned)wifiSelectorCount);
  drawWifiSelectorScreen();
}

void closeWifiSelector() {
  if (!wifiSelectorActive) return;
  wifiSelectorActive = false;
  wifiSelectorMessage = nullptr;
  Serial.println("wifi selector: closed");
  if (!waitForDmaIdle(200)) return;
  // The status screen it was opened over, unless that is closing as well.
  if (surveyActive) drawSurveyScreen();
}

void serviceWifiSelectorTimeout() {
  if (!wifiSelectorActive) return;
  const uint32_t now = millis();
  // BOOT is active low. A press held now is input: it restarts the wait.
  const bool pressHeld =
      bcfg->hasBootButton() && digitalRead(bcfg->pinBootButton) == LOW;
  if (pressHeld) wifiSelectorInputAt = now;
  if (!wifiselector::idleTimedOut(now, wifiSelectorInputAt,
                                  WIFI_SELECTOR_IDLE_MS, touchAvailable,
                                  restartAt != 0, pressHeld)) {
    return;
  }
  Serial.println("wifi selector: idle, closing");
  // Back to the stream or the idle card, not the status screen: on the knob
  // carrier, where BOOT is mute, that would be one more screen BOOT cannot
  // leave.
  surveyActive = false;
  closeWifiSelector();
  applyBacklight();
  if (idleActive) drawIdleScreen();
}

void moveWifiSelector(int direction) {
  if (!wifiSelectorActive || wifiSelectorCount == 0) return;
  wifiSelectorIndex = wifiselector::movedIndex(
      wifiSelectorIndex, wifiSelectorCount, direction);
  wifiSelectorMessage = nullptr;
  wifiSelectorInputAt = millis();
  Serial.printf("wifi selector: slot %u highlighted\n",
                (unsigned)wifiSelectorSlots[wifiSelectorIndex]);
  drawWifiSelectorScreen();
}

void handleWifiSelectorTap(int16_t x, int16_t y) {
  if (!wifiSelectorActive || panel == nullptr || bcfg == nullptr) return;
  const int width = PANEL_GEOMETRY.frameWidth(panelLandscape);
  const int height = PANEL_GEOMETRY.frameHeight(panelLandscape);
  const wifiselector::SelectorLayout layout = wifiselector::selectorLayout(
      width, height, bcfg->panel->roundDisplay, wifiSelectorCount,
      wifiSelectorIndex);
  const wifiselector::Hit hit =
      wifiselector::selectorHitTest(layout, wifiSelectorCount, x, y);
  switch (hit.target) {
    case wifiselector::HitTarget::Back:
      Serial.printf("wifi selector: touch back at (%d,%d)\n", x, y);
      closeWifiSelector();
      break;
    case wifiselector::HitTarget::Previous:
      Serial.printf("wifi selector: touch up at (%d,%d)\n", x, y);
      moveWifiSelector(-1);
      break;
    case wifiselector::HitTarget::Next:
      Serial.printf("wifi selector: touch down at (%d,%d)\n", x, y);
      moveWifiSelector(1);
      break;
    case wifiselector::HitTarget::Connect:
      Serial.printf("wifi selector: touch connect at (%d,%d)\n", x, y);
      activateWifiSelector();
      break;
    case wifiselector::HitTarget::Row:
      wifiSelectorIndex = hit.rowIndex;
      wifiSelectorMessage = nullptr;
      Serial.printf("wifi selector: touch highlighted slot %u at (%d,%d)\n",
                    (unsigned)wifiSelectorSlots[wifiSelectorIndex], x, y);
      drawWifiSelectorScreen();
      break;
    default:
      Serial.printf("wifi selector: touch outside controls at (%d,%d)\n", x,
                    y);
      break;
  }
}

void activateWifiSelector() {
  if (!wifiSelectorActive) return;
  wifiSelectorInputAt = millis();
  if (wifiSelectorCount == 0) {
    closeWifiSelector();
    return;
  }
  const uint8_t slot = wifiSelectorSlots[wifiSelectorIndex];
  const WifiStoreStatus status = selectWifiPreset(slot);
  if (status != WifiStoreStatus::Ok) {
    wifiSelectorMessage =
        status == WifiStoreStatus::Unavailable ? "PRESET UNAVAILABLE"
                                               : "SAVE FAILED";
    Serial.printf("wifi selector: slot %u could not be selected\n",
                  (unsigned)slot);
    drawWifiSelectorScreen();
    return;
  }

  wifiSelectorMessage = "SWITCHING WIFI";
  Serial.printf("wifi selector: slot %u selected; restarting\n",
                (unsigned)slot);
  drawWifiSelectorScreen();
  restartAt = millis() + 800;
}

bool handleSurveyTap(int16_t x, int16_t y) {
  if (!surveyActive || wifiSelectorActive || panel == nullptr ||
      bcfg == nullptr) {
    return false;
  }
  const int width = PANEL_GEOMETRY.frameWidth(panelLandscape);
  const int height = PANEL_GEOMETRY.frameHeight(panelLandscape);
  const wifiselector::Rect button = wifiselector::surveyPresetButton(
      width, height, bcfg->panel->roundDisplay);
  if (!button.contains(x, y)) return false;
  Serial.printf("wifi selector: survey button tapped at (%d,%d)\n", x, y);
  openWifiSelector();
  return true;
}

// Compose and push the WiFi status screen (the signal survey): the live RSSI,
// huge, centred, at full brightness, so the panel itself is the meter while it
// is carried around the room, with the network over it and the panel's own
// facts under it. Laid out by wifistatus::layout() for this glass. Redrawn
// every 500 ms by loop() while surveyActive.
void drawSurveyScreen() {
#if defined(CONFIG_IDF_TARGET_ESP32C3)
  return;
#endif
  if (wifiSelectorActive) return;
  // Entry is user-driven and should be visible immediately. Once surveyActive
  // is set no new stream DMA is queued, so waiting drains only the pass that
  // was already in flight when BOOT was pressed.
  if (!waitForDmaIdle(200)) return;
  bootscreen::release();
  const int w = bufLandscape ? PANEL_H : PANEL_W;
  const int hgt = bufLandscape ? PANEL_W : PANEL_H;
  const bool connected = WiFi.status() == WL_CONNECTED;
  const int rssi = connected ? wifiworker::rssi() : 0;

  // From the WiFi worker's cache, never the radio: on P4 WiFi.SSID() is a
  // hosted RPC that can hold this loop for seconds.
  char ssidBytes[33] = {0};
  const bool haveSsid = connected &&
                        wifiworker::ssid(ssidBytes, sizeof(ssidBytes)) &&
                        ssidBytes[0] != 0;
  // Both are bytes, usually UTF-8; shown in the font's closest form.
  char ssid[33];
  wifiselector::panelText((const uint8_t *)ssidBytes, strlen(ssidBytes), ssid,
                          sizeof(ssid));
  char name[33];
  wifiselector::panelText((const uint8_t *)cfgName.c_str(), cfgName.length(),
                          name, sizeof(name));
  char signal[8], quality[24], address[24], firmware[24], battery[24];
  if (connected && rssi != 0) {
    snprintf(signal, sizeof(signal), "%d", rssi);
    snprintf(quality, sizeof(quality), "dBm, %s",
             surveyQualityWord(connected, rssi));
  } else {
    snprintf(signal, sizeof(signal), "--");
    snprintf(quality, sizeof(quality), "%s",
             surveyQualityWord(connected, rssi));
  }
  if (connected) {
    snprintf(address, sizeof(address), "IP %s",
             WiFi.localIP().toString().c_str());
  } else {
    snprintf(address, sizeof(address), "IP --");
  }
  snprintf(firmware, sizeof(firmware), "FW %s", FW_VERSION);
  // Only for a board with a battery and a reading that has not aged out, as
  // on the idle card.
  const bool showBattery = panelstate::shouldShowBatteryLine(
      bcfg->hasBattery(), batteryReadingCurrent());
  if (showBattery) {
    panelstate::formatBatteryLine(
        battery, sizeof(battery), externalPowerForDisplay(),
        lastBattery.present, lastBattery.percentKnown, lastBattery.percent,
        toChargeWord(lastBattery.charge));
  }

  using namespace wifistatus;
  const char *text[ROW_COUNT] = {};
  text[ROW_NETWORK] =
      haveSsid ? ssid : (connected ? "connected" : "not connected");
  text[ROW_SIGNAL] = signal;
  text[ROW_QUALITY] = quality;
  text[ROW_ADDRESS] = address;
  text[ROW_NAME] = name;
  text[ROW_FIRMWARE] = firmware;
  text[ROW_BATTERY] = showBattery ? battery : "";
  // How to close it, longest wording first; the longest that fits its row is
  // drawn, and the layout is sized for the shortest. The knob carrier's BOOT
  // is its mute, so it closes nothing there.
  static const char *const BOOT_AND_TAP[] = {
      "PRESS BOOT OR TAP TO CLOSE", "BOOT OR TAP TO CLOSE", "BOOT/TAP: CLOSE"};
  static const char *const BOOT_ONLY[] = {"PRESS BOOT TO CLOSE",
                                          "BOOT: CLOSE"};
  static const char *const TAP_ONLY[] = {"TAP OUTSIDE TO CLOSE",
                                         "TAP TO CLOSE"};
  const bool bootCloses = bcfg->hasBootButton() && !bcfg->hasEncoder();
  const char *const *hints = nullptr;
  size_t hintCount = 0;
  if (bootCloses && touchAvailable) {
    hints = BOOT_AND_TAP;
    hintCount = sizeof(BOOT_AND_TAP) / sizeof(BOOT_AND_TAP[0]);
  } else if (bootCloses) {
    hints = BOOT_ONLY;
    hintCount = sizeof(BOOT_ONLY) / sizeof(BOOT_ONLY[0]);
  } else if (touchAvailable) {
    hints = TAP_ONLY;
    hintCount = sizeof(TAP_ONLY) / sizeof(TAP_ONLY[0]);
  }
  text[ROW_HINT] = hintCount > 0 ? hints[hintCount - 1] : "";
  size_t lengths[ROW_COUNT];
  for (int row = 0; row < ROW_COUNT; ++row) lengths[row] = strlen(text[row]);
  const bool roundGlass = bcfg->panel->roundDisplay;
  const Layout layout = wifistatus::layout(w, hgt, roundGlass, lengths);
  for (size_t i = 0; i < hintCount; ++i) {
    if (strlen(hints[i]) <= layout.maxChars(ROW_HINT)) {
      text[ROW_HINT] = hints[i];
      break;
    }
  }

  memset(bufB, 0, FRAME_BYTES);  // black field: maximum contrast, no burn-in
  const uint16_t meterColor = surveyQualityColor(connected, rssi);
  for (int row = 0; row < ROW_COUNT; ++row) {
    if (layout.scale[row] == 0) continue;
    char line[48];
    fitStatusText(line, sizeof(line), text[row], layout.maxChars((Row)row));
    const int scale = layout.scale[row];
    const int lineW = (int)strlen(line) * 6 * scale;
    uint16_t color = 0xFFFF;
    if (row == ROW_SIGNAL || row == ROW_QUALITY) color = meterColor;
    if (row == ROW_HINT) color = 0x8410;
    drawText(bufB, w, hgt, layout.centreX - lineW / 2, layout.y[row], line,
             color, scale);
  }
  if (layout.dividerWidth > 0) {
    fillRect565(bufB, w, hgt, layout.dividerX, layout.dividerY,
                layout.dividerWidth, 1, 0x4208);
  }
  const wifiselector::Rect presetsButton =
      wifiselector::surveyPresetButton(w, hgt, roundGlass);
  drawWifiControl(w, hgt, presetsButton,
                  touchAvailable ? "WIFI PRESETS" : "HOLD BOOT: PRESETS",
                  touchAvailable);

  if (queuePanelBitmap(panel, *bcfg, 0, 0, w, hgt, bufB) != ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
  }
  lastSurveyDrawAt = millis();
  // Full brightness unless this installation has an explicit fixed level.
  // Exiting the survey restores the state-driven level via applyBacklight().
  driveBrightness(fixedBlLevel != 0 ? fixedBlLevel : BL_SURVEY);
}

// What the quick info bar says by default: battery on a board that has one
// and a current reading, "usb power" is folded into that by
// formatBatteryLine already, and the WiFi line on a board with no battery to
// report, so a tap there still shows something rather than an empty bar.
//
// A single word ("default") rather than the whole line, because this is the
// one point meant to grow into a user-customisable choice later - the To-do
// item that asked for this bar called it out explicitly - and everything
// downstream of this function already treats the bar's text as an opaque
// string, so swapping in a different default (or a small rotation of them)
// is a change to this function alone.
const char *defaultInfoBarText() {
  static char text[24];
  if (panelstate::shouldShowBatteryLine(bcfg->hasBattery(),
                                       batteryReadingCurrent())) {
    panelstate::formatBatteryLine(text, sizeof(text), externalPowerForDisplay(),
                                  lastBattery.present, lastBattery.percentKnown,
                                  lastBattery.percent,
                                  toChargeWord(lastBattery.charge));
  } else if (WiFi.status() == WL_CONNECTED) {
    panelstate::formatWifiLine(text, sizeof(text), true, wifiworker::rssi());
  } else {
    panelstate::formatWifiLine(text, sizeof(text), false, 0);
  }
  return text;
}

// Show (or refresh) the quick info bar: a centred status line across the top
// of the panel for INFO_BAR_MS, triggered by a plain tap on a lit panel.
//
// Composed the same way drawIdleScreen composes the idle card - onto bufB
// from bufA, so bufA (the network path's always-current framebuffer, see
// the comment on bufA/bufB near their declaration) stays the ground truth
// this bar sits on top of rather than replaces - but only the bar's OWN row
// range is touched, not the whole frame: streaming keeps drawing everywhere
// else uninterrupted, which is the entire point of this being a bar and not
// a card.
void showInfoBar(const char *text) {
#if defined(CONFIG_IDF_TARGET_ESP32C3)
  (void)text;
  return;
#endif
  if (bufB == nullptr || panel == nullptr) return;

  const int w = bufLandscape ? PANEL_H : PANEL_W;
  const int hgt = bufLandscape ? PANEL_W : PANEL_H;

  strncpy(infoBarText, text, sizeof(infoBarText) - 1);
  infoBarText[sizeof(infoBarText) - 1] = 0;
  infoBarScale = infoBarGlyphScale(infoBarText, w);
  const int lineH = 9 * infoBarScale;
  panelstate::infoBarRowRange(w, hgt, bcfg->panel->roundDisplay, lineH, infoBarY0,
                              infoBarY1);
  infoBarUntil = millis() + INFO_BAR_MS;

  if (!waitForDmaIdle(200)) return;
  size_t rowBytes = (size_t)w * 2;
  size_t off = (size_t)infoBarY0 * rowBytes;
  size_t bytes = (size_t)(infoBarY1 - infoBarY0) * rowBytes;
  // Over the boot screen the bar sits on the boot screen, not on bufA's
  // empty frame.
  if (!bootscreen::composeRows(bufB + off, w, infoBarY0, infoBarY1)) {
    memcpy(bufB + off, bufA + off, bytes);  // bufA stays pristine for the overlay
  }
  int textX = panelstate::centeredX(
      w, (int)strlen(infoBarText) * 6 * infoBarScale);
  drawOutlinedText(bufB, w, hgt, textX, infoBarY0, infoBarText, infoBarScale);

  if (queuePanelBitmap(panel, *bcfg, 0, infoBarY0, w, infoBarY1, bufB + off) !=
      ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
  }
}

// Redraw the info bar's row range from bufA (plain, no text) once its
// window has elapsed, so its last-shown text does not linger as a stale
// overlay once the bar itself has expired. bufA is guaranteed current for
// every row (see the comment on bufA's declaration), including the bar's,
// because the network task keeps writing every arriving band into it
// regardless of whether the bar is covering that row on the panel right now
// - which is exactly what makes "just redraw bufA's rows" a correct revert
// rather than a stale snapshot.
void clearInfoBarIfExpired() {
#if defined(CONFIG_IDF_TARGET_ESP32C3)
  infoBarUntil = 0;
  return;
#endif
  if (infoBarUntil == 0 || infoBarActive()) return;
  infoBarUntil = 0;
  if (bufB == nullptr || panel == nullptr) return;
  // The bar's band was copied from bufA, the stream, so over a status card or
  // the survey it would leave that band showing stream pixels. Repaint the
  // screen that is up instead.
  if (surveyActive) {
    drawSurveyScreen();
    return;
  }
  if (idleActive) {
    drawIdleScreen();
    return;
  }
  const int w = bufLandscape ? PANEL_H : PANEL_W;
  if (!waitForDmaIdle(200)) return;
  size_t rowBytes = (size_t)w * 2;
  size_t off = (size_t)infoBarY0 * rowBytes;
  size_t bytes = (size_t)(infoBarY1 - infoBarY0) * rowBytes;
  if (!bootscreen::composeRows(bufB + off, w, infoBarY0, infoBarY1)) {
    memcpy(bufB + off, bufA + off, bytes);
  }
  if (queuePanelBitmap(panel, *bcfg, 0, infoBarY0, w, infoBarY1, bufB + off) !=
      ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
  }
}

// Redraw the bar over its own row range after a streaming run that just
// overwrote part or all of it with fresh frame content. Called from
// loop()'s per-run draw path (see forEachRun's lambda) whenever a run's
// rows overlap the bar's, so a live stream cannot silently erase the bar
// mid-window the way a plain per-band draw_bitmap would.
//
// Self-contained rather than reusing whatever the triggering run left in
// bufB: that run's own row range and the bar's may only partially overlap,
// so bufB is not guaranteed valid across the bar's whole range going in.
// This re-copies bufA -> bufB for exactly the bar's rows first, the same way
// showInfoBar() does, then draws text on top - bufA is always current (see
// its declaration comment), so this is a correct base regardless of which
// run triggered the call.
void redrawInfoBarOverRun() {
#if defined(CONFIG_IDF_TARGET_ESP32C3)
  return;
#endif
  if (bufB == nullptr || panel == nullptr) return;
  const int w = bufLandscape ? PANEL_H : PANEL_W;
  const int hgt = bufLandscape ? PANEL_W : PANEL_H;
  size_t rowBytes = (size_t)w * 2;
  size_t off = (size_t)infoBarY0 * rowBytes;
  size_t bytes = (size_t)(infoBarY1 - infoBarY0) * rowBytes;
  memcpy(bufB + off, bufA + off, bytes);
  int textX = panelstate::centeredX(
      w, (int)strlen(infoBarText) * 6 * infoBarScale);
  drawOutlinedText(bufB, w, hgt, textX, infoBarY0, infoBarText, infoBarScale);
  if (queuePanelBitmap(panel, *bcfg, 0, infoBarY0, w, infoBarY1, bufB + off) !=
      ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
  }
}

// ---- Touch marker (CFGTOUCHLOG only) -------------------------------------
// Drawn through the same panel path as every frame, so it lands under the
// finger exactly when touch and pixels agree about which way is up. Its own
// buffer, filled once and never rewritten, so no screen's staging is disturbed
// and the source outlives any transfer still reading it.
static const int TOUCH_MARKER_PX = 12;
// Aligned like the frame buffers, so a direct SPI draw (C3/C6) need not bounce
// it through a temporary copy.
static uint8_t touchMarkerPixels[TOUCH_MARKER_PX * TOUCH_MARKER_PX * 2]
    __attribute__((aligned(4)));
static bool touchMarkerFilled = false;

void drawTouchMarker(int16_t x, int16_t y) {
  if (panel == nullptr) return;
  if (!touchMarkerFilled) {
    for (size_t i = 0; i < sizeof(touchMarkerPixels); i += 2) {
      touchMarkerPixels[i] = 0xF8;  // magenta, big-endian RGB565 like bufB
      touchMarkerPixels[i + 1] = 0x1F;
    }
    touchMarkerFilled = true;
  }
  const int w = PANEL_GEOMETRY.frameWidth(panelLandscape);
  const int hgt = PANEL_GEOMETRY.frameHeight(panelLandscape);
  if (w < TOUCH_MARKER_PX || hgt < TOUCH_MARKER_PX) return;
  int x0 = x - TOUCH_MARKER_PX / 2;
  int y0 = y - TOUCH_MARKER_PX / 2;
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x0 > w - TOUCH_MARKER_PX) x0 = w - TOUCH_MARKER_PX;
  if (y0 > hgt - TOUCH_MARKER_PX) y0 = hgt - TOUCH_MARKER_PX;
  if (!waitForDmaIdle(200)) return;
  if (queuePanelBitmap(panel, *bcfg, x0, y0, x0 + TOUCH_MARKER_PX,
                       y0 + TOUCH_MARKER_PX, touchMarkerPixels) != ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
  }
}

// Show OTA progress on the glass.
//
// An update takes tens of seconds during which nothing else is drawn, and a panel
// that simply freezes mid-picture looks broken rather than busy - so it says what
// is happening on the device, not only in the terminal doing the pushing.
//
// Composed in staging (bufB) like the other screens: bufA holds the last
// streamed frame and belongs to the network path, which keeps writing into it
// throughout.
// percent < 0 draws no bar, for the states where there is no meaningful figure.
void drawOtaScreen(const char *headline, int percent) {
#if defined(CONFIG_IDF_TARGET_ESP32C3)
  (void)headline;
  (void)percent;
  return;
#endif
  if (bufB == nullptr || panel == nullptr) {
    return;
  }
  if (!waitForDmaIdle(200)) return;
  bootscreen::release();
  // This screen replaces the whole panel; an info bar still counting down
  // must not repaint the idle card or survey over it when it expires.
  infoBarUntil = 0;

  const int w = PANEL_GEOMETRY.frameWidth(panelLandscape);
  const int hgt = PANEL_GEOMETRY.frameHeight(panelLandscape);
  // Round glass hides the framebuffer corners, so keep to the inscribed square
  // exactly as drawIdleScreen does.
  int margin = 4;
  if (bcfg->panel->roundDisplay) {
    int d = w < hgt ? w : hgt;
    margin += (int)(0.1465f * (float)d);
  }

  // Deep blue: unmistakable next to the boot fills (gray waiting for WiFi, teal
  // ready, dark red no WiFi), so the state is readable across a room.
  const uint16_t bg = 0x0008;
  const uint8_t bgHi = bg >> 8, bgLo = bg & 0xFF;
  for (size_t i = 0; i < FRAME_BYTES; i += 2) {
    bufB[i] = bgHi;
    bufB[i + 1] = bgLo;
  }

  char pctText[8];
  pctText[0] = 0;
  if (percent >= 0) {
    snprintf(pctText, sizeof(pctText), "%d%%", percent);
  }

  size_t widest = strlen(headline);
  if (strlen(pctText) > widest) widest = strlen(pctText);
  int scale = 2;
  if ((int)widest * 6 * scale > w - 2 * margin) {
    scale = 1;
  }
  const int lineH = 9 * scale;
  const int barH = 6 * scale;
  const int blockH = lineH * 2 + barH + 3 * scale;
  int y = (hgt - blockH) / 2;
  if (y < margin) y = margin;

  drawOutlinedText(bufB, w, hgt, (w - (int)strlen(headline) * 6 * scale) / 2, y,
                   headline, scale);
  if (pctText[0] != 0) {
    drawOutlinedText(bufB, w, hgt,
                     (w - (int)strlen(pctText) * 6 * scale) / 2, y + lineH,
                     pctText, scale);

    // Progress bar: outlined box, filled left to right. Drawn by hand because
    // the font toolkit has no rectangle primitive and one bar does not justify
    // adding one.
    const int barW = w - 2 * margin;
    const int barX = margin;
    const int barY = y + lineH * 2 + 3 * scale;
    const int filledTo = (barW * percent) / 100;
    for (int px = 0; px < barW; px++) {
      for (int py = 0; py < barH; py++) {
        int sx = barX + px, sy = barY + py;
        if (sx < 0 || sy < 0 || sx >= w || sy >= hgt) continue;
        bool edge = (px == 0 || px == barW - 1 || py == 0 || py == barH - 1);
        uint16_t color = (edge || px < filledTo) ? 0xFFFF : bg;
        size_t off = ((size_t)sy * (size_t)w + (size_t)sx) * 2;
        bufB[off] = color >> 8;
        bufB[off + 1] = color & 0xFF;
      }
    }
  }

  if (queuePanelBitmap(panel, *bcfg, 0, 0, w, hgt, bufB) != ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
  }
  // Drain before returning: the caller is about to resume writing flash.
  waitForDmaIdle(500);
}
