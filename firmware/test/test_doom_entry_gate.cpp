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
#include <utility>
#include <vector>

#include <Arduino.h>
#include <Preferences.h>
#include <driver/gpio.h>
#include <esp_system.h>
#include <freertos/task.h>
#include <esp_timer.h>

#include <board_config.h>

#include <board_touch.h>
#include <touch_map.h>
#include <doom_mode.h>

#include "../display_stream/app_state.h"
#include "../display_stream/boot_menu.h"
#include "../display_stream/input_touch.h"
#include "../display_stream/boot_menu_model.h"
#include "../display_stream/device_protocol.h"
#include "../display_stream/input_button.h"
#include "../display_stream/input_map.h"
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
void (*fakeEspTimerCallback)(void *arg) = nullptr;
void *fakeEspTimerArg = nullptr;
FakeEsp ESP;
std::map<std::string, bool> fakeNvsBools;
std::map<std::string, std::string> fakeNvsStrings;
std::map<std::string, std::string> fakeNvsBytes;
bool fakeNvsWritesFail = false;
static uint32_t fakeNow = 1000;
static int fakeBootLevel = 1;
static void (*bootIsr)() = nullptr;
board::Variant boardVariant = board::Variant::P4_4C;
const board::Config *bcfg = nullptr;

void delay(uint32_t ms) { fakeNow += ms; }
uint32_t millis() { return fakeNow; }
void pinMode(int, int) {}
// Every other pin (the knob's encoder pair) keeps its own level and interrupt.
static std::map<int, int> fakePinLevel;
static std::map<int, void (*)()> fakePinIsr;
static int levelOf(int pin) {
  if (bcfg != nullptr && pin == bcfg->pinBootButton) return fakeBootLevel;
  const auto found = fakePinLevel.find(pin);
  return found == fakePinLevel.end() ? 1 : found->second;
}
int digitalRead(int pin) { return levelOf(pin); }
int digitalPinToInterrupt(int pin) { return pin; }
void attachInterrupt(int interrupt, void (*isr)(), int) {
  if (bcfg != nullptr && interrupt == bcfg->pinBootButton) {
    bootIsr = isr;
  } else {
    fakePinIsr[interrupt] = isr;
  }
}
int gpio_get_level(gpio_num_t pin) { return levelOf((int)pin); }
// On a board the FreeRTOS tick count starts when the scheduler does, after
// esp_timer, so it always trails millis(). Modelled here, or code that mixes
// the two clocks would pass on the host and misjudge presses on the glass.
static const uint32_t TICK_LAG_MS = 700;
TickType_t xTaskGetTickCount() { return fakeNow - TICK_LAG_MS; }
TickType_t xTaskGetTickCountFromISR() { return fakeNow - TICK_LAG_MS; }

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
static std::vector<shutdown_handler_t> shutdownHandlers;
esp_err_t esp_register_shutdown_handler(shutdown_handler_t handler) {
  for (shutdown_handler_t known : shutdownHandlers) {
    if (known == handler) return 1;  // ESP_ERR_INVALID_STATE, as the SDK
  }
  shutdownHandlers.push_back(handler);
  return 0;
}
// What esp_restart() does before the chip resets.
static void runShutdownHandlers() {
  for (shutdown_handler_t handler : shutdownHandlers) handler();
}

bool blIsHigh() { return userBlLevel == BL_HIGH; }
static int backlightApplies = 0;
void applyBacklight() { backlightApplies++; }
static int displayPrefSaves = 0;
void saveDisplayPrefs() { displayPrefSaves++; }
static int surveyDraws = 0;
void drawSurveyScreen() { surveyDraws++; }
void drawIdleScreen() {}
// The WiFi selector's state as ui_screens.cpp keeps it: opening it puts the
// survey (the status screen) under it, which closing it returns to.
static int selectorOpens = 0;
static int selectorMoves = 0;
static int selectorActivations = 0;
void openWifiSelector() {
  selectorOpens++;
  wifiSelectorActive = true;
  surveyActive = true;
}
void moveWifiSelector(int) { selectorMoves++; }
void activateWifiSelector() { selectorActivations++; }

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
// A tap completes at `at`; its finger went down TAP_MS earlier.
struct ScriptedInput {
  uint32_t at;
  enum Kind { BootDown, BootUp, Tap, KnobTurn } kind;
  int16_t x;
  int16_t y;
};
static const uint32_t TAP_MS = 80;
static std::vector<ScriptedInput> script;
static void bootIsrAt(bool down);

// One knob detent through the real encoder interrupt: the decoder counts a
// detent on each A change, clockwise when A and B then differ, and a B-only
// change counts nothing. So B is first lined up with A (clockwise) or set
// apart from it (counterclockwise), and the A change that follows is the
// detent.
static void knobDetent(bool clockwise) {
  const int a = bcfg->pinEncoderA, b = bcfg->pinEncoderB;
  if ((levelOf(a) == levelOf(b)) != clockwise) {
    fakePinLevel[b] = levelOf(b) ? 0 : 1;
    fakePinIsr[b]();
  }
  fakePinLevel[a] = levelOf(a) ? 0 : 1;
  fakePinIsr[a]();
}

// A menu that is never left would spin forever on the fake clock. The menu loop
// polls these fakes every pass, so the guard fires there and the test fails
// with a message instead of hanging the suite.
struct FakeHang {};
static uint32_t fakeHangAt = 0;
static void deliverScript(ScriptedInput::Kind wanted) {
  if ((int32_t)(fakeNow - fakeHangAt) >= 0) throw FakeHang();
  while (!script.empty() && script.front().at <= fakeNow) {
    const ScriptedInput next = script.front();
    (void)wanted;
    script.erase(script.begin());
    if (next.kind == ScriptedInput::KnobTurn) {
      // x detents clockwise.
      for (int16_t i = 0; i < next.x; ++i) knobDetent(true);
    } else {
      bootIsrAt(next.kind == ScriptedInput::BootDown);
    }
  }
}
void handleSerialConfig() { deliverScript(ScriptedInput::BootDown); }

// ---- The touch controller, for the REAL serviceTouch() (input_touch.cpp) ----
// Reports are handed out one per poll once their time comes, the way the
// controller's interrupt-raised flag hands them to the loop.
struct TouchReport {
  uint32_t at;
  bool pressed;
  uint16_t rawX;
  uint16_t rawY;
};
static std::vector<TouchReport> touchReports;
// Where a finger actually is, independent of what the controller has reported:
// an interrupt-driven controller (CST816) need not report a finger holding
// still, but answers a direct read with it.
struct Finger {
  uint32_t from, until;  // until == 0: never lifted
  uint16_t rawX, rawY;
};
static std::vector<Finger> fingers;
// When set, BOOT goes down from inside the touch poll at that time - after the
// pass's handleButton() has drained the edge queue, before its expiry check.
static uint32_t bootDownInsideTouchPollAt = 0;
namespace boardtouch {
bool poll(Sample &sample) {
  if (bootDownInsideTouchPollAt != 0 &&
      (int32_t)(fakeNow - bootDownInsideTouchPollAt) >= 0) {
    bootDownInsideTouchPollAt = 0;
    bootIsrAt(true);
  }
  if (touchReports.empty() || touchReports.front().at > fakeNow) return false;
  const TouchReport report = touchReports.front();
  touchReports.erase(touchReports.begin());
  sample.pressed = report.pressed;
  sample.rawX = report.rawX;
  sample.rawY = report.rawY;
  sample.points = report.pressed ? 1 : 0;
  return true;
}
bool readNow(Sample &sample) {
  for (const Finger &f : fingers) {
    if ((int32_t)(fakeNow - f.from) >= 0 &&
        (f.until == 0 || (int32_t)(fakeNow - f.until) < 0)) {
      sample.pressed = true;
      sample.rawX = f.rawX;
      sample.rawY = f.rawY;
      sample.points = 1;
      return true;
    }
  }
  sample.pressed = false;
  sample.points = 0;
  return true;
}
}  // namespace boardtouch

// Fakes for what input_touch.cpp reaches outside the menu path.
uint32_t touchWakeUntil = 0;
bool touchWakeActive() { return false; }
bool displaySleeping = false;
extern const uint32_t TOUCH_WAKE_MS = 8000;
uint16_t hbPort = 0;
uint32_t hbIp = 0;
// Every datagram the panel sends, so the knob's reports can be read back.
static std::vector<std::vector<uint8_t>> sentPackets;
void sendToSender(const uint8_t *data, size_t length) {
  sentPackets.emplace_back(data, data + length);
}
touchmap::Calibration touchCalibration = touchmap::GT911_ON_JD9365_4C;
bool panelMirrorX = false;
uint8_t appliedPanelRotation = 0;
uint8_t addressedPanelRotation() { return appliedPanelRotation; }
static std::vector<std::pair<int16_t, int16_t>> touchMarkers;
void drawTouchMarker(int16_t x, int16_t y) { touchMarkers.push_back({x, y}); }
// Whether the status screen was still up under the selector as it closed,
// which is what the real one repaints.
static bool surveyUpAtSelectorClose = false;
void closeWifiSelector() {
  surveyUpAtSelectorClose = surveyActive;
  wifiSelectorActive = false;
}
void handleWifiSelectorTap(int16_t, int16_t) {}
bool handleSurveyTap(int16_t, int16_t) { return false; }
const char *defaultInfoBarText() { return ""; }

// ---- Fakes for the Doom library -------------------------------------------
static const char *wadProblem = nullptr;
static int preflightCalls = 0;
extern "C" const char *doom_wad_preflight(void) {
  preflightCalls++;
  return wadProblem;
}
// The game store's WADs the Doom boot would accept; none unless a test says.
static std::vector<std::string> storedWads;
static const char *storedWadProblem = nullptr;
static int storedWadPreflightCalls = 0;
extern "C" size_t doom_store_wad_preflight(
    char names[][GAME_STORE_NAME_BYTES + 1], size_t max, const char **problem) {
  storedWadPreflightCalls++;
  *problem = storedWadProblem;
  size_t count = 0;
  for (const std::string &name : storedWads) {
    if (count == max) break;
    snprintf(names[count++], GAME_STORE_NAME_BYTES + 1, "%s", name.c_str());
  }
  return count;
}

// ---- Fakes for the Quake library ------------------------------------------
// The test profile is a P4 carrier, so this image carries Quake. Its pak is
// missing unless a test says otherwise, which keeps every Doom-only case
// above exactly as it was.
static const char *const NO_PAK = "no quake_pak partition";
static const char *pakProblem = NO_PAK;
static int pakPreflightCalls = 0;
extern "C" const char *quake_pak_preflight(void) {
  pakPreflightCalls++;
  return pakProblem;
}

static void bootIsrAt(bool down) {
  fakeBootLevel = down ? 0 : 1;
  bootIsr();
}

// An edge, then the loop passes that see it settle once the debounce window
// has run out.
static void bootEdge(bool down) {
  bootIsrAt(down);
  handleButton();
  fakeNow += 30;
  handleButton();
}

// A press and release, then a loop pass once its debounce window has run
// out, as the firmware's loop gives it.
static void shortPress() {
  bootEdge(true);
  fakeNow += 100;
  bootEdge(false);
  fakeNow += 100;
  handleButton();
}

static void resetObservations() {
  // Every test starts on this board's defaults, today's behaviour.
  fakeNvsBytes.clear();
  loadInputMap();
  // Shared state an earlier test may have left behind. A survey left on once
  // made a later test pass vacuously: its release took the survey branch, so
  // the rotate it was meant to catch could never happen.
  surveyActive = false;
  idleActive = false;
  wifiSelectorActive = false;
  bootMenuActive = false;
  fixedBlLevel = 0;
  userBlLevel = BL_HIGH;
  panelManuallyOff = false;
  panelRotation = 0;
  Serial.captured.clear();
  ESP.restarts = 0;
  fakeNvsBools.clear();
  fakeNvsStrings.clear();
  storedWads.clear();
  storedWadProblem = nullptr;
  storedWadPreflightCalls = 0;
  infoBarShown.clear();
  preflightCalls = 0;
  pakProblem = NO_PAK;
  pakPreflightCalls = 0;
  displayPrefSaves = 0;
  surveyDraws = 0;
  selectorOpens = 0;
  selectorMoves = 0;
  selectorActivations = 0;
  fakeNvsWritesFail = false;
  menuDraws = 0;
  menuLabels.clear();
  menuTitle.clear();
  menuMessage.clear();
  script.clear();
  touchReports.clear();
  fingers.clear();
  bootDownInsideTouchPollAt = 0;
  touchAvailable = false;
  fakeResetReason = ESP_RST_POWERON;
  // Let the double-press tracker and the triple-press window close.
  fakeNow += 5000;
  handleButton();
  // Far past any menu a test means to run: an hour of fake time.
  fakeHangAt = fakeNow + 3600000u;
}

