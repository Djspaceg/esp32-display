#include "boot_menu.h"

#if defined(ESPDISP_BOOT_MENU_RUNTIME)

#include <Arduino.h>
#include <Preferences.h>
#include <esp_system.h>
#include <string.h>
#include <strings.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

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
// Defines ESPDISP_QUAKE_RUNTIME where this image carries Quake.
#include <quake_mode.h>
#endif

bool bootMenuActive = false;

static bootmenu::Choices bootMenuChoices;
static size_t bootMenuIndex = 0;
static bootmenu::Countdown bootMenuCountdown;
static uint32_t bootMenuShownSeconds = 0;
static const char *bootMenuMessage = nullptr;
// "STARTING <WAD>" for a stored WAD's row.
static char bootMenuStartingMessage[16 + GAME_STORE_NAME_BYTES];

// The game store's WADs the Doom boot would accept, as the preflight listed
// them, and their menu labels.
static_assert(bootmenu::STORED_WAD_MAX == GAME_STORE_MAX_DOOM_WADS,
              "one menu row per WAD the game store can hold");
static char storedWadNames[bootmenu::STORED_WAD_MAX][GAME_STORE_NAME_BYTES + 1];
static char storedWadLabels[bootmenu::STORED_WAD_MAX][GAME_STORE_NAME_BYTES + 1];

// Every menu time is on the FreeRTOS tick clock, because that is what the BOOT
// interrupt stamps edges with. millis() runs ahead of it by however long the
// scheduler took to start, so mixing the two misjudged a press made just after
// the menu opened as one from before it.
static uint32_t menuClockMs() {
  return (uint32_t)xTaskGetTickCount() * (uint32_t)portTICK_PERIOD_MS;
}

static const char *BOOT_MENU_REQUEST_KEY = "bootmenu";
// Read by setup() before the normal boot; see the Doom branch there.
static const char *DOOM_REQUEST_KEY = "doomonce";
// Read with it: which stored WAD to play. Absent for the bundled doom1.wad.
static const char *DOOM_WAD_KEY = "doomwad";
// Read by setup() likewise; see the Quake branch there.
static const char *QUAKE_REQUEST_KEY = "quakeonce";

// Without the WAD check, which reads flash; see bootMenuCapabilities().
static bootmenu::Capabilities builtCapabilities() {
  bootmenu::Capabilities caps;
#if defined(ESPDISP_DOOM_RUNTIME)
  caps.doomBuild = true;
#endif
  caps.doomBoard = board::supportsDoom(boardVariant);
#if defined(ESPDISP_QUAKE_RUNTIME)
  caps.quakeBuild = true;
  caps.quakeBoard = quakeSupportsBoard(boardVariant);
#endif
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
    // The WADs the Mac app put in the game store, each checked as the Doom
    // boot would check it.
    const char *storedProblem = nullptr;
    caps.storedWads = doom_store_wad_preflight(
        storedWadNames, bootmenu::STORED_WAD_MAX, &storedProblem);
    for (size_t i = 0; i < caps.storedWads; ++i) {
      game_store_doom_label(storedWadNames[i], storedWadLabels[i]);
    }
    if (storedProblem != nullptr) {
      Serial.printf("boot menu: a stored WAD not offered (%s)\n",
                    storedProblem);
    }
  }
