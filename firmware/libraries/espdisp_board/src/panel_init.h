// Panel bring-up and orientation, shared by display_stream and display_test.
//
// Shared rather than copied so the bring-up test exercises the exact code the
// real firmware runs: a test that constructs the panel its own way can pass
// while the firmware's path is broken, which is the failure mode this file
// exists to remove.
//
// The pieces that vary by board (driver, bus, pins, gap, inversion) all come
// out of board_config.h. Compile-time guards below limit each artifact to the
// driver set it can actually select: C6 keeps its two runtime-detected panels,
// while each fixed S3 target links only its own controller.
//
// Two bus shapes exist:
//   SPI   single data lane plus a D/C pin (the C6 LCDs). 8-bit commands.
//   QSPI  four data lanes, no D/C pin (the S3 panels). Commands travel in
//         a 32-bit envelope the panel driver builds itself; this file only
//         has to configure the IO layer for quad mode and 32-bit commands.
#pragma once

#include <driver/spi_master.h>
#include <esp_err.h>
#include <esp_lcd_panel_io.h>
#include <esp_lcd_panel_ops.h>
#include <esp_lcd_panel_vendor.h>

#include <board_config.h>
#include <board_io.h>
#if defined(ESPDISP_PANEL_S3_RUNTIME) || defined(ESPDISP_PANEL_C3_RUNTIME)
#include <esp_lcd_gc9107.h>
#if defined(ESPDISP_PANEL_S3_RUNTIME)
#include <esp_lcd_panel_st7789.h>
#include <esp_lcd_st77916.h>
#include <esp_lcd_co5300.h>
#endif
#elif defined(ESPDISP_PANEL_GC9107_128X128)
#include <esp_lcd_gc9107.h>
#elif defined(ESPDISP_PANEL_ST7789_240X240)
#include <esp_lcd_panel_st7789.h>
#elif defined(ESPDISP_PANEL_ST77916_360X360)
#include <esp_lcd_st77916.h>
#elif defined(ESPDISP_PANEL_CO5300_466X466)
#include <esp_lcd_co5300.h>
#elif defined(ESPDISP_PANEL_C6_RUNTIME)
#include <esp_lcd_panel_st7789.h>
#include <esp_lcd_jd9853.h>
#elif defined(ESPDISP_PANEL_ST7703_720X720)
// MIPI-DSI targets are constructed by panel_init_dsi.h.
#else
#error "No panel implementation selected for this firmware family"
#endif

#include "panel_orientation.h"

