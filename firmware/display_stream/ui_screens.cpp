#include "ui_screens.h"

#include <Arduino.h>
#include <WiFi.h>

#include "esp_lcd_panel_ops.h"
#include "esp_random.h"

#include <board_power.h>
#include <display_backend.h>

#include "app_state.h"
#include "control_apply.h"
#include "device_protocol.h"
#include "display_power.h"
#include "dma_gate.h"
#include "frame_pipeline.h"
#include "glyph_draw.h"
#include "orientation.h"
#include "panel_state.h"
#include "prefs_store.h"
#include "telemetry.h"
#include "wifi_selector_model.h"


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
                             WiFi.status() == WL_CONNECTED, (int)WiFi.RSSI());
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
        lineBattery, sizeof(lineBattery), lastBattery.externalPower,
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

  dmaMarkQueued();
  if (boarddisplay::drawBitmap(panel, *bcfg, 0, 0, w, hgt, bufB) != ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
    dmaUnmarkFailed();
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
  if (rssi >= -60) return "excellent";
  if (rssi >= -70) return "good";
  if (rssi >= -75) return "fair";
  if (rssi >= -80) return "poor";
  return "unusable";
}

bool wifiSelectorActive = false;
static uint8_t wifiSelectorSlots[wifipresets::SLOT_MAX] = {0};
static wifipresets::Credentials
    wifiSelectorCredentials[wifipresets::SLOT_MAX];
static size_t wifiSelectorCount = 0;
static size_t wifiSelectorIndex = 0;
static uint8_t wifiSelectorActiveSlot = 0;
static const char *wifiSelectorMessage = nullptr;

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
  int margin = 4;
  if (bcfg->panel->roundDisplay) {
    const int diameter = width < height ? width : height;
    margin += (int)(0.1465f * (float)diameter);
  }
  return margin;
}

static void drawCenteredWifiText(int width, int height, int y,
                                 const char *text, int scale) {
  const int textWidth = (int)strlen(text) * 6 * scale;
  drawOutlinedText(bufB, width, height, (width - textWidth) / 2, y, text,
                   scale);
}

