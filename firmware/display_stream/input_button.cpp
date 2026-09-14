#include "input_button.h"

#include <Arduino.h>
#include <Preferences.h>
#include <driver/gpio.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include "app_state.h"
#include "button_press_model.h"
#include "display_power.h"
#include "orientation.h"
#include "prefs_store.h"
#include "ui_screens.h"

#if defined(ESPDISP_DOOM_RUNTIME)
#include <doom_mode.h>
#endif


// ---- BOOT button (plain input after boot) -------------------------------
// Short press: toggle backlight high/low. Long press: turn the display 180
// (rotation += 2 - a physical button reachable from behind a mounted panel
// stays a two-position toggle even where quarter turns exist).
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
// idle card, and all three single-press tiers are taken. The first release
// previews its backlight toggle immediately; the second restores the original
// level, so the double-press costs nothing but a blink - which doubles as
// feedback. A lone preview is persisted after this window closes.
static const uint32_t DOUBLE_PRESS_MS = 800;
static const uint32_t DEBOUNCE_MS = 30;

struct BootButtonEdge {
  uint32_t atMs;
  bool down;
};

static const uint8_t BOOT_EDGE_QUEUE_CAPACITY = 16;
static const uint8_t BOOT_EDGE_QUEUE_MASK = BOOT_EDGE_QUEUE_CAPACITY - 1;
static volatile BootButtonEdge
    bootEdges[BOOT_EDGE_QUEUE_CAPACITY];
static volatile uint8_t bootEdgeRead = 0;
static volatile uint8_t bootEdgeWrite = 0;
static volatile uint32_t lastBootEdgeAt = 0;
static volatile bool haveBootEdge = false;
static gpio_num_t bootButtonPin = GPIO_NUM_NC;
static portMUX_TYPE bootButtonMux = portMUX_INITIALIZER_UNLOCKED;
static buttonpress::DoublePressTracker shortPressTracker;
static uint8_t shortPressPreviewOriginalBlLevel = 0;

static uint32_t buttonClockMs() {
  return (uint32_t)xTaskGetTickCount() * (uint32_t)portTICK_PERIOD_MS;
}

static void IRAM_ATTR onBootButtonEdge() {
  const uint32_t now =
      (uint32_t)xTaskGetTickCountFromISR() * (uint32_t)portTICK_PERIOD_MS;
  const bool down = gpio_get_level(bootButtonPin) == 0;

  portENTER_CRITICAL_ISR(&bootButtonMux);
  if (haveBootEdge && now - lastBootEdgeAt < DEBOUNCE_MS) {
    portEXIT_CRITICAL_ISR(&bootButtonMux);
    return;
  }
  haveBootEdge = true;
  lastBootEdgeAt = now;

  const uint8_t next = (bootEdgeWrite + 1) & BOOT_EDGE_QUEUE_MASK;
  if (next == bootEdgeRead) {
    // Prefer the newest physical state if an extreme stall fills the queue.
    bootEdgeRead = (bootEdgeRead + 1) & BOOT_EDGE_QUEUE_MASK;
  }
  bootEdges[bootEdgeWrite].atMs = now;
  bootEdges[bootEdgeWrite].down = down;
  bootEdgeWrite = next;
  portEXIT_CRITICAL_ISR(&bootButtonMux);
}

static bool takeBootButtonEdge(BootButtonEdge &edge) {
  portENTER_CRITICAL(&bootButtonMux);
  if (bootEdgeRead == bootEdgeWrite) {
    portEXIT_CRITICAL(&bootButtonMux);
    return false;
  }
  edge.atMs = bootEdges[bootEdgeRead].atMs;
  edge.down = bootEdges[bootEdgeRead].down;
  bootEdgeRead = (bootEdgeRead + 1) & BOOT_EDGE_QUEUE_MASK;
  portEXIT_CRITICAL(&bootButtonMux);
  return true;
}

void initializeButtonInput() {
  if (bcfg == nullptr || !bcfg->hasBootButton()) return;
  bootButtonPin = (gpio_num_t)bcfg->pinBootButton;
  pinMode(bcfg->pinBootButton, INPUT_PULLUP);
  portENTER_CRITICAL(&bootButtonMux);
  bootEdgeRead = 0;
  bootEdgeWrite = 0;
  haveBootEdge = false;
  portEXIT_CRITICAL(&bootButtonMux);
  attachInterrupt(digitalPinToInterrupt(bcfg->pinBootButton),
                  onBootButtonEdge, CHANGE);
}

static void setSignalSurvey(bool active) {
  surveyActive = active;
  Serial.printf("button: double press -> signal survey %s\n",
                surveyActive ? "on" : "off");
  if (surveyActive) {
    drawSurveyScreen();
  } else {
    applyBacklight();
    if (idleActive) drawIdleScreen();
    // A live stream repaints itself: its pending tiles/bands kept
    // accumulating while the pass was suppressed.
  }
}