// How a menu run ended: it returned (streaming), it restarted (a game was
// chosen; a real restart never returns), or it never ended.
enum class MenuRun { Returned, Restarted, Hung };
static MenuRun runMenu(bool requested) {
  ESP.throwOnRestart = true;
  MenuRun result = MenuRun::Returned;
  try {
    runBootMenuIfDue(requested);
  } catch (const FakeRestart &) {
    result = MenuRun::Restarted;
  } catch (const FakeHang &) {
    result = MenuRun::Hung;
  }
  ESP.throwOnRestart = false;
  bootMenuActive = false;
  return result;
}

// The menu's layout for `rows` choices: STREAMING and DOOM unless a test also
// offers QUAKE.
static wifiselector::SelectorLayout menuLayout(size_t rows = 2) {
  return wifiselector::selectorLayout(
      PANEL_GEOMETRY.frameWidth(panelLandscape),
      PANEL_GEOMETRY.frameHeight(panelLandscape), bcfg->panel->roundDisplay,
      rows, 0);
}

// The raw controller coordinate the board's own calibration maps onto (x, y),
// found by search rather than by inverting the transform here, so the test
// cannot share a mistake with the code under test.
static void rawFor(int16_t x, int16_t y, uint16_t &rawX, uint16_t &rawY) {
  int best = 1 << 30;
  for (int rx = 0; rx < 1024; rx += 2) {
    for (int ry = 0; ry < 1024; ry += 2) {
      const touchmap::Point p = touchmap::map(
          (int16_t)rx, (int16_t)ry, panelLandscape, addressedPanelRotation(),
          touchCalibration);
      const int d = (p.x - x) * (p.x - x) + (p.y - y) * (p.y - y);
      if (d < best) {
        best = d;
        rawX = (uint16_t)rx;
        rawY = (uint16_t)ry;
      }
    }
  }
}

// A finger down at `at - heldMs` and lifted at `at`, at the centre of rect.
static void touchPress(uint32_t at, uint32_t heldMs, int16_t x, int16_t y) {
  uint16_t rawX = 0, rawY = 0;
  rawFor(x, y, rawX, rawY);
  touchReports.push_back({at - heldMs, true, rawX, rawY});
  touchReports.push_back({at, false, rawX, rawY});
  fingers.push_back({at - heldMs, at, rawX, rawY});
}
// A finger held from `from` to `until`, reported every 10 ms the way a polled
// GT911 keeps reporting a resting finger, then lifted (unless until is 0).
static void touchHeld(uint32_t from, uint32_t until, int16_t x, int16_t y) {
  uint16_t rawX = 0, rawY = 0;
  rawFor(x, y, rawX, rawY);
  fingers.push_back({from, until, rawX, rawY});
  const uint32_t end = until != 0 ? until : from + 7200000u;
  for (uint32_t at = from; (int32_t)(end - at) > 0; at += 10) {
    touchReports.push_back({at, true, rawX, rawY});
  }
  if (until != 0) touchReports.push_back({until, false, rawX, rawY});
}

static void touchTap(uint32_t at, const wifiselector::Rect &rect) {
  touchPress(at, TAP_MS, (int16_t)(rect.x + rect.width / 2),
             (int16_t)(rect.y + rect.height / 2));
}

// Let the real handler see a release so the next test starts clean.
static void releaseBoot(uint32_t at) {
  fakeNow = at;
  bootEdge(false);
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
  // Press one opened the status screen and presses one and two were a double
  // press, which opened the WiFi selector; staying normal must close both,
  // leave the backlight as it was, and not spend the third press moving the
  // selector.
  CHECK(!surveyActive);
  CHECK(!wifiSelectorActive);
  CHECK(selectorOpens == 1);
  CHECK(selectorMoves == 0);
  CHECK(userBlLevel == BL_HIGH);
  CHECK(displayPrefSaves == 0);
  // The status screen was marked closed before the selector over it closed,
  // so it was not drawn once just to be taken down.
  CHECK(!surveyUpAtSelectorClose);
  // The Doom reason is the last line, after the undo.
  CHECK(Serial.captured.rfind("button: Doom unavailable") >
        Serial.captured.rfind("wifi status off"));
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
  CHECK(!wifiSelectorActive);
  CHECK(surveyUpAtSelectorClose);
  CHECK(selectorMoves == 0);
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
  // The third press reached the triple press, not the selector the double
  // opened.
  CHECK(selectorMoves == 0);
  wifiSelectorActive = false;
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
  // The late third press is an ordinary press in the selector.
  CHECK(wifiSelectorActive);
  CHECK(selectorMoves == 1);
  wifiSelectorActive = false;
  return 0;
}

// ---- BOOT presses outside the menus ----------------------------------------
// A single press opens the WiFi status screen (the signal survey) and the next
// one closes it; a double press opens the WiFi selector. No press touches the
// backlight or saves it: brightness is the app's to set.

static int singlePressTogglesTheStatusScreenOnly() {
  resetObservations();
  const uint8_t level = userBlLevel;
  shortPress();
  CHECK(surveyActive);
  CHECK(!wifiSelectorActive);
  CHECK(surveyDraws == 1);
  // The double-press window closing leaves the screen up and saves nothing.
  fakeNow += 1000;
  handleButton();
  CHECK(surveyActive);
  shortPress();
  CHECK(!surveyActive);
  fakeNow += 1000;
  handleButton();
  CHECK(!surveyActive);
  CHECK(userBlLevel == level);
  CHECK(displayPrefSaves == 0);
  CHECK(selectorOpens == 0);
  CHECK(Serial.captured.find("backlight") == std::string::npos);
  CHECK(Serial.captured.find("button: short press -> wifi status on") !=
        std::string::npos);
  CHECK(Serial.captured.find("button: short press -> wifi status off") !=
        std::string::npos);
  return 0;
}

static int singlePressKeepsAnyBacklightLevel() {
  resetObservations();
  userBlLevel = BL_LOW;
  shortPress();
  fakeNow += 1000;
  handleButton();
  CHECK(userBlLevel == BL_LOW);
  CHECK(displayPrefSaves == 0);
  // A fixed level once disabled the press, which toggled the backlight. The
  // status screen is not a backlight toggle, so it opens all the same.
  resetObservations();
  fixedBlLevel = 120;
  shortPress();
  CHECK(surveyActive);
  CHECK(Serial.captured.find("ignored") == std::string::npos);
  fixedBlLevel = 0;
  surveyActive = false;
  return 0;
}

static int doublePressOpensTheWifiSelector() {
  resetObservations();
  wadProblem = nullptr;
  shortPress();
  shortPress();
  CHECK(wifiSelectorActive);
  CHECK(selectorOpens == 1);
  CHECK(userBlLevel == BL_HIGH);
  CHECK(displayPrefSaves == 0);
  CHECK(Serial.captured.find("button: double press -> wifi selector") !=
        std::string::npos);
  // Inside the selector nothing changed: past the triple-press window a press
  // moves the highlight and a hold chooses it.
  fakeNow += 1000;
  shortPress();
  CHECK(selectorMoves == 1);
  CHECK(ESP.restarts == 0);
  bootEdge(true);
  fakeNow += 700;
  handleButton();
  CHECK(selectorActivations == 1);
  fakeNow += 100;
  bootEdge(false);
  CHECK(selectorMoves == 1);
  CHECK(selectorOpens == 1);

  // From the status screen as well: the first press closes it and the second
  // opens the selector over it.
  resetObservations();
  surveyActive = true;
  shortPress();
  shortPress();
  CHECK(wifiSelectorActive);
  CHECK(selectorOpens == 1);
  CHECK(displayPrefSaves == 0);
  wifiSelectorActive = false;
  surveyActive = false;
  return 0;
}

// A release the BOOT interrupt drops as bounce (inside DEBOUNCE_MS of the
// edge before it) once left the button reading as held while it was up: the
// press did nothing, three seconds later the "extra-long press" turned the
// panel off, and the next press's release counted as a long press. Seen on
// the 1.75" round as "one press sometimes does nothing, sometimes turns the
// display off". The pin's settled level must win.
static void serviceButtonFor(uint32_t ms) {
  for (const uint32_t until = fakeNow + ms; fakeNow < until; fakeNow += 10) {
    handleButton();
  }
}

static int droppedReleaseStillEndsThePress() {
  // A release that bounces: up, down again 35 ms later (kept: past the
  // window), and up 5 ms after that (dropped: inside it).
  resetObservations();
  bootIsrAt(true);
  handleButton();
  fakeNow += 120;
  bootIsrAt(false);
  handleButton();
  fakeNow += 35;
  bootIsrAt(true);
  handleButton();
  fakeNow += 5;
  bootIsrAt(false);
  serviceButtonFor(4000);
  CHECK(surveyActive);
  // Held, as the button wrongly read, 600 ms on the status screen opened the
  // WiFi selector over it.
  CHECK(!wifiSelectorActive);
  CHECK(!panelManuallyOff);
  CHECK(panelRotation == 0);
  CHECK(Serial.captured.find("extra-long press") == std::string::npos);
  CHECK(Serial.captured.find("long press") == std::string::npos);
  // And the next press is an ordinary single again: it closes the screen.
  shortPress();
  serviceButtonFor(1000);
  CHECK(!surveyActive);
  CHECK(panelRotation == 0);
  CHECK(!panelManuallyOff);

  // A blip shorter than the window (its release dropped outright) is bounce,
  // as it always was, but it must not leave the button reading as held: the
  // next real press is a single that opens the status screen.
  resetObservations();
  bootIsrAt(true);
  handleButton();
  fakeNow += 12;
  bootIsrAt(false);
  serviceButtonFor(4000);
  CHECK(!surveyActive);
  CHECK(!panelManuallyOff);
  CHECK(Serial.captured.find("long press") == std::string::npos);
  shortPress();
  CHECK(surveyActive);
  CHECK(!wifiSelectorActive);
  surveyActive = false;
  return 0;
}

// The ISR reads the pin when it runs, so on a bouncing contact it can record
// an edge with the wrong direction, and the real edge a few ms later is then
// dropped as bounce. Seen on the 1.75" round (BOOT is the small button by the
// USB port): a press that logged nothing at all, and a press on the status
// screen that opened the WiFi selector instead of closing it.
static void misreadEdge(bool levelSeenDown, bool settledDown) {
  fakeBootLevel = levelSeenDown ? 0 : 1;
  bootIsr();
  fakeNow += 5;
  fakeBootLevel = settledDown ? 0 : 1;
  bootIsr();  // inside DEBOUNCE_MS: dropped
  handleButton();
}

static int misreadEdgesStillMakeOnePress() {
  // (a) A press whose down edge reads as up is still a press, and so is the
  // first press on a panel that has gone idle and dimmed or asleep.
  for (int asleep = 0; asleep < 2; ++asleep) {
    resetObservations();
    idleActive = true;
    displaySleeping = asleep == 1;
    misreadEdge(false, true);
    fakeNow += 120;
    bootEdge(false);
    serviceButtonFor(1000);
    CHECK(surveyActive);
    CHECK(!wifiSelectorActive);
    CHECK(Serial.captured.find("button: short press -> wifi status on") !=
          std::string::npos);
    displaySleeping = false;
    idleActive = false;
    surveyActive = false;
  }

  // (b) On the status screen, a press whose release reads as down closes the
  // screen; it does not sit "held" until the hold opens the selector.
  resetObservations();
  shortPress();
  serviceButtonFor(1000);
  CHECK(surveyActive);
  bootEdge(true);
  fakeNow += 120;
  misreadEdge(true, false);
  serviceButtonFor(2000);
  CHECK(!surveyActive);
  CHECK(!wifiSelectorActive);
  CHECK(selectorOpens == 0);
  CHECK(Serial.captured.find("button: short press -> wifi status off") !=
        std::string::npos);

  // (c) Single presses, however they bounce, never open the selector; two
  // inside the window do.
  resetObservations();
  misreadEdge(false, true);
  fakeNow += 120;
  bootEdge(false);
  serviceButtonFor(1000);
  bootEdge(true);
  fakeNow += 120;
  misreadEdge(true, false);
  serviceButtonFor(1000);
  CHECK(selectorOpens == 0);
  CHECK(!surveyActive);
  bootEdge(true);
  fakeNow += 100;
  misreadEdge(true, false);
  fakeNow += 100;
  misreadEdge(false, true);
  fakeNow += 100;
  bootEdge(false);
  serviceButtonFor(1000);
  CHECK(selectorOpens == 1);
  CHECK(wifiSelectorActive);
  wifiSelectorActive = false;
  surveyActive = false;
  return 0;
}

