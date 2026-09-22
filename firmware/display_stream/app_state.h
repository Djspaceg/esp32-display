// Read-mostly device identity shared by every module: WiFi credentials, the
// device name, firmware version, MAC-derived hardware ID, the detected board
// variant and its config, the compile-time panel geometry, the esp_lcd panel
// handle, peripheral availability flags, and the shared stats counters.
//
// Everything here is defined in app_state.cpp; setup() populates the mutable
// pieces before any other module reads them. See docs/code-structure.md for
// the module map.
#pragma once

#include <Arduino.h>

#include <board_config.h>
#include <touch_map.h>

#include "band_protocol.h"
#include "esp_lcd_panel_ops.h"

// WiFi credentials and device name (NVS-backed; see prefs load in setup()).
extern String cfgSsid;
extern String cfgPass;
extern uint8_t wifiCredentialPresetSlot;
extern bool wifiLegacyMirrorPending;
extern String cfgName;
extern const char *FW_VERSION;
extern uint8_t deviceId[6];
String defaultDeviceName();

// Board identity. boardVariant/bcfg are settled by setup() before use.
extern board::Variant boardVariant;
extern const board::Config *bcfg;

/// Runtime panel geometry. setup() assigns these immediately after one physical
/// profile has been resolved and before frame buffers or protocol state exist.
extern bandproto::Geometry PANEL_GEOMETRY;
extern int16_t PANEL_W;
extern int16_t PANEL_H;
extern size_t FRAME_BYTES;
void configurePanelGeometry(const board::Config &config);
extern const uint16_t UDP_PORT;

extern esp_lcd_panel_handle_t panel;
bool initDisplay();

// Whether this board speaks the magic-prefixed large-tile protocol.
bool largeTileStreamEnabled();

// Whether this board speaks the tile-stream protocol instead of packed bands.
bool tileStreamEnabled();

// Peripheral availability, settled by setup() before mDNS announces caps.
extern bool touchAvailable;
extern touchmap::Calibration touchCalibration;
extern bool batteryAvailable;
extern bool audioAvailable;

// Shared stats counters (volatile: written from the receive task/callback and
// read from the loop). The 5-second serial report and EHB1 read them.
extern volatile uint32_t statFramesShown;
extern volatile uint32_t statFramesDropped;
extern volatile uint32_t statFramesPartial;
extern volatile uint32_t statPackets;
extern volatile uint32_t statBadLen;
extern volatile uint32_t statDrawErrors;
