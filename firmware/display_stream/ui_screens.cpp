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
#include "static_ui_renderer.h"
#include "telemetry.h"
#include "ui_theme.h"
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
static TextStyle infoBarStyle = {TextFamily::Small, 9};

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
static TextStyle infoBarTextStyle(const char *text, int frameWidth,
                                  int frameHeight,
                                  uint16_t diagonalTenthsMm) {
  TextStyle style =
      smallTextStyle(frameWidth, frameHeight, diagonalTenthsMm);
  if (textWidth(text, style) > frameWidth - 8 && style.pixels > 9) {
    style = {TextFamily::Small, 9};
  }
  return style;
}

// Compose the idle card over the (pristine) last frame in bufA and push it.
// Text position moves on every draw to avoid burn-in.
void drawIdleScreen() {
  if (!screenPresent()) return;
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

  staticui::Panel screen = {bufB, w, hgt, bcfg->panel->roundDisplay,
                            bcfg->panelDiagonalTenthsMm()};
  staticui::drawIdle(screen, lines, lineCount);

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

void drawWifiSelectorScreen() {
  if (!screenPresent()) return;
#if defined(CONFIG_IDF_TARGET_ESP32C3)
  return;
#endif
  if (!wifiSelectorActive || bufB == nullptr || panel == nullptr) return;
  if (!waitForDmaIdle(200)) return;
  bootscreen::release();

  const int width = PANEL_GEOMETRY.frameWidth(panelLandscape);
  const int height = PANEL_GEOMETRY.frameHeight(panelLandscape);
  char labelStorage[wifipresets::SLOT_MAX][33] = {};
  const char *labels[wifipresets::SLOT_MAX] = {};
  for (size_t i = 0; i < wifiSelectorCount; ++i) {
    wifiselector::displaySsid(wifiSelectorCredentials[i], labelStorage[i],
                              sizeof(labelStorage[i]));
    labels[i] = labelStorage[i];
  }
  static const char *const EMPTY[] = {"No saved presets"};
  const char *const *visibleLabels = wifiSelectorCount == 0 ? EMPTY : labels;
  const size_t visibleCount = wifiSelectorCount == 0 ? 1 : wifiSelectorCount;
  int activeIndex = -1;
  for (size_t i = 0; i < wifiSelectorCount; ++i) {
    if (wifiSelectorSlots[i] == wifiSelectorActiveSlot) {
      activeIndex = (int)i;
      break;
    }
  }
  staticui::Panel screen = {bufB, width, height, bcfg->panel->roundDisplay,
                            bcfg->panelDiagonalTenthsMm()};
  staticui::drawSelector(screen, "WiFi presets", visibleLabels,
                         wifiSelectorCount == 0 ? nullptr : wifiSelectorSlots,
                         visibleCount, wifiSelectorCount == 0 ? 0 : wifiSelectorIndex,
                         activeIndex,
                         touchAvailable, false, wifiSelectorMessage);

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
  if (!screenPresent()) return;
  // No CONFIG_IDF_TARGET_ESP32C3 guard: a C3 image carries no game, so
  // ESPDISP_BOOT_MENU_RUNTIME is undefined there and this function does not
  // exist to be called.
  if (bufB == nullptr || panel == nullptr || bcfg == nullptr) return;
  if (!waitForDmaIdle(200)) return;
  bootscreen::release();

  const int width = PANEL_GEOMETRY.frameWidth(panelLandscape);
  const int height = PANEL_GEOMETRY.frameHeight(panelLandscape);
  staticui::Panel screen = {bufB, width, height, bcfg->panel->roundDisplay,
                            bcfg->panelDiagonalTenthsMm()};
  staticui::drawSelector(screen, title, labels, nullptr, count, selected, -1,
                         touchAvailable, true, message);

  if (queuePanelBitmap(panel, *bcfg, 0, 0, width, height, bufB) != ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
  }
  driveBrightness(fixedBlLevel != 0 ? fixedBlLevel : BL_SURVEY);
}
#endif  // ESPDISP_BOOT_MENU_RUNTIME

void openWifiSelector() {
  if (!screenPresent()) return;
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
  if (!screenPresent()) return;
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
  char address[24], battery[24];
  if (connected) {
    snprintf(address, sizeof(address), "IP %s",
             WiFi.localIP().toString().c_str());
  } else {
    snprintf(address, sizeof(address), "IP --");
  }
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

  // How to close it, longest wording first. The knob carrier's BOOT is its
  // mute, so it closes nothing there.
  static const char *const BOOT_AND_TAP[] = {
      "Press Boot or tap to close", "Boot or tap to close", "Press to close"};
  static const char *const BOOT_ONLY[] = {"Press Boot to close",
                                          "Press to close"};
  static const char *const TAP_ONLY[] = {"Tap outside to close",
                                         "Tap to close"};
  const bool bootCloses = bcfg->hasBootButton() && !bcfg->hasEncoder();
  const char *hint = "close";
  if (bootCloses && touchAvailable) {
    hint = BOOT_AND_TAP[0];
  } else if (bootCloses) {
    hint = BOOT_ONLY[0];
  } else if (touchAvailable) {
    hint = TAP_ONLY[0];
  }
  char qualityLabel[24];
  snprintf(qualityLabel, sizeof(qualityLabel), "%s",
           surveyQualityWord(connected, rssi));
  if (qualityLabel[0] >= 'a' && qualityLabel[0] <= 'z') {
    qualityLabel[0] = (char)(qualityLabel[0] - 'a' + 'A');
  }
  const char *network = haveSsid ? ssid : (connected ? "Connected" : "No WiFi");
  const char *ipValue = connected ? address + 3 : "--";
  char firmwareValue[16];
  snprintf(firmwareValue, sizeof(firmwareValue), "%s", FW_VERSION);
  staticui::Panel screen = {bufB, w, hgt, bcfg->panel->roundDisplay,
                            bcfg->panelDiagonalTenthsMm()};
  staticui::drawSurvey(screen, network, rssi, qualityLabel, ipValue,
                       firmwareValue, showBattery ? battery : "", hint,
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
  if (!screenPresent()) return;
#if defined(CONFIG_IDF_TARGET_ESP32C3)
  (void)text;
  return;
#endif
  if (bufB == nullptr || panel == nullptr) return;

  const int w = bufLandscape ? PANEL_H : PANEL_W;
  const int hgt = bufLandscape ? PANEL_W : PANEL_H;

  strncpy(infoBarText, text, sizeof(infoBarText) - 1);
  infoBarText[sizeof(infoBarText) - 1] = 0;
  infoBarStyle = infoBarTextStyle(infoBarText, w, hgt,
                                  bcfg->panelDiagonalTenthsMm());
  int lineH = textLineHeight(infoBarStyle) + 10;
  if (w < 170) lineH += textLineHeight(infoBarStyle);
  const int margin =
      wifiselector::safeMargin(w, hgt, bcfg->panel->roundDisplay);
  infoBarY0 = margin;
  infoBarY1 = margin + lineH;
  if (infoBarY1 > hgt) infoBarY1 = hgt;
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
  staticui::Panel screen = {bufB, w, hgt, bcfg->panel->roundDisplay,
                            bcfg->panelDiagonalTenthsMm()};
  staticui::drawStatusPill(
      screen, {0, (int16_t)infoBarY0, (int16_t)w,
               (int16_t)(infoBarY1 - infoBarY0)},
      "Streaming", infoBarText);

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
  if (!screenPresent()) {
    infoBarUntil = 0;
    return;
  }
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
  if (!screenPresent()) return;
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
  staticui::Panel screen = {bufB, w, hgt, bcfg->panel->roundDisplay,
                            bcfg->panelDiagonalTenthsMm()};
  staticui::drawStatusPill(
      screen, {0, (int16_t)infoBarY0, (int16_t)w,
               (int16_t)(infoBarY1 - infoBarY0)},
      "Streaming", infoBarText);
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
  if (!screenPresent()) return;
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
  // Use the same visibly safe round-glass inset as every other UI screen.
  const int margin = wifiselector::safeMargin(
      w, hgt, bcfg->panel->roundDisplay);

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

  TextStyle headlineStyle =
      largeTextStyle(w, hgt, bcfg->panelDiagonalTenthsMm());
  TextStyle percentStyle =
      monoTextStyle(w, hgt, bcfg->panelDiagonalTenthsMm());
  if (textWidth(headline, headlineStyle) > w - 2 * margin &&
      headlineStyle.family != TextFamily::Classic) {
    headlineStyle = smallTextStyle(w, hgt, bcfg->panelDiagonalTenthsMm());
  }
  const int lineH = textLineHeight(headlineStyle);
  const int percentH = textLineHeight(percentStyle);
  const int barH = (w < hgt ? w : hgt) >= 240 ? 12 : 6;
  const int blockH = lineH + percentH + barH + 10;
  int y = (hgt - blockH) / 2;
  if (y < margin) y = margin;

  drawOutlinedText(bufB, w, hgt, (w - textWidth(headline, headlineStyle)) / 2,
                   y, headline, headlineStyle);
  if (pctText[0] != 0) {
    drawOutlinedText(bufB, w, hgt, (w - textWidth(pctText, percentStyle)) / 2,
                     y + lineH, pctText, percentStyle);

    // Progress bar: outlined box, filled left to right. Drawn by hand because
    // the font toolkit has no rectangle primitive and one bar does not justify
    // adding one.
    const int barW = w - 2 * margin;
    const int barX = margin;
    const int barY = y + lineH + percentH + 10;
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
