#include "input_button.h"

#include <Arduino.h>
#include <driver/gpio.h>
#include <esp_timer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include "app_state.h"
#include "boot_menu.h"  // also decides whether this image has a menu at all
#if defined(ESPDISP_BOOT_MENU_RUNTIME)
#include "boot_menu_model.h"
#endif
#include "button_press_model.h"
#include "display_power.h"
#include "input_touch.h"
#include "orientation.h"
#include "prefs_store.h"
#include "rotary_encoder_model.h"
#include "ui_screens.h"


// ---- BOOT button (plain input after boot) -------------------------------
// Short press: open or close the WiFi status screen (the signal survey), or on
// the knob carrier toggle the sender's mute (see the rotary encoder section).
// No press changes or saves the backlight; brightness is the app's to set.
// Long press: turn the display 180 (rotation += 2 - a physical button
// reachable from behind a mounted panel stays a two-position toggle even
// where quarter turns exist), or on the status screen open the WiFi selector.
static const uint32_t LONG_PRESS_MS = 600;
// A third tier, well past the long press, for the one action that should not
// be reachable by an accidental long-hold: turning the panel off from a
// button reachable from behind a mounted display. 3s is long enough that
// nobody clears LONG_PRESS_MS's 600ms by accident and keeps holding without
// meaning to - the long-press flip already fired and released the button in
// any ordinary press.
static const uint32_t EXTRA_LONG_PRESS_MS = 3000;
// Two short presses within this window open the WiFi selector. The first
// release opens the status screen at once, so a single press waits for
// nothing; the second replaces it with the selector. Both must be reachable
// MID-STREAM (the status screen's meter walks an actively-failing panel to
// better air, and the selector moves it to a network that works), so neither
// can live on the idle card alone. On the knob carrier the first click is a
// mute toggle and the second toggles it back.
static const uint32_t DOUBLE_PRESS_MS = 800;
static const uint32_t DEBOUNCE_MS = 30;
#if defined(ESPDISP_DOOM_RUNTIME)
// Short enough for the info bar to show unclipped on every Doom panel, the
// 128 px square and the 360 px round included.
static const char DOOM_NEEDS_USB_FLASH_TEXT[] = "Doom: full USB flash";
#endif

struct BootButtonEdge {
  uint32_t atMs;
  bool down;
};

// Room for a bouncing press and release between two loop passes.
static const uint8_t BOOT_EDGE_QUEUE_CAPACITY = 64;
static const uint8_t BOOT_EDGE_QUEUE_MASK = BOOT_EDGE_QUEUE_CAPACITY - 1;
static volatile BootButtonEdge
    bootEdges[BOOT_EDGE_QUEUE_CAPACITY];
static volatile uint8_t bootEdgeRead = 0;
static volatile uint8_t bootEdgeWrite = 0;
static gpio_num_t bootButtonPin = GPIO_NUM_NC;
static portMUX_TYPE bootButtonMux = portMUX_INITIALIZER_UNLOCKED;
static buttonpress::DoublePressTracker shortPressTracker;
#if defined(ESPDISP_BOOT_MENU_RUNTIME)
static bootmenu::TriplePress triplePressTracker;
// Set as the boot menu ends: a BOOT press that went down by then belongs to the
// menu, and its release must not reach the normal press tiers.
static bool swallowPressFromMenu = false;
static uint32_t menuEndedAt = 0;

void swallowBootPressAcrossMenuEnd(uint32_t endedAt) {
  swallowPressFromMenu = true;
  menuEndedAt = endedAt;
}
#endif
// The status screen as it was before the latest single press, and whether
// the double that followed opened the WiFi selector. Presses one and two of a
// triple press are a single and a double, so a triple press that stays normal
// puts both back, and the third press, which lands in that selector, is still
// counted towards the triple rather than moving its highlight.
static bool statusBeforeSingle = false;
static bool selectorOpenedByDouble = false;

