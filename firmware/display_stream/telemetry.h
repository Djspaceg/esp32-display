// Outbound telemetry: capability/flag derivation and the EINF, EBAT, and
// EACK packets, plus the cached battery reading the serial line, CFGSHOW,
// and the on-device screens quote.
#pragma once

#include <stdint.h>

#include <board_power.h>

#include "device_protocol.h"
#include "panel_state.h"

// Advertised capabilities and live device flags (mDNS caps TXT, EINF, EACK).
uint32_t deviceCapabilities();
uint8_t currentDeviceFlags();

void sendDeviceInfo();
void sendBatteryStatus();
void sendControlAck(const deviceproto::ControlCommand &command,
                    uint8_t status = 0);

// Last successful battery reading; only quote it through
// batteryReadingCurrent(), which ages it out.
extern boardpower::Reading lastBattery;
bool batteryReadingCurrent();

/// The cached reading's external-power state collapsed to the bool that the
/// on-device battery line still takes.
///
/// Only Present becomes true. Unknown collapses to false alongside Absent, and
/// that IS a loss: on the panel, a board that cannot tell reads the same as a
/// board with nothing plugged in. Saying it in one place, with a name that
/// admits it is for display, keeps the loss from spreading - the source of
/// truth in boardpower::Reading::external stays three-valued, and the two
/// surfaces that could carry the third value are both gated on the user's
/// approval: the on-screen text, and EBAT flags bit 2, which the packet's
/// reserved space already leaves room for.
bool externalPowerForDisplay();

/// The word for the external-power state, for the serial report line: "on",
/// "off", or "unknown". Nothing parses this line, so unlike the panel and the
/// wire it can be honest today.
const char *externalPowerWord();

int batteryPercentOrUnknown();
panelstate::Charge toChargeWord(boardpower::Charge charge);
const char *batteryChargeWord(boardpower::Charge charge);

// The battery half of loop()'s 5-second serial report.
void reportBatteryLine();
