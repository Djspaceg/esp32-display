#include "boot_menu.h"

#if defined(ESPDISP_BOOT_MENU_RUNTIME)

#include <Arduino.h>
#include <Preferences.h>
#include <esp_system.h>

#include "app_state.h"
#include "boot_menu_model.h"
#include "display_power.h"
#include "frame_pipeline.h"
#include "input_button.h"
#include "input_touch.h"
#include "orientation.h"
#include "serial_config.h"
#include "ui_screens.h"
#include "wifi_selector_model.h"

#if defined(ESPDISP_DOOM_RUNTIME)
#include <doom_mode.h>
#endif

bool bootMenuActive = false;

static bootmenu::Choices bootMenuChoices;
static size_t bootMenuIndex = 0;
static bootmenu::Countdown bootMenuCountdown;
static uint32_t bootMenuShownSeconds = 0;
static const char *bootMenuMessage = nullptr;

static const char *BOOT_MENU_REQUEST_KEY = "bootmenu";
// Read by setup() before the normal boot; see the Doom branch there.
static const char *DOOM_REQUEST_KEY = "doomonce";

// Without the WAD check, which reads flash; see bootMenuCapabilities().
static bootmenu::Capabilities builtCapabilities() {
  bootmenu::Capabilities caps;
#if defined(ESPDISP_DOOM_RUNTIME)
  caps.doomBuild = true;
#endif
  caps.doomBoard = board::supportsDoom(boardVariant);
  return caps;
}

static bootmenu::Capabilities bootMenuCapabilities(const char **refusal) {
  bootmenu::Capabilities caps = builtCapabilities();
  if (refusal != nullptr) *refusal = nullptr;
#if defined(ESPDISP_DOOM_RUNTIME)
  if (caps.doomBuild && caps.doomBoard) {
    // The Doom boot's own partition rule and structural check, read through
    // the flash API without mapping the WAD.
    const char *wadProblem = doom_wad_preflight();
    caps.doomWadReady = wadProblem == nullptr;
    if (wadProblem != nullptr) {
      if (refusal != nullptr) *refusal = wadProblem;
      Serial.printf("boot menu: Doom not offered (%s)\n", wadProblem);
    }
  }
#endif
  return caps;
}

static bootmenu::ResetKind bootResetKind() {
  switch (esp_reset_reason()) {
    case ESP_RST_POWERON:
    case ESP_RST_EXT:
    case ESP_RST_USB:
      return bootmenu::ResetKind::User;
    default:
      return bootmenu::ResetKind::Automatic;
  }
}

bool takeBootMenuRequest() {
  Preferences prefs;
  if (!prefs.begin("espdisp", false)) return false;
  bool requested = false;
  if (prefs.isKey(BOOT_MENU_REQUEST_KEY)) {
    requested = prefs.remove(BOOT_MENU_REQUEST_KEY) &&
                !prefs.isKey(BOOT_MENU_REQUEST_KEY);
    if (!requested) {
      Serial.println("boot menu: could not consume request; ignoring it");
    }
  }
  prefs.end();
  return requested;
}

bool bootMenuMayOfferGames() {
  return bootmenu::anyGameBuilt(builtCapabilities());
}

bool bootMenuOffered(const char **refusal) {
  return bootmenu::offeredModes(bootMenuCapabilities(refusal)).count > 1;
}

static bool saveOneShotFlag(const char *key) {
  Preferences prefs;
  if (!prefs.begin("espdisp", false)) return false;
  const bool saved = prefs.putBool(key, true) == sizeof(uint8_t);
  prefs.end();
  return saved;
}

void requestBootMenuAndRestart() {
  if (!saveOneShotFlag(BOOT_MENU_REQUEST_KEY)) {
    Serial.println("button: boot menu request could not be saved; staying");
    return;
  }
  Serial.println("button: boot menu requested; restarting");
  Serial.flush();
  delay(50);
  ESP.restart();
}

static void drawBootMenu() {
  const char *labels[bootmenu::MODE_MAX];
  for (size_t i = 0; i < bootMenuChoices.count; ++i) {
    labels[i] = bootmenu::modeLabel(bootMenuChoices.modes[i]);
  }
  bootMenuShownSeconds = bootMenuCountdown.secondsLeft(millis());
  char title[24];
  snprintf(title, sizeof(title), "STREAMING IN %lu",
           (unsigned long)bootMenuShownSeconds);
  drawBootMenuScreen(labels, bootMenuChoices.count, bootMenuIndex, title,
                     bootMenuMessage);
}

void moveBootMenu(int direction) {
  if (!bootMenuActive || bootMenuChoices.count == 0) return;
  bootMenuCountdown.noteInput(millis());
  bootMenuIndex = wifiselector::movedIndex(bootMenuIndex,
                                           bootMenuChoices.count, direction);
  bootMenuMessage = nullptr;
  Serial.printf("boot menu: %s highlighted\n",
                bootmenu::modeLabel(bootMenuChoices.modes[bootMenuIndex]));
  drawBootMenu();
}

// Leaves the menu; setup() then carries on into the streaming firmware. Does not
// itself start anything.
static void leaveMenuForStreaming(const char *why) {
  Serial.printf("boot menu: streaming (%s)\n", why);
  bootMenuActive = false;
}

