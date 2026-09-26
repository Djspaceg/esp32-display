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
#include "rotary_encoder_model.h"
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

// ---- Rotary encoder (knob carriers) ------------------------------------
// Each completed detent is one step of the controls the BOOT button already
// has: it moves the WiFi selector highlight like a short press does there, and
// otherwise picks the high or low backlight preset the short press toggles
// between. The knob's push switch is the carrier's BOOT button, so every press
// tier above applies to it unchanged - except that a press during which the
// knob turned performs no press action, because press-and-turn is one gesture.
// Steps are decoded in the ISR (a fast turn can cross several detents inside
// one render pass) and their net is applied from loop().
static gpio_num_t encoderPinA = GPIO_NUM_NC;
static gpio_num_t encoderPinB = GPIO_NUM_NC;
static rotaryencoder::Decoder encoderDecoder;
static volatile int16_t encoderPendingSteps = 0;
static portMUX_TYPE encoderMux = portMUX_INITIALIZER_UNLOCKED;

static void IRAM_ATTR onEncoderEdge() {
  const uint8_t state = rotaryencoder::pinState(
      gpio_get_level(encoderPinA) != 0, gpio_get_level(encoderPinB) != 0);
  portENTER_CRITICAL_ISR(&encoderMux);
  const int8_t step = encoderDecoder.update(state);
  if (step != 0 && encoderPendingSteps > -1000 && encoderPendingSteps < 1000) {
    encoderPendingSteps = (int16_t)(encoderPendingSteps + step);
  }
  portEXIT_CRITICAL_ISR(&encoderMux);
}

static void initializeEncoderInput() {
  if (bcfg == nullptr || !bcfg->hasEncoder()) return;
  encoderPinA = (gpio_num_t)bcfg->pinEncoderA;
  encoderPinB = (gpio_num_t)bcfg->pinEncoderB;
  pinMode(bcfg->pinEncoderA, INPUT_PULLUP);
  pinMode(bcfg->pinEncoderB, INPUT_PULLUP);
  portENTER_CRITICAL(&encoderMux);
  encoderDecoder = rotaryencoder::Decoder();
  encoderDecoder.state = rotaryencoder::pinState(
      digitalRead(bcfg->pinEncoderA) != LOW,
      digitalRead(bcfg->pinEncoderB) != LOW);
  encoderPendingSteps = 0;
  portEXIT_CRITICAL(&encoderMux);
  attachInterrupt(digitalPinToInterrupt(bcfg->pinEncoderA), onEncoderEdge,
                  CHANGE);
  attachInterrupt(digitalPinToInterrupt(bcfg->pinEncoderB), onEncoderEdge,
                  CHANGE);
  Serial.printf("knob: encoder on GPIO%d/GPIO%d\n", bcfg->pinEncoderA,
                bcfg->pinEncoderB);
}

void initializeButtonInput() {
  initializeEncoderInput();
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
#if defined(CONFIG_IDF_TARGET_ESP32C3)
  (void)active;
  Serial.println("button: signal survey unavailable on compact C3 framebuffer");
  return;
#endif
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

// A turn this large between two loop passes is a stall, not intent; the
// selector still moves at most this many rows for it.
static const int16_t MAX_SELECTOR_STEPS_PER_PASS = 4;

static void applyEncoderTurn(int16_t steps) {
  Serial.printf("knob: turn %+d\n", (int)steps);
  const int8_t direction = steps > 0 ? 1 : -1;
  if (wifiSelectorActive) {
    const int16_t count = steps > 0 ? steps : (int16_t)-steps;
    for (int16_t i = 0; i < count && i < MAX_SELECTOR_STEPS_PER_PASS; ++i) {
      moveWifiSelector(direction);
    }
    return;
  }
  if (surveyActive) {
    Serial.println("knob: turn ignored during signal survey");
    return;
  }
  if (fixedBlLevel != 0) {
    Serial.printf("knob: turn ignored (backlight fixed at %u)\n",
                  fixedBlLevel);
    return;
  }
  // A short press still waiting out its double-press window commits first,
  // so the knob never lands on a level the pending decision then overrides.
  applyShortPressDecision(shortPressTracker.flush());
  const uint8_t want = direction > 0 ? BL_HIGH : BL_LOW;
  if (userBlLevel == want) return;
  userBlLevel = want;
  applyBacklight();
  saveDisplayPrefs();
  Serial.printf("knob: turn -> backlight %s (saved)\n",
                blIsHigh() ? "high" : "low");
}

// Applies any detents since the last pass; returns whether there were any.
static bool handleEncoder() {
  if (bcfg == nullptr || !bcfg->hasEncoder()) return false;
  portENTER_CRITICAL(&encoderMux);
  const int16_t steps = encoderPendingSteps;
  encoderPendingSteps = 0;
  portEXIT_CRITICAL(&encoderMux);
  if (steps == 0) return false;
  applyEncoderTurn(steps);
  return true;
}

// Process queued BOOT edges: short press toggles backlight, a completed long
// press flips the display 180 degrees, and an extra-long press toggles manual
// display off/on. Capturing the edges outside the render loop is load-bearing:
// a full S3 tile pass can otherwise begin and end between two polls.
// Normal-mode rotation waits for release, so crossing the three-second power
// threshold cannot visibly rotate the picture first. Survey-selector holds
// keep their immediate behavior because they are a separate mode and never
// fall through to the power action.
void handleButton() {
  const bool knobTurned = handleEncoder();
  if (bcfg == nullptr || !bcfg->hasBootButton()) return;

  static bool wasDown = false;
  static bool longFired = false;
  static bool extraLongFired = false;
  static bool selectorEntryHold = false;
  static bool turnedWhileDown = false;
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
        turnedWhileDown = false;
        downAt = edge.atMs;
      }
      continue;
    }
    if (!wasDown) continue;
    if (knobTurned) turnedWhileDown = true;
    if (turnedWhileDown) {
      Serial.println("knob: press released after a turn; no press action");
      wasDown = false;
      longFired = false;
      extraLongFired = false;
      selectorEntryHold = false;
      turnedWhileDown = false;
      continue;
    }

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

    switch (buttonpress::normalAction(
        heldMs, true, DEBOUNCE_MS, LONG_PRESS_MS, EXTRA_LONG_PRESS_MS)) {
      case buttonpress::Action::Power:
        if (!extraLongFired) fireExtraLongPress();
        break;
      case buttonpress::Action::Rotate:
        if (!longFired) fireLongPress();
        break;
      case buttonpress::Action::Short:
        handleShortRelease(edge.atMs);
        break;
      case buttonpress::Action::None:
        break;
    }
    wasDown = false;
  }

  if (wasDown && knobTurned) turnedWhileDown = true;
  if (wasDown && !turnedWhileDown) {
    const uint32_t heldMs = buttonClockMs() - downAt;
    if (!selectorEntryHold) {
      if (wifiSelectorActive) {
        if (!longFired && heldMs >= LONG_PRESS_MS) {
          longFired = true;
          activateWifiSelector();
        }
      } else if (surveyActive) {
        if (!longFired && heldMs >= LONG_PRESS_MS) {
          fireLongPress();
        }
      } else {
        if (!extraLongFired &&
            buttonpress::normalAction(
                heldMs, false, DEBOUNCE_MS, LONG_PRESS_MS,
                EXTRA_LONG_PRESS_MS) == buttonpress::Action::Power) {
          fireExtraLongPress();
        }
      }
    }
  }
  applyShortPressDecision(
      shortPressTracker.resolve(buttonClockMs(), DOUBLE_PRESS_MS));
}
