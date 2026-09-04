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
#include "telemetry.h"


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

// Compose and push the signal-survey card: the live RSSI, huge, centred,
// at full brightness, so the panel itself is the meter while it is carried
// around the room. Redrawn every 500 ms by loop() while surveyActive.
void drawSurveyScreen() {
  if (dmaInFlight != 0) return;  // skip a beat rather than race bufB
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
  const char *lines[4] = {"SIGNAL", lineRssi, surveyQualityWord(connected, rssi),
                          "2x boot / tap exits"};
  // Per-line scales: the number dominates, everything else is legible-small.
  // Width-capped like infoBarGlyphScale, so the C6's 172 px and the S3's 466
  // both centre without clipping.
  int scales[4];
  for (int i = 0; i < 4; i++) {
    const int wanted = i == 1 ? 8 : 2;
    int fit = (w - 8) / ((int)strlen(lines[i]) * 6);
    scales[i] = fit < wanted ? fit : wanted;
    if (scales[i] < 1) scales[i] = 1;
  }
  int blockH = 0;
  for (int i = 0; i < 4; i++) blockH += 9 * scales[i] + 4;
  int y = (hgt - blockH) / 2;
  if (y < 4) y = 4;

  memset(bufB, 0, FRAME_BYTES);  // black field: maximum contrast, no burn-in
  for (int i = 0; i < 4; i++) {
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
  // Full brightness whatever the idle/sleep state dimmed to: a meter being
  // carried around the room must be readable at arm's length. Exiting the
  // survey restores the state-driven level via applyBacklight().
  driveBrightness(255);
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

