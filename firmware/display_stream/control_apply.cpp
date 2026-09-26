#include "control_apply.h"

#include <Arduino.h>

#include "app_state.h"
#include "display_power.h"
#include "orientation.h"
#include "prefs_store.h"
#include "signal_led.h"
#include "telemetry.h"

// Lines the sender asked the panel to show on its status card, with when they
// arrived so the card can say how old they are. Written by the UDP task and
// read by the loop, so both go through controlMux.
deviceproto::IdleTextMessage idleText;
uint32_t idleTextAt = 0;
// The last idle-text content actually written to NVS, so loop()'s periodic
// check (see IDLE_TEXT_SAVE_INTERVAL_MS below) can tell "really changed"
// from "same as what is already saved" without re-touching flash. Zero-
// initialized to an empty message by static storage; setup() overwrites it
// with whatever was loaded, so a freshly booted panel does not immediately
// rewrite NVS with the value it just read back out of it.
deviceproto::IdleTextMessage lastSavedIdleText;

// Management controls arrive on lwIP's callback task and are applied by the
// Arduino loop. NVS writes, panel changes, LED work, and restarts must never
// run inside the network callback.
portMUX_TYPE controlMux = portMUX_INITIALIZER_UNLOCKED;
controlq::ControlQueue controls;
uint32_t restartAt = 0;

void applyPendingControl() {
  deviceproto::ControlCommand command;
  deviceproto::ControlCommand duplicateAck;
  bool hasCommand = false;
  bool hasDuplicateAck = false;
  portENTER_CRITICAL(&controlMux);
  hasCommand = controls.take(command);
  hasDuplicateAck = controls.takeDuplicateAck(duplicateAck);
  portEXIT_CRITICAL(&controlMux);

  if (hasCommand) {
    uint8_t ackStatus = 0;
    switch (command.opcode) {
      case deviceproto::ControlOpcode::Brightness:
        if (fixedBlLevel != 0) {
          ackStatus = 1;
          Serial.printf("network: backlight change refused (fixed at %u)\n",
                        fixedBlLevel);
          break;
        }
        userBlLevel = command.value != 0 ? BL_HIGH : BL_LOW;
        saveDisplayPrefs();
        applyBacklight();
        Serial.printf("network: backlight %s (saved)\n", blIsHigh() ? "high" : "low");
        break;
      case deviceproto::ControlOpcode::BrightnessLevel:
        if (fixedBlLevel != 0) {
          ackStatus = 1;
          Serial.printf("network: backlight level refused (fixed at %u)\n",
                        fixedBlLevel);
          break;
        }
        userBlLevel = (uint8_t)command.value;
        saveDisplayPrefs();
        applyBacklight();
        Serial.printf("network: backlight level %u (saved)\n", userBlLevel);
        break;
      case deviceproto::ControlOpcode::Flip:
        // Kept for old senders. Flip 1 is rotation 2; Flip 0 is upright.
        // Deliberately absolute rather than "toggle the 180 bit": a sender
        // that says Flip 0 means "upright", and leaving a quarter turn
        // standing would contradict it.
        panelRotation = command.value != 0 ? 2 : 0;
        madctlDirty = true;
        saveDisplayPrefs();
        Serial.printf("network: flip180=%d -> rotation=%u (saved)\n",
                      command.value != 0, panelRotation);
        break;
      case deviceproto::ControlOpcode::Rotate:
        if ((command.value & 1) != 0 &&
            !bcfg->panel->supportsCommandRotation) {
          // Defense in depth behind the capability gate: a panel without
          // validated quarter turns never advertises CAP_ROTATE, so a
          // well-behaved sender never sends 1 or 3 here.
          ackStatus = 1;
          Serial.printf("network: rotate %ld refused (panel backend unsupported)\n",
                        (long)command.value);
          break;
        }
        panelRotation = (uint8_t)(command.value & 3);
        madctlDirty = true;
        saveDisplayPrefs();
        Serial.printf("network: rotation=%u (saved)\n", panelRotation);
        break;
      case deviceproto::ControlOpcode::Power:
        panelManuallyOff = command.value == 0;
        saveDisplayPrefs();
        applyBacklight();
        Serial.printf("network: display %s (saved)\n",
                      panelManuallyOff ? "off" : "on");
        break;
      case deviceproto::ControlOpcode::Identify:
        // Backlight pulse on every board; LED too where there is one.
        identifyUntil = millis() + (uint32_t)command.value * 1000;
        identifyPhaseAt = 0;  // pulse on the next loop pass, not one blink later
        if (bcfg->hasRgbLed() && rgbLed != nullptr) {
          rgbLed->fill(rgbLed->Color(0, 96, 255));
          rgbLed->show();
          ledOverrideUntil = identifyUntil;
        }
        Serial.printf("network: identify for %lds\n", (long)command.value);
        break;
      case deviceproto::ControlOpcode::Restart:
        restartAt = millis() + 500;
        Serial.println("network: restart requested");
        break;
    }
    portENTER_CRITICAL(&controlMux);
    controls.markApplied(command.sequence);
    portEXIT_CRITICAL(&controlMux);
    sendControlAck(command, ackStatus);
    sendDeviceInfo();
  }
  if (hasDuplicateAck) {
    sendControlAck(duplicateAck);
  }
}