void drawWifiSelectorScreen() {
  if (!wifiSelectorActive || bufB == nullptr || panel == nullptr) return;
  waitForDmaIdle(200);

  const int width = PANEL_GEOMETRY.frameWidth(panelLandscape);
  const int height = PANEL_GEOMETRY.frameHeight(panelLandscape);
  const int margin = wifiScreenMargin(width, height);
  const uint16_t background = 0x0006;
  fillRect565(bufB, width, height, 0, 0, width, height, background);

  char title[24];
  if (width < 172 && wifiSelectorCount > 0) {
    snprintf(title, sizeof(title), "WIFI %u/%u",
             (unsigned)(wifiSelectorIndex + 1),
             (unsigned)wifiSelectorCount);
  } else {
    snprintf(title, sizeof(title), "WIFI PRESETS");
  }
  int titleScale = 2;
  if ((int)strlen(title) * 6 * titleScale > width - 2 * margin) {
    titleScale = 1;
  }
  drawCenteredWifiText(width, height, margin, title, titleScale);

  const int titleBottom = margin + 9 * titleScale + 4;
  if (wifiSelectorMessage != nullptr) {
    int messageScale = 2;
    if ((int)strlen(wifiSelectorMessage) * 6 * messageScale >
        width - 2 * margin) {
      messageScale = 1;
    }
    drawCenteredWifiText(width, height, (height - 9 * messageScale) / 2,
                         wifiSelectorMessage, messageScale);
  } else if (wifiSelectorCount == 0) {
    drawCenteredWifiText(width, height, titleBottom + 10, "NO SAVED PRESETS",
                         1);
    drawCenteredWifiText(width, height, titleBottom + 28, "ADD THEM IN APP",
                         1);
  } else {
    const int footerLines = touchAvailable ? 3 : 2;
    const int footerHeight = footerLines * 9;
    const int listAvailable = height - margin - footerHeight - 6 - titleBottom;
    int listScale = width >= 360 ? 2 : 1;
    if ((int)wifiSelectorCount * 9 * listScale > listAvailable) {
      listScale = 1;
    }
    const int lineHeight = 9 * listScale;
    size_t visibleCount =
        listAvailable > 0 ? (size_t)(listAvailable / lineHeight) : 1;
    if (visibleCount == 0) visibleCount = 1;
    if (visibleCount > wifiSelectorCount) visibleCount = wifiSelectorCount;
    const size_t firstVisible = wifiselector::windowStart(
        wifiSelectorIndex, wifiSelectorCount, visibleCount);
    const int listHeight = (int)visibleCount * lineHeight;
    int listY = titleBottom + (listAvailable - listHeight) / 2;
    if (listY < titleBottom) listY = titleBottom;
    const int maxLabelChars =
        (width - 2 * margin - 4) / (6 * listScale);

    for (size_t row = 0; row < visibleCount; ++row) {
      const size_t i = firstVisible + row;
      const bool selected = i == wifiSelectorIndex;
      const bool active = wifiSelectorSlots[i] == wifiSelectorActiveSlot;
      const int rowY = listY + (int)row * lineHeight;
      if (selected) {
        fillRect565(bufB, width, height, margin, rowY - 1,
                    width - 2 * margin, lineHeight, 0x03EF);
      }

      char ssid[33];
      size_t ssidCapacity = sizeof(ssid);
      const int prefixChars = wifiSelectorSlots[i] >= 10 ? 6 : 5;
      if (maxLabelChars > prefixChars &&
          (size_t)(maxLabelChars - prefixChars + 1) < ssidCapacity) {
        ssidCapacity = (size_t)(maxLabelChars - prefixChars + 1);
      }
      wifiselector::displaySsid(wifiSelectorCredentials[i], ssid,
                                ssidCapacity);
      char line[48];
      snprintf(line, sizeof(line), "%c%c%u %s", selected ? '>' : ' ',
               active ? '*' : ' ', (unsigned)wifiSelectorSlots[i], ssid);
      drawOutlinedText(bufB, width, height, margin + 2, rowY, line,
                       listScale);
    }
  }

  int footerY = height - margin - (touchAvailable ? 27 : 18);
  if (footerY < titleBottom) footerY = titleBottom;
  const bool compact = width < 172;
  drawCenteredWifiText(
      width, height, footerY,
      wifiSelectorCount == 0
          ? "HOLD: BACK"
          : (compact ? "BOOT: NEXT" : "BOOT: NEXT / HOLD USE"),
      1);
  if (touchAvailable) {
    drawCenteredWifiText(width, height, footerY + 9,
                         wifiSelectorCount == 0
                             ? "HOLD TOUCH: BACK"
                             : (compact ? "HOLD: USE"
                                        : "TOUCH: SWIPE / TAP USE"),
                         1);
    drawCenteredWifiText(width, height, footerY + 18,
                         wifiSelectorCount == 0 || compact
                             ? ""
                             : "HOLD TOUCH: BACK",
                         1);
  } else {
    drawCenteredWifiText(width, height, footerY + 9,
                         wifiSelectorCount == 0
                             ? ""
                             : (compact ? "HOLD: USE"
                                        : "* = ACTIVE PRESET"),
                         1);
  }

  dmaMarkQueued();
  if (boarddisplay::drawBitmap(panel, *bcfg, 0, 0, width, height, bufB) !=
      ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
    dmaUnmarkFailed();
  }
  driveBrightness(fixedBlLevel != 0 ? fixedBlLevel : 255);
}

void openWifiSelector() {
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
  waitForDmaIdle(200);
  drawSurveyScreen();
}

void moveWifiSelector(int direction) {
  if (!wifiSelectorActive || wifiSelectorCount == 0) return;
  wifiSelectorIndex = wifiselector::movedIndex(
      wifiSelectorIndex, wifiSelectorCount, direction);
  wifiSelectorMessage = nullptr;
  Serial.printf("wifi selector: slot %u highlighted\n",
                (unsigned)wifiSelectorSlots[wifiSelectorIndex]);
  drawWifiSelectorScreen();
}

