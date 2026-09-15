#include "display_power.h"

#include <Arduino.h>

#include <display_backend.h>

#include "app_state.h"
#include "panel_state.h"

uint8_t BL_HIGH = 128;   // 50%, Waveshare's recommended ceiling
uint8_t BL_LOW = 24;     // ~10%
uint8_t BL_IDLE = 10;
uint8_t BL_SURVEY = 255;

bool setBrightnessLevels(uint8_t low, uint8_t high, uint8_t idle,
                         uint8_t survey) {
  if (low == 0 || high == 0 || idle == 0 || survey == 0 || low >= high) {
    return false;
  }
  BL_LOW = low;
  BL_HIGH = high;
  BL_IDLE = idle;
  BL_SURVEY = survey;
  return true;
}
// The backlight level to use when awake and being driven, 1..255. This is the
// single source of truth: the BOOT button steps it between BL_LOW and BL_HIGH,
// and the sender can set any level. Keeping one value instead of a high/low
// flag is what lets both live together without them disagreeing.
uint8_t userBlLevel = BL_HIGH;
// An installation can lock its lit brightness and stop advertising brightness
// controls. Sleep and explicit power-off still turn the panel dark.
uint8_t fixedBlLevel = 0;

uint8_t configuredBrightness() {
  return fixedBlLevel != 0 ? fixedBlLevel : userBlLevel;
}

// True when the level is nearer high than low, which is what the high/low
// toggle and the reported flag mean now that any level is possible.
bool blIsHigh() {
  return panelstate::brightnessIsHigh(configuredBrightness(), BL_LOW);
}

// ---- Status card & display sleep ----------------------------------------
// The status card means "nothing is driving this panel", NOT "the picture
// hasn't changed". Liveness comes from the sender's 2s keepalive, which
// arrives regardless of whether any pixels changed - with dirty-band
// diffing, a static photo legitimately sends no frame data for minutes, and
// keying off frame arrivals made the panel dim itself mid-use.
// Backlight off is driven by the Mac's own display/system sleep ("ESLP").
const uint32_t SENDER_GONE_MS = 45000;
const uint32_t IDLE_REPOSITION_MS = 30000;
bool idleActive = false;
volatile uint32_t lastSenderPacketAt = 0;  // any packet, incl. keepalive
uint32_t lastIdleDrawAt = 0;
volatile bool sleepRequested = false;  // set by UDP task on ESLP
volatile bool wakeRequested = false;   // set by UDP task on EWAK
bool displaySleeping = false;
// Signal-survey mode: a bright, half-second-refresh RSSI meter on the glass,
// so a marginal panel can be walked around the room to find placement that
// actually carries the stream - sections 17.17 and 18.5-18.6 are all stories
// about radio placement, and until now the only live readout was a laptop
// pinging it. Entered and left by a BOOT double-press at ANY time (streaming
// included - the stream's draw pass is suppressed while the meter is up and
// its dirty state keeps accumulating for the exit repaint), or by a tap on
// touch boards; a tap on the lit status card also enters it.
bool surveyActive = false;
uint32_t lastSurveyDrawAt = 0;

// User-requested "display off", independent of the Mac's own ESLP/EWAK sleep
// sync and the idle timer. Both of those are transient states this firmware
// arrives at and clears on the next drawn frame; this one is a standing
// instruction like rotation or brightness level, persisted in NVS and held
// until an explicit Power command turns it back on - see panelstate::
// backlightLevel for why it outranks even a wake-touch, and the CAP_POWER
// comment in device_protocol.h for why it is not simply riding ESLP/EWAK.
bool panelManuallyOff = false;

// ---- Touch (Touch board only) ------------------------------------------
// A finger on a dimmed panel lights it for a bounded window, and that touch is
// consumed rather than also firing whatever a tap is wired to - the same way a
// phone's first tap wakes the screen instead of pressing what is under it.
//
// Deliberately local and deliberately silent: the Mac's sleep state is
// authoritative, so waking never sends anything. It stops this panel from being
// dark while somebody is looking at it, and nothing more.
const uint32_t TOUCH_WAKE_MS = 10000;
uint32_t touchWakeUntil = 0;

bool touchWakeActive() {
  return touchWakeUntil != 0 && (int32_t)(millis() - touchWakeUntil) < 0;
}

uint8_t currentBrightness() {
  return panelstate::backlightLevel(panelManuallyOff, displaySleeping,
                                    idleActive, touchWakeActive(), userBlLevel,
                                    BL_IDLE, fixedBlLevel);
}

// Push a raw level to whichever brightness sink this board has: PWM duty on
// the backlight pin, or the panel's own 0x51 command on the AMOLED. Safe to
// call before the panel exists: the panel path does nothing until
// initDisplay() has run.
void driveBrightness(uint8_t level) {
  if (bcfg->isDsi() && panel != nullptr) {
    boarddisplay::setBrightness(panel, *bcfg, level);
  } else if (bcfg->hasBacklightPin()) {
    analogWrite(bcfg->pinBl, level);
  } else if (panel != nullptr) {
    boarddisplay::setBrightness(panel, *bcfg, level);
  }
}

// Panel init leaves scanout enabled. Track only successfully applied
// transitions so a failed command is retried on the next state update.
static bool panelDisplayEnabled = true;

// Drive both the panel's DISPON/DISPOFF state and its brightness. Manual power
// and host sleep use the driver's real display command; touch wake temporarily
// turns a sleeping panel back on, preserving the existing ten-second peek.
void applyBacklight() {
  const bool shouldEnable = panelstate::displayShouldBeEnabled(
      panelManuallyOff, displaySleeping, touchWakeActive());
  if (panel != nullptr && shouldEnable != panelDisplayEnabled) {
    if (!shouldEnable) driveBrightness(0);
    const esp_err_t err =
        boarddisplay::setDisplayEnabled(panel, *bcfg, shouldEnable);
    if (err == ESP_OK) {
      panelDisplayEnabled = shouldEnable;
      Serial.printf("display: panel command %s\n",
                    shouldEnable ? "on" : "off");
    } else {
      Serial.printf("display: panel command %s failed err=%d\n",
                    shouldEnable ? "on" : "off", (int)err);
    }
    if (shouldEnable) driveBrightness(currentBrightness());
    return;
  }
  driveBrightness(currentBrightness());
}

// ---- Identify ----------------------------------------------------------
// "Which panel is this?" must work on both boards, and only one of them has an
// addressable LED, so the primary signal is a backlight pulse: present on every
// board and visible across a room. Where an LED does exist it still turns blue
// as well, so nothing regresses on the boards that already had that.
static const uint32_t IDENTIFY_BLINK_MS = 250;
uint32_t identifyUntil = 0;
uint32_t identifyPhaseAt = 0;
bool identifyPhaseHigh = false;

// Deliberately not folded into applyBacklight()/currentBrightness(): the
// brightness reported over EINF/EACK must stay the steady value the user chose.
// If the pulse went through the reported path, every telemetry packet during an
// identify would carry a different number and the manager's slider would twitch.
void updateIdentify() {
  if (identifyUntil == 0) return;
  uint32_t now = millis();
  if ((int32_t)(now - identifyUntil) >= 0) {
    identifyUntil = 0;
    applyBacklight();  // hand the pin back to the sleep/idle/user state machine
    return;
  }
  if (fixedBlLevel != 0) return;
  if (now - identifyPhaseAt < IDENTIFY_BLINK_MS) return;
  identifyPhaseAt = now;
  identifyPhaseHigh = !identifyPhaseHigh;
  driveBrightness(identifyPhaseHigh ? 255 : BL_LOW);
}
