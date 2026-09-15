#include "telemetry.h"

#include <Arduino.h>
#include <WiFi.h>

#include <board_power.h>

#include "app_state.h"
#include "chip_identity.h"
#include "device_protocol.h"
#include "display_power.h"
#include "net_link.h"
#include "orientation.h"
#include "ota_policy.h"
#include "ota_service.h"
#include "panel_state.h"

// Capabilities every board has, whatever panel or peripherals it carries.
static const uint32_t BASE_CAPABILITIES =
    deviceproto::CAP_FLIP |
    deviceproto::CAP_IDENTIFY | deviceproto::CAP_RESTART |
    deviceproto::CAP_SLEEP_SYNC | deviceproto::CAP_TELEMETRY |
    deviceproto::CAP_IDLE_TEXT |
    // A manual on/off is not a hardware fact the way battery or rotate are -
    // every board here has a backlight or panel-command brightness sink
    // already, so every board can honour it.
    deviceproto::CAP_POWER;

// Last successful battery reading, so the 5s status line and CFGSHOW can report
// it without resampling the PMU or ADC. Only meaningful once batteryReadingValid
// is set; a failed sample leaves the previous one standing rather than reporting
// a zeroed battery as fact.
//
// It does not stand forever, though. lastBatteryAt ages it out after
// deviceproto::BATTERY_MAX_AGE_MS, so a telemetry source that answers at boot and
// then goes silent stops being quoted as if it were still talking.
// batteryReadingCurrent() is the one test both serial and CFGSHOW go through.
boardpower::Reading lastBattery = {};
static bool batteryReadingValid = false;
static uint32_t lastBatteryAt = 0;

// Advertised capabilities. Runtime rather than a constant because CAP_TOUCH
// depends on the hardware, and the sender uses these bits to decide which
// controls to offer - a panel without touch should not show touch actions.
uint32_t deviceCapabilities() {
  // Long press rides with touch rather than being its own condition: the same
  // classifier produces both, so a panel whose controller answered can report
  // holds. It is a separate bit so a sender can tell this firmware from an
  // older build whose holds classified as nothing.
  return BASE_CAPABILITIES
         | (fixedBlLevel == 0
                ? (deviceproto::CAP_BRIGHTNESS |
                   deviceproto::CAP_BRIGHTNESS_LEVEL)
                : 0u)
         | (touchAvailable ? (deviceproto::CAP_TOUCH
                              | deviceproto::CAP_TOUCH_LONGPRESS)
                           : 0u)
         | (batteryAvailable ? deviceproto::CAP_BATTERY : 0u)
         // Exactly ONE bit-15 frame protocol per board, never both: a tile
         // packet and a packed band packet are byte-ambiguous past the
         // shared flag bit, so a board that accepted both could misparse
         // one as the other. The tile board still accepts classic unpacked
         // band packets (bit 15 clear) as the fallback for senders that
         // predate tiles; every other board keeps packed bands, and the RLE
         // decode is chip-independent so the C6 gains from packing too (an
         // 80-band keyframe becomes a handful of datagrams).
         // CAP_TILE_HALFRES and CAP_TILE_VISIBLE_SPANS ride the same
         // decision, not separate ones: both modify tile records and are
         // meaningless without tiles. Folded into this ternary rather than
         // added independently so the C6 - where tileStreamEnabled() is
         // always false - emits no capability for bytes it never parses.
         //
         // It is still a SEPARATE BIT on the wire, which is the part that
         // matters: tile firmware predating this advertises CAP_TILE_STREAM
         // alone, so a sender can tell the two apart and withhold codec 3
         // from the older one.
         | (largeTileStreamEnabled()
                ? deviceproto::CAP_LARGE_TILE_STREAM
                : (tileStreamEnabled()
                       ? (deviceproto::CAP_TILE_STREAM
                          | deviceproto::CAP_TILE_HALFRES
                          | deviceproto::CAP_TILE_VISIBLE_SPANS)
                       : deviceproto::CAP_COMPRESSED_BANDS))
         // Round glass: a fifth of the framebuffer is behind the bezel and
         // invisible forever. Straight from the board table - the sender
         // has no other way to know the panel's shape, and the firmware
         // itself does nothing with it (see the CAP_ROUND_DISPLAY comment).
         | (bcfg->panel->roundDisplay ? deviceproto::CAP_ROUND_DISPLAY : 0u)
         // Quarter turns only where the glass is square. On a rectangular
         // panel a 90-degree mounting turn is what the sender-driven
         // landscape mechanism already expresses, and honouring rotation 1/3
         // there would fight it - so the capability is withheld and the
         // Rotate handler NACKs those values as defense in depth behind it.
         | (bcfg->panel->width == bcfg->panel->height &&
                    bcfg->panel->supportsCommandRotation
                ? deviceproto::CAP_ROTATE : 0u)
         // Only when OTA actually came up, not merely because this build
         // contains the code and not merely because a password is stored: a
         // panel that is not listening advertises no OTA, so nothing offers an
         // update path that would time out. advertisesCapability owns that rule.
         | (otapolicy::advertisesCapability(currentOtaStatus())
                ? deviceproto::CAP_OTA
                : 0u);
}


uint8_t currentDeviceFlags() {
  return panelstate::deviceFlags(blIsHigh(), panelRotation, displaySleeping,
                                 idleActive, WiFi.status() == WL_CONNECTED,
                                 panelManuallyOff);
}