// A release takes effect once its bounce has settled, DEBOUNCE_MS after it.
// The hold path must time the press to the release, not to that settling:
// a press let go just short of 3 s once turned the panel off and then also
// rotated it, and one let go just short of 600 ms on the status screen opened
// the WiFi selector.
static int releaseJustBeforeAThresholdIsNotAHold() {
  resetObservations();
  bootIsrAt(true);
  serviceButtonFor(2985);
  bootIsrAt(false);
  serviceButtonFor(1000);
  CHECK(!panelManuallyOff);
  CHECK(panelRotation == 2);
  CHECK(Serial.captured.find("extra-long press") == std::string::npos);
  panelRotation = 0;

  resetObservations();
  shortPress();
  serviceButtonFor(1000);
  CHECK(surveyActive);
  bootIsrAt(true);
  serviceButtonFor(590);
  bootIsrAt(false);
  serviceButtonFor(1000);
  CHECK(!wifiSelectorActive);
  CHECK(!surveyActive);
  return 0;
}

// A hold on the status screen that a slow loop pass only sees at its release
// opens the selector there; the press after it is the selector's, not
// swallowed as the rest of that hold.
static int holdSeenOnlyAtReleaseLeavesTheNextPress() {
  resetObservations();
  shortPress();
  serviceButtonFor(1000);
  bootIsrAt(true);
  fakeNow += 700;
  bootIsrAt(false);
  fakeNow += 40;
  handleButton();
  fakeNow += 40;
  handleButton();
  CHECK(wifiSelectorActive);
  fakeNow += 1000;
  shortPress();
  CHECK(selectorMoves == 1);
  wifiSelectorActive = false;
  surveyActive = false;
  return 0;
}

// A release burst whose very last level read is wrong, seen by one slow loop
// pass together with the next press, used to settle at that wrong level: the
// release was lost, the button read as held, and the next press's release
// was a rotate. The 10 ms pin sampler corrects the queue in between.
static void fireBootSampler() {
  if (fakeEspTimerCallback != nullptr) fakeEspTimerCallback(fakeEspTimerArg);
}

static int samplerCorrectsAWrongLastRead() {
  resetObservations();
  CHECK(fakeEspTimerCallback != nullptr);
  bootEdge(true);
  fakeNow += 120;
  // The release: two edges, both read as down; the pin is up.
  fakeBootLevel = 0;
  bootIsr();
  fakeNow += 3;
  bootIsr();
  fakeBootLevel = 1;
  for (int i = 0; i < 5; ++i) {
    fakeNow += 10;
    fireBootSampler();
  }
  // The next press, a second later, before any loop pass.
  fakeNow += 1000;
  bootIsrAt(true);
  fakeNow += 120;
  bootIsrAt(false);
  serviceButtonFor(1000);
  CHECK(!surveyActive);
  CHECK(!wifiSelectorActive);
  CHECK(panelRotation == 0);
  CHECK(Serial.captured.find("long press") == std::string::npos);
  CHECK(Serial.captured.find("button: short press -> wifi status on") !=
        std::string::npos);
  CHECK(Serial.captured.find("button: short press -> wifi status off") !=
        std::string::npos);
  // With nothing to correct, the sampler queues nothing.
  resetObservations();
  for (int i = 0; i < 20; ++i) {
    fakeNow += 10;
    fireBootSampler();
  }
  handleButton();
  CHECK(Serial.captured.empty());
  return 0;
}

// Review probes: each of these once survived a mutation of the press logic.
static int quickSelectorPressesAfterTheWindowAreMoves() {
  // Past the triple-press window, presses in a selector a double opened are
  // the selector's, however quickly they come: three of them must not count
  // as a triple and restart into the boot menu.
  resetObservations();
  wadProblem = nullptr;
  shortPress();
  shortPress();
  CHECK(wifiSelectorActive);
  fakeNow += 1000;
  shortPress();
  shortPress();
  shortPress();
  CHECK(selectorMoves == 3);
  CHECK(ESP.restarts == 0);
  CHECK(fakeNvsBools.count("bootmenu") == 0);
  wifiSelectorActive = false;
  surveyActive = false;
  return 0;
}

static int closingTheStatusScreenRestoresTheBacklight() {
  // The status screen lights the panel at the survey level; closing it hands
  // the backlight back to the saved, state-driven level.
  resetObservations();
  shortPress();
  backlightApplies = 0;
  fakeNow += 1000;
  handleButton();
  shortPress();
  CHECK(!surveyActive);
  CHECK(backlightApplies >= 1);
  CHECK(userBlLevel == BL_HIGH);
  return 0;
}