static uint32_t buttonClockMs() {
  return (uint32_t)xTaskGetTickCount() * (uint32_t)portTICK_PERIOD_MS;
}

// The level the newest queued entry read, for the sampler below.
static volatile bool lastQueuedDown = false;

// Called with bootButtonMux held.
static void IRAM_ATTR queueBootLevel(uint32_t now, bool down) {
  const uint8_t next = (bootEdgeWrite + 1) & BOOT_EDGE_QUEUE_MASK;
  if (next == bootEdgeRead) {
    // Prefer the newest physical state if an extreme stall fills the queue.
    bootEdgeRead = (bootEdgeRead + 1) & BOOT_EDGE_QUEUE_MASK;
  }
  bootEdges[bootEdgeWrite].atMs = now;
  bootEdges[bootEdgeWrite].down = down;
  bootEdgeWrite = next;
  lastQueuedDown = down;
}

static void IRAM_ATTR onBootButtonEdge() {
  const uint32_t now =
      (uint32_t)xTaskGetTickCountFromISR() * (uint32_t)portTICK_PERIOD_MS;
  const bool down = gpio_get_level(bootButtonPin) == 0;

  // Every edge is queued; handleButton() debounces them. The level is read
  // here, after the edge, and on a bouncing contact can already be the
  // opposite one, so no single edge's level is trusted on its own.
  portENTER_CRITICAL_ISR(&bootButtonMux);
  queueBootLevel(now, down);
  portEXIT_CRITICAL_ISR(&bootButtonMux);
}

// Every BOOT_SAMPLE_MS the pin is read and, if it disagrees with the level the
// newest queue entry read, queued as one more entry. A burst whose very last
// read was wrong is then corrected even when one slow loop pass sees it and
// the next press together, which the quiet-pin read in handleButton() cannot
// do. It never queues while the queue already agrees with the pin, so a
// button left alone costs nothing but the read.
static const uint32_t BOOT_SAMPLE_MS = 10;
static esp_timer_handle_t bootSampler = nullptr;

