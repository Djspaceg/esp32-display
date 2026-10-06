// Host test for the BOOT triple press and the boot-mode menu it reopens
// (display_stream/input_button.cpp and boot_menu.cpp, compiled here unmodified
// against fakes/doom_entry).
//
// Only a full USB flash of the bundle writes the Doom WAD; WiFi updates and
// rescue images write the app alone. A triple press on a board without a
// usable WAD must therefore stay in the normal firmware, say why on the panel
// and the serial port, and never set a one-shot flag or restart. With a usable
// WAD it restarts into the menu. The menu defaults to streaming, offers Doom
// only with a usable WAD, and enters Doom only through its one-shot flag.
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include <Arduino.h>
#include <Preferences.h>
#include <driver/gpio.h>
#include <esp_system.h>
#include <freertos/task.h>

#include <board_config.h>

#include "../display_stream/app_state.h"
#include "../display_stream/boot_menu.h"
#include "../display_stream/boot_menu_model.h"
#include "../display_stream/input_button.h"
#include "../display_stream/wifi_selector_model.h"

// Reads a sketch source file, for the assertions that pin routing the fakes here
// cannot exercise.
static std::string readFirmwareSource(const char *name) {
  // Relative to this file, not the working directory: run_tests.sh runs the
  // built binary from a temporary directory.
  const std::string testFile = __FILE__;
  const size_t slash = testFile.find_last_of('/');
  const std::string testDir =
      slash == std::string::npos ? "." : testFile.substr(0, slash);
  const std::string path = testDir + "/../display_stream/" + name;
  FILE *file = fopen(path.c_str(), "rb");
  if (file == nullptr) return std::string();
  std::string text;
  char chunk[4096];
  size_t read = 0;
  while ((read = fread(chunk, 1, sizeof(chunk), file)) > 0) {
    text.append(chunk, read);
  }
  fclose(file);
  return text;
}

static int checks = 0;
#define CHECK(cond)                                          \
  do {                                                       \
    checks++;                                                \
    if (!(cond)) {                                           \
      printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      printf("serial was:\n%s", Serial.captured.c_str());   \
      return 1;                                              \
    }                                                        \
  } while (0)

// ---- Fakes for the Arduino and FreeRTOS surface --------------------------
FakeSerial Serial;
FakeEsp ESP;
std::map<std::string, bool> fakeNvsBools;
bool fakeNvsWritesFail = false;
static uint32_t fakeNow = 1000;
static int fakeBootLevel = 1;
static void (*bootIsr)() = nullptr;
board::Variant boardVariant = board::Variant::P4_4C;
const board::Config *bcfg = nullptr;

void delay(uint32_t ms) { fakeNow += ms; }
uint32_t millis() { return fakeNow; }
void pinMode(int, int) {}
int digitalRead(int) { return fakeBootLevel; }
int digitalPinToInterrupt(int pin) { return pin; }
void attachInterrupt(int interrupt, void (*isr)(), int) {
  if (bcfg != nullptr && interrupt == bcfg->pinBootButton) bootIsr = isr;
}
int gpio_get_level(gpio_num_t) { return fakeBootLevel; }
TickType_t xTaskGetTickCount() { return fakeNow; }
TickType_t xTaskGetTickCountFromISR() { return fakeNow; }

// ---- Fakes for the sketch modules input_button.cpp calls -----------------
uint8_t BL_HIGH = 200;
uint8_t BL_LOW = 40;
uint8_t userBlLevel = 200;
uint8_t fixedBlLevel = 0;
bool surveyActive = false;
bool idleActive = false;
bool wifiSelectorActive = false;
uint8_t panelRotation = 0;
bool madctlDirty = false;
bool panelManuallyOff = false;
bool touchAvailable = false;
bool panelLandscape = false;
bandproto::Geometry PANEL_GEOMETRY = {0, 0};
static esp_reset_reason_t fakeResetReason = ESP_RST_POWERON;
esp_reset_reason_t esp_reset_reason(void) { return fakeResetReason; }

bool blIsHigh() { return userBlLevel == BL_HIGH; }
void applyBacklight() {}
static int displayPrefSaves = 0;
void saveDisplayPrefs() { displayPrefSaves++; }
void drawSurveyScreen() {}
void drawIdleScreen() {}
void openWifiSelector() {}
void moveWifiSelector(int) {}
void activateWifiSelector() {}

static std::string infoBarShown;
void showInfoBar(const char *text) { infoBarShown = text; }