void activateWifiSelector() {
  if (!wifiSelectorActive) return;
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

// Compose and push the signal-survey card: the live RSSI, huge, centred,
// at full brightness, so the panel itself is the meter while it is carried
// around the room. Redrawn every 500 ms by loop() while surveyActive.
void drawSurveyScreen() {
  if (wifiSelectorActive) return;
  // Entry is user-driven and should be visible immediately. Once surveyActive
  // is set no new stream DMA is queued, so waiting drains only the pass that
  // was already in flight when BOOT was pressed.
  waitForDmaIdle(200);
  if (dmaInFlight != 0) return;
  const int w = bufLandscape ? PANEL_H : PANEL_W;
  const int hgt = bufLandscape ? PANEL_W : PANEL_H;
  const bool connected = WiFi.status() == WL_CONNECTED;
  const int rssi = connected ? (int)WiFi.RSSI() : 0;

  char lineRssi[16];
  if (connected) {
    snprintf(lineRssi, sizeof(lineRssi), "%d", rssi);
  } else {
    snprintf(lineRssi, sizeof(lineRssi), "--");
  }
  const char *lines[5] = {"SIGNAL", lineRssi,
                          surveyQualityWord(connected, rssi),
                          "hold: wifi presets",
                          "2x boot / tap exits"};
  // Per-line scales: the number dominates, everything else is legible-small.
  // Width-capped like infoBarGlyphScale, so the C6's 172 px and the S3's 466
  // both centre without clipping.
  int scales[5];
  for (int i = 0; i < 5; i++) {
    const int wanted = i == 1 ? 8 : 2;
    int fit = (w - 8) / ((int)strlen(lines[i]) * 6);
    scales[i] = fit < wanted ? fit : wanted;
    if (scales[i] < 1) scales[i] = 1;
  }
  int blockH = 0;
  for (int i = 0; i < 5; i++) blockH += 9 * scales[i] + 4;
  int y = (hgt - blockH) / 2;
  if (y < 4) y = 4;

  memset(bufB, 0, FRAME_BYTES);  // black field: maximum contrast, no burn-in
  for (int i = 0; i < 5; i++) {
    const int lineW = (int)strlen(lines[i]) * 6 * scales[i];
    drawOutlinedText(bufB, w, hgt, (w - lineW) / 2, y, lines[i], scales[i]);
    y += 9 * scales[i] + 4;
  }

  dmaMarkQueued();
  if (boarddisplay::drawBitmap(panel, *bcfg, 0, 0, w, hgt, bufB) != ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
    dmaUnmarkFailed();
  }
  lastSurveyDrawAt = millis();
  // Full brightness unless this installation has an explicit fixed level.
  // Exiting the survey restores the state-driven level via applyBacklight().
  driveBrightness(fixedBlLevel != 0 ? fixedBlLevel : 255);
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
    panelstate::formatBatteryLine(text, sizeof(text), lastBattery.externalPower,
                                  lastBattery.present, lastBattery.percentKnown,
                                  lastBattery.percent,
                                  toChargeWord(lastBattery.charge));
  } else if (WiFi.status() == WL_CONNECTED) {
    panelstate::formatWifiLine(text, sizeof(text), true, (int)WiFi.RSSI());
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

  waitForDmaIdle(200);  // bufB may still be feeding a previous transfer
  size_t rowBytes = (size_t)w * 2;
  size_t off = (size_t)infoBarY0 * rowBytes;
  size_t bytes = (size_t)(infoBarY1 - infoBarY0) * rowBytes;
  memcpy(bufB + off, bufA + off, bytes);  // bufA stays pristine for the overlay
  int textX = panelstate::centeredX(
      w, (int)strlen(infoBarText) * 6 * infoBarScale);
  drawOutlinedText(bufB, w, hgt, textX, infoBarY0, infoBarText, infoBarScale);

  dmaMarkQueued();
  if (boarddisplay::drawBitmap(panel, *bcfg, 0, infoBarY0, w, infoBarY1,
                                bufB + off) != ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
    dmaUnmarkFailed();
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
  if (infoBarUntil == 0 || infoBarActive()) return;
  infoBarUntil = 0;
  if (bufB == nullptr || panel == nullptr) return;
  const int w = bufLandscape ? PANEL_H : PANEL_W;
  waitForDmaIdle(200);
  size_t rowBytes = (size_t)w * 2;
  size_t off = (size_t)infoBarY0 * rowBytes;
  size_t bytes = (size_t)(infoBarY1 - infoBarY0) * rowBytes;
  memcpy(bufB + off, bufA + off, bytes);
  dmaMarkQueued();
  if (boarddisplay::drawBitmap(panel, *bcfg, 0, infoBarY0, w, infoBarY1,
                                bufB + off) != ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
    dmaUnmarkFailed();
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
  dmaMarkQueued();
  if (boarddisplay::drawBitmap(panel, *bcfg, 0, infoBarY0, w, infoBarY1,
                                bufB + off) != ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
    dmaUnmarkFailed();
  }
}

// Show OTA progress on the glass.
//
// An update takes tens of seconds during which nothing else is drawn, and a panel
// that simply freezes mid-picture looks broken rather than busy - so it says what
// is happening on the device, not only in the terminal doing the pushing.
//
// Composed in staging (bufB) like fillPanel does: bufA holds the last streamed
// frame and belongs to the network path, which keeps writing into it throughout.
// percent < 0 draws no bar, for the states where there is no meaningful figure.
void drawOtaScreen(const char *headline, int percent) {
  if (bufB == nullptr || panel == nullptr) {
    return;
  }
  waitForDmaIdle(200);  // bufB may still be feeding the previous transfer

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

  dmaMarkQueued();
  if (boarddisplay::drawBitmap(panel, *bcfg, 0, 0, w, hgt, bufB) != ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
    dmaUnmarkFailed();
  }
  // Drain before returning: the caller is about to resume writing flash.
  waitForDmaIdle(500);
}
