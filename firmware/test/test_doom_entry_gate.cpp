// Host test for the BOOT triple-press Doom request (display_stream/
// input_button.cpp, compiled here unmodified against fakes/doom_entry).
//
// Only a full USB flash of the bundle writes the Doom WAD; WiFi updates and
// rescue images write the app alone. A triple press on a board without a
// usable WAD must therefore stay in the normal firmware, say why on the panel
// and the serial port, and never set the one-shot Doom flag or restart.
#include <cstdio>
#include <cstring>
#include <map>
#include <string>

#include <Arduino.h>
#include <Preferences.h>
#include <driver/gpio.h>
#include <freertos/task.h>

#include <board_config.h>

#include "../display_stream/input_button.h"

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

// ---- Fakes for the Doom library -------------------------------------------
// Every third short release is a triple press; the timing window itself is
// doom_mode.cpp's and is not under test here.
static int tripleTapCalls = 0;
extern "C" bool doom_check_triple_tap(uint32_t, bool pressed) {
  if (!pressed) return false;
  return ++tripleTapCalls % 3 == 0;
}
static const char *wadProblem = nullptr;
static int preflightCalls = 0;
extern "C" const char *doom_wad_preflight(void) {
  preflightCalls++;
  return wadProblem;
}

static void bootEdge(bool down) {
  fakeBootLevel = down ? 0 : 1;
  bootIsr();
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

static int tripleWithValidWadRebootsIntoDoom() {
  resetObservations();
  wadProblem = nullptr;
  shortPress();
  shortPress();
  shortPress();
  CHECK(preflightCalls == 1);
  CHECK(fakeNvsBools.count("doomonce") == 1);
  CHECK(fakeNvsBools["doomonce"]);
  CHECK(ESP.restarts == 1);
  CHECK(Serial.captured.find(
            "button: Doom requested; rebooting into isolated mode") !=
        std::string::npos);
  CHECK(infoBarShown.empty());
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
  if (tripleWithValidWadRebootsIntoDoom() != 0) return 1;
  if (ineligibleProfileNeverChecksWad() != 0) return 1;
  printf("test_doom_entry_gate: %d checks passed\n", checks);
  return 0;
}