// The boot menu's screen, recorded rather than drawn.
static int menuDraws = 0;
static size_t menuCount = 0;
static size_t menuSelected = 0;
static std::string menuLabels;
static std::string menuTitle;
static std::string menuMessage;
void drawBootMenuScreen(const char *const *labels, size_t count,
                        size_t selected, const char *title,
                        const char *message) {
  menuDraws++;
  menuCount = count;
  menuSelected = selected;
  menuLabels.clear();
  for (size_t i = 0; i < count; ++i) {
    menuLabels += labels[i];
    menuLabels += i + 1 < count ? "," : "";
  }
  menuTitle = title;
  menuMessage = message == nullptr ? "" : message;
}

// Input scripted against the fake clock and delivered from inside the menu's
// own loop: BOOT edges through the real ISR, taps through the real handler.
struct ScriptedInput {
  uint32_t at;
  enum Kind { BootDown, BootUp, Tap } kind;
  int16_t x;
  int16_t y;
};
static std::vector<ScriptedInput> script;
static void bootIsrAt(bool down);
static void deliverScript(ScriptedInput::Kind wanted) {
  while (!script.empty() && script.front().at <= fakeNow) {
    const ScriptedInput next = script.front();
    if ((next.kind == ScriptedInput::Tap) != (wanted == ScriptedInput::Tap)) {
      return;
    }
    script.erase(script.begin());
    if (next.kind == ScriptedInput::Tap) {
      handleBootMenuTap(next.x, next.y);
    } else {
      bootIsrAt(next.kind == ScriptedInput::BootDown);
    }
  }
}
void handleSerialConfig() { deliverScript(ScriptedInput::BootDown); }
void serviceTouch() { deliverScript(ScriptedInput::Tap); }

// ---- Fakes for the Doom library -------------------------------------------
static const char *wadProblem = nullptr;
static int preflightCalls = 0;
extern "C" const char *doom_wad_preflight(void) {
  preflightCalls++;
  return wadProblem;
}

static void bootIsrAt(bool down) {
  fakeBootLevel = down ? 0 : 1;
  bootIsr();
}

static void bootEdge(bool down) {
  bootIsrAt(down);
  handleButton();
}

static void shortPress() {
  bootEdge(true);
  fakeNow += 100;
  bootEdge(false);
  fakeNow += 100;
}

static void resetObservations() {
  Serial.captured.clear();
  ESP.restarts = 0;
  fakeNvsBools.clear();
  infoBarShown.clear();
  preflightCalls = 0;
  displayPrefSaves = 0;
  fakeNvsWritesFail = false;
  menuDraws = 0;
  menuLabels.clear();
  menuTitle.clear();
  menuMessage.clear();
  script.clear();
  touchAvailable = false;
  fakeResetReason = ESP_RST_POWERON;
  // Let the double-press tracker and the triple-press window close.
  fakeNow += 5000;
  handleButton();
}

static int tripleWithInvalidWadStaysNormal() {
  resetObservations();
  wadProblem = "no doom_wad partition";
  shortPress();
  shortPress();
  shortPress();
  CHECK(ESP.restarts == 0);
  CHECK(fakeNvsBools.count("doomonce") == 0);
  CHECK(preflightCalls == 1);
  CHECK(Serial.captured.find("button: Doom unavailable (no doom_wad partition)") !=
        std::string::npos);
  CHECK(Serial.captured.find("rebooting into isolated mode") ==
        std::string::npos);
  CHECK(infoBarShown == "Doom: full USB flash");
  // Presses one and two were also a double press, which toggled the signal
  // survey; staying normal must leave it, and the backlight, as they were.
  CHECK(!surveyActive);
  CHECK(userBlLevel == BL_HIGH);
  CHECK(displayPrefSaves == 0);
  // The Doom reason is the last line, after the survey undo.
  CHECK(Serial.captured.rfind("button: Doom unavailable") >
        Serial.captured.rfind("signal survey off"));
  return 0;
}

static int refusalWithFixedBacklight() {
  resetObservations();
  fixedBlLevel = 120;
  wadProblem = "WAD lump outside the file";
  shortPress();
  shortPress();
  shortPress();
  fixedBlLevel = 0;
  CHECK(ESP.restarts == 0);
  CHECK(!surveyActive);
  CHECK(userBlLevel == BL_HIGH);
  CHECK(displayPrefSaves == 0);
  return 0;
}

static int refusalKeepsASurveyThatWasOn() {
  resetObservations();
  surveyActive = true;
  wadProblem = "WAD header missing";
  shortPress();
  shortPress();
  shortPress();
  CHECK(ESP.restarts == 0);
  CHECK(surveyActive);
  surveyActive = false;
  return 0;
}

