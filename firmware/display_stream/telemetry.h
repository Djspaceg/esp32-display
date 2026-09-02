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
int batteryPercentOrUnknown();
panelstate::Charge toChargeWord(boardpower::Charge charge);
const char *batteryChargeWord(boardpower::Charge charge);

// The battery half of loop()'s 5-second serial report.
void reportBatteryLine();