void activateBootMenu() {
  if (!bootMenuActive || bootMenuChoices.count == 0) return;
  bootMenuCountdown.noteInput(millis());
  const bootmenu::Mode mode = bootMenuChoices.modes[bootMenuIndex];
  switch (mode) {
    case bootmenu::Mode::Streaming:
      leaveMenuForStreaming("chosen");
      return;
    case bootmenu::Mode::Doom:
      // The same one-shot handoff the triple press used to write directly:
      // the next boot consumes it before anything fallible, so a missing WAD
      // or a Doom crash comes back up streaming instead of looping.
      if (!saveOneShotFlag(DOOM_REQUEST_KEY)) {
        bootMenuMessage = "SAVE FAILED";
        Serial.println("boot menu: Doom request could not be saved");
        drawBootMenu();
        return;
      }
      bootMenuMessage = "STARTING DOOM";
      Serial.println("boot menu: Doom chosen; restarting into isolated mode");
      drawBootMenu();
      Serial.flush();
      delay(50);
      ESP.restart();
      return;
    case bootmenu::Mode::Quake:
      // Never offered until a Quake runtime exists. Its handoff goes here, a
      // one-shot flag and restart like Doom's above.
      leaveMenuForStreaming("no Quake runtime in this image");
      return;
  }
}

void handleBootMenuTap(int16_t x, int16_t y) {
  if (!bootMenuActive || bcfg == nullptr) return;
  bootMenuCountdown.noteInput(millis());
  const int width = PANEL_GEOMETRY.frameWidth(panelLandscape);
  const int height = PANEL_GEOMETRY.frameHeight(panelLandscape);
  const wifiselector::SelectorLayout layout = wifiselector::selectorLayout(
      width, height, bcfg->panel->roundDisplay, bootMenuChoices.count,
      bootMenuIndex);
  const wifiselector::Hit hit = wifiselector::selectorHitTest(
      layout, bootMenuChoices.count, x, y);
  switch (hit.target) {
    case wifiselector::HitTarget::Previous:
      moveBootMenu(-1);
      break;
    case wifiselector::HitTarget::Next:
      moveBootMenu(1);
      break;
    case wifiselector::HitTarget::Connect:
      Serial.printf("boot menu: touch start at (%d,%d)\n", x, y);
      activateBootMenu();
      break;
    case wifiselector::HitTarget::Row:
      bootMenuIndex = hit.rowIndex;
      bootMenuMessage = nullptr;
      Serial.printf("boot menu: touch highlighted %s at (%d,%d)\n",
                    bootmenu::modeLabel(bootMenuChoices.modes[bootMenuIndex]),
                    x, y);
      drawBootMenu();
      break;
    default:
      // The selector's Back corner has no meaning here: the title spans it,
      // and leaving the menu is START on STREAMING or waiting.
      // The countdown still restarted; the run loop redraws its title.
      Serial.printf("boot menu: touch outside controls at (%d,%d)\n", x, y);
      break;
  }
}

bool runBootMenuIfDue(bool requested) {
  const bool hasInput = touchAvailable || bcfg->hasBootButton();
  const bootmenu::ResetKind reset = bootResetKind();
  // Only read a game's data when the menu could open at all, so automatic
  // restarts and boards with no game pay nothing.
  if (bootmenu::opening(reset, requested, bootMenuMayOfferGames() ? 2 : 1,
                        hasInput, panelManuallyOff) ==
      bootmenu::Opening::None) {
    return false;
  }
  bootMenuChoices = bootmenu::offeredModes(bootMenuCapabilities(nullptr));
  const bootmenu::Opening how =
      bootmenu::opening(reset, requested, bootMenuChoices.count, hasInput,
                        panelManuallyOff);
  if (how == bootmenu::Opening::None) {
    if (requested) {
      Serial.println("boot menu: requested but nothing to offer; streaming");
    }
    return false;
  }

  bootMenuIndex = 0;
  bootMenuMessage = nullptr;
  bootMenuCountdown.start(millis(), how);
  bootMenuActive = true;
  Serial.printf("boot menu: %s, %u modes, streaming in %lus\n",
                how == bootmenu::Opening::Requested ? "requested" : "power-on",
                (unsigned)bootMenuChoices.count,
                (unsigned long)bootMenuCountdown.secondsLeft(millis()));
  drawBootMenu();

  while (bootMenuActive) {
    handleSerialConfig();
    handleButton();
    // Before serviceTouch, so a BOOT hold that chose STREAMING cannot let one
    // normal-path touch pass run here, before WiFi or a sender exists.
    if (!bootMenuActive) break;
    serviceTouch();
    if (!bootMenuActive) break;
    const uint32_t now = millis();
    if (bootMenuCountdown.expired(now)) {
      // Whatever is highlighted, the default is what an expiring menu starts.
      leaveMenuForStreaming("countdown ended");
      break;
    }
    if (bootMenuCountdown.secondsLeft(now) != bootMenuShownSeconds) {
      drawBootMenu();
    }
    delay(10);
  }
  bootMenuMessage = nullptr;
  applyBacklight();
  return true;
}

#endif  // ESPDISP_BOOT_MENU_RUNTIME