static int tripleWithValidWadReopensBootMenu() {
  resetObservations();
  wadProblem = nullptr;
  shortPress();
  shortPress();
  shortPress();
  CHECK(preflightCalls == 1);
  CHECK(fakeNvsBools.count("bootmenu") == 1);
  CHECK(fakeNvsBools["bootmenu"]);
  // Doom itself is now the menu's to choose.
  CHECK(fakeNvsBools.count("doomonce") == 0);
  CHECK(ESP.restarts == 1);
  CHECK(Serial.captured.find("button: boot menu requested; restarting") !=
        std::string::npos);
  CHECK(infoBarShown.empty());
  return 0;
}

static int twoPressesAreNotATriple() {
  resetObservations();
  wadProblem = nullptr;
  shortPress();
  shortPress();
  fakeNow += 1000;
  shortPress();
  CHECK(preflightCalls == 0);
  CHECK(ESP.restarts == 0);
  CHECK(fakeNvsBools.count("bootmenu") == 0);
  return 0;
}

// ---- The boot-mode menu ---------------------------------------------------

static int requestIsConsumedOnce() {
  resetObservations();
  fakeNvsBools["bootmenu"] = true;
  CHECK(takeBootMenuRequest());
  CHECK(fakeNvsBools.count("bootmenu") == 0);
  CHECK(!takeBootMenuRequest());
  return 0;
}

static int automaticRestartSkipsMenu() {
  const esp_reset_reason_t automatic[] = {
      ESP_RST_SW, ESP_RST_PANIC, ESP_RST_TASK_WDT, ESP_RST_INT_WDT,
      ESP_RST_WDT, ESP_RST_BROWNOUT, ESP_RST_UNKNOWN};
  for (const esp_reset_reason_t reason : automatic) {
    resetObservations();
    wadProblem = nullptr;
    fakeResetReason = reason;
    CHECK(!runBootMenuIfDue(false));
    CHECK(menuDraws == 0);
    // A Doom exit, crash, or watchdog never pays for a WAD read either.
    CHECK(preflightCalls == 0);
    CHECK(ESP.restarts == 0);
  }
  return 0;
}

static int untouchedPowerOnMenuStreams() {
  const esp_reset_reason_t user[] = {ESP_RST_POWERON, ESP_RST_EXT,
                                     ESP_RST_USB};
  for (const esp_reset_reason_t reason : user) {
    resetObservations();
    wadProblem = nullptr;
    fakeResetReason = reason;
    const uint32_t startedAt = fakeNow;
    CHECK(runBootMenuIfDue(false));
    CHECK(!bootMenuActive);
    CHECK(menuLabels == "STREAMING,DOOM");
    CHECK(menuSelected == 0);
    CHECK(fakeNow - startedAt >= 3000);
    CHECK(fakeNow - startedAt < 3100);
    // The title counted 3, 2, 1 down to streaming.
    CHECK(menuDraws == 3);
    CHECK(menuTitle == "STREAMING IN 1");
    CHECK(ESP.restarts == 0);
    CHECK(fakeNvsBools.count("doomonce") == 0);
    CHECK(Serial.captured.find("boot menu: streaming (countdown ended)") !=
          std::string::npos);
  }
  return 0;
}

static int unusableWadOffersNoMenu() {
  resetObservations();
  wadProblem = "no doom_wad partition";
  CHECK(!runBootMenuIfDue(false));
  CHECK(menuDraws == 0);
  CHECK(preflightCalls == 1);
  CHECK(Serial.captured.find(
            "boot menu: Doom not offered (no doom_wad partition)") !=
        std::string::npos);
  wadProblem = nullptr;
  return 0;
}

static int manuallyOffPanelSkipsTimedMenuOnly() {
  resetObservations();
  wadProblem = nullptr;
  panelManuallyOff = true;
  CHECK(!runBootMenuIfDue(false));
  CHECK(menuDraws == 0);
  // A triple press is someone asking for it.
  CHECK(runBootMenuIfDue(true));
  CHECK(menuDraws > 0);
  panelManuallyOff = false;
  return 0;
}

static int requestedMenuWaitsLongerThenStreams() {
  resetObservations();
  wadProblem = nullptr;
  fakeResetReason = ESP_RST_SW;
  const uint32_t startedAt = fakeNow;
  CHECK(runBootMenuIfDue(true));
  CHECK(fakeNow - startedAt >= 15000);
  CHECK(fakeNow - startedAt < 15100);
  CHECK(ESP.restarts == 0);
  CHECK(fakeNvsBools.count("doomonce") == 0);
  return 0;
}

