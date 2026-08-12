// Panel bring-up and orientation, shared by display_stream and display_test.
//
// Shared rather than copied so the bring-up test exercises the exact code the
// real firmware runs: a test that constructs the panel its own way can pass
// while the firmware's path is broken, which is the failure mode this file
// exists to remove.
//
// The pieces that vary by board (driver, bus, pins, gap, inversion) all come
// out of board_config.h, so there are no board conditionals here beyond
// picking the bus shape and the driver constructor.
//
// Two bus shapes exist:
//   SPI   single data lane plus a D/C pin (the C6 LCDs). 8-bit commands.
//   QSPI  four data lanes, no D/C pin (the CO5300 AMOLED). Commands travel in
//         a 32-bit envelope the panel driver builds itself; this file only
//         has to configure the IO layer for quad mode and 32-bit commands.
#pragma once

#include <driver/spi_master.h>
#include <esp_lcd_panel_io.h>
#include <esp_lcd_panel_ops.h>
#include <esp_lcd_panel_st7789.h>
#include <esp_lcd_panel_vendor.h>

#include <board_config.h>
#include <esp_lcd_co5300.h>
#include <esp_lcd_jd9853.h>

#include "panel_orientation.h"

namespace boardpanel {

/// Bring up the SPI/QSPI bus and the panel described by cfg.
///
/// spiHz is the pixel clock; pass cfg.pclkHz unless deliberately
/// experimenting (80MHz single-lane on the C6 LCDs, 40MHz quad on the
/// CO5300 - both straight from the vendors' own BSPs).
///
/// doneCb fires from an ISR when a queued transfer completes; pass nullptr if
/// the caller does not track DMA completions.
inline bool init(const board::Config &cfg, spi_host_device_t host,
                 uint32_t spiHz, size_t maxTransferSz,
                 esp_lcd_panel_io_color_trans_done_cb_t doneCb, void *userCtx,
                 esp_lcd_panel_io_handle_t *outIo,
                 esp_lcd_panel_handle_t *outPanel) {
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
  if (spi_bus_initialize(host, &buscfg, SPI_DMA_CH_AUTO) != ESP_OK) {
    return false;
  }

  esp_lcd_panel_io_spi_config_t io_config = {};
  io_config.cs_gpio_num = cfg.pinCs;
  io_config.dc_gpio_num = cfg.pinDc;  // NO_PIN (-1) on QSPI: no D/C line
  io_config.spi_mode = 0;
  io_config.pclk_hz = spiHz;
  io_config.trans_queue_depth = 2;
  io_config.on_color_trans_done = doneCb;
  io_config.user_ctx = userCtx;
  if (cfg.isQspi()) {
    // The QSPI command envelope: [opcode 0x02][cmd][0x00] in a 32-bit
    // command word, 8-bit parameters, all four lanes. The CO5300 driver
    // builds the envelope; these widths are what let it through the IO layer.
    io_config.lcd_cmd_bits = 32;
    io_config.lcd_param_bits = 8;
    io_config.flags.quad_mode = 1;
  } else {
    io_config.lcd_cmd_bits = 8;
    io_config.lcd_param_bits = 8;
  }

  esp_lcd_panel_io_handle_t io = nullptr;
  if (esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)host, &io_config, &io) !=
      ESP_OK) {
    return false;
  }

  esp_lcd_panel_dev_config_t panel_config = {};
  panel_config.reset_gpio_num = cfg.pinRst;
  panel_config.rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB;
  // The framebuffer arrives from the Mac already in panel byte order, so the
  // ESP32 never touches a pixel. The core's ST7789 driver defaults to
  // big-endian and only diverges when this is set to LITTLE; the vendored
  // JD9853 and CO5300 drivers do not read the field at all and their panel
  // default is likewise big-endian. Setting BIG is therefore correct on all
  // and a no-op on all - it documents the buffer's contract rather than
  // changing anything.
  panel_config.data_endian = LCD_RGB_DATA_ENDIAN_BIG;
  panel_config.bits_per_pixel = 16;

  esp_lcd_panel_handle_t panel = nullptr;
  esp_err_t err;
  switch (cfg.driver) {
    case board::PanelDriver::Co5300: {
      // The driver must know it is on QSPI to wrap commands in the envelope.
      // It copies what it needs out of vendor_config during construction, so
      // a stack instance is fine; init_cmds = NULL selects the driver's own
      // init table (which carries this glass's column window and SLPOUT).
      co5300_vendor_config_t vendor = {};
      vendor.flags.use_qspi_interface = cfg.isQspi() ? 1 : 0;
      panel_config.vendor_config = &vendor;
      err = esp_lcd_new_panel_co5300(io, &panel_config, &panel);
      break;
    }
    case board::PanelDriver::Jd9853:
      err = esp_lcd_new_panel_jd9853(io, &panel_config, &panel);
      break;
    case board::PanelDriver::St7789:
    default:
      err = esp_lcd_new_panel_st7789(io, &panel_config, &panel);
      break;
  }
  if (err != ESP_OK) {
    return false;
  }

  esp_lcd_panel_reset(panel);
  esp_lcd_panel_init(panel);
  esp_lcd_panel_invert_color(panel, cfg.invertColor);
  esp_lcd_panel_set_gap(panel, cfg.colOffset, 0);
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
  if (cfg.hasBacklightPin() || cfg.driver != board::PanelDriver::Co5300) {
    return false;
  }
  uint8_t percent = (uint8_t)(((unsigned)level * 100) / 255);
  return esp_lcd_panel_co5300_set_brightness(panel, percent) == ESP_OK;
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
/// The centring gap follows the axis swap: colOffset sits on the x axis for
/// even quadrants and moves to the y axis for odd ones, exactly as it always
/// did for landscape. On the 1.47" panels the gap axis is symmetric within
/// the 240-wide controller RAM, so mirroring does not move it. This mapping
/// matches the rotation/gap matrix in Waveshare's own ESP-IDF example for
/// the JD9853 board, and was verified (not assumed) to hold on the ST7789
/// too.
///
/// On the square CO5300 the two orientations address the same buffer shape,
/// so the landscape half of this matrix is inert there; the rotation path is
/// what matters. Whether its 6px gap survives MADCTL mirroring unmoved is
/// NOT yet verified on hardware - if a rotated 1.75C shows a 6px fringe on
/// one edge, the gap likely needs re-deriving per mirror state, and this is
/// the place to do it.
inline void applyOrientation(esp_lcd_panel_handle_t panel,
                             const board::Config &cfg, bool landscape,
                             uint8_t rotation) {
  const uint8_t q = panelorient::quadrant(rotation, landscape);
  const bool swap = panelorient::swapXY(q);
  esp_lcd_panel_swap_xy(panel, swap);
  esp_lcd_panel_mirror(panel, panelorient::mirrorX(q), panelorient::mirrorY(q));
  esp_lcd_panel_set_gap(panel, swap ? 0 : cfg.colOffset,
                        swap ? cfg.colOffset : 0);
}

}  // namespace boardpanel