void sendDeviceInfo() {
  if (hbPort == 0) return;
  uint8_t packet[96];
  size_t len = deviceproto::writeInfo(
      packet, sizeof(packet), currentDeviceFlags(), deviceCapabilities(),
      millis() / 1000, WiFi.status() == WL_CONNECTED ? (int16_t)WiFi.RSSI() : -127,
      currentBrightness(), deviceId, cfgName.c_str(), FW_VERSION);
  if (len > 0) {
    sendToSender(packet, len);
  }
}

// Sample the active battery telemetry source and report it. Its own packet
// rather than fields on EINF: an
// already-shipped sender length-checks EINF exactly and would reject every one
// of them, whereas an unknown packet type is simply dropped (see the EBAT
// comment in device_protocol.h).
void sendBatteryStatus() {
  if (!batteryAvailable) return;
  boardpower::Reading reading;
  if (!boardpower::read(reading)) return;
  lastBattery = reading;
  batteryReadingValid = true;
  lastBatteryAt = millis();
  if (hbPort == 0) return;

  uint8_t flags = 0;
  if (reading.present) flags |= deviceproto::BATTERY_FLAG_PRESENT;
  if (reading.externalPower) flags |= deviceproto::BATTERY_FLAG_EXTERNAL_POWER;
  deviceproto::ChargeState state = deviceproto::ChargeState::Unknown;
  switch (reading.charge) {
    case boardpower::Charge::Charging:
      state = deviceproto::ChargeState::Charging;
      break;
    case boardpower::Charge::Discharging:
      state = deviceproto::ChargeState::Discharging;
      break;
    case boardpower::Charge::Standby:
      state = deviceproto::ChargeState::Standby;
      break;
    case boardpower::Charge::Unknown:
      break;
  }

  uint8_t packet[deviceproto::BATTERY_PACKET_BYTES];
  deviceproto::writeBattery(
      packet, flags,
      reading.percentKnown ? reading.percent : deviceproto::BATTERY_PERCENT_UNKNOWN,
      state, reading.millivolts);
  sendToSender(packet, sizeof(packet));
}

// board_power.h's Charge enum to panel_state.h's - two separate types for the
// reason board_power.h's own doc comment gives (that header stays independent
// of the wire/UI format), so every caller that wants a word or a formatted
// line converts through here rather than switching on boardpower::Charge
// itself in more than one place.
panelstate::Charge toChargeWord(boardpower::Charge charge) {
  switch (charge) {
    case boardpower::Charge::Charging:
      return panelstate::Charge::Charging;
    case boardpower::Charge::Discharging:
      return panelstate::Charge::Discharging;
    case boardpower::Charge::Standby:
      return panelstate::Charge::Standby;
    default:
      return panelstate::Charge::Unknown;
  }
}

// Charge state as one word, for the serial status line. Forwards to
// panelstate::chargeWord so the serial line and the on-device idle card
// (drawIdleScreen(), via panelstate::formatBatteryLine) cannot disagree on
// what a charge state is called - one word list, one place, every caller.
const char *batteryChargeWord(boardpower::Charge charge) {
  return panelstate::chargeWord(toChargeWord(charge));
}

// Whether the cached reading is recent enough to quote. False before the first
// sample and again once one stops arriving - a source that answered at boot and
// then died must not keep its percentage on the serial line and in CFGSHOW, which are
// the only ways to read a battery on a panel no sender has found.
bool batteryReadingCurrent() {
  return batteryAvailable && batteryReadingValid &&
         deviceproto::batteryReadingCurrent(millis(), lastBatteryAt);
}

// Battery percentage for CFGSHOW, or -1 when there is no telemetry source, no
// cell, no settled estimate/gauge reading, or nothing recent enough to report. Negative rather
// than 0 so "we do not know" can never be read as "empty".
int batteryPercentOrUnknown() {
  if (!batteryReadingCurrent()) return -1;
  if (!lastBattery.present || !lastBattery.percentKnown) return -1;
  return (int)lastBattery.percent;
}

void sendControlAck(const deviceproto::ControlCommand &command,
                           uint8_t status) {
  if (hbPort == 0) return;
  uint8_t packet[deviceproto::ACK_PACKET_BYTES];
  deviceproto::writeAck(packet, command.opcode, command.sequence, status,
                        currentDeviceFlags(), currentBrightness());
  sendToSender(packet, sizeof(packet));
}
// The battery half of loop()'s 5-second serial report.
void reportBatteryLine() {
    // Its own line, and only where a battery telemetry source exists.
    if (batteryReadingCurrent()) {
      if (!lastBattery.present) {
        Serial.printf("battery: absent vbus=%d\n", lastBattery.externalPower);
      } else {
        Serial.printf("battery: %d%% %s %umV present=1 vbus=%d\n",
                      batteryPercentOrUnknown(),
                      batteryChargeWord(lastBattery.charge),
                      (unsigned)lastBattery.millivolts,
                      lastBattery.externalPower);
      }
    } else if (batteryAvailable && batteryReadingValid) {
      // The source answered once and has stopped. Said out loud rather than
      // silently repeating the last percentage, because this line is where a
      // dead battery telemetry path is diagnosed.
      Serial.printf("battery: no reading for %us (source stopped answering?)\n",
                    (unsigned)((millis() - lastBatteryAt) / 1000));
    }
}