static int bootPressThenHoldChoosesDoom() {
  resetObservations();
  wadProblem = nullptr;
  const uint32_t t = fakeNow;
  script = {{t + 500, ScriptedInput::BootDown, 0, 0},
            {t + 600, ScriptedInput::BootUp, 0, 0},
            {t + 1000, ScriptedInput::BootDown, 0, 0},
            {t + 2000, ScriptedInput::BootUp, 0, 0}};
  ESP.throwOnRestart = true;
  bool restarted = false;
  try {
    runBootMenuIfDue(false);
  } catch (const FakeRestart &) {
    restarted = true;
  }
  ESP.throwOnRestart = false;
  bootMenuActive = false;
  CHECK(restarted);
  // Chosen while still held, at the long-press threshold.
  CHECK(fakeNow - t >= 1600);
  CHECK(fakeNow - t < 1700);
  CHECK(menuSelected == 1);
  CHECK(menuMessage == "STARTING DOOM");
  CHECK(fakeNvsBools.count("doomonce") == 1);
  CHECK(fakeNvsBools["doomonce"]);
  CHECK(ESP.restarts == 1);
  CHECK(Serial.captured.find("boot menu: DOOM highlighted") !=
        std::string::npos);
  // Let the real handler see the release so later tests start clean.
  fakeNow = t + 2000;
  bootEdge(false);
  return 0;
}

static int holdOnStreamingLeavesNoNormalPressBehind() {
  resetObservations();
  wadProblem = nullptr;
  const uint32_t t = fakeNow;
  // Held well past the power threshold: the rest of the hold belongs to the
  // STREAMING choice, so neither a rotate nor a power toggle may follow.
  script = {{t + 300, ScriptedInput::BootDown, 0, 0}};
  CHECK(runBootMenuIfDue(false));
  CHECK(fakeNow - t < 1000);
  CHECK(Serial.captured.find("boot menu: streaming (chosen)") !=
        std::string::npos);
  fakeNow = t + 4000;
  handleButton();
  bootEdge(false);
  CHECK(!panelManuallyOff);
  CHECK(panelRotation == 0);
  CHECK(displayPrefSaves == 0);
  return 0;
}

static int touchRowThenStartChoosesDoom() {
  resetObservations();
  wadProblem = nullptr;
  touchAvailable = true;
  const int width = PANEL_GEOMETRY.frameWidth(panelLandscape);
  const int height = PANEL_GEOMETRY.frameHeight(panelLandscape);
  const wifiselector::SelectorLayout layout = wifiselector::selectorLayout(
      width, height, bcfg->panel->roundDisplay, 2, 0);
  CHECK(layout.visibleCount == 2);
  const wifiselector::Rect doomRow = layout.rowRect(1);
  const uint32_t t = fakeNow;
  script = {{t + 500, ScriptedInput::Tap,
             (int16_t)(doomRow.x + doomRow.width / 2),
             (int16_t)(doomRow.y + doomRow.height / 2)},
            {t + 900, ScriptedInput::Tap,
             (int16_t)(layout.connect.x + layout.connect.width / 2),
             (int16_t)(layout.connect.y + layout.connect.height / 2)}};
  ESP.throwOnRestart = true;
  bool restarted = false;
  try {
    runBootMenuIfDue(false);
  } catch (const FakeRestart &) {
    restarted = true;
  }
  ESP.throwOnRestart = false;
  bootMenuActive = false;
  CHECK(restarted);
  CHECK(fakeNvsBools.count("doomonce") == 1);
  CHECK(Serial.captured.find("boot menu: touch highlighted DOOM") !=
        std::string::npos);
  return 0;
}

// The branch's headline invariant: whatever is highlighted, a menu nobody
// chooses from starts STREAMING. Without this, an expiry that honoured the
// highlight would boot Doom on a board left alone.
static int doomHighlightedButLeftAloneStillStreams() {
  resetObservations();
  wadProblem = nullptr;
  const uint32_t t = fakeNow;
  // One short BOOT press moves the highlight to DOOM, then nobody touches it.
  script = {{t + 500, ScriptedInput::BootDown, 0, 0},
            {t + 600, ScriptedInput::BootUp, 0, 0}};
  CHECK(runBootMenuIfDue(false));
  CHECK(menuSelected == 1);
  CHECK(menuLabels == "STREAMING,DOOM");
  CHECK(Serial.captured.find("boot menu: DOOM highlighted") !=
        std::string::npos);
  CHECK(!bootMenuActive);
  CHECK(ESP.restarts == 0);
  CHECK(fakeNvsBools.count("doomonce") == 0);
  CHECK(Serial.captured.find("boot menu: streaming (countdown ended)") !=
        std::string::npos);
  return 0;
}