static void sampleBootButton(void *) {
  const uint32_t now =
      (uint32_t)xTaskGetTickCount() * (uint32_t)portTICK_PERIOD_MS;
  portENTER_CRITICAL(&bootButtonMux);
  const bool down = gpio_get_level(bootButtonPin) == 0;
  if (down != lastQueuedDown) queueBootLevel(now, down);
  portEXIT_CRITICAL(&bootButtonMux);
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

// Debounce: a run of edges each inside DEBOUNCE_MS of the one before is one
// transition, timed by its first edge. It settles once the next edge comes
// DEBOUNCE_MS or more later (taking the level its last edge read) or once the
// pin has been quiet that long (taking the pin's level then). The ISR used to
// drop any edge inside the window instead, keeping whatever level the first
// one read: on the 1.75" round a press whose down edge read as up was lost
// outright, and a release that read as down left the button "held", so a
// press on the status screen opened the WiFi selector 600 ms later, or one
// elsewhere turned the panel off after 3 s. A settled level the button is
// already at (a glitch) changes nothing.
static bool bootRunOpen = false;
static uint32_t bootRunStartAt = 0;
static uint32_t bootRunLastAt = 0;
static bool bootRunDown = false;

static bool takeDebouncedBootEdge(BootButtonEdge &settled) {
  BootButtonEdge raw;
  while (takeBootButtonEdge(raw)) {
    if (bootRunOpen && raw.atMs - bootRunLastAt < DEBOUNCE_MS) {
      bootRunLastAt = raw.atMs;
      bootRunDown = raw.down;
      continue;
    }
    const bool hadRun = bootRunOpen;
    settled.atMs = bootRunStartAt;
    settled.down = bootRunDown;
    bootRunOpen = true;
    bootRunStartAt = raw.atMs;
    bootRunLastAt = raw.atMs;
    bootRunDown = raw.down;
    if (hadRun) return true;
  }
  if (bootRunOpen && buttonClockMs() - bootRunLastAt >= DEBOUNCE_MS) {
    // Read under the queue's lock, and only if no edge has landed since the
    // queue was drained: such an edge belongs to the next run, and the level
    // read after it would merge two presses into one.
    portENTER_CRITICAL(&bootButtonMux);
    const bool quiet = bootEdgeRead == bootEdgeWrite;
    const bool down = gpio_get_level(bootButtonPin) == 0;
    portEXIT_CRITICAL(&bootButtonMux);
    if (!quiet) return takeDebouncedBootEdge(settled);
    bootRunOpen = false;
    settled.atMs = bootRunStartAt;
    settled.down = down;
    return true;
  }
  return false;
}

// ---- Rotary encoder (knob carriers) ------------------------------------
// The knob carrier has no speaker, so its knob drives the sender's volume:
// each completed detent is reported as one knob turn, and its push switch -
// the carrier's BOOT button - reports a short press as one knob press, which
// the sender maps to mute. In the boot menu and the WiFi selector a detent
// moves the highlight like a short press does there. Every other press tier
// applies to the switch unchanged, except that a press during which the knob
// turned performs no press action, because press-and-turn is one gesture.
// Steps are decoded in the ISR (a fast turn can cross several detents inside
// one render pass) and their net is applied from loop().
static gpio_num_t encoderPinA = GPIO_NUM_NC;
static gpio_num_t encoderPinB = GPIO_NUM_NC;
static rotaryencoder::Decoder encoderDecoder;
static volatile int16_t encoderPendingSteps = 0;
static portMUX_TYPE encoderMux = portMUX_INITIALIZER_UNLOCKED;

// When the first detent not yet applied was turned, on the BOOT edges' clock:
// a turn is part of a press only if it came before the press's release.
static volatile uint32_t encoderFirstStepAt = 0;

static void IRAM_ATTR onEncoderEdge() {
  const uint32_t now =
      (uint32_t)xTaskGetTickCountFromISR() * (uint32_t)portTICK_PERIOD_MS;
  const uint8_t state = rotaryencoder::pinState(
      gpio_get_level(encoderPinA) != 0, gpio_get_level(encoderPinB) != 0);
  portENTER_CRITICAL_ISR(&encoderMux);
  const int8_t step = encoderDecoder.update(state);
  if (step != 0 && encoderPendingSteps > -1000 && encoderPendingSteps < 1000) {
    if (encoderPendingSteps == 0) encoderFirstStepAt = now;
    encoderPendingSteps = (int16_t)(encoderPendingSteps + step);
  }
  portEXIT_CRITICAL_ISR(&encoderMux);
}

// Whether the short press is the knob's mute click rather than the status
// screen: on the knob carrier, whose push switch is its BOOT button.
static bool knobDrivesVolume() { return bcfg != nullptr && bcfg->hasEncoder(); }

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
  bootRunOpen = false;
  lastQueuedDown = gpio_get_level(bootButtonPin) == 0;
  portEXIT_CRITICAL(&bootButtonMux);
  attachInterrupt(digitalPinToInterrupt(bcfg->pinBootButton),
                  onBootButtonEdge, CHANGE);
  if (bootSampler == nullptr) {
    esp_timer_create_args_t args = {};
    args.callback = sampleBootButton;
    args.name = "bootsample";
    if (esp_timer_create(&args, &bootSampler) != ESP_OK ||
        esp_timer_start_periodic(bootSampler, BOOT_SAMPLE_MS * 1000) !=
            ESP_OK) {
      Serial.println("button: BOOT sampler unavailable; edges only");
    }
  }
}

bool bootPressSettling() { return bootRunOpen; }