static void applyShortPressDecision(
    const buttonpress::ShortPressDecision &decision) {
  for (uint8_t i = 0; i < decision.count; ++i) {
    switch (decision.effects[i]) {
      case buttonpress::ShortPressEffect::Preview:
        shortPressPreviewOriginalBlLevel = userBlLevel;
        userBlLevel = blIsHigh() ? BL_LOW : BL_HIGH;
        applyBacklight();
        Serial.printf("button: short press -> backlight %s (save pending)\n",
                      blIsHigh() ? "high" : "low");
        break;
      case buttonpress::ShortPressEffect::Commit:
        saveDisplayPrefs();
        Serial.printf("button: short press -> backlight %s (saved)\n",
                      blIsHigh() ? "high" : "low");
        break;
      case buttonpress::ShortPressEffect::Revert:
        userBlLevel = shortPressPreviewOriginalBlLevel;
        applyBacklight();
        Serial.printf(
            "button: double press -> backlight %s restored (not saved)\n",
            blIsHigh() ? "high" : "low");
        break;
      case buttonpress::ShortPressEffect::Double:
        setSignalSurvey(!surveyActive);
        break;
    }
  }
}

static void handleShortRelease(uint32_t releasedAt) {
#if defined(ESPDISP_DOOM_RUNTIME)
  // Enter through a one-shot reboot rather than tearing down a live stream.
  // The next setup consumes the flag before starting networking, allocating
  // normal frame buffers, or subscribing loopTask to the watchdog, giving
  // Doom exclusive panel and PSRAM ownership. Any crash then boots normally
  // because the flag has already been removed.
  if (board::supportsDoom(boardVariant) &&
      doom_check_triple_tap(releasedAt, true)) {
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

  const bool previewEnabled = fixedBlLevel == 0;
  if (!previewEnabled) {
    Serial.printf("button: short press ignored (backlight fixed at %u)\n",
                  fixedBlLevel);
  }
  applyShortPressDecision(
      shortPressTracker.record(releasedAt, DOUBLE_PRESS_MS, previewEnabled));
}

// Process queued BOOT edges: short press toggles backlight, long press (fires
// while still held) flips the display 180 degrees, and an extra-long press
// (also fires while held, past the long-press point) toggles the manual
// display off/on. Capturing the edges outside the render loop is load-bearing:
// a full S3 tile pass can otherwise begin and end between two polls.
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
  if (bcfg == nullptr || !bcfg->hasBootButton()) return;

  static bool wasDown = false;
  static bool longFired = false;
  static bool extraLongFired = false;
  static bool selectorEntryHold = false;
  static uint32_t downAt = 0;

  auto fireLongPress = [&]() {
    longFired = true;
    if (surveyActive) {
      selectorEntryHold = true;
      applyShortPressDecision(shortPressTracker.flush());
      openWifiSelector();
      return;
    }
    // Still a 180 toggle, now expressed as rotation += 2 so it composes with
    // a quarter turn instead of erasing one.
    panelRotation = (uint8_t)((panelRotation + 2) & 3);
    madctlDirty = true;
    saveDisplayPrefs();
    Serial.printf("button: long press -> rotation=%u (saved)\n", panelRotation);
  };

  auto fireExtraLongPress = [&]() {
    extraLongFired = true;
    panelManuallyOff = !panelManuallyOff;
    saveDisplayPrefs();
    applyBacklight();
    Serial.printf("button: extra-long press -> pwr=%s (saved)\n",
                  panelManuallyOff ? "off" : "on");
  };

  BootButtonEdge edge;
  while (takeBootButtonEdge(edge)) {
    if (edge.down) {
      if (!wasDown) {
        wasDown = true;
        longFired = false;
        extraLongFired = false;
        downAt = edge.atMs;
      }
      continue;
    }
    if (!wasDown) continue;

    const uint32_t heldMs = edge.atMs - downAt;
    if (selectorEntryHold) {
      wasDown = false;
      longFired = false;
      extraLongFired = false;
      selectorEntryHold = false;
      continue;
    }

    if (wifiSelectorActive) {
      if (!longFired && heldMs >= LONG_PRESS_MS) {
        longFired = true;
        activateWifiSelector();
      }
      wasDown = false;
      if (!longFired && heldMs >= DEBOUNCE_MS) {
        moveWifiSelector(1);
      }
      continue;
    }

    if (!longFired && heldMs >= LONG_PRESS_MS) {
      fireLongPress();
    }
    if (selectorEntryHold) {
      wasDown = false;
      longFired = false;
      extraLongFired = false;
      selectorEntryHold = false;
      continue;
    }
    if (longFired && !extraLongFired && heldMs >= EXTRA_LONG_PRESS_MS) {
      fireExtraLongPress();
    }
    wasDown = false;
    if (!longFired && heldMs >= DEBOUNCE_MS) {
      handleShortRelease(edge.atMs);
    }
  }

  if (wasDown) {
    const uint32_t heldMs = buttonClockMs() - downAt;
    if (!selectorEntryHold) {
      if (wifiSelectorActive) {
        if (!longFired && heldMs >= LONG_PRESS_MS) {
          longFired = true;
          activateWifiSelector();
        }
      } else {
        if (!longFired && heldMs >= LONG_PRESS_MS) {
          fireLongPress();
        }
        if (!selectorEntryHold && longFired && !extraLongFired &&
            heldMs >= EXTRA_LONG_PRESS_MS) {
          fireExtraLongPress();
        }
      }
    }
  }
  applyShortPressDecision(
      shortPressTracker.resolve(buttonClockMs(), DOUBLE_PRESS_MS));
}
