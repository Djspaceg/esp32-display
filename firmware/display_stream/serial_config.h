// The CFG* serial configuration surface (USB CDC or carrier UART bridge,
// 115200): WiFi credentials, device name, orientation, power, board override,
// LED diagnostics, OTA password, tuning knobs, and CFGSHOW.
#pragma once

#include <board_config.h>

void beginSerialConfig(const board::Config &cfg);
void beginSerialRecovery();
void handleSerialConfig();
