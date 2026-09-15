// The backlight/visibility state machine: the user's brightness level, the
// manual power switch, sender-driven sleep, the idle status card flag, the
// touch-wake window, the signal-survey flag, and the identify pulse. Every
// path to the brightness sink funnels through currentBrightness() /
// applyBacklight() here, so the sink can never disagree with what is reported
// over the network (panel_state.h owns the tested level policy).
#pragma once

#include <stdint.h>

// Per-board brightness presets (NVS-backed).
extern uint8_t BL_HIGH;
extern uint8_t BL_LOW;
extern uint8_t BL_IDLE;
extern uint8_t BL_SURVEY;
bool setBrightnessLevels(uint8_t low, uint8_t high, uint8_t idle,
                         uint8_t survey);

// The awake-and-driven backlight level, 1..255 (NVS-backed).
extern uint8_t userBlLevel;
// Zero means normal controls; 1..255 fixes every lit state at that level.
extern uint8_t fixedBlLevel;
uint8_t configuredBrightness();
bool blIsHigh();

// Status card & sleep state. lastSenderPacketAt is written by the network
// receive path (any packet, including keepalives) and is what "the sender is
// gone" is judged against; lastIdleDrawAt/lastSurveyDrawAt are written by
// ui_screens.cpp when it paints.
extern const uint32_t SENDER_GONE_MS;
extern const uint32_t IDLE_REPOSITION_MS;
extern bool idleActive;
extern volatile uint32_t lastSenderPacketAt;
extern uint32_t lastIdleDrawAt;
extern volatile bool sleepRequested;  // set by UDP task on ESLP
extern volatile bool wakeRequested;   // set by UDP task on EWAK
extern bool displaySleeping;
extern bool surveyActive;
extern uint32_t lastSurveyDrawAt;

// The user's standing display-off instruction (NVS-backed; see CFGPOWER).
extern bool panelManuallyOff;

// Touch-wake window: a finger on a dimmed panel lights it for this long.
extern const uint32_t TOUCH_WAKE_MS;
extern uint32_t touchWakeUntil;
bool touchWakeActive();

uint8_t currentBrightness();
void driveBrightness(uint8_t level);
void applyBacklight();

// Identify pulse state (control_apply.cpp arms it; loop() ticks it).
extern uint32_t identifyUntil;
extern uint32_t identifyPhaseAt;
extern bool identifyPhaseHigh;
void updateIdentify();
