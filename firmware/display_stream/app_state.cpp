#include "app_state.h"

#include <panel_init.h>

#include "dma_gate.h"


// WiFi credentials live in NVS flash and are reconfigurable over the USB
// serial port without reflashing (see handleSerialConfig). The compiled-in
// wifi_config.h values are only the first-boot fallback.
String cfgSsid;
String cfgPass;

// Device name: mDNS hostname + service instance name, so multiple panels
// coexist and the Mac discovers them by browsing _espdisp._udp instead of
// resolving a hardcoded hostname. Default is unique per board
// (espdisplay-XXXX from the MAC); changeable via CFGNAME over USB.
String cfgName;
const char *FW_VERSION = "1.4.1";
uint8_t deviceId[6] = {0};

// Reads the MAC straight from eFuse rather than via WiFi.macAddress(),
// because the name is needed before WiFi is initialized: the DHCP hostname
// is latched inside WiFi.mode() when entering STA mode.
String defaultDeviceName() {
  char buf[24];
  snprintf(buf, sizeof(buf), "espdisplay-%02x%02x", deviceId[4], deviceId[5]);
  return String(buf);
}

// ---- Board identity ---------------------------------------------------
// On the C6, one binary serves both Waveshare 1.47" boards: the panel
// controller and pin map differ, the 172x320 resolution does not. Detected at
// boot, cached only when explicitly forced with CFGBOARD over USB. S3 geometry
// is compile-time selected: the default is 1.75C/CO5300 and
// ESPDISP_BOARD_S3_185 selects 1.85C/ST77916.
board::Variant boardVariant = board::COMPILED_VARIANT;
const board::Config *bcfg = &board::configFor(board::COMPILED_VARIANT);

// ---- Display geometry --------------------------------------------------
// A per-binary compile-time fact, NOT a per-boot one: buffers, band layout,
// and the mDNS advertisement are all sized from it. Reading it from
// COMPILED_VARIANT is correct on every target because the C6 boards (the
// only case where detection can change the variant at runtime) share their
// resolution; setup() enforces that invariant against a stale CFGBOARD
// override. Pins, panel driver, pixel clock, gap and inversion stay runtime
// facts read from bcfg.
const bandproto::Geometry PANEL_GEOMETRY = {
    board::configFor(board::COMPILED_VARIANT).panelW,
    board::configFor(board::COMPILED_VARIANT).panelH};
const int16_t PANEL_W = (int16_t)PANEL_GEOMETRY.width;
const int16_t PANEL_H = (int16_t)PANEL_GEOMETRY.height;

esp_lcd_panel_handle_t panel = nullptr;

// Whether this board speaks the tile-stream protocol instead of packed
// bands. A variant fact, not a shape fact: the draw path behind it is tuned
// to this board's QSPI and PSRAM (see device_protocol.h's CAP_TILE_STREAM
// comment), so a future square panel on other silicon must opt in
// explicitly rather than inherit it.
bool tileStreamEnabled() {
  return bcfg->variant == board::Variant::AmoledCo5300;
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

const uint16_t UDP_PORT = 5568;
const size_t FRAME_BYTES = PANEL_GEOMETRY.frameBytes();

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
  return boardpanel::init(*bcfg, SPI2_HOST, bcfg->pclkHz, FRAME_BYTES,
                          onColorTransDone, nullptr, nullptr, &panel);
}