static void setStatusScreen(bool active, const char *cause) {
#if defined(CONFIG_IDF_TARGET_ESP32C3)
  (void)active;
  (void)cause;
  Serial.println("button: wifi status unavailable on compact C3 framebuffer");
  return;
#endif
  surveyActive = active;
  Serial.printf("button: %s -> wifi status %s\n", cause,
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
      case buttonpress::ShortPressEffect::Single:
        statusBeforeSingle = surveyActive;
        selectorOpenedByDouble = false;
        // Mute is a toggle on the sender, so the click is sent at once and a
        // double click's undo sends it again, leaving mute where it was.
        if (knobDrivesVolume()) {
          Serial.println("button: knob click -> mute");
          sendKnobGesture(KnobGesture::Press);
          break;
        }
        setStatusScreen(!surveyActive, "short press");
        break;
      case buttonpress::ShortPressEffect::Undo:
        if (knobDrivesVolume()) {
          Serial.println("button: double click -> mute restored");
          sendKnobGesture(KnobGesture::Press);
        }
        // The status screen is not put back: the selector the double opens
        // next replaces whatever is up, and closing it returns to the status
        // screen either way.
        break;
      case buttonpress::ShortPressEffect::Double:
        if (wifiSelectorActive) break;
        Serial.println("button: double press -> wifi selector");
        openWifiSelector();
        selectorOpenedByDouble = wifiSelectorActive;
        break;
    }
  }
}

#if defined(ESPDISP_BOOT_MENU_RUNTIME)
// The third short press of a triple: reopen the boot-mode menu through a
// one-shot restart, or say why not and put back what presses one and two did.
static void handleTriplePress() {
  const char *refusal = nullptr;
  if (bootMenuOffered(&refusal)) {
    requestBootMenuAndRestart();
    return;
  }
  // Staying normal must undo the single and the double that the triple's
  // first two presses also were. A reboot used to hide them. Closing the
  // selector repaints the status screen under it, so when that is closing too
  // it is marked closed first rather than drawn once and then taken down.
  if (selectorOpenedByDouble && wifiSelectorActive) {
    if (!statusBeforeSingle) surveyActive = false;
    closeWifiSelector();
  }
  selectorOpenedByDouble = false;
  if (!statusBeforeSingle) {
    setStatusScreen(false, "triple press refused, undo");
  } else if (!surveyActive) {
    setStatusScreen(true, "triple press refused, undo");
  }
#if defined(ESPDISP_DOOM_RUNTIME)
  // Doom is the only game, so a menu with nothing but streaming means its
  // WAD is unusable. Only a full USB flash of the bundle writes the WAD; a
  // WiFi update or a rescue image writes the app alone. Refuse here, where
  // the reason can be shown.
  Serial.printf(
      "button: Doom unavailable (%s); staying normal. Only a full USB "
      "flash of the firmware bundle writes the Doom WAD.\n",
      refusal != nullptr ? refusal : "not offered");
  showInfoBar(DOOM_NEEDS_USB_FLASH_TEXT);
#else
  // A game other than Doom refused. Say so rather than swallowing the press.
  Serial.printf("button: no game available (%s); staying normal\n",
                refusal != nullptr ? refusal : "no runtime");
#endif
}
#endif  // ESPDISP_BOOT_MENU_RUNTIME

// A short press in the WiFi selector that a double press just opened may be
// the third press of a triple. Returns whether it was, and so was spent on the
// triple rather than on moving the highlight.
static bool selectorPressCompletesTriple(uint32_t releasedAt) {
#if defined(ESPDISP_BOOT_MENU_RUNTIME)
  if (!wifiSelectorActive || !selectorOpenedByDouble) return false;
  if (!bootMenuMayOfferGames() || !triplePressTracker.record(releasedAt)) {
    // Too late for a triple: from here on the selector's presses are its own.
    selectorOpenedByDouble = false;
    return false;
  }
  handleTriplePress();
  return true;
#else
  (void)releasedAt;
  return false;
#endif
}