namespace boardpanel {

#if defined(ESPDISP_PANEL_GC9107_128X128) || \
    defined(ESPDISP_PANEL_S3_RUNTIME) || defined(ESPDISP_PANEL_C3_RUNTIME)
// Waveshare's controller-specific Arduino GC9107 sequence. It deliberately
// includes COLMOD=0x05, INVON, SLPOUT with 120ms delay, and DISPON with 20ms
// delay; the generic Espressif defaults are not this panel's sequence.
static const uint8_t gc9107_eb[] = {0x14};
static const uint8_t gc9107_zero[] = {0x00};
static const uint8_t gc9107_84[] = {0x40};
static const uint8_t gc9107_ff[] = {0xFF};
static const uint8_t gc9107_88[] = {0x0A};
static const uint8_t gc9107_89[] = {0x21};
static const uint8_t gc9107_8b[] = {0x80};
static const uint8_t gc9107_8c[] = {0x01};
static const uint8_t gc9107_b6[] = {0x00, 0x20};
static const uint8_t gc9107_3a[] = {0x05};
static const uint8_t gc9107_90[] = {0x08, 0x08, 0x08, 0x08};
static const uint8_t gc9107_bd[] = {0x06};
static const uint8_t gc9107_ff_page[] = {0x60, 0x01, 0x04};
static const uint8_t gc9107_13[] = {0x13};
static const uint8_t gc9107_22[] = {0x22};
static const uint8_t gc9107_11[] = {0x11};
static const uint8_t gc9107_e1[] = {0x10, 0x0E};
static const uint8_t gc9107_df[] = {0x21, 0x0C, 0x02};
static const uint8_t gc9107_f0[] = {0x45, 0x09, 0x08, 0x08, 0x26, 0x2A};
static const uint8_t gc9107_f1[] = {0x43, 0x70, 0x72, 0x36, 0x37, 0x6F};
static const uint8_t gc9107_ed[] = {0x1B, 0x0B};
static const uint8_t gc9107_77[] = {0x77};
static const uint8_t gc9107_63[] = {0x63};
static const uint8_t gc9107_70[] = {0x07, 0x07, 0x04, 0x0E, 0x0F, 0x09, 0x07, 0x08, 0x03};
static const uint8_t gc9107_34[] = {0x34};
static const uint8_t gc9107_62[] = {0x18, 0x0D, 0x71, 0xED, 0x70, 0x70, 0x18, 0x0F, 0x71, 0xEF, 0x70, 0x70};
static const uint8_t gc9107_63_block[] = {0x18, 0x11, 0x71, 0xF1, 0x70, 0x70, 0x18, 0x13, 0x71, 0xF3, 0x70, 0x70};
static const uint8_t gc9107_64[] = {0x28, 0x29, 0xF1, 0x01, 0xF1, 0x00, 0x07};
static const uint8_t gc9107_66[] = {0x3C, 0x00, 0xCD, 0x67, 0x45, 0x45, 0x10, 0x00, 0x00, 0x00};
static const uint8_t gc9107_67[] = {0x00, 0x3C, 0x00, 0x00, 0x00, 0x01, 0x54, 0x10, 0x32, 0x98};
static const uint8_t gc9107_74[] = {0x10, 0x85, 0x80, 0x00, 0x00, 0x4E, 0x00};
static const uint8_t gc9107_98[] = {0x3E, 0x07};
static const gc9107_lcd_init_cmd_t GC9107_WAVESHARE_INIT[] = {
    {0xEF, nullptr, 0, 0}, {0xEB, gc9107_eb, sizeof(gc9107_eb), 0},
    {0xFE, nullptr, 0, 0}, {0xEF, nullptr, 0, 0},
    {0xEB, gc9107_eb, sizeof(gc9107_eb), 0}, {0x84, gc9107_84, sizeof(gc9107_84), 0},
    {0x85, gc9107_ff, sizeof(gc9107_ff), 0}, {0x86, gc9107_ff, sizeof(gc9107_ff), 0},
    {0x87, gc9107_ff, sizeof(gc9107_ff), 0}, {0x88, gc9107_88, sizeof(gc9107_88), 0},
    {0x89, gc9107_89, sizeof(gc9107_89), 0}, {0x8A, gc9107_zero, sizeof(gc9107_zero), 0},
    {0x8B, gc9107_8b, sizeof(gc9107_8b), 0}, {0x8C, gc9107_8c, sizeof(gc9107_8c), 0},
    {0x8D, gc9107_8c, sizeof(gc9107_8c), 0}, {0x8E, gc9107_ff, sizeof(gc9107_ff), 0},
    {0x8F, gc9107_ff, sizeof(gc9107_ff), 0}, {0xB6, gc9107_b6, sizeof(gc9107_b6), 0},
    {0x3A, gc9107_3a, sizeof(gc9107_3a), 0}, {0x90, gc9107_90, sizeof(gc9107_90), 0},
    {0xBD, gc9107_bd, sizeof(gc9107_bd), 0}, {0xBC, gc9107_zero, sizeof(gc9107_zero), 0},
    {0xFF, gc9107_ff_page, sizeof(gc9107_ff_page), 0}, {0xC3, gc9107_13, sizeof(gc9107_13), 0},
    {0xC4, gc9107_13, sizeof(gc9107_13), 0}, {0xC9, gc9107_22, sizeof(gc9107_22), 0},
    {0xBE, gc9107_11, sizeof(gc9107_11), 0}, {0xE1, gc9107_e1, sizeof(gc9107_e1), 0},
    {0xDF, gc9107_df, sizeof(gc9107_df), 0}, {0xF0, gc9107_f0, sizeof(gc9107_f0), 0},
    {0xF1, gc9107_f1, sizeof(gc9107_f1), 0}, {0xF2, gc9107_f0, sizeof(gc9107_f0), 0},
    {0xF3, gc9107_f1, sizeof(gc9107_f1), 0}, {0xED, gc9107_ed, sizeof(gc9107_ed), 0},
    {0xAE, gc9107_77, sizeof(gc9107_77), 0}, {0xCD, gc9107_63, sizeof(gc9107_63), 0},
    {0x70, gc9107_70, sizeof(gc9107_70), 0}, {0xE8, gc9107_34, sizeof(gc9107_34), 0},
    {0x62, gc9107_62, sizeof(gc9107_62), 0}, {0x63, gc9107_63_block, sizeof(gc9107_63_block), 0},
    {0x64, gc9107_64, sizeof(gc9107_64), 0}, {0x66, gc9107_66, sizeof(gc9107_66), 0},
    {0x67, gc9107_67, sizeof(gc9107_67), 0}, {0x74, gc9107_74, sizeof(gc9107_74), 0},
    {0x98, gc9107_98, sizeof(gc9107_98), 0}, {0x35, nullptr, 0, 0},
    {0x21, nullptr, 0, 0}, {0x11, nullptr, 0, 120}, {0x29, nullptr, 0, 20},
};
#endif

/// Bring up the SPI/QSPI bus and the panel described by cfg.
///
/// The composed PanelConfig is the sole source for pixel clock, bus mode,
/// controller, inversion, geometry and address offsets. Carrier Config supplies
/// only wiring and reset topology.
///
/// doneCb fires from an ISR when a queued transfer completes; pass nullptr if
/// the caller does not track DMA completions.
inline bool init(const board::Config &cfg, spi_host_device_t host,
                 size_t maxTransferSz,
                 esp_lcd_panel_io_color_trans_done_cb_t doneCb, void *userCtx,
                 esp_lcd_panel_io_handle_t *outIo,
                 esp_lcd_panel_handle_t *outPanel) {
  if (cfg.pinPanelPower != board::NO_PIN) {
    // A carrier-switched panel rail must be up and settled before the
    // controller sees reset or its first command. Boot detection may have
    // pulsed and released it; from here on it is held high.
    pinMode(cfg.pinPanelPower, OUTPUT);
    digitalWrite(cfg.pinPanelPower, HIGH);
    delay(20);
  }
  if (!boardio::begin(cfg) || !boardio::pulseReset(cfg.panelResetExio)) {
    return false;
  }
  spi_bus_config_t buscfg = {};
  buscfg.sclk_io_num = cfg.pinSclk;
  buscfg.max_transfer_sz = (int)maxTransferSz;
  if (cfg.isQspi()) {
    // Four data lanes. data0 aliases mosi (and data1 miso, data2 quadwp,
    // data3 quadhd) in the IDF's union, which is why the single-lane branch
    // can keep the traditional field names.
    buscfg.data0_io_num = cfg.pinMosi;
    buscfg.data1_io_num = cfg.pinData1;
    buscfg.data2_io_num = cfg.pinData2;
    buscfg.data3_io_num = cfg.pinData3;
  } else {
    buscfg.mosi_io_num = cfg.pinMosi;
    buscfg.miso_io_num = -1;  // nothing to read back; MISO is unused
    buscfg.quadwp_io_num = -1;
    buscfg.quadhd_io_num = -1;
  }
  const esp_err_t busResult = spi_bus_initialize(host, &buscfg, SPI_DMA_CH_AUTO);
  if (busResult != ESP_OK) {
    return false;
  }

  esp_lcd_panel_io_spi_config_t io_config = {};
  io_config.cs_gpio_num = cfg.pinCs;
  io_config.dc_gpio_num = cfg.pinDc;  // NO_PIN (-1) on QSPI: no D/C line
  io_config.spi_mode = cfg.panel->spiMode;
  io_config.pclk_hz = cfg.panel->pixelClockHz;
  io_config.trans_queue_depth = 2;
  io_config.on_color_trans_done = doneCb;
  io_config.user_ctx = userCtx;
  if (cfg.isQspi()) {
    // The QSPI command envelope: [opcode 0x02][cmd][0x00] in a 32-bit
    // command word, 8-bit parameters, all four lanes. The selected QSPI panel
    // driver builds the envelope; these widths let it through the IO layer.
    io_config.lcd_cmd_bits = 32;
    io_config.lcd_param_bits = 8;
    io_config.flags.quad_mode = 1;
  } else {
    io_config.lcd_cmd_bits = 8;
    io_config.lcd_param_bits = 8;
  }

  esp_lcd_panel_io_handle_t io = nullptr;
  const esp_err_t ioResult =
      esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)host, &io_config, &io);
  if (ioResult != ESP_OK) {
    return false;
  }

  esp_lcd_panel_dev_config_t panel_config = {};
  panel_config.reset_gpio_num = cfg.pinRst;
  panel_config.rgb_ele_order =
      cfg.panel->driver == board::PanelDriver::Gc9107
          ? LCD_RGB_ELEMENT_ORDER_BGR
          : LCD_RGB_ELEMENT_ORDER_RGB;
  // The framebuffer arrives from the Mac already in panel byte order, so the
  // ESP32 never touches a pixel. The core's ST7789 driver defaults to
  // big-endian and only diverges when this is set to LITTLE; the vendored
  // panel drivers keep the same panel byte order. Setting BIG is correct on all
  // and a no-op on all - it documents the buffer's contract rather than
  // changing anything.
  panel_config.data_endian = LCD_RGB_DATA_ENDIAN_BIG;
  panel_config.bits_per_pixel = 16;

  esp_lcd_panel_handle_t panel = nullptr;
  esp_err_t err = ESP_ERR_NOT_SUPPORTED;
  switch (cfg.panel->driver) {
#if defined(ESPDISP_PANEL_GC9107_128X128) || \
    defined(ESPDISP_PANEL_S3_RUNTIME) || defined(ESPDISP_PANEL_C3_RUNTIME)
    case board::PanelDriver::Gc9107: {
      gc9107_vendor_config_t vendor = {
          .init_cmds = GC9107_WAVESHARE_INIT,
          .init_cmds_size = sizeof(GC9107_WAVESHARE_INIT) /
                            sizeof(GC9107_WAVESHARE_INIT[0]),
      };
      panel_config.vendor_config = &vendor;
      err = esp_lcd_new_panel_gc9107(io, &panel_config, &panel);
      break;
    }
#endif
#if defined(ESPDISP_PANEL_ST7789_240X240) || \
    defined(ESPDISP_PANEL_S3_RUNTIME)
    case board::PanelDriver::St7789:
      err = esp_lcd_new_panel_st7789(io, &panel_config, &panel);
      break;
#endif
#if defined(ESPDISP_PANEL_ST77916_360X360) || \
    defined(ESPDISP_PANEL_S3_RUNTIME)
    case board::PanelDriver::St77916: {
      st77916_vendor_config_t vendor = {};
      vendor.flags.use_qspi_interface = cfg.isQspi() ? 1 : 0;
      panel_config.vendor_config = &vendor;
      err = esp_lcd_new_panel_st77916(io, &panel_config, &panel);
      break;
    }
#endif
#if defined(ESPDISP_PANEL_CO5300_466X466) || \
    defined(ESPDISP_PANEL_S3_RUNTIME)
    case board::PanelDriver::Co5300: {
      co5300_vendor_config_t vendor = {};
      vendor.flags.use_qspi_interface = cfg.isQspi() ? 1 : 0;
      panel_config.vendor_config = &vendor;
      err = esp_lcd_new_panel_co5300(io, &panel_config, &panel);
      break;
    }
#endif
#if defined(ESPDISP_PANEL_C6_RUNTIME)
    case board::PanelDriver::Jd9853:
      err = esp_lcd_new_panel_jd9853(io, &panel_config, &panel);
      break;
    case board::PanelDriver::St7789:
      err = esp_lcd_new_panel_st7789(io, &panel_config, &panel);
      break;
#endif
    default:
      break;
  }
  if (err != ESP_OK) {
    return false;
  }

  esp_lcd_panel_reset(panel);
  esp_lcd_panel_init(panel);
  esp_lcd_panel_invert_color(panel, cfg.panel->invertColor);
  esp_lcd_panel_set_gap(panel, cfg.panel->colOffset, cfg.panel->rowOffset);
  esp_lcd_panel_disp_on_off(panel, true);

  if (outIo != nullptr) *outIo = io;
  *outPanel = panel;
  return true;
}

