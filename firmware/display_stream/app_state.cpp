#include "app_state.h"

#include <display_backend.h>

#include "dma_gate.h"

// tools/espdisp.py writes build_identity.h into its private copy of the sketch
// before compiling, naming the commit the image was built from - the same
// commit, spelled the same way, as the bundle manifest's source_commit and
// source_dirty. A compile outside that tool has no such file and reports
// "unknown", which is an answer rather than a guess.
#if __has_include("build_identity.h")
#include "build_identity.h"
#endif
#ifndef ESPDISP_SOURCE_ID
#define ESPDISP_SOURCE_ID "unknown"
#endif


// WiFi credentials live in NVS flash and are reconfigurable over the USB
// serial port without reflashing (see handleSerialConfig). The compiled-in
// wifi_config.h values are only the first-boot fallback.
String cfgSsid;
String cfgPass;
uint8_t wifiCredentialPresetSlot = 0;
bool wifiLegacyMirrorPending = false;

// Device name: mDNS hostname + service instance name, so multiple panels
// coexist and the Mac discovers them by browsing _espdisp._udp instead of
// resolving a hardcoded hostname. Default is unique per board
// (espdisplay-XXXX from the MAC); changeable via CFGNAME over USB.
String cfgName;
const char *FW_VERSION = "2.0.0";
// Which build of FW_VERSION this is: "<40 hex>" or "<40 hex>-dirty". FW_VERSION
// only moves at a release, so without this every image built between two
// releases reports the same thing. Reported as CFGINFO src= and mDNS TXT src,
// both new optional fields; EINF is length-checked exactly by shipped senders,
// so it is not extended.
const char *FW_SOURCE = ESPDISP_SOURCE_ID;
uint8_t deviceId[6] = {0};

// Reads the MAC straight from eFuse rather than via WiFi.macAddress(),
// because the name is needed before WiFi is initialized: the DHCP hostname
// is latched inside WiFi.mode() when entering STA mode.
String defaultDeviceName() {
  char buf[24];
  snprintf(buf, sizeof(buf), "espdisplay-%02x%02x", deviceId[4], deviceId[5]);
  return String(buf);
}

// ---- Board identity and display geometry ------------------------------
// Every family resolves a physical profile before any panel GPIO is driven;
// P4 does so by reading its DSI panel's controller ID. The user-facing target
// remains the chip family in every case.
board::Variant boardVariant = board::COMPILED_VARIANT;
const board::Config *bcfg = nullptr;
bandproto::Geometry PANEL_GEOMETRY = {0, 0};
int16_t PANEL_W = 0;
int16_t PANEL_H = 0;
size_t FRAME_BYTES = 0;

void configurePanelGeometry(const board::Config &config) {
  PANEL_GEOMETRY = {config.panel->width, config.panel->height};
  PANEL_W = (int16_t)PANEL_GEOMETRY.width;
  PANEL_H = (int16_t)PANEL_GEOMETRY.height;
  FRAME_BYTES = PANEL_GEOMETRY.frameBytes();
}

esp_lcd_panel_handle_t panel = nullptr;

// Whether this board speaks the tile-stream protocol instead of packed
// bands. A variant fact, not a shape fact: the draw path behind it is tuned
// to this board's QSPI and PSRAM (see device_protocol.h's CAP_TILE_STREAM
// comment), so a future square panel on other silicon must opt in
// explicitly rather than inherit it.
bool tileStreamEnabled() {
  return bcfg->variant == board::Variant::AmoledCo5300;
}

bool largeTileStreamEnabled() {
  return bcfg->variant == board::Variant::P4_4B ||
         bcfg->variant == board::Variant::P4_4C ||
         bcfg->variant == board::Variant::P4_34C;
}

// Whether the touch controller came up. Not simply "is this the Touch board":
// the chip has to actually answer, so a board with dead touch advertises no
// touch rather than promising gestures that never arrive.
bool touchAvailable = false;

// Which board's touch calibration to run raw coordinates through. Picked
// once at boot from bcfg->touch (see setup()) rather than defaulted, because
// touchmap::map's Calibration parameter defaults to the C6's AXS5106L
// calibration - correct only for that one board - and every other board
// must pass its own explicitly or inherit a mirroring/rotation convention
// that was never measured on its hardware.
touchmap::Calibration touchCalibration = touchmap::AXS5106L_ON_C6;

// Whether a battery telemetry source came up. On S3 this is the AXP2101 PMU;
// on C6 touch it is the GPIO0 voltage divider, whose charge state is unavailable.
bool batteryAvailable = false;
bool audioAvailable = false;

const uint16_t UDP_PORT = 5568;

// Stats.
volatile uint32_t statFramesShown = 0;
volatile uint32_t statFramesDropped = 0;  // incomplete, abandoned
// Draw passes that painted PARTIAL frames - tiles drawn because
// tunePartialDrawMs elapsed with none of their frame's remainder arriving
// (section 15.3). Kept apart from statFramesShown because conflating them cost
// real accuracy: from section 15.3 until now, `shown` counted draw passes of
// both kinds, which inflated it roughly fourfold at low frame rates (8 fps
// offered read as 30.8) and, worse, fed that inflated number to the sender's
// pacing hill-climb, which steers on it (section 17.5).
//
// This occupies EHB1's third u32, where the never-incremented
// statFramesSkipped used to sit - the slot has always transmitted zero, so
// nothing has ever read a meaningful value out of it.
volatile uint32_t statFramesPartial = 0;
volatile uint32_t statPackets = 0;
volatile uint32_t statBadLen = 0;
volatile uint32_t statDrawErrors = 0;

// Bring up SPI and the panel for whichever board this is. The body lives in
// boardpanel::init so display_test exercises the identical path - a bring-up
// test that constructs the panel its own way can pass while this is broken.
bool initDisplay() {
  return boarddisplay::init(*bcfg, SPI2_HOST, FRAME_BYTES,
                            onColorTransDone, nullptr, nullptr, &panel);
}