// Stray input must not hold the menu open for ever: a case pressing the glass or
// a noisy controller would otherwise mean the board never streams.
static int strayInputCannotHoldTheMenuForEver() {
  resetObservations();
  wadProblem = nullptr;
  touchAvailable = true;
  const int height = PANEL_GEOMETRY.frameHeight(panelLandscape);
  const uint32_t t = fakeNow;
  // A tap outside every control, the first inside the opening 3 s window and
  // the rest inside each renewed 15 s window, for far longer than any ceiling.
  script.push_back({t + 2000, ScriptedInput::Tap, 0, (int16_t)(height / 2)});
  for (uint32_t i = 1; i <= 200; ++i) {
    script.push_back({t + 2000 + i * 5000, ScriptedInput::Tap, 0,
                      (int16_t)(height / 2)});
  }
  CHECK(runBootMenuIfDue(false));
  CHECK(!bootMenuActive);
  CHECK(ESP.restarts == 0);
  CHECK(fakeNvsBools.count("doomonce") == 0);
  CHECK(Serial.captured.find("boot menu: streaming (countdown ended)") !=
        std::string::npos);
  // Bounded by the ceiling, not by the taps running out.
  CHECK(fakeNow - t <= bootmenu::MAX_OPEN_MS + 100);
  CHECK(!script.empty());
  // The title never promises time the ceiling will not give.
  CHECK(menuTitle == "STREAMING IN 1");
  return 0;
}

// NVS refusing the handoff must leave the board on the menu, saying so, rather
// than restarting into a Doom boot that will find no request.
static int doomSaveFailureKeepsTheMenuUp() {
  resetObservations();
  wadProblem = nullptr;
  touchAvailable = true;
  const int width = PANEL_GEOMETRY.frameWidth(panelLandscape);
  const int height = PANEL_GEOMETRY.frameHeight(panelLandscape);
  const wifiselector::SelectorLayout layout = wifiselector::selectorLayout(
      width, height, bcfg->panel->roundDisplay, 2, 0);
  const wifiselector::Rect doomRow = layout.rowRect(1);
  const uint32_t t = fakeNow;
  script = {{t + 500, ScriptedInput::Tap,
             (int16_t)(doomRow.x + doomRow.width / 2),
             (int16_t)(doomRow.y + doomRow.height / 2)},
            {t + 900, ScriptedInput::Tap,
             (int16_t)(layout.connect.x + layout.connect.width / 2),
             (int16_t)(layout.connect.y + layout.connect.height / 2)}};
  fakeNvsWritesFail = true;
  CHECK(runBootMenuIfDue(false));
  CHECK(ESP.restarts == 0);
  CHECK(fakeNvsBools.count("doomonce") == 0);
  CHECK(menuMessage == "SAVE FAILED");
  CHECK(Serial.captured.find("boot menu: Doom request could not be saved") !=
        std::string::npos);
  // And it still ends up streaming rather than stuck.
  CHECK(!bootMenuActive);
  CHECK(Serial.captured.find("boot menu: streaming (countdown ended)") !=
        std::string::npos);
  return 0;
}

// A triple press whose request cannot be saved must not restart either.
static int menuRequestSaveFailureStaysNormal() {
  resetObservations();
  wadProblem = nullptr;
  fakeNvsWritesFail = true;
  shortPress();
  shortPress();
  shortPress();
  CHECK(ESP.restarts == 0);
  CHECK(fakeNvsBools.count("bootmenu") == 0);
  CHECK(Serial.captured.find(
            "button: boot menu request could not be saved") !=
        std::string::npos);
  return 0;
}