static void handleShortRelease(uint32_t releasedAt) {
  // A triple press reopens the boot-mode menu through a one-shot restart
  // rather than tearing down a live stream; a game chosen there gets its own
  // isolated boot. Boards whose image or profile runs no game keep all three
  // presses as ordinary short presses. Its third press normally lands in the
  // WiFi selector the double opened (selectorPressCompletesTriple()); this
  // catches one that did not open.
#if defined(ESPDISP_BOOT_MENU_RUNTIME)
  if (bootMenuMayOfferGames() && triplePressTracker.record(releasedAt)) {
    handleTriplePress();
    return;
  }
#endif  // ESPDISP_BOOT_MENU_RUNTIME
  applyShortPressDecision(
      shortPressTracker.record(releasedAt, DOUBLE_PRESS_MS));
}

// The boot-mode menu and the WiFi selector share one control scheme: a short
// press or a detent moves the highlight and a long hold chooses it.
static bool selectorOwnsInput() {
  return bootMenuActive || wifiSelectorActive;
}

// pressStartedAt is when the press went down, on the tick clock BOOT edges are
// stamped with (bootMenuClockMs()). The boot menu ignores a press that began
// before it opened; the WiFi selector does not need it.
static void moveSelector(int direction, uint32_t pressStartedAt) {
  if (bootMenuActive) {
    moveBootMenu(direction, pressStartedAt, bootmenu::PressSource::Boot);
  } else {
    moveWifiSelector(direction);
  }
}

static void activateSelector(uint32_t pressStartedAt) {
  if (bootMenuActive) {
    activateBootMenu(pressStartedAt);
  } else {
    activateWifiSelector();
  }
}

// A turn this large between two loop passes is a stall, not intent; the
// selector still moves at most this many rows for it, and the sender's volume
// this many steps.
static const int16_t MAX_KNOB_STEPS_PER_PASS = 4;

static void applyEncoderTurn(int16_t steps) {
  const int8_t direction = steps > 0 ? 1 : -1;
  int16_t count = steps > 0 ? steps : (int16_t)-steps;
  if (count > MAX_KNOB_STEPS_PER_PASS) {
    Serial.printf("knob: turn %+d, %d applied (stall)\n", (int)steps,
                  (int)MAX_KNOB_STEPS_PER_PASS);
    count = MAX_KNOB_STEPS_PER_PASS;
  } else {
    Serial.printf("knob: turn %+d\n", (int)steps);
  }
  if (selectorOwnsInput()) {
#if defined(ESPDISP_BOOT_MENU_RUNTIME)
    if (bootMenuActive) {
      // A turn is a gesture, however many detents it crossed: the turn that
      // stops the countdown does not also move the highlight. Whether BOOT or
      // a finger is down now tells it whether a press-and-turn is still going.
      const bool bootDown = bootButtonPin != GPIO_NUM_NC &&
                            gpio_get_level(bootButtonPin) == 0;
      turnBootMenu(direction, count, buttonClockMs(),
                   bootDown || touchPressHeld());
      return;
    }
#endif
    for (int16_t i = 0; i < count; ++i) moveWifiSelector(direction);
    return;
  }
  // A click still inside its double-press window is settled first, so a
  // click, a turn and a click are two mutes rather than a double press.
  shortPressTracker.flush();
  const KnobGesture gesture =
      direction > 0 ? KnobGesture::Clockwise : KnobGesture::Counterclockwise;
  for (int16_t i = 0; i < count; ++i) sendKnobGesture(gesture);
}

// Applies any detents since the last pass; returns whether there were any.
static uint32_t knobTurnedAt = 0;

static bool handleEncoder() {
  if (bcfg == nullptr || !bcfg->hasEncoder()) return false;
  portENTER_CRITICAL(&encoderMux);
  const int16_t steps = encoderPendingSteps;
  encoderPendingSteps = 0;
  knobTurnedAt = encoderFirstStepAt;
  portEXIT_CRITICAL(&encoderMux);
  if (steps == 0) return false;
  applyEncoderTurn(steps);
  return true;
}