/// Set brightness on panels whose brightness sink is the panel itself
/// (cfg.hasBacklightPin() == false; today that means the CO5300 AMOLED,
/// command 0x51) rather than a PWM backlight pin.
///
/// level uses the project's 0-255 brightness scale. The driver's public API
/// takes percent, so the value quantizes to 100 steps here; imperceptible on
/// the panel, but worth knowing when comparing telemetry to the level sent.
///
/// Returns false when this board's brightness is not panel-command based, so
/// callers can fall through to their PWM path.
inline bool setPanelBrightness(esp_lcd_panel_handle_t panel,
                               const board::Config &cfg, uint8_t level) {
#if defined(ESPDISP_PANEL_CO5300_466X466) || \
    defined(ESPDISP_PANEL_S3_RUNTIME)
  // Only a family that links the CO5300 command API can reach this path.
  if (cfg.hasBacklightPin() ||
      cfg.panel->driver != board::PanelDriver::Co5300) {
    return false;
  }
  uint8_t percent = (uint8_t)(((unsigned)level * 100) / 255);
  return esp_lcd_panel_co5300_set_brightness(panel, percent) == ESP_OK;
#else
  (void)panel;
  (void)cfg;
  (void)level;
  return false;
#endif
}

/// Apply orientation and the user's mounting rotation (clockwise quarter
/// turns, 0-3; 2 is the old 180-degree flip).
///
/// MADCTL affects how incoming pixel writes are addressed rather than scan-out,
/// so a change here becomes visible with the next drawn frame, not immediately.
///
/// The MADCTL matrix is the quarter-turn table in panel_orientation.h,
/// composed as q = rotation + landscape. With rotation limited to {0, 2} that
/// is byte-for-byte the historical four-state table:
///
///   portrait   MADCTL 0       flipped  MX|MY
///   landscape  MV|MX          flipped  MV|MY
///
/// which the host suite asserts, so shipped panels are unaffected. Rotations
/// 1 and 3 only make sense on square glass (the sketch gates them there); on
/// rectangular panels a quarter turn is what the sender-driven landscape
/// mechanism already expresses.
///
inline void applyOrientation(esp_lcd_panel_handle_t panel,
                             const board::Config &cfg, bool landscape,
                             uint8_t rotation,
                             bool installationMirrorX = false) {
  const uint8_t q = panelorient::quadrant(
      (uint8_t)(rotation + cfg.panel->orientationOffset), landscape);
  const bool swap = panelorient::swapXY(q);
  esp_lcd_panel_swap_xy(panel, swap);
  esp_lcd_panel_mirror(panel,
                       panelorient::mirrorX(q, installationMirrorX),
                       panelorient::mirrorY(q, installationMirrorX));
  const panelorient::WindowGap gap = panelorient::windowGap(
      cfg.panel->width, cfg.panel->height, cfg.panel->memoryWidth,
      cfg.panel->memoryHeight, cfg.panel->colOffset, cfg.panel->rowOffset, q,
      installationMirrorX);
  esp_lcd_panel_set_gap(panel, gap.x, gap.y);
  // Report what was actually programmed, because nothing else could: the panel
  // has no readback and the driver is told no resolution, so which quadrant got
  // which gap was previously only inferrable from looking at the glass one flash
  // at a time. Four rounds of that got the placement rule wrong three times. This
  // is a log line and deliberately NOT a new config command - the command surface
  // is a compatibility contract and this is a diagnostic.
  //
  // ONLY ON CHANGE. applyOrientation sits in the render path, and printing every
  // call floods the serial link and starves frames: the first version of this cost
  // 177 dropped frames in 634, against 2 to 12 on the builds either side of it. A
  // diagnostic that perturbs what it measures is worse than none.
  static uint8_t lastQ = 0xFF;
  static uint16_t lastGapX = 0xFFFF, lastGapY = 0xFFFF;
  if (q == lastQ && gap.x == lastGapX && gap.y == lastGapY) return;
  lastQ = q;
  lastGapX = gap.x;
  lastGapY = gap.y;
  Serial.printf(
      "place: q=%u rot=%u landscape=%u swap=%u mx=%u my=%u gap=%u,%u "
      "glass=%ux%u mem=%ux%u near=%u,%u\n",
      (unsigned)q, (unsigned)rotation, (unsigned)landscape, (unsigned)swap,
      (unsigned)panelorient::mirrorX(q, installationMirrorX),
      (unsigned)panelorient::mirrorY(q, installationMirrorX),
      (unsigned)gap.x, (unsigned)gap.y,
      (unsigned)cfg.panel->width, (unsigned)cfg.panel->height,
      (unsigned)cfg.panel->memoryWidth, (unsigned)cfg.panel->memoryHeight,
      (unsigned)cfg.panel->colOffset, (unsigned)cfg.panel->rowOffset);
}

}  // namespace boardpanel