// The touch path's boot-menu routing, checked at the source: the real
// serviceTouch() is faked here, so this is what keeps the branch from being
// deleted or moved below the wake-swallow and the sender report. Same technique
// the WiFi selector's own routing check uses (test_band_protocol.cpp).
static int touchRoutingReachesTheMenuFirst() {
  const std::string touchSource = readFirmwareSource("input_touch.cpp");
  const size_t routing = touchSource.find("if (bootMenuActive) {");
  const size_t tap =
      touchSource.find("handleBootMenuTap(event.startX, event.startY)");
  const size_t wakeSwallow = touchSource.find("touchConsumed = true;");
  const size_t senderReport =
      touchSource.find("sendTouchEvent(event.gesture, event.startX");
  CHECK(routing != std::string::npos);
  CHECK(tap != std::string::npos);
  CHECK(wakeSwallow != std::string::npos);
  CHECK(senderReport != std::string::npos);
  CHECK(routing < senderReport);
  CHECK(tap < senderReport);
  // Ahead of the wake-swallow, so a tap on the menu is never spent lighting the
  // panel instead of choosing, and ahead of the report to a sender that does not
  // exist yet at menu time.
  CHECK(routing < wakeSwallow);
  return 0;
}

static int touchStartOnStreamingStreams() {
  resetObservations();
  wadProblem = nullptr;
  touchAvailable = true;
  const int width = PANEL_GEOMETRY.frameWidth(panelLandscape);
  const int height = PANEL_GEOMETRY.frameHeight(panelLandscape);
  const wifiselector::SelectorLayout layout = wifiselector::selectorLayout(
      width, height, bcfg->panel->roundDisplay, 2, 0);
  const uint32_t t = fakeNow;
  // A tap outside every control restarts the countdown at the idle window.
  script = {{t + 2500, ScriptedInput::Tap, 0, (int16_t)(height / 2)},
            {t + 5000, ScriptedInput::Tap,
             (int16_t)(layout.connect.x + layout.connect.width / 2),
             (int16_t)(layout.connect.y + layout.connect.height / 2)}};
  CHECK(runBootMenuIfDue(false));
  CHECK(fakeNow - t >= 5000);
  CHECK(fakeNow - t < 5100);
  CHECK(ESP.restarts == 0);
  CHECK(fakeNvsBools.count("doomonce") == 0);
  CHECK(Serial.captured.find("boot menu: streaming (chosen)") !=
        std::string::npos);
  return 0;
}

static int ineligibleProfileNeverChecksWad() {
  resetObservations();
  const board::Variant saved = boardVariant;
  boardVariant = board::Variant::TouchJd9853;
  wadProblem = "no doom_wad partition";
  shortPress();
  shortPress();
  shortPress();
  boardVariant = saved;
  CHECK(preflightCalls == 0);
  CHECK(ESP.restarts == 0);
  CHECK(infoBarShown.empty());
  return 0;
}

int main() {
  bcfg = &board::configFor(boardVariant);
  PANEL_GEOMETRY = {bcfg->panel->width, bcfg->panel->height};
  if (!bcfg->hasBootButton()) {
    printf("FAIL: test profile has no BOOT button\n");
    return 1;
  }
  initializeButtonInput();
  if (bootIsr == nullptr) {
    printf("FAIL: BOOT interrupt was not attached\n");
    return 1;
  }
  if (tripleWithInvalidWadStaysNormal() != 0) return 1;
  if (refusalKeepsASurveyThatWasOn() != 0) return 1;
  if (refusalWithFixedBacklight() != 0) return 1;
  if (tripleWithValidWadReopensBootMenu() != 0) return 1;
  if (twoPressesAreNotATriple() != 0) return 1;
  if (ineligibleProfileNeverChecksWad() != 0) return 1;
  if (requestIsConsumedOnce() != 0) return 1;
  if (automaticRestartSkipsMenu() != 0) return 1;
  if (untouchedPowerOnMenuStreams() != 0) return 1;
  if (unusableWadOffersNoMenu() != 0) return 1;
  if (manuallyOffPanelSkipsTimedMenuOnly() != 0) return 1;
  if (requestedMenuWaitsLongerThenStreams() != 0) return 1;
  if (bootPressThenHoldChoosesDoom() != 0) return 1;
  if (holdOnStreamingLeavesNoNormalPressBehind() != 0) return 1;
  if (touchRowThenStartChoosesDoom() != 0) return 1;
  if (touchStartOnStreamingStreams() != 0) return 1;
  if (doomHighlightedButLeftAloneStillStreams() != 0) return 1;
  if (strayInputCannotHoldTheMenuForEver() != 0) return 1;
  if (doomSaveFailureKeepsTheMenuUp() != 0) return 1;
  if (menuRequestSaveFailureStaysNormal() != 0) return 1;
  if (touchRoutingReachesTheMenuFirst() != 0) return 1;
  printf("test_doom_entry_gate: %d checks passed\n", checks);
  return 0;
}