static int holdsKeepTheirJobs() {
  // A hold on the status screen still opens the selector, and the release that
  // ends it does nothing more.
  resetObservations();
  shortPress();
  fakeNow += 1000;
  handleButton();
  bootEdge(true);
  fakeNow += 700;
  handleButton();
  CHECK(wifiSelectorActive);
  CHECK(selectorOpens == 1);
  fakeNow += 100;
  bootEdge(false);
  CHECK(panelRotation == 0);
  CHECK(selectorMoves == 0);
  CHECK(selectorActivations == 0);
  wifiSelectorActive = false;
  surveyActive = false;

  // With no screen up a hold turns the panel 180 and saves that, as before.
  resetObservations();
  bootEdge(true);
  fakeNow += 700;
  bootEdge(false);
  CHECK(panelRotation == 2);
  CHECK(displayPrefSaves == 1);
  CHECK(!surveyActive);
  CHECK(userBlLevel == BL_HIGH);
  panelRotation = 0;
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

// Rule: a board nobody touches comes up streaming after a 5 s countdown shown
// counting 5, 4, 3, 2, 1.
static int untouchedPowerOnMenuStreams() {
  const esp_reset_reason_t user[] = {ESP_RST_POWERON, ESP_RST_EXT,
                                     ESP_RST_USB};
  for (const esp_reset_reason_t reason : user) {
    resetObservations();
    wadProblem = nullptr;
    fakeResetReason = reason;
    const uint32_t startedAt = fakeNow;
    CHECK(runMenu(false) == MenuRun::Returned);
    CHECK(menuLabels == "STREAMING,DOOM");
    CHECK(menuSelected == 0);
    CHECK(fakeNow - startedAt >= 5000);
    CHECK(fakeNow - startedAt < 5100);
    CHECK(menuDraws == 5);
    CHECK(menuTitle == "STREAMING IN 1");
    CHECK(ESP.restarts == 0);
    CHECK(fakeNvsBools.count("doomonce") == 0);
    CHECK(Serial.captured.find("boot menu: power-on, 2 modes, streaming in 5s") !=
          std::string::npos);
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
  CHECK(runMenu(false) == MenuRun::Returned);
  CHECK(menuDraws == 0);
  // A triple press is someone asking for it. It has no countdown, so a hold
  // on STREAMING is what ends it.
  const uint32_t t = fakeNow;
  script = {{t + 500, ScriptedInput::BootDown, 0, 0}};
  CHECK(runMenu(true) == MenuRun::Returned);
  CHECK(menuDraws > 0);
  releaseBoot(t + 1500);
  panelManuallyOff = false;
  return 0;
}

// Rule: a menu opened on purpose (the triple press) has no countdown. It is
// still up after an hour less a minute of nobody touching it, and its FIRST
// press acts - here, moving straight to DOOM - instead of only cancelling.
static int requestedMenuHasNoCountdown() {
  resetObservations();
  wadProblem = nullptr;
  fakeResetReason = ESP_RST_SW;
  const uint32_t t = fakeNow;
  const uint32_t late = t + 3540000u;
  script = {{late, ScriptedInput::BootDown, 0, 0},
            {late + 100, ScriptedInput::BootUp, 0, 0},
            {late + 500, ScriptedInput::BootDown, 0, 0}};
  CHECK(runMenu(true) == MenuRun::Restarted);
  CHECK(Serial.captured.find("boot menu: requested, 2 modes, no countdown") !=
        std::string::npos);
  CHECK(menuTitle == "CHOOSE A MODE");
  CHECK(Serial.captured.find("countdown ended") == std::string::npos);
  CHECK(Serial.captured.find("cancelled the countdown") == std::string::npos);
  CHECK(Serial.captured.find("boot menu: DOOM highlighted") !=
        std::string::npos);
  CHECK(fakeNvsBools.count("doomonce") == 1);
  CHECK(fakeNow - late >= 1100);
  releaseBoot(late + 1600);
  return 0;
}

// Rule: the FIRST press on a counting menu stops the countdown and does
// nothing else - the highlight does not move - and the menu then stays up
// until something is chosen, however long that takes.
static int firstBootPressOnlyCancels() {
  resetObservations();
  wadProblem = nullptr;
  const uint32_t t = fakeNow;
  const uint32_t late = t + 3540000u;
  script = {{t + 1000, ScriptedInput::BootDown, 0, 0},
            {t + 1100, ScriptedInput::BootUp, 0, 0},
            // Long after the countdown would have ended, a hold on the
            // still-highlighted STREAMING chooses it.
            {late, ScriptedInput::BootDown, 0, 0}};
  CHECK(runMenu(false) == MenuRun::Returned);
  CHECK(Serial.captured.find("boot menu: press cancelled the countdown") !=
        std::string::npos);
  CHECK(Serial.captured.find("boot menu: move spent on the cancel") !=
        std::string::npos);
  CHECK(Serial.captured.find("highlighted") == std::string::npos);
  CHECK(Serial.captured.find("countdown ended") == std::string::npos);
  CHECK(menuSelected == 0);
  CHECK(menuTitle == "CHOOSE A MODE");
  CHECK(fakeNow - late >= 600);
  CHECK(Serial.captured.find("boot menu: streaming (chosen)") !=
        std::string::npos);
  CHECK(ESP.restarts == 0);
  releaseBoot(late + 1000);
  return 0;
}

// The same rule for a hold: a hold during the countdown only cancels it, and
// the rest of that hold cannot rotate or power off the panel either.
static int firstHoldOnlyCancelsAndLeavesNoNormalPress() {
  resetObservations();
  wadProblem = nullptr;
  const uint32_t t = fakeNow;
  script = {{t + 300, ScriptedInput::BootDown, 0, 0},
            {t + 4300, ScriptedInput::BootUp, 0, 0},
            {t + 9000, ScriptedInput::BootDown, 0, 0}};
  CHECK(runMenu(false) == MenuRun::Returned);
  CHECK(Serial.captured.find("boot menu: press cancelled the countdown") !=
        std::string::npos);
  CHECK(Serial.captured.find("boot menu: choose spent on the cancel") !=
        std::string::npos);
  // Still up past where the 5 s countdown would have ended, then chosen.
  CHECK(fakeNow - t >= 9600);
  CHECK(Serial.captured.find("boot menu: streaming (chosen)") !=
        std::string::npos);
  releaseBoot(t + 13000);
  CHECK(!panelManuallyOff);
  CHECK(panelRotation == 0);
  CHECK(displayPrefSaves == 0);
  return 0;
}

// Rule: a press that went down before the menu opened - pressed during boot,
// after the BOOT interrupt is attached and before the menu is up - is neither a
// cancel nor a selection. (The triple press that requests a menu acts on its
// third release and then restarts, so none of its presses reach the new boot.)
static int pressBegunBeforeTheMenuIsIgnored() {
  resetObservations();
  wadProblem = nullptr;
  const uint32_t t = fakeNow;
  // Down before the menu opens; released inside it.
  bootIsrAt(true);
  fakeNow += 200;
  script = {{fakeNow + 300, ScriptedInput::BootUp, 0, 0}};
  CHECK(runMenu(false) == MenuRun::Returned);
  CHECK(Serial.captured.find("ignored (began before the menu)") !=
        std::string::npos);
  CHECK(Serial.captured.find("cancelled the countdown") == std::string::npos);
  CHECK(Serial.captured.find("highlighted") == std::string::npos);
  // The countdown ran on and still started streaming at 5 s.
  CHECK(Serial.captured.find("boot menu: streaming (countdown ended)") !=
        std::string::npos);
  CHECK(fakeNow - t >= 5200);
  CHECK(menuSelected == 0);
  return 0;
}

// Review finding: a press made late in the countdown, still down when 5 s ran
// out, escaped into the normal firmware - the menu streamed and the release then
// rotated, dimmed, or powered off the panel and saved it. A press that goes down
// inside a counting menu stops the countdown at once, so the menu waits and the
// release is spent on the menu.
static int pressDownLateInTheCountdownStaysInTheMenu() {
  struct Case {
    uint32_t down, up;
  };
  // A short release over the deadline (backlight), a long one (rotate), and an
  // extra-long one (power).
  // And a press in the countdown's last DEBOUNCE_MS, which stops it although it
  // only settles after the deadline.
  const Case cases[] = {
      {4900, 5100}, {4985, 5100}, {4700, 5500}, {4700, 8000}};
  for (const Case &c : cases) {
    resetObservations();
    wadProblem = nullptr;
    const uint32_t t = fakeNow;
    const uint32_t savedRotation = panelRotation;
    const uint8_t savedLevel = userBlLevel;
    script = {{t + c.down, ScriptedInput::BootDown, 0, 0},
              {t + c.up, ScriptedInput::BootUp, 0, 0},
              // Then a deliberate hold on STREAMING ends the menu.
              {t + c.up + 2000, ScriptedInput::BootDown, 0, 0}};
    CHECK(runMenu(false) == MenuRun::Returned);
    CHECK(Serial.captured.find("countdown ended") == std::string::npos);
    CHECK(Serial.captured.find("boot menu: streaming (chosen)") !=
          std::string::npos);
    releaseBoot(t + c.up + 3000);
    CHECK(Serial.captured.find("button: long press") == std::string::npos);
    CHECK(Serial.captured.find("button: short press") == std::string::npos);
    CHECK(Serial.captured.find("button: extra-long press") == std::string::npos);
    CHECK(panelRotation == savedRotation);
    CHECK(userBlLevel == savedLevel);
    CHECK(!panelManuallyOff);
    CHECK(displayPrefSaves == 0);
  }
  return 0;
}

// Review finding: BOOT press times come from the tick clock and the menu's
// opening time came from millis(), so a press in the first moments of the menu
// was wrongly "ignored (began before the menu)".
static int pressJustAfterTheMenuOpensCounts() {
  resetObservations();
  wadProblem = nullptr;
  const uint32_t t = fakeNow;
  script = {{t + 100, ScriptedInput::BootDown, 0, 0},
            {t + 200, ScriptedInput::BootUp, 0, 0},
            {t + 2000, ScriptedInput::BootDown, 0, 0}};
  CHECK(runMenu(false) == MenuRun::Returned);
  CHECK(Serial.captured.find("ignored (began before the menu)") ==
        std::string::npos);
  CHECK(Serial.captured.find("cancelled the countdown") != std::string::npos);
  CHECK(Serial.captured.find("boot menu: streaming (chosen)") !=
        std::string::npos);
  releaseBoot(t + 3000);
  return 0;
}

// Review finding: a press held 400-600 ms classifies as no gesture and a
// long press is dropped on the menu, so a touch held on the glass never
// stopped the countdown and the board streamed anyway. Through the REAL
// serviceTouch(): the finger landing is what stops it.
static int touchHeldTooLongForATapStillCancels() {
  resetObservations();
  wadProblem = nullptr;
  touchAvailable = true;
  const wifiselector::SelectorLayout layout = menuLayout();
  const wifiselector::Rect row = layout.rowRect(1);
  const uint32_t t = fakeNow;
  // 500 ms and 2 s holds: no tap, and a long press the menu ignores.
  touchPress(t + 1500, 500, (int16_t)(row.x + row.width / 2),
             (int16_t)(row.y + row.height / 2));
  touchPress(t + 4500, 2000, (int16_t)(row.x + row.width / 2),
             (int16_t)(row.y + row.height / 2));
  touchTap(t + 20000, layout.connect);
  CHECK(runMenu(false) == MenuRun::Returned);
  CHECK(Serial.captured.find("boot menu: press cancelled the countdown") !=
        std::string::npos);
  CHECK(Serial.captured.find("countdown ended") == std::string::npos);
  CHECK(fakeNow - t >= 20000);
  CHECK(menuSelected == 0);
  CHECK(Serial.captured.find("boot menu: streaming (chosen)") !=
        std::string::npos);
  return 0;
}

// The hold path judges a press by when it went down too: BOOT down during boot
// and held past the choose threshold inside the menu chooses nothing.
static int holdBegunBeforeTheMenuChoosesNothing() {
  resetObservations();
  wadProblem = nullptr;
  const uint32_t t = fakeNow;
  bootIsrAt(true);
  fakeNow += 100;
  script = {{fakeNow + 1500, ScriptedInput::BootUp, 0, 0}};
  CHECK(runMenu(false) == MenuRun::Returned);
  CHECK(Serial.captured.find("boot menu: choose ignored (began before the menu)") !=
        std::string::npos);
  CHECK(Serial.captured.find("cancelled the countdown") == std::string::npos);
  CHECK(Serial.captured.find("boot menu: streaming (countdown ended)") !=
        std::string::npos);
  CHECK(fakeNow - t >= 5100);
  CHECK(ESP.restarts == 0);
  return 0;
}

// Runs one menu on the Elecrow knob's real profile with the script already set,
// returning the serial log, and puts the 4C back for whatever runs next.
static MenuRun runMenuOnKnob(std::string &serial) {
  const board::Variant savedVariant = boardVariant;
  const board::Config *savedConfig = bcfg;
  boardVariant = board::Variant::ElecrowKnob128;
  bcfg = &board::configFor(boardVariant);
  fakePinLevel.clear();
  fakePinIsr.clear();
  initializeButtonInput();
  const MenuRun run = runMenu(false);
  serial = Serial.captured;
  boardVariant = savedVariant;
  bcfg = savedConfig;
  fakePinIsr.clear();
  initializeButtonInput();
  return run;
}

// Round-2 finding 2: a real flick spreads its detents over several loop passes.
// The first detent stopped the countdown and the next, 30 ms later, moved the
// highlight. A flick is one gesture.
static int knobFlickSpreadOverPassesOnlyCancels() {
  resetObservations();
  wadProblem = nullptr;
  const uint32_t t = fakeNow;
  // Three detents 30 ms apart: one flick across several loop passes.
  script = {{t + 1000, ScriptedInput::KnobTurn, 1, 0},
            {t + 1030, ScriptedInput::KnobTurn, 1, 0},
            {t + 1060, ScriptedInput::KnobTurn, 1, 0},
            // Long after, a deliberate hold on the untouched STREAMING.
            {t + 5000, ScriptedInput::BootDown, 0, 0}};
  std::string serial;
  const MenuRun run = runMenuOnKnob(serial);
  releaseBoot(t + 6000);
  CHECK(run == MenuRun::Returned);
  CHECK(serial.find("boot menu: press cancelled the countdown") !=
        std::string::npos);
  CHECK(serial.find("highlighted") == std::string::npos);
  CHECK(serial.find("boot menu: streaming (chosen)") != std::string::npos);
  return 0;
}

// Round-2 finding 2: press-and-turn is one gesture. BOOT going down stopped the
// countdown, and the turn made while it was held then moved the highlight.
static int knobPressAndTurnOnlyCancels() {
  resetObservations();
  wadProblem = nullptr;
  const uint32_t t = fakeNow;
  script = {{t + 1000, ScriptedInput::BootDown, 0, 0},
            {t + 1200, ScriptedInput::KnobTurn, 1, 0},
            {t + 1400, ScriptedInput::BootUp, 0, 0},
            {t + 5000, ScriptedInput::BootDown, 0, 0}};
  std::string serial;
  const MenuRun run = runMenuOnKnob(serial);
  releaseBoot(t + 6000);
  CHECK(run == MenuRun::Returned);
  CHECK(serial.find("boot menu: press cancelled the countdown") !=
        std::string::npos);
  CHECK(serial.find("highlighted") == std::string::npos);
  CHECK(serial.find("boot menu: streaming (chosen)") != std::string::npos);
  return 0;
}

// Review finding: a fast knob turn crossing several detents both cancelled the
// countdown and moved the highlight. One turn is one press. On the knob
// carrier's real profile, through its encoder interrupt and applyEncoderTurn.
static int fastKnobTurnOnlyCancels() {
  const board::Variant savedVariant = boardVariant;
  const board::Config *savedConfig = bcfg;
  boardVariant = board::Variant::ElecrowKnob128;
  bcfg = &board::configFor(boardVariant);
  if (!bcfg->hasEncoder() || !bcfg->hasBootButton()) {
    printf("FAIL: knob profile has no encoder or BOOT\n");
    return 1;
  }
  fakePinLevel.clear();
  fakePinIsr.clear();
  initializeButtonInput();
  resetObservations();
  wadProblem = nullptr;
  const uint32_t t = fakeNow;
  script = {{t + 1000, ScriptedInput::KnobTurn, 2, 0},
            // A later one-detent turn moves; then a hold chooses DOOM.
            {t + 2000, ScriptedInput::KnobTurn, 1, 0},
            {t + 3000, ScriptedInput::BootDown, 0, 0}};
  const MenuRun run = runMenu(false);
  releaseBoot(t + 4000);
  const std::string serial = Serial.captured;
  // Back to the 4C for whatever runs next.
  boardVariant = savedVariant;
  bcfg = savedConfig;
  fakePinIsr.clear();
  initializeButtonInput();
  CHECK(run == MenuRun::Restarted);
  CHECK(serial.find("knob: turn +2") != std::string::npos);
  CHECK(serial.find("boot menu: press cancelled the countdown") !=
        std::string::npos);
  // Exactly one highlight move: the second turn's, after the cancel.
  const size_t first = serial.find("highlighted");
  CHECK(first != std::string::npos);
  CHECK(serial.find("highlighted", first + 1) == std::string::npos);
  CHECK(serial.find("press cancelled the countdown") < first);
  CHECK(fakeNvsBools.count("doomonce") == 1);
  return 0;
}

// Round-2 finding 1 (blocking): the touch controller is first polled inside
// the menu, so a finger already on the glass at power-on was taken for a menu
// press, cancelled the countdown, and - with no ceiling - the board never
// streamed. A resting hand or a case pressing the glass must not do that.
static int touchAlreadyDownAtOpenStillStreams() {
  const bool lifts[] = {false, true};
  for (const bool lift : lifts) {
    resetObservations();
    wadProblem = nullptr;
    touchAvailable = true;
    const wifiselector::SelectorLayout layout = menuLayout();
    const wifiselector::Rect row = layout.rowRect(1);
    const uint32_t t = fakeNow;
    touchHeld(t - 300, lift ? t + 2000 : 0, (int16_t)(row.x + row.width / 2),
              (int16_t)(row.y + row.height / 2));
    CHECK(runMenu(false) == MenuRun::Returned);
    CHECK(Serial.captured.find("boot menu: streaming (countdown ended)") !=
          std::string::npos);
    CHECK(Serial.captured.find("cancelled the countdown") == std::string::npos);
    CHECK(fakeNow - t < 5300);
  }
  return 0;
}

// Round-2 finding 3: a touch that chooses while BOOT is still held ended the
// menu with BOOT down, and its release then landed on the streaming firmware
// as a long press: rotation changed and saved.
static int touchChoiceWhileBootHeldLeavesNoNormalPress() {
  resetObservations();
  wadProblem = nullptr;
  touchAvailable = true;
  const wifiselector::SelectorLayout layout = menuLayout();
  const uint32_t t = fakeNow;
  const uint32_t savedRotation = panelRotation;
  script = {{t + 500, ScriptedInput::BootDown, 0, 0}};
  // START tapped 300 ms later, BOOT still down: chooses STREAMING.
  touchTap(t + 800, layout.connect);
  CHECK(runMenu(false) == MenuRun::Returned);
  CHECK(Serial.captured.find("boot menu: streaming (chosen)") !=
        std::string::npos);
  // BOOT released after the menu has gone, 1.5 s after it went down.
  releaseBoot(t + 2000);
  CHECK(Serial.captured.find("button: long press") == std::string::npos);
  CHECK(Serial.captured.find("button: short press") == std::string::npos);
  CHECK(panelRotation == savedRotation);
  CHECK(displayPrefSaves == 0);
  return 0;
}

// Round-2 finding 3: BOOT going down inside the menu's last pass, after its
// button handling but before the expiry check, escaped the menu and its release
// then rotated the panel. Such a press is the menu's and is swallowed.
static int bootDownInTheLastPassLeavesNoNormalPress() {
  resetObservations();
  wadProblem = nullptr;
  touchAvailable = true;
  const uint32_t t = fakeNow;
  const uint32_t savedRotation = panelRotation;
  // The menu opens after the 60 ms touch prime, so its countdown runs out in
  // the pass at t + 5060; aim just inside that pass. An earlier hit cancels the
  // countdown instead, which the "countdown ended" check below catches.
  bootDownInsideTouchPollAt = t + 5055;
  CHECK(runMenu(false) == MenuRun::Returned);
  // The hook fired inside the menu, or this test proves nothing.
  CHECK(bootDownInsideTouchPollAt == 0);
  CHECK(Serial.captured.find("boot menu: streaming (countdown ended)") !=
        std::string::npos);
  releaseBoot(t + 6200);
  CHECK(Serial.captured.find("button: long press") == std::string::npos);
  CHECK(panelRotation == savedRotation);
  CHECK(displayPrefSaves == 0);
  // And the next real press after the menu is a normal one again.
  fakeNow += 3000;
  shortPress();
  CHECK(Serial.captured.find("button: short press") != std::string::npos);
  return 0;
}

// Round-3 finding 1: an interrupt-driven controller (CST816, on three Doom
// boards) need not report a finger that is holding still, so a prime that only
// waits for reports can miss one resting since boot. A later slight shift then
// looked like a fresh press, cancelled the countdown, and the board never
// streamed.
static int silentRestingFingerStillStreams() {
  resetObservations();
  wadProblem = nullptr;
  touchAvailable = true;
  const wifiselector::SelectorLayout layout = menuLayout();
  const wifiselector::Rect row = layout.rowRect(1);
  const int16_t x = (int16_t)(row.x + row.width / 2);
  const int16_t y = (int16_t)(row.y + row.height / 2);
  uint16_t rawX = 0, rawY = 0;
  rawFor(x, y, rawX, rawY);
  const uint32_t t = fakeNow;
  // On the glass since before the menu, never lifted, and reported only once,
  // when it shifts a little a second into the menu.
  fingers.push_back({t - 300, 0, rawX, rawY});
  touchReports.push_back({t + 1000, true, (uint16_t)(rawX + 4), rawY});
  CHECK(runMenu(false) == MenuRun::Returned);
  CHECK(Serial.captured.find("cancelled the countdown") == std::string::npos);
  CHECK(Serial.captured.find("boot menu: streaming (countdown ended)") !=
        std::string::npos);
  return 0;
}

// The other side of the prime: a finger that lifts while it is looking is
// gone, and the next real tap on the menu counts.
static int fingerLiftedDuringPrimeThenTapCounts() {
  resetObservations();
  wadProblem = nullptr;
  touchAvailable = true;
  const wifiselector::SelectorLayout layout = menuLayout();
  const wifiselector::Rect row = layout.rowRect(1);
  const uint32_t t = fakeNow;
  touchHeld(t - 300, t + 30, (int16_t)(row.x + row.width / 2),
            (int16_t)(row.y + row.height / 2));
  touchTap(t + 1500, layout.rowRect(0));
  touchTap(t + 3000, layout.connect);
  CHECK(runMenu(false) == MenuRun::Returned);
  CHECK(Serial.captured.find("boot menu: press cancelled the countdown") !=
        std::string::npos);
  CHECK(Serial.captured.find("countdown ended") == std::string::npos);
  CHECK(Serial.captured.find("boot menu: streaming (chosen)") !=
        std::string::npos);
  return 0;
}

// Round-3 finding 2: after a press-and-turn the BOOT release never reaches the
// menu as a press, so the turn rule went on treating that press as held and
// every later turn was spent - the knob was dead.
static int knobWorksAfterPressAndTurn() {
  resetObservations();
  wadProblem = nullptr;
  const uint32_t t = fakeNow;
  script = {{t + 1000, ScriptedInput::BootDown, 0, 0},
            {t + 1200, ScriptedInput::KnobTurn, 1, 0},
            {t + 1400, ScriptedInput::BootUp, 0, 0},
            // Later, separate turns move the highlight, then a hold chooses.
            {t + 2500, ScriptedInput::KnobTurn, 1, 0},
            {t + 4000, ScriptedInput::BootDown, 0, 0}};
  std::string serial;
  const MenuRun run = runMenuOnKnob(serial);
  releaseBoot(t + 5000);
  CHECK(run == MenuRun::Restarted);
  CHECK(serial.find("boot menu: DOOM highlighted") != std::string::npos);
  CHECK(fakeNvsBools.count("doomonce") == 1);
  return 0;
}

static int bootPressesThenHoldChooseDoom() {
  resetObservations();
  wadProblem = nullptr;
  const uint32_t t = fakeNow;
  script = {{t + 500, ScriptedInput::BootDown, 0, 0},   // cancels only
            {t + 600, ScriptedInput::BootUp, 0, 0},
            {t + 800, ScriptedInput::BootDown, 0, 0},   // moves to DOOM
            {t + 900, ScriptedInput::BootUp, 0, 0},
            {t + 1200, ScriptedInput::BootDown, 0, 0},  // held: chooses
            {t + 2200, ScriptedInput::BootUp, 0, 0}};
  CHECK(runMenu(false) == MenuRun::Restarted);
  // Chosen while still held, at the long-press threshold.
  CHECK(fakeNow - t >= 1800);
  CHECK(fakeNow - t < 1900);
  CHECK(menuSelected == 1);
  CHECK(menuMessage == "STARTING DOOM");
  CHECK(fakeNvsBools.count("doomonce") == 1);
  CHECK(fakeNvsBools["doomonce"]);
  CHECK(ESP.restarts == 1);
  CHECK(Serial.captured.find("boot menu: DOOM highlighted") !=
        std::string::npos);
  releaseBoot(t + 2200);
  return 0;
}

static int touchCancelRowThenStartChoosesDoom() {
  resetObservations();
  wadProblem = nullptr;
  touchAvailable = true;
  const wifiselector::SelectorLayout layout = menuLayout();
  CHECK(layout.visibleCount == 2);
  const uint32_t t = fakeNow;
  // The first tap - even on the DOOM row - only cancels the countdown.
  touchTap(t + 500, layout.rowRect(1));
  touchTap(t + 900, layout.rowRect(1));
  touchTap(t + 1300, layout.connect);
  CHECK(runMenu(false) == MenuRun::Restarted);
  CHECK(Serial.captured.find("boot menu: press cancelled the countdown") !=
        std::string::npos);
  CHECK(Serial.captured.find("boot menu: tap spent on the cancel") !=
        std::string::npos);
  CHECK(Serial.captured.find("boot menu: touch highlighted DOOM") !=
        std::string::npos);
  CHECK(Serial.captured.rfind("cancelled the countdown") <
        Serial.captured.find("touch highlighted DOOM"));
  CHECK(fakeNvsBools.count("doomonce") == 1);
  return 0;
}

static int touchAloneDrivesTheMenuToStreaming() {
  resetObservations();
  wadProblem = nullptr;
  touchAvailable = true;
  const wifiselector::SelectorLayout layout = menuLayout();
  const int height = PANEL_GEOMETRY.frameHeight(panelLandscape);
  const uint32_t t = fakeNow;
  // A tap outside every control cancels; START, much later, chooses.
  touchPress(t + 2500, TAP_MS, 2, (int16_t)(height / 2));
  touchTap(t + 600000u, layout.connect);
  CHECK(runMenu(false) == MenuRun::Returned);
  CHECK(fakeNow - t >= 600000u);
  CHECK(fakeNow - t < 600100u);
  CHECK(ESP.restarts == 0);
  CHECK(fakeNvsBools.count("doomonce") == 0);
  CHECK(Serial.captured.find("boot menu: streaming (chosen)") !=
        std::string::npos);
  return 0;
}

// NVS refusing the handoff must leave the board on the menu, saying so, rather
// than restarting into a Doom boot that will find no request. The user can then
// still choose STREAMING.
static int doomSaveFailureKeepsTheMenuUp() {
  resetObservations();
  wadProblem = nullptr;
  touchAvailable = true;
  const wifiselector::SelectorLayout layout = menuLayout();
  const uint32_t t = fakeNow;
  touchTap(t + 300, layout.rowRect(1));   // cancels
  touchTap(t + 500, layout.rowRect(1));   // highlights DOOM
  touchTap(t + 900, layout.connect);      // fails to save
  touchTap(t + 1300, layout.rowRect(0));  // highlights STREAMING
  touchTap(t + 1700, layout.connect);     // streams
  fakeNvsWritesFail = true;
  CHECK(runMenu(false) == MenuRun::Returned);
  CHECK(ESP.restarts == 0);
  CHECK(fakeNvsBools.count("doomonce") == 0);
  CHECK(Serial.captured.find("boot menu: Doom request could not be saved") !=
        std::string::npos);
  CHECK(Serial.captured.find("boot menu: streaming (chosen)") !=
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
      touchSource.find("handleBootMenuTap(event.startX, event.startY,");
  const size_t wakeSwallow = touchSource.find("touchConsumed = true;");
  const size_t senderReport =
      touchSource.find("dispatchTouchGesture(event.gesture, event.startX");
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

// Rule: with a usable pak the menu offers Quake third, and an untouched menu
// still streams without saving any game request.
static int validPakOffersQuake() {
  resetObservations();
  wadProblem = nullptr;
  pakProblem = nullptr;
  CHECK(runMenu(false) == MenuRun::Returned);
  CHECK(menuLabels == "STREAMING,DOOM,QUAKE");
  CHECK(pakPreflightCalls == 1);
  CHECK(fakeNvsBools.count("quakeonce") == 0);
  CHECK(fakeNvsBools.count("doomonce") == 0);
  CHECK(Serial.captured.find("boot menu: power-on, 3 modes, streaming in 5s") !=
        std::string::npos);
  return 0;
}

// Rule: an unusable pak is reported and Quake is left out; Doom is unaffected.
static int unusablePakLeavesQuakeOut() {
  resetObservations();
  wadProblem = nullptr;
  pakProblem = "no PACK header";
  CHECK(runMenu(false) == MenuRun::Returned);
  CHECK(menuLabels == "STREAMING,DOOM");
  CHECK(Serial.captured.find("boot menu: Quake not offered (no PACK header)") !=
        std::string::npos);
  return 0;
}

// Rule: Quake alone is a menu: no WAD, a usable pak.
static int quakeWithoutWadStillOpensTheMenu() {
  resetObservations();
  wadProblem = "no doom_wad partition";
  pakProblem = nullptr;
  CHECK(runMenu(false) == MenuRun::Returned);
  CHECK(menuLabels == "STREAMING,QUAKE");
  CHECK(Serial.captured.find("boot menu: Doom not offered") !=
        std::string::npos);
  return 0;
}

// Rule: choosing QUAKE saves its own one-shot request and restarts, exactly as
// DOOM does; nothing asks for Doom.
static int bootPressesThenHoldChooseQuake() {
  resetObservations();
  wadProblem = nullptr;
  pakProblem = nullptr;
  const uint32_t t = fakeNow;
  script = {{t + 500, ScriptedInput::BootDown, 0, 0},   // cancels only
            {t + 600, ScriptedInput::BootUp, 0, 0},
            {t + 800, ScriptedInput::BootDown, 0, 0},   // moves to DOOM
            {t + 900, ScriptedInput::BootUp, 0, 0},
            {t + 1100, ScriptedInput::BootDown, 0, 0},  // moves to QUAKE
            {t + 1200, ScriptedInput::BootUp, 0, 0},
            {t + 1500, ScriptedInput::BootDown, 0, 0},  // held: chooses
            {t + 2500, ScriptedInput::BootUp, 0, 0}};
  CHECK(runMenu(false) == MenuRun::Restarted);
  CHECK(menuSelected == 2);
  CHECK(menuMessage == "STARTING QUAKE");
  CHECK(fakeNvsBools.count("quakeonce") == 1);
  CHECK(fakeNvsBools["quakeonce"]);
  CHECK(fakeNvsBools.count("doomonce") == 0);
  CHECK(ESP.restarts == 1);
  CHECK(Serial.captured.find(
            "boot menu: Quake chosen; restarting into isolated mode") !=
        std::string::npos);
  releaseBoot(t + 2500);
  return 0;
}

// Rule: a Quake request that cannot be saved keeps the menu up, as Doom's does.
static int quakeSaveFailureKeepsTheMenuUp() {
  resetObservations();
  wadProblem = nullptr;
  pakProblem = nullptr;
  touchAvailable = true;
  const wifiselector::SelectorLayout layout = menuLayout(3);
  const uint32_t t = fakeNow;
  touchTap(t + 300, layout.rowRect(2));   // cancels
  touchTap(t + 500, layout.rowRect(2));   // highlights QUAKE
  touchTap(t + 900, layout.connect);      // fails to save
  touchTap(t + 1300, layout.rowRect(0));  // highlights STREAMING
  touchTap(t + 1700, layout.connect);     // streams
  fakeNvsWritesFail = true;
  CHECK(runMenu(false) == MenuRun::Returned);
  CHECK(ESP.restarts == 0);
  CHECK(fakeNvsBools.count("quakeonce") == 0);
  CHECK(Serial.captured.find("boot menu: Quake request could not be saved") !=
        std::string::npos);
  return 0;
}

// Rule: a board Quake does not run on never reads the quake_pak partition,
// even in an image that carries Quake (the 0.85, whose 128x128 panel cannot
// hold a 320x240 frame).
static int nonQuakeBoardNeverReadsThePak() {
  resetObservations();
  const board::Variant saved = boardVariant;
  boardVariant = board::Variant::LcdGc9107;
  wadProblem = nullptr;
  pakProblem = nullptr;
  CHECK(runMenu(false) == MenuRun::Returned);
  boardVariant = saved;
  CHECK(menuLabels == "STREAMING,DOOM");
  CHECK(pakPreflightCalls == 0);
  return 0;
}

// Rule: the S3 boards with a big enough panel ask the pak check, which is
// where a 16 MiB chip says no; a 32 MiB one with the pak offers Quake.
static int s3QuakeBoardsAskThePakCheck() {
  const board::Variant saved = boardVariant;
  for (board::Variant variant :
       {board::Variant::AmoledCo5300, board::Variant::LcdSt77916}) {
    resetObservations();
    boardVariant = variant;
    wadProblem = nullptr;
    pakProblem = "flash too small for Quake's data (needs 32 MiB)";
    CHECK(runMenu(false) == MenuRun::Returned);
    CHECK(menuLabels == "STREAMING,DOOM");
    CHECK(pakPreflightCalls == 1);
    CHECK(Serial.captured.find("boot menu: Quake not offered (flash too small "
                               "for Quake's data (needs 32 MiB))") !=
          std::string::npos);
    resetObservations();
    pakProblem = nullptr;
    CHECK(runMenu(false) == MenuRun::Returned);
    CHECK(menuLabels == "STREAMING,DOOM,QUAKE");
  }
  boardVariant = saved;
  return 0;
}

// Rule: each WAD in the game store is its own row, after the bundled DOOM and
// before QUAKE, labelled by its name.
static int storedWadsAreRowsOfTheirOwn() {
  resetObservations();
  wadProblem = nullptr;
  pakProblem = nullptr;
  storedWads = {"freedoom1.wad", "miniwad.wad"};
  CHECK(runMenu(false) == MenuRun::Returned);
  CHECK(menuLabels == "STREAMING,DOOM,FREEDOOM1,MINIWAD,QUAKE");
  CHECK(storedWadPreflightCalls == 1);
  CHECK(fakeNvsStrings.empty());
  return 0;
}

// Rule: stored WADs are offered even when the bundled one is not, and a
// stored WAD the Doom boot would refuse is reported.
static int storedWadsWithoutTheBundledOne() {
  resetObservations();
  wadProblem = "WAD header missing";
  pakProblem = NO_PAK;
  storedWads = {"miniwad.wad"};
  storedWadProblem = "WAD lump outside the file";
  CHECK(runMenu(false) == MenuRun::Returned);
  CHECK(menuLabels == "STREAMING,MINIWAD");
  CHECK(Serial.captured.find(
            "boot menu: a stored WAD not offered (WAD lump outside the file)") !=
        std::string::npos);
  return 0;
}

// Rule: choosing a stored WAD saves its name with Doom's one-shot request, so
// the Doom boot plays that file; choosing DOOM saves no name.
static int choosingAStoredWadNamesIt() {
  resetObservations();
  wadProblem = nullptr;
  pakProblem = NO_PAK;
  storedWads = {"freedoom1.wad", "miniwad.wad"};
  touchAvailable = true;
  const wifiselector::SelectorLayout layout = menuLayout(4);
  const uint32_t t = fakeNow;
  touchTap(t + 300, layout.rowRect(3));  // cancels
  touchTap(t + 500, layout.rowRect(3));  // highlights MINIWAD
  touchTap(t + 900, layout.connect);     // chooses it
  CHECK(runMenu(false) == MenuRun::Restarted);
  CHECK(menuMessage == "STARTING MINIWAD");
  CHECK(fakeNvsBools.count("doomonce") == 1);
  CHECK(fakeNvsStrings.count("doomwad") == 1);
  CHECK(fakeNvsStrings["doomwad"] == "miniwad.wad");
  CHECK(Serial.captured.find("boot menu: miniwad.wad chosen") !=
        std::string::npos);

  resetObservations();
  wadProblem = nullptr;
  storedWads = {"miniwad.wad"};
  fakeNvsStrings["doomwad"] = "stale.wad";
  touchAvailable = true;
  const wifiselector::SelectorLayout three = menuLayout(3);
  const uint32_t u = fakeNow;
  touchTap(u + 300, three.rowRect(1));  // cancels
  touchTap(u + 500, three.rowRect(1));  // highlights DOOM
  touchTap(u + 900, three.connect);     // chooses it
  CHECK(runMenu(false) == MenuRun::Restarted);
  CHECK(menuMessage == "STARTING DOOM");
  CHECK(fakeNvsBools.count("doomonce") == 1);
  CHECK(fakeNvsStrings.count("doomwad") == 0);
  return 0;
}

// Rule: CFGGAME picks a boot-menu row by its label, over serial, exactly as
// choosing it on the menu does; a label the menu does not offer starts nothing.
static int serialChoosesAMenuRowByLabel() {
  resetObservations();
  wadProblem = nullptr;
  pakProblem = nullptr;
  storedWads = {"freedoom1.wad", "miniwad.wad"};
  ESP.throwOnRestart = true;
  bool restarted = false;
  try {
    (void)chooseBootMenuEntry("miniwad");
  } catch (const FakeRestart &) {
    restarted = true;
  }
  ESP.throwOnRestart = false;
  bootMenuActive = false;
  CHECK(restarted);
  CHECK(fakeNvsStrings["doomwad"] == "miniwad.wad");
  CHECK(fakeNvsBools.count("doomonce") == 1);

  resetObservations();
  wadProblem = nullptr;
  pakProblem = nullptr;
  ESP.throwOnRestart = true;
  restarted = false;
  try {
    (void)chooseBootMenuEntry("QUAKE");
  } catch (const FakeRestart &) {
    restarted = true;
  }
  ESP.throwOnRestart = false;
  bootMenuActive = false;
  CHECK(restarted);
  CHECK(fakeNvsBools.count("quakeonce") == 1);
  CHECK(fakeNvsStrings.count("doomwad") == 0);

  resetObservations();
  wadProblem = nullptr;
  CHECK(chooseBootMenuEntry("FREEDOOM2") == BootMenuSerialChoice::NotOffered);
  CHECK(ESP.restarts == 0);
  CHECK(fakeNvsBools.empty());
  CHECK(Serial.captured.find("boot menu: no FREEDOOM2 row") != std::string::npos);

  // A request that cannot be saved starts nothing, says so, and draws no
  // menu over the streaming panel.
  resetObservations();
  wadProblem = nullptr;
  fakeNvsWritesFail = true;
  CHECK(chooseBootMenuEntry("DOOM") == BootMenuSerialChoice::SaveFailed);
  CHECK(ESP.restarts == 0);
  CHECK(menuDraws == 0);
  CHECK(chooseBootMenuEntry("streaming") == BootMenuSerialChoice::Streaming);
  CHECK(menuDraws == 0);
  return 0;
}

// Rule: a stored WAD whose name cannot be saved starts nothing: no Doom
// request is left to boot the wrong WAD.
static int storedWadSaveFailureStartsNothing() {
  resetObservations();
  wadProblem = nullptr;
  pakProblem = NO_PAK;
  storedWads = {"miniwad.wad"};
  touchAvailable = true;
  const wifiselector::SelectorLayout layout = menuLayout(3);
  const uint32_t t = fakeNow;
  touchTap(t + 300, layout.rowRect(2));   // cancels
  touchTap(t + 500, layout.rowRect(2));   // highlights MINIWAD
  touchTap(t + 900, layout.connect);      // fails to save
  touchTap(t + 1300, layout.rowRect(0));  // highlights STREAMING
  touchTap(t + 1700, layout.connect);     // streams
  fakeNvsWritesFail = true;
  CHECK(runMenu(false) == MenuRun::Returned);
  CHECK(ESP.restarts == 0);
  CHECK(fakeNvsBools.count("doomonce") == 0);
  CHECK(fakeNvsStrings.count("doomwad") == 0);
  return 0;
}

// The knob carrier has no speaker, so its knob drives the Mac's volume: each
// detent reports one knob turn to the sender, a click reports one knob press
// (the Mac's mute toggle), and neither moves or saves the backlight the knob
// used to step. On the carrier's real profile, through its encoder and BOOT
// interrupts and the real input_touch.cpp sender.
// Sets the map the way an EMAP from the sender does: one function per input,
// from input 1, the rest left at the board's defaults.
static bool setInputMap(const std::vector<uint8_t> &functions) {
  std::vector<uint8_t> packet = {'E', 'M', 'A', 'P',
                                 deviceproto::INPUT_MAP_VERSION,
                                 (uint8_t)functions.size(), 0, 0};
  packet.insert(packet.end(), functions.begin(), functions.end());
  if (!offerInputMap(packet.data(), packet.size())) return false;
  applyPendingInputMap();
  return true;
}

// Inputs 1-9 (gestures and knob) left with the sender, then BOOT's single,
// double, triple, long and extra-long, then the power key's press and hold.
static std::vector<uint8_t> mapWithBoot(uint8_t single, uint8_t twice,
                                        uint8_t thrice, uint8_t hold,
                                        uint8_t extraHold) {
  return {1, 1, 1, 1, 1, 1, 1, 1, 1, single, twice, thrice, hold, extraHold};
}

static std::vector<uint8_t> sentInputs() {
  std::vector<uint8_t> inputs;
  for (const std::vector<uint8_t> &packet : sentPackets) {
    deviceproto::TouchEvent event;
    if (deviceproto::parseTouch(packet.data(), packet.size(), event)) {
      inputs.push_back((uint8_t)event.gesture);
    }
  }
  return inputs;
}

static std::vector<deviceproto::TouchGesture> sentKnobGestures(
    std::vector<uint16_t> *sequences = nullptr) {
  std::vector<deviceproto::TouchGesture> gestures;
  for (const std::vector<uint8_t> &packet : sentPackets) {
    deviceproto::TouchEvent event;
    if (!deviceproto::parseTouch(packet.data(), packet.size(), event)) continue;
    gestures.push_back(event.gesture);
    if (sequences != nullptr) sequences->push_back(event.sequence);
  }
  return gestures;
}

static int knobTurnIsVolumeAndClickIsMute() {
  using deviceproto::TouchGesture;
  const board::Variant savedVariant = boardVariant;
  const board::Config *savedConfig = bcfg;
  boardVariant = board::Variant::ElecrowKnob128;
  bcfg = &board::configFor(boardVariant);
  fakePinLevel.clear();
  fakePinIsr.clear();
  initializeButtonInput();
  resetObservations();
  hbPort = 4210;
  sentPackets.clear();
  const uint8_t blBefore = userBlLevel;

  // Two detents clockwise, then one back: one report per detent, on the
  // touch sequence so the sender's duplicate filter covers them.
  knobDetent(true);
  knobDetent(true);
  handleButton();
  knobDetent(false);
  handleButton();
  std::vector<uint16_t> sequences;
  std::vector<TouchGesture> got = sentKnobGestures(&sequences);
  CHECK(got.size() == 3);
  CHECK(got[0] == TouchGesture::KnobClockwise);
  CHECK(got[1] == TouchGesture::KnobClockwise);
  CHECK(got[2] == TouchGesture::KnobCounterclockwise);
  CHECK(sequences[1] == (uint16_t)(sequences[0] + 1));
  CHECK(sequences[2] == (uint16_t)(sequences[1] + 1));

  // A stall that piles up detents still sends a bounded burst.
  sentPackets.clear();
  for (int i = 0; i < 9; ++i) knobDetent(true);
  handleButton();
  CHECK(sentKnobGestures().size() == 4);

  // A click is one mute toggle, and its double-press window closing sends
  // nothing more. The click is the knob's mute, not the status screen.
  sentPackets.clear();
  shortPress();
  got = sentKnobGestures();
  CHECK(got.size() == 1 && got[0] == TouchGesture::KnobPress);
  CHECK(!surveyActive);
  fakeNow += 1000;
  handleButton();
  CHECK(sentKnobGestures().size() == 1);

  // A double click opens the WiFi selector, and toggles mute twice, so mute
  // ends where it started.
  sentPackets.clear();
  shortPress();
  shortPress();
  got = sentKnobGestures();
  CHECK(got.size() == 2);
  CHECK(got[0] == TouchGesture::KnobPress && got[1] == TouchGesture::KnobPress);
  CHECK(wifiSelectorActive);
  wifiSelectorActive = false;
  surveyActive = false;

  // A click the sender gave a function a second click does not undo is
  // counted out: a double click is the double alone, never two of the
  // single. And a turn given to a board function runs it once per turn.
  resetObservations();
  hbPort = 4210;
  {
    std::vector<uint8_t> functions = mapWithBoot(0, 3, 0, 5, 6);
    std::vector<uint8_t> packet = {'E', 'M', 'A', 'P', 1,
                                   (uint8_t)functions.size(),
                                   deviceproto::INPUT_MAP_FLAG_COUNT_PRESSES, 0};
    packet.insert(packet.end(), functions.begin(), functions.end());
    CHECK(offerInputMap(packet.data(), packet.size()));
    applyPendingInputMap();
  }
  CHECK(!bootShortPressesAsDefault());
  sentPackets.clear();
  shortPress();
  shortPress();
  CHECK(sentKnobGestures().empty());
  CHECK(wifiSelectorActive);
  // Closing the selector leaves the status screen it opened over.
  wifiSelectorActive = false;
  surveyActive = false;
  shortPress();
  CHECK(sentKnobGestures().empty());
  fakeNow += 900;
  handleButton();
  got = sentKnobGestures();
  CHECK(got.size() == 1 && got[0] == TouchGesture::KnobPress);
  CHECK(setInputMap({1, 1, 1, 1, 1, 1, 5}));
  for (int i = 0; i < 3; ++i) {
    knobDetent(true);
    handleButton();
    fakeNow += 40;
  }
  CHECK(panelRotation == 2);
  fakeNow += 400;
  knobDetent(true);
  handleButton();
  CHECK(panelRotation == 0);
  surveyActive = false;
  displayPrefSaves = 0;  // the turns' rotations; the checks below are the knob's own
  CHECK(setInputMap({}));  // back to the defaults for the checks below

  // Nothing the knob did touched the backlight.
  CHECK(userBlLevel == blBefore);
  CHECK(displayPrefSaves == 0);
  CHECK(Serial.captured.find("backlight") == std::string::npos);

  // A turn just after the click was let go, while its release still settles,
  // is not a turn made during the press: the click still mutes.
  sentPackets.clear();
  fakeNow += 1000;
  handleButton();
  bootIsrAt(true);
  handleButton();
  fakeNow += 100;
  bootIsrAt(false);
  handleButton();
  fakeNow += 10;
  knobDetent(true);
  handleButton();
  fakeNow += 40;
  handleButton();
  got = sentKnobGestures();
  CHECK(got.size() == 2);
  CHECK(got.size() == 2 && got[0] == TouchGesture::KnobClockwise &&
        got[1] == TouchGesture::KnobPress);
  CHECK(Serial.captured.find("press released after a turn") ==
        std::string::npos);
  fakeNow += 1000;
  handleButton();

  // A click, a turn and a click are two mutes, not a double click: the turn
  // settles the first click's window.
  sentPackets.clear();
  fakeNow += 1000;
  handleButton();
  shortPress();
  knobDetent(true);
  handleButton();
  shortPress();
  got = sentKnobGestures();
  CHECK(got.size() == 3);
  CHECK(got[0] == TouchGesture::KnobPress &&
        got[1] == TouchGesture::KnobClockwise &&
        got[2] == TouchGesture::KnobPress);
  CHECK(!wifiSelectorActive);
  fakeNow += 1000;
  handleButton();

  // With no sender yet there is nowhere to report to; the log says so.
  sentPackets.clear();
  hbPort = 0;
  knobDetent(true);
  handleButton();
  CHECK(sentPackets.empty());
  CHECK(Serial.captured.find("knob: clockwise ignored, no sender") !=
        std::string::npos);
  hbPort = 4210;

  // A fixed backlight disables the backlight toggle, never the mute click.
  resetObservations();
  sentPackets.clear();
  fixedBlLevel = 120;
  shortPress();
  got = sentKnobGestures();
  CHECK(got.size() == 1 && got[0] == TouchGesture::KnobPress);
  fixedBlLevel = 0;

  // Press-and-turn is one gesture outside the menus too: the turn steps the
  // volume and the release mutes nothing.
  resetObservations();
  sentPackets.clear();
  bootEdge(true);
  fakeNow += 100;
  knobDetent(true);
  handleButton();
  fakeNow += 100;
  bootEdge(false);
  fakeNow += 1000;
  handleButton();
  got = sentKnobGestures();
  CHECK(got.size() == 1 && got[0] == TouchGesture::KnobClockwise);
  CHECK(Serial.captured.find("press released after a turn") !=
        std::string::npos);

  // A refused triple press: presses one and two mute and unmute, the third
  // sends nothing, and the selector their double opened is closed again.
  resetObservations();
  sentPackets.clear();
  wadProblem = "no doom_wad partition";
  shortPress();
  shortPress();
  shortPress();
  got = sentKnobGestures();
  CHECK(got.size() == 2);
  CHECK(got[0] == TouchGesture::KnobPress && got[1] == TouchGesture::KnobPress);
  CHECK(!surveyActive);
  CHECK(!wifiSelectorActive);
  CHECK(ESP.restarts == 0);
  CHECK(Serial.captured.find("button: Doom unavailable") != std::string::npos);
  wadProblem = nullptr;
  hbPort = 0;

  boardVariant = savedVariant;
  bcfg = savedConfig;
  fakePinIsr.clear();
  initializeButtonInput();
  return 0;
}

// CFGTOUCHLOG: a press is logged once, raw and mapped, and marked where it
// mapped, and nothing else acts on it - a corner tap on the survey card would
// otherwise land on its preset button and open the WiFi selector.
static void serviceTouchFor(uint32_t ms) {
  for (const uint32_t until = fakeNow + ms; fakeNow < until; fakeNow += 10) {
    serviceTouch();
  }
}

static int touchLogOnlyLogsAndMarks() {
  resetObservations();
  touchAvailable = true;
  hbPort = 4210;
  sentPackets.clear();
  touchMarkers.clear();
  // A quarter turn, so the raw and mapped points differ and logging or
  // marking the wrong one shows: (700,15) is raw (704,700) at rotation 1.
  appliedPanelRotation = 1;

  // Off: the tap reaches the sender and leaves no marker.
  touchPress(fakeNow + 100, 50, 10, 20);
  serviceTouchFor(400);
  CHECK(sentPackets.size() == 1);
  CHECK(touchMarkers.empty());
  CHECK(Serial.captured.find("touchlog:") == std::string::npos);

  touchLogEnabled = true;
  sentPackets.clear();
  touchPress(fakeNow + 100, 50, 700, 15);
  serviceTouchFor(400);
  CHECK(sentPackets.empty());
  CHECK(touchMarkers.size() == 1);
  CHECK(touchMarkers[0].first == 700 && touchMarkers[0].second == 15);
  const size_t at = Serial.captured.find(
      "touchlog: raw=(704,700) mapped=(700,15) frame=720x720 rot=1 "
      "addressed=1");
  CHECK(at != std::string::npos);
  CHECK(Serial.captured.find("touchlog:", at + 1) == std::string::npos);

  // A hold long enough for a long press is still only logged once.
  touchHeld(fakeNow + 100, fakeNow + 2100, 360, 360);
  serviceTouchFor(2400);
  CHECK(sentPackets.empty());
  CHECK(!wifiSelectorActive);
  CHECK(touchMarkers.size() == 2);

  // A dimmed status card is lit, without the press being spent as a wake.
  idleActive = true;
  backlightApplies = 0;
  touchPress(fakeNow + 100, 50, 10, 20);
  serviceTouchFor(400);
  CHECK(backlightApplies > 0);
  CHECK(Serial.captured.find("touch: wake") == std::string::npos);
  CHECK(touchMarkers.size() == 3);

  // The survey card keeps its own brightness, as the real wake leaves it.
  surveyActive = true;
  touchWakeUntil = 0;
  backlightApplies = 0;
  touchPress(fakeNow + 100, 50, 10, 20);
  serviceTouchFor(400);
  CHECK(backlightApplies == 0);
  CHECK(touchMarkers.size() == 4);
  surveyActive = false;
  idleActive = false;
  touchWakeUntil = 0;

  // A press that began logged stays logged after the toggle goes off: its
  // hold, still down, sends no long press.
  touchHeld(fakeNow + 10, fakeNow + 1500, 10, 20);
  serviceTouchFor(100);
  touchLogEnabled = false;
  serviceTouchFor(1800);
  CHECK(sentPackets.empty());
  CHECK(touchMarkers.size() == 5);

  // A wake press that began unlogged is still a wake once the toggle comes
  // on, and its release leaves nothing to eat the next tap.
  idleActive = true;
  touchHeld(fakeNow + 10, fakeNow + 1500, 10, 20);
  serviceTouchFor(100);
  CHECK(Serial.captured.find("touch: wake") != std::string::npos);
  touchLogEnabled = true;
  serviceTouchFor(1800);
  touchLogEnabled = false;
  idleActive = false;
  touchPress(fakeNow + 100, 50, 10, 20);
  serviceTouchFor(400);
  CHECK(sentPackets.size() == 1);
  CHECK(touchMarkers.size() == 5);

  appliedPanelRotation = 0;
  hbPort = 0;
  touchAvailable = false;
  return 0;
}

// ---- The input map outside the menus ------------------------------------
static int defaultMapIsTodaysBehaviour() {
  resetObservations();
  loadInputMap();
  CHECK(Serial.captured.find("input map: 1111111112345600 (defaults)") !=
        std::string::npos);
  CHECK(bootShortPressesAsDefault());
  // Choosing today's map from the sender stores no map at all.
  CHECK(setInputMap(mapWithBoot(2, 3, 4, 5, 6)));
  CHECK(fakeNvsBytes.count("inmap") == 0);
  return 0;
}

static int remappedSingleWaitsOutTheDoubleWindow() {
  resetObservations();
  // The single turns the picture; double and triple keep their jobs, so a
  // single must wait to be sure it is not the start of one.
  CHECK(setInputMap(mapWithBoot(5, 3, 4, 5, 6)));
  CHECK(!bootShortPressesAsDefault());
  CHECK(fakeNvsBytes.count("inmap") == 1);
  shortPress();
  CHECK(panelRotation == 0);
  CHECK(!surveyActive);
  fakeNow += 900;
  handleButton();
  CHECK(panelRotation == 2);
  CHECK(!surveyActive);
  // Two presses are the double alone: the selector, and no turn.
  shortPress();
  shortPress();
  fakeNow += 900;
  handleButton();
  CHECK(wifiSelectorActive);
  CHECK(selectorOpens == 1);
  CHECK(panelRotation == 2);
  wifiSelectorActive = false;
  panelRotation = 0;
  return 0;
}

static int remappedSingleWithNothingAboveActsAtOnce() {
  resetObservations();
  CHECK(setInputMap(mapWithBoot(6, 0, 0, 5, 6)));
  shortPress();
  CHECK(panelManuallyOff);
  shortPress();
  CHECK(!panelManuallyOff);
  CHECK(!surveyActive);
  CHECK(selectorOpens == 0);
  return 0;
}

static int theStatusScreenKeepsItsPress() {
  resetObservations();
  CHECK(setInputMap(mapWithBoot(5, 0, 0, 5, 6)));
  surveyActive = true;
  shortPress();
  CHECK(!surveyActive);
  CHECK(panelRotation == 0);
  return 0;
}

static int holdsFollowTheMap() {
  resetObservations();
  CHECK(setInputMap(mapWithBoot(2, 3, 4, 6, 0)));
  // The long hold now turns the display off, and nothing turns it.
  bootEdge(true);
  fakeNow += 700;
  bootEdge(false);
  CHECK(panelManuallyOff);
  CHECK(panelRotation == 0);
  // The extra-long hold does nothing.
  panelManuallyOff = false;
  bootEdge(true);
  serviceButtonFor(3500);
  bootEdge(false);
  CHECK(!panelManuallyOff);
  CHECK(panelRotation == 0);
  return 0;
}

static int bootInputsGivenToTheSenderAreReported() {
  resetObservations();
  hbPort = 4210;
  sentPackets.clear();
  CHECK(setInputMap(mapWithBoot(1, 0, 0, 1, 6)));
  shortPress();
  bootEdge(true);
  fakeNow += 700;
  bootEdge(false);
  const std::vector<uint8_t> got = sentInputs();
  CHECK(got.size() == 2);
  CHECK(got[0] == (uint8_t)deviceproto::TouchGesture::BootSinglePress);
  CHECK(got[1] == (uint8_t)deviceproto::TouchGesture::BootLongPress);
  CHECK(!surveyActive);
  CHECK(panelRotation == 0);
  hbPort = 0;
  return 0;
}

static int touchGivenToTheBoardRunsThere() {
  resetObservations();
  touchAvailable = true;
  hbPort = 4210;
  sentPackets.clear();
  // A tap turns the picture here; the swipes stay the sender's.
  CHECK(setInputMap({5}));
  touchPress(fakeNow + 100, 50, 360, 360);
  serviceTouchFor(400);
  CHECK(panelRotation == 2);
  CHECK(sentInputs().empty());
  CHECK(infoBarShown.empty());
  // Given back to the sender, the tap is reported with the info bar again.
  CHECK(setInputMap({1}));
  touchPress(fakeNow + 100, 50, 360, 360);
  serviceTouchFor(400);
  const std::vector<uint8_t> got = sentInputs();
  CHECK(got.size() == 1 && got[0] == (uint8_t)deviceproto::TouchGesture::Tap);
  panelRotation = 0;
  touchAvailable = false;
  hbPort = 0;
  return 0;
}

// A 3-second hold given to a screen opens it and ends there: the rest of the
// hold does not choose a network in the selector it opened (which would
// switch WiFi and restart) or open the selector from the status screen.
static int extraLongHoldToAScreenSpendsTheHold() {
  resetObservations();
  CHECK(setInputMap(mapWithBoot(2, 3, 4, 5, 3)));
  bootEdge(true);
  serviceButtonFor(4000);
  bootEdge(false);
  CHECK(wifiSelectorActive);
  CHECK(selectorOpens == 1);
  CHECK(selectorActivations == 0);
  CHECK(ESP.restarts == 0);
  wifiSelectorActive = false;

  resetObservations();
  CHECK(setInputMap(mapWithBoot(2, 3, 4, 5, 2)));
  bootEdge(true);
  serviceButtonFor(4000);
  bootEdge(false);
  CHECK(surveyActive);
  CHECK(selectorOpens == 0);
  surveyActive = false;
  return 0;
}

// A map another sender stored is not in force for a sender that never sent
// one (an app that predates maps): it gets today's behaviour. With no sender
// at all, or once this sender sends its map, the stored one applies.
static int storedMapAppliesOnlyForItsSender() {
  resetObservations();
  hbIp = 0x0108A8C0;
  hbPort = 50000;
  CHECK(setInputMap(mapWithBoot(2, 3, 4, 6, 6)));
  CHECK(inputFunctionFor(13) == 6);
  hbIp = 0x0208A8C0;  // a different Mac, which never sent EMAP
  CHECK(inputFunctionFor(13) == 5);
  bootEdge(true);
  fakeNow += 700;
  bootEdge(false);
  CHECK(panelRotation == 2);
  CHECK(!panelManuallyOff);
  hbPort = 0;  // no sender: the board's own stored map
  CHECK(inputFunctionFor(13) == 6);
  panelRotation = 0;
  hbIp = 0;
  return 0;
}

static int mapSurvivesARestartAndCanBeReset() {
  resetObservations();
  CHECK(setInputMap({0, 5}));
  CHECK(inputFunctionFor(1) == 0);
  CHECK(inputFunctionFor(2) == 5);
  CHECK(inputFunctionFor(3) == 1);
  // A restart reads it back.
  loadInputMap();
  CHECK(inputFunctionFor(2) == 5);
  CHECK(Serial.captured.find("(saved)") != std::string::npos);
  // A malformed map changes nothing; an empty one restores the defaults and
  // removes the stored copy.
  const uint8_t bad[9] = {'E', 'M', 'A', 'P', 1, 1, 0, 0, 9};
  CHECK(!offerInputMap(bad, sizeof(bad)));
  CHECK(setInputMap({}));
  CHECK(inputFunctionFor(2) == 1);
  CHECK(fakeNvsBytes.count("inmap") == 0);
  // The newest map from the same sender is saved at once, however soon it
  // follows the last one, so a restart never brings back an older map.
  CHECK(setInputMap({0, 6}));
  CHECK(inputFunctionFor(2) == 6);
  CHECK(fakeNvsBytes.count("inmap") == 1);
  CHECK(fakeNvsBytes["inmap"].size() == 17);
  CHECK(fakeNvsBytes["inmap"][1] == 6);
  CHECK(setInputMap({0, 5}));
  CHECK(fakeNvsBytes["inmap"][1] == 5);
  loadInputMap();
  CHECK(inputFunctionFor(2) == 5);

  // Two senders trading maps: used at once, but saved at most every 30 s so
  // they cannot wear NVS. A deliberate restart in that window still saves
  // the newest one first (esp_restart() runs the shutdown handler).
  fakeNow += 31000;
  hbPort = 50000;
  hbIp = 0x0108A8C0;
  CHECK(setInputMap({0, 6}));
  CHECK(fakeNvsBytes["inmap"][1] == 6);  // past the interval: at once
  hbIp = 0x0208A8C0;
  CHECK(setInputMap({0, 4}));
  CHECK(inputFunctionFor(2) == 4);
  CHECK(fakeNvsBytes["inmap"][1] == 6);  // alternating: held back
  runShutdownHandlers();
  CHECK(fakeNvsBytes["inmap"][1] == 4);
  loadInputMap();
  hbPort = 0;
  CHECK(inputFunctionFor(2) == 4);
  // ...and without a restart it lands once the interval has passed.
  fakeNow += 31000;
  hbPort = 50000;
  hbIp = 0x0108A8C0;
  CHECK(setInputMap({0, 6}));
  hbIp = 0x0208A8C0;
  CHECK(setInputMap({0, 3}));
  CHECK(fakeNvsBytes["inmap"][1] == 6);
  fakeNow += 31000;
  CHECK(applyPendingInputMap());
  CHECK(fakeNvsBytes["inmap"][1] == 3);
  // A, then B, then A again inside 30 s: once B was held back, A's next
  // change waits for the interval too, so the two cannot write on every
  // swap. The newest one lands.
  fakeNow += 31000;
  hbIp = 0x0108A8C0;
  CHECK(setInputMap({0, 6}));
  CHECK(fakeNvsBytes["inmap"][1] == 6);
  hbIp = 0x0208A8C0;
  CHECK(setInputMap({0, 3}));
  hbIp = 0x0108A8C0;
  CHECK(setInputMap({0, 4}));
  CHECK(fakeNvsBytes["inmap"][1] == 6);
  fakeNow += 31000;
  CHECK(applyPendingInputMap());
  CHECK(fakeNvsBytes["inmap"][1] == 4);
  // The same Mac back on a new port is still the same sender.
  hbPort = 50001;
  CHECK(setInputMap({0, 2}));
  CHECK(fakeNvsBytes["inmap"][1] == 2);

  // A save that fails is retried on the interval, not on every loop pass.
  fakeNvsWritesFail = true;
  Serial.captured.clear();
  CHECK(setInputMap({0, 5}));
  for (int i = 0; i < 10; ++i) {
    fakeNow += 10;
    applyPendingInputMap();
  }
  size_t attempts = 0;
  for (size_t at = Serial.captured.find("NOT saved"); at != std::string::npos;
       at = Serial.captured.find("NOT saved", at + 1)) {
    ++attempts;
  }
  CHECK(attempts == 1);
  fakeNvsWritesFail = false;
  fakeNow += 31000;
  CHECK(applyPendingInputMap());
  CHECK(fakeNvsBytes["inmap"][1] == 5);
  hbPort = 0;
  hbIp = 0;
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
  loadInputMap();
  if (defaultMapIsTodaysBehaviour() != 0) return 1;
  if (remappedSingleWaitsOutTheDoubleWindow() != 0) return 1;
  if (remappedSingleWithNothingAboveActsAtOnce() != 0) return 1;
  if (theStatusScreenKeepsItsPress() != 0) return 1;
  if (holdsFollowTheMap() != 0) return 1;
  if (bootInputsGivenToTheSenderAreReported() != 0) return 1;
  if (touchGivenToTheBoardRunsThere() != 0) return 1;
  if (mapSurvivesARestartAndCanBeReset() != 0) return 1;
  if (extraLongHoldToAScreenSpendsTheHold() != 0) return 1;
  if (storedMapAppliesOnlyForItsSender() != 0) return 1;
  if (tripleWithInvalidWadStaysNormal() != 0) return 1;
  if (touchLogOnlyLogsAndMarks() != 0) return 1;
  if (refusalKeepsASurveyThatWasOn() != 0) return 1;
  if (refusalWithFixedBacklight() != 0) return 1;
  if (tripleWithValidWadReopensBootMenu() != 0) return 1;
  if (twoPressesAreNotATriple() != 0) return 1;
  if (singlePressTogglesTheStatusScreenOnly() != 0) return 1;
  if (singlePressKeepsAnyBacklightLevel() != 0) return 1;
  if (doublePressOpensTheWifiSelector() != 0) return 1;
  if (holdsKeepTheirJobs() != 0) return 1;
  if (quickSelectorPressesAfterTheWindowAreMoves() != 0) return 1;
  if (droppedReleaseStillEndsThePress() != 0) return 1;
  if (misreadEdgesStillMakeOnePress() != 0) return 1;
  if (releaseJustBeforeAThresholdIsNotAHold() != 0) return 1;
  if (holdSeenOnlyAtReleaseLeavesTheNextPress() != 0) return 1;
  if (samplerCorrectsAWrongLastRead() != 0) return 1;
  if (closingTheStatusScreenRestoresTheBacklight() != 0) return 1;
  if (ineligibleProfileNeverChecksWad() != 0) return 1;
  if (requestIsConsumedOnce() != 0) return 1;
  if (automaticRestartSkipsMenu() != 0) return 1;
  if (untouchedPowerOnMenuStreams() != 0) return 1;
  if (unusableWadOffersNoMenu() != 0) return 1;
  if (manuallyOffPanelSkipsTimedMenuOnly() != 0) return 1;
  if (requestedMenuHasNoCountdown() != 0) return 1;
  if (firstBootPressOnlyCancels() != 0) return 1;
  if (firstHoldOnlyCancelsAndLeavesNoNormalPress() != 0) return 1;
  if (pressBegunBeforeTheMenuIsIgnored() != 0) return 1;
  if (pressDownLateInTheCountdownStaysInTheMenu() != 0) return 1;
  if (pressJustAfterTheMenuOpensCounts() != 0) return 1;
  if (touchHeldTooLongForATapStillCancels() != 0) return 1;
  if (holdBegunBeforeTheMenuChoosesNothing() != 0) return 1;
  if (fastKnobTurnOnlyCancels() != 0) return 1;
  if (touchAlreadyDownAtOpenStillStreams() != 0) return 1;
  if (knobFlickSpreadOverPassesOnlyCancels() != 0) return 1;
  if (knobPressAndTurnOnlyCancels() != 0) return 1;
  if (touchChoiceWhileBootHeldLeavesNoNormalPress() != 0) return 1;
  if (bootDownInTheLastPassLeavesNoNormalPress() != 0) return 1;
  if (silentRestingFingerStillStreams() != 0) return 1;
  if (fingerLiftedDuringPrimeThenTapCounts() != 0) return 1;
  if (knobWorksAfterPressAndTurn() != 0) return 1;
  if (knobTurnIsVolumeAndClickIsMute() != 0) return 1;
  if (bootPressesThenHoldChooseDoom() != 0) return 1;
  if (touchCancelRowThenStartChoosesDoom() != 0) return 1;
  if (touchAloneDrivesTheMenuToStreaming() != 0) return 1;
  if (doomSaveFailureKeepsTheMenuUp() != 0) return 1;
  if (menuRequestSaveFailureStaysNormal() != 0) return 1;
  if (touchRoutingReachesTheMenuFirst() != 0) return 1;
  if (validPakOffersQuake() != 0) return 1;
  if (unusablePakLeavesQuakeOut() != 0) return 1;
  if (quakeWithoutWadStillOpensTheMenu() != 0) return 1;
  if (bootPressesThenHoldChooseQuake() != 0) return 1;
  if (quakeSaveFailureKeepsTheMenuUp() != 0) return 1;
  if (nonQuakeBoardNeverReadsThePak() != 0) return 1;
  if (s3QuakeBoardsAskThePakCheck() != 0) return 1;
  if (storedWadsAreRowsOfTheirOwn() != 0) return 1;
  if (storedWadsWithoutTheBundledOne() != 0) return 1;
  if (choosingAStoredWadNamesIt() != 0) return 1;
  if (storedWadSaveFailureStartsNothing() != 0) return 1;
  if (serialChoosesAMenuRowByLabel() != 0) return 1;
  printf("test_doom_entry_gate: %d checks passed\n", checks);
  return 0;
}