#endif
#if defined(ESPDISP_QUAKE_RUNTIME)
  if (caps.quakeBuild && caps.quakeBoard) {
    // The Quake boot's own check, read with esp_partition_read(); the pak
    // crosses 16 MiB, so it is never mapped.
    const char *pakProblem = quake_pak_preflight();
    caps.quakePakReady = pakProblem == nullptr;
    if (pakProblem != nullptr) {
      if (refusal != nullptr && *refusal == nullptr) *refusal = pakProblem;
      Serial.printf("boot menu: Quake not offered (%s)\n", pakProblem);
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

// Doom's request with the WAD it is for: the stored WAD's name first, then
// the flag, so a saved flag always has its name; a name with no flag is
// removed, and choosing the bundled WAD removes any name left from before.
static bool saveDoomRequest(const char *storedWad) {
  Preferences prefs;
  if (!prefs.begin("espdisp", false)) return false;
  bool saved;
  if (storedWad != nullptr) {
    saved = prefs.putString(DOOM_WAD_KEY, storedWad) == strlen(storedWad);
  } else {
    saved = !prefs.isKey(DOOM_WAD_KEY) || prefs.remove(DOOM_WAD_KEY);
  }
  saved = saved && prefs.putBool(DOOM_REQUEST_KEY, true) == sizeof(uint8_t);
  if (!saved && storedWad != nullptr) prefs.remove(DOOM_WAD_KEY);
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

// A row's label: the mode's, or a stored WAD's own.
static const char *choiceLabel(size_t index) {
  if (bootMenuChoices.modes[index] == bootmenu::Mode::StoredDoom) {
    return storedWadLabels[bootMenuChoices.storedWad[index]];
  }
  return bootmenu::modeLabel(bootMenuChoices.modes[index]);
}

static void drawBootMenu() {
  // CFGGAME chooses without the menu open; nothing is drawn over streaming.
  if (!bootMenuActive) return;
  const char *labels[bootmenu::MODE_MAX];
  for (size_t i = 0; i < bootMenuChoices.count; ++i) {
    labels[i] = choiceLabel(i);
  }
  bootMenuShownSeconds = bootMenuCountdown.secondsLeft(menuClockMs());
  char title[24];
  if (bootMenuCountdown.counting()) {
    snprintf(title, sizeof(title), "STREAMING IN %lu",
             (unsigned long)bootMenuShownSeconds);
  } else {
    snprintf(title, sizeof(title), "CHOOSE A MODE");
  }
  drawBootMenuScreen(labels, bootMenuChoices.count, bootMenuIndex, title,
                     bootMenuMessage);
}

// The effect of one press, logged and drawn the same way whichever input made
// it. Returns whether it should go on to move or choose.
static bool applyEffect(bootmenu::PressEffect effect, bool wasCounting,
                        const char *what) {
  switch (effect) {
    case bootmenu::PressEffect::Ignore:
      Serial.printf("boot menu: %s ignored (began before the menu)\n", what);
      return false;
    case bootmenu::PressEffect::CancelOnly:
      if (wasCounting) {
        Serial.printf("boot menu: %s cancelled the countdown\n", what);
        drawBootMenu();
      } else {
        // Its press going down already stopped the countdown.
        Serial.printf("boot menu: %s spent on the cancel\n", what);
      }
      return false;
    case bootmenu::PressEffect::Act:
      return true;
  }
  return false;
}

// The one gate every completed press passes, so no input path can skip a rule.
// Returns whether the press should go on to move or choose.
static bool admitPress(uint32_t pressStartedAt, bootmenu::PressSource source,
                       const char *what) {
  const bool wasCounting = bootMenuCountdown.counting();
  return applyEffect(bootMenuCountdown.onPress(pressStartedAt, source),
                     wasCounting, what);
}

static void moveHighlight(int direction) {
  bootMenuIndex = wifiselector::movedIndex(bootMenuIndex,
                                           bootMenuChoices.count, direction);
  bootMenuMessage = nullptr;
  Serial.printf("boot menu: %s highlighted\n", choiceLabel(bootMenuIndex));
  drawBootMenu();
}

uint32_t bootMenuClockMs() { return menuClockMs(); }

void bootMenuPressDown(uint32_t at, bootmenu::PressSource source) {
  if (!bootMenuActive) return;
  switch (bootMenuCountdown.onPressDown(at, source)) {
    case bootmenu::PressEffect::CancelOnly:
      Serial.println("boot menu: press cancelled the countdown");
      drawBootMenu();
      break;
    case bootmenu::PressEffect::Ignore:
    case bootmenu::PressEffect::Act:
      // Judged again when the press completes.
      break;
  }
}

void turnBootMenu(int direction, int steps, uint32_t at, bool pressHeld) {
  if (!bootMenuActive || bootMenuChoices.count == 0 || steps <= 0) return;
  // A turn is a gesture, however many detents and loop passes it spans: the
  // flick that stops the countdown moves nothing, nor does a turn made while
  // the press that stopped it is still down (see Countdown::onTurn).
  const bool wasCounting = bootMenuCountdown.counting();
  const bootmenu::PressEffect effect =
      bootMenuCountdown.onTurn(at, pressHeld);
  if (effect == bootmenu::PressEffect::CancelOnly && wasCounting) {
    Serial.println("boot menu: press cancelled the countdown");
    drawBootMenu();
    return;
  }
  if (!applyEffect(effect, false, "turn")) return;
  for (int i = 0; i < steps; ++i) moveHighlight(direction);
}

void moveBootMenu(int direction, uint32_t pressStartedAt,
                  bootmenu::PressSource source) {
  if (!bootMenuActive || bootMenuChoices.count == 0) return;
  if (!admitPress(pressStartedAt, source, "move")) return;
  moveHighlight(direction);
}

// Leaves the menu; setup() then carries on into the streaming firmware. Does not
// itself start anything.
static void leaveMenuForStreaming(const char *why) {
  Serial.printf("boot menu: streaming (%s)\n", why);
  bootMenuActive = false;
}

static void chooseHighlighted() {
  const bootmenu::Mode mode = bootMenuChoices.modes[bootMenuIndex];
  switch (mode) {
    case bootmenu::Mode::Streaming:
      leaveMenuForStreaming("chosen");
      return;
    case bootmenu::Mode::StoredDoom: {
      // Doom's handoff, naming the WAD; setup() hands the name to the Doom
      // boot (doom_select_store_wad).
      const uint8_t wad = bootMenuChoices.storedWad[bootMenuIndex];
      if (!saveDoomRequest(storedWadNames[wad])) {
        bootMenuMessage = "SAVE FAILED";
        Serial.printf("boot menu: %s request could not be saved\n",
                      storedWadNames[wad]);
        drawBootMenu();
        return;
      }
      snprintf(bootMenuStartingMessage, sizeof(bootMenuStartingMessage),
               "STARTING %s", storedWadLabels[wad]);
      bootMenuMessage = bootMenuStartingMessage;
      Serial.printf("boot menu: %s chosen; restarting into isolated mode\n",
                    storedWadNames[wad]);
      drawBootMenu();
      Serial.flush();
      delay(50);
      ESP.restart();
      return;
    }
    case bootmenu::Mode::Doom:
      // The same one-shot handoff the triple press used to write directly:
      // the next boot consumes it before anything fallible, so a missing WAD
      // or a Doom crash comes back up streaming instead of looping.
      if (!saveDoomRequest(nullptr)) {
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
      // Doom's handoff: a one-shot flag the next boot consumes before
      // anything fallible, then a restart.
      if (!saveOneShotFlag(QUAKE_REQUEST_KEY)) {
        bootMenuMessage = "SAVE FAILED";
        Serial.println("boot menu: Quake request could not be saved");
        drawBootMenu();
        return;
      }
      bootMenuMessage = "STARTING QUAKE";
      Serial.println("boot menu: Quake chosen; restarting into isolated mode");
      drawBootMenu();
      Serial.flush();
      delay(50);
      ESP.restart();
      return;
  }
}

BootMenuSerialChoice chooseBootMenuEntry(const char *label) {
  bootMenuChoices = bootmenu::offeredModes(bootMenuCapabilities(nullptr));
  for (size_t i = 0; i < bootMenuChoices.count; ++i) {
    if (strcasecmp(choiceLabel(i), label) != 0) continue;
    bootMenuIndex = i;
    Serial.printf("boot menu: %s chosen over serial\n", choiceLabel(i));
    // A game restarts from here; only STREAMING, or a request that could
    // not be saved, comes back.
    chooseHighlighted();
    return bootMenuChoices.modes[i] == bootmenu::Mode::Streaming
               ? BootMenuSerialChoice::Streaming
               : BootMenuSerialChoice::SaveFailed;
  }
  Serial.printf("boot menu: no %s row to choose\n", label);
  return BootMenuSerialChoice::NotOffered;
}

void activateBootMenu(uint32_t pressStartedAt) {
  if (!bootMenuActive || bootMenuChoices.count == 0) return;
  if (!admitPress(pressStartedAt, bootmenu::PressSource::Boot, "choose")) {
    return;
  }
  chooseHighlighted();
}

void handleBootMenuTap(int16_t x, int16_t y, uint32_t pressStartedAt) {
  if (!bootMenuActive || bcfg == nullptr) return;
  if (!admitPress(pressStartedAt, bootmenu::PressSource::Touch, "tap")) return;
  const int width = PANEL_GEOMETRY.frameWidth(panelLandscape);
  const int height = PANEL_GEOMETRY.frameHeight(panelLandscape);
  const wifiselector::SelectorLayout layout = wifiselector::selectorLayout(
      width, height, bcfg->panel->roundDisplay, bootMenuChoices.count,
      bootMenuIndex);
  const wifiselector::Hit hit = wifiselector::selectorHitTest(
      layout, bootMenuChoices.count, x, y);
  switch (hit.target) {
    case wifiselector::HitTarget::Previous:
      moveHighlight(-1);
      break;
    case wifiselector::HitTarget::Next:
      moveHighlight(1);
      break;
    case wifiselector::HitTarget::Connect:
      Serial.printf("boot menu: touch start at (%d,%d)\n", x, y);
      chooseHighlighted();
      break;
    case wifiselector::HitTarget::Row:
      bootMenuIndex = hit.rowIndex;
      bootMenuMessage = nullptr;
      Serial.printf("boot menu: touch highlighted %s at (%d,%d)\n",
                    choiceLabel(bootMenuIndex),
                    x, y);
      drawBootMenu();
      break;
    default:
      // The selector's Back corner has no meaning here: the title spans it,
      // and leaving the menu is START on STREAMING.
      Serial.printf("boot menu: touch outside controls at (%d,%d)\n", x, y);
      break;
  }
}

bool runBootMenuIfDue(bool requested) {
  // The menu is a screen; a board without one boots straight on.
  if (!screenPresent()) return false;
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
  // Before the menu exists: a finger already on the glass is read now, so the
  // touch poll inside the menu cannot take it for a press made on the menu.
  primeTouchForBootMenu();
  bootMenuCountdown.start(menuClockMs(), how);
  bootMenuActive = true;
  if (how == bootmenu::Opening::Requested) {
    Serial.printf("boot menu: requested, %u modes, no countdown\n",
                  (unsigned)bootMenuChoices.count);
  } else {
    Serial.printf("boot menu: power-on, %u modes, streaming in %lus\n",
                  (unsigned)bootMenuChoices.count,
                  (unsigned long)bootMenuCountdown.secondsLeft(menuClockMs()));
  }
  drawBootMenu();

  while (bootMenuActive) {
    handleSerialConfig();
    handleButton();
    // Before serviceTouch, so a BOOT hold that chose STREAMING cannot let one
    // normal-path touch pass run here, before WiFi or a sender exists.
    if (!bootMenuActive) break;
    serviceTouch();
    if (!bootMenuActive) break;
    const uint32_t now = menuClockMs();
    bootMenuCountdown.tick(now);
    if (!bootPressSettling() && bootMenuCountdown.expired(now)) {
      // Only an untouched menu expires, so its highlight is still STREAMING.
      leaveMenuForStreaming("countdown ended");
      break;
    }
    if (bootMenuCountdown.secondsLeft(now) != bootMenuShownSeconds) {
      drawBootMenu();
    }
    delay(10);
  }
  bootMenuMessage = nullptr;
  // A BOOT press still down as the menu ends - one that went down while a
  // touch chose, or in the menu's last pass - belongs to the menu. Without
  // this its release would land on the streaming firmware as a rotate or
  // power press.
  swallowBootPressAcrossMenuEnd(menuClockMs());
  applyBacklight();
  return true;
}

#endif  // ESPDISP_BOOT_MENU_RUNTIME
