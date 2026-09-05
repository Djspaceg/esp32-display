#include "input_button.h"

#include <Arduino.h>
#include <Preferences.h>

#include "app_state.h"
#include "display_power.h"
#include "orientation.h"
#include "prefs_store.h"
#include "ui_screens.h"

#if defined(ESPDISP_DOOM_RUNTIME)
#include <doom_mode.h>
#endif


// ---- BOOT button (ESP32-C6 boot strap; plain input after boot) ----------
// Short press: toggle backlight high/low. Long press: turn the display 180
// (rotation += 2 - a physical button reachable from behind a mounted panel
// stays a two-position toggle even where quarter turns exist).
// GPIO9 on both boards - see bcfg, and the note there about Waveshare's pinout
// table claiming GPIO8 for the Touch variant.
// How often loop() checks whether the idle-text template needs saving to
static const uint32_t LONG_PRESS_MS = 600;
// A third tier, well past the long press, for the one action that should not
// be reachable by an accidental long-hold: turning the panel off from a
// button reachable from behind a mounted display. 3s is long enough that
// nobody clears LONG_PRESS_MS's 600ms by accident and keeps holding without
// meaning to - the long-press flip already fired and released the button in
// any ordinary press.
static const uint32_t EXTRA_LONG_PRESS_MS = 3000;
// Two short presses within this window toggle the signal survey - the one
// panel-side action that must be reachable MID-STREAM (its whole job is
// walking an actively-failing panel to better air), so it cannot live on the
// idle card, and all three single-press tiers are taken. The two presses'
// backlight toggles cancel each other, so the double-press costs nothing but
// a blink - which doubles as feedback.
static const uint32_t DOUBLE_PRESS_MS = 600;
static const uint32_t DEBOUNCE_MS = 30;
// Poll the BOOT button: short press toggles backlight, long press (fires
// while still held) flips the display 180 degrees, and an extra-long press
// (also fires while held, past the long-press point) toggles the manual
// display off/on - the same standing instruction CFGPOWER and the network
// Power opcode set, reachable without a Mac or a phone on the same WiFi.
//
// COMPOUNDS RATHER THAN REPLACES the long-press flip: holding past
// EXTRA_LONG_PRESS_MS also toggles power, on top of whatever the long press
// already did at LONG_PRESS_MS, because the long press fires immediately
// while held rather than waiting to see how long the button is down for -
// changing that would need release-time semantics for the rotation action,
// a bigger change than adding a third tier justifies. A user who only wants
// the power toggle and not the flip can press long enough for power and then
// long-press once more to flip back; this is the same tradeoff the two-step
// 180 toggle already makes.
void handleButton() {
  static bool wasDown = false;
  static bool longFired = false;
  static bool extraLongFired = false;
  static uint32_t downAt = 0;

  bool down = digitalRead(bcfg->pinBootButton) == LOW;
  uint32_t now = millis();

  if (down && !wasDown) {
    wasDown = true;
    longFired = false;
    extraLongFired = false;
    downAt = now;
  } else if (down && wasDown && !longFired && now - downAt >= LONG_PRESS_MS) {
    longFired = true;
    // Still a 180 toggle, now expressed as rotation += 2 so it composes with
    // a quarter turn instead of erasing one: a panel mounted at 90 and
    // long-pressed lands at 270, not at 0. The physical button's semantics
    // are unchanged - press it twice and you are back where you started.
    panelRotation = (uint8_t)((panelRotation + 2) & 3);
    madctlDirty = true;
    saveDisplayPrefs();
    Serial.printf("button: long press -> rotation=%u (saved)\n", panelRotation);
  } else if (down && wasDown && longFired && !extraLongFired &&
            now - downAt >= EXTRA_LONG_PRESS_MS) {
    extraLongFired = true;
    // Mirrors the CFGPOWER serial command and ControlOpcode::Power exactly:
    // same flag, same NVS key, same immediate backlight effect.
    panelManuallyOff = !panelManuallyOff;
    saveDisplayPrefs();
    applyBacklight();
    Serial.printf("button: extra-long press -> pwr=%s (saved)\n",
                  panelManuallyOff ? "off" : "on");
  } else if (!down && wasDown) {
    wasDown = false;
    if (!longFired && now - downAt >= DEBOUNCE_MS) {
#if defined(ESPDISP_DOOM_RUNTIME)
      // Enter through a one-shot reboot rather than tearing down a live stream.
      // The next setup consumes the flag before starting networking, allocating
      // normal frame buffers, or subscribing loopTask to the watchdog, giving
      // Doom exclusive panel and PSRAM ownership. Any crash then boots normally
      // because the flag has already been removed.
      if (boardVariant == board::Variant::AmoledCo5300 &&
          doom_check_triple_tap(now, true)) {
        Preferences prefs;
        bool saved = prefs.begin("espdisp", false);
        if (saved) {
          saved = prefs.putBool("doomonce", true) == sizeof(uint8_t);
          prefs.end();
        }
        if (!saved) {
          Serial.println("button: Doom request could not be saved; staying normal");
          return;
        }
        Serial.println("button: Doom requested; rebooting into isolated mode");
        Serial.flush();
        delay(50);
        ESP.restart();
        return;
      }
#endif
      // Normal short-press: toggle backlight high/low
      userBlLevel = blIsHigh() ? BL_LOW : BL_HIGH;
      applyBacklight();
      saveDisplayPrefs();
      Serial.printf("button: short press -> backlight %s (saved)\n",
                    blIsHigh() ? "high" : "low");
      // Two shorts inside DOUBLE_PRESS_MS toggle the signal survey, at any
      // time - streaming included, which is the point: a panel is surveyed
      // BECAUSE its stream is struggling, so the entry cannot depend on the
      // idle card (which never appears while a paused sender's keepalives
      // still flow). The two backlight toggles above cancelled each other.
      static uint32_t lastShortAt = 0;
      if (now - lastShortAt <= DOUBLE_PRESS_MS) {
        lastShortAt = 0;
        surveyActive = !surveyActive;
        Serial.printf("button: double press -> signal survey %s\n",
                      surveyActive ? "on" : "off");
        if (surveyActive) {
          drawSurveyScreen();
        } else {
          applyBacklight();
          if (idleActive) drawIdleScreen();
          // A live stream repaints itself: its pending tiles/bands kept
          // accumulating while the pass was suppressed below.
        }
      } else {
        lastShortAt = now;
      }
    }
  }
}