// Process queued BOOT edges: a short press opens or closes the WiFi status
// screen (the knob carrier's mute), a double press opens the WiFi selector, a
// completed long press flips the display 180 degrees, and an extra-long press
// toggles manual display off/on. Capturing the edges
// outside the render loop is load-bearing: a full S3 tile pass can otherwise
// begin and end between two polls.
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
      shortPressTracker.flush();
      selectorOpenedByDouble = false;
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

#if defined(ESPDISP_BOOT_MENU_RUNTIME)
  // Held as the menu ended: the rest of this press is the menu's.
  if (swallowPressFromMenu && wasDown) selectorEntryHold = true;
#endif
  BootButtonEdge edge;
  while (takeDebouncedBootEdge(edge)) {
    if (edge.down) {
      if (!wasDown) {
        wasDown = true;
        longFired = false;
        extraLongFired = false;
        turnedWhileDown = false;
        downAt = edge.atMs;
        // The press going down is what stops a counting boot menu, so one
        // still held when the countdown would have run out cannot have its
        // release land on the streaming firmware.
        if (bootMenuActive) {
          bootMenuPressDown(downAt, bootmenu::PressSource::Boot);
        }
#if defined(ESPDISP_BOOT_MENU_RUNTIME)
        // Down before the menu ended, though only seen now (the menu's last
        // pass): the menu's press, so the rest of it is swallowed.
        if (swallowPressFromMenu && (int32_t)(downAt - menuEndedAt) <= 0) {
          selectorEntryHold = true;
        }
#endif
      }
      continue;
    }
    if (!wasDown) continue;
    // Only a turn made before this release: one just after it, while the
    // release still settles, is a turn after the press.
    if (knobTurned && (int32_t)(edge.atMs - knobTurnedAt) > 0) {
      turnedWhileDown = true;
    }
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

    if (selectorOwnsInput()) {
      if (!longFired && heldMs >= LONG_PRESS_MS) {
        longFired = true;
        activateSelector(downAt);
      }
      wasDown = false;
      if (!longFired && heldMs >= DEBOUNCE_MS &&
          !(wifiSelectorActive && selectorPressCompletesTriple(edge.atMs))) {
        moveSelector(1, downAt);
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
    // A status-screen hold seen only now, at its release, opened the selector
    // just above; the press it marked to swallow has already ended.
    selectorEntryHold = false;
    wasDown = false;
  }

#if defined(ESPDISP_BOOT_MENU_RUNTIME)
  // Every edge from before the menu ended has now been seen.
  // Unless a press is still settling: if it went down before the menu ended,
  // it is still the menu's when it settles.
  if (!bootRunOpen) swallowPressFromMenu = false;
#endif
  // Not if the press's release is already in, still settling, from before
  // the turn.
  if (wasDown && knobTurned &&
      !(bootRunOpen && (int32_t)(knobTurnedAt - bootRunStartAt) >= 0)) {
    turnedWhileDown = true;
  }
  if (wasDown && !turnedWhileDown) {
    // Timed to the edge that may be this press's release, still settling,
    // rather than to now: a press let go just short of a threshold is not a
    // hold for the DEBOUNCE_MS its release takes to settle.
    const uint32_t heldMs = (bootRunOpen ? bootRunStartAt : buttonClockMs()) -
                            downAt;
    if (!selectorEntryHold) {
      if (selectorOwnsInput()) {
        if (!longFired && heldMs >= LONG_PRESS_MS) {
          longFired = true;
          // The rest of this hold belongs to the choice it just made. Choosing
          // STREAMING closes the boot menu while BOOT is still down, and the
          // release must not then count as a normal rotate or power press.
          selectorEntryHold = true;
          activateSelector(downAt);
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
  // Not while a press is still settling: its time is its first edge, so the
  // window must not close on it in the meantime.
  if (!bootRunOpen) {
    shortPressTracker.resolve(buttonClockMs(), DOUBLE_PRESS_MS);
  }
}
