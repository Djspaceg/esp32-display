// Panel bring-up and orientation, shared by display_stream and display_test.
//
// Shared rather than copied so the bring-up test exercises the exact code the
// real firmware runs: a test that constructs the panel its own way can pass
// while the firmware's path is broken, which is the failure mode this file
// exists to remove.
//
// The pieces that vary by board (driver, pins, gap, inversion) all come out of
// board_config.h, so there are no board conditionals here beyond picking the
// driver constructor.
#pragma once

#include <driver/spi_master.h>
#include <esp_lcd_panel_io.h>
#include <esp_lcd_panel_ops.h>
#include <esp_lcd_panel_st7789.h>
#include <esp_lcd_panel_vendor.h>

#include <board_config.h>
#include <esp_lcd_jd9853.h>

namespace boardpanel {

/// Bring up the SPI bus and the panel described by cfg.
///
/// spiHz is the pixel clock. 80MHz is what both Waveshare BSPs use and what
/// this project's throughput budget assumes.
///
/// doneCb fires from an ISR when a queued transfer completes; pass nullptr if
/// the caller does not track DMA completions.
inline bool init(const board::Config &cfg, spi_host_device_t host,
                 uint32_t spiHz, size_t maxTransferSz,
                 esp_lcd_panel_io_color_trans_done_cb_t doneCb, void *userCtx,
                 esp_lcd_panel_io_handle_t *outIo,
                 esp_lcd_panel_handle_t *outPanel) {
  spi_bus_config_t buscfg = {};
  buscfg.mosi_io_num = cfg.pinMosi;
  buscfg.miso_io_num = -1;  // nothing to read back; MISO is unused on both boards
  buscfg.sclk_io_num = cfg.pinSclk;
  buscfg.quadwp_io_num = -1;
  buscfg.quadhd_io_num = -1;
  buscfg.max_transfer_sz = (int)maxTransferSz;
  if (spi_bus_initialize(host, &buscfg, SPI_DMA_CH_AUTO) != ESP_OK) {
    return false;
  }

  esp_lcd_panel_io_spi_config_t io_config = {};
  io_config.cs_gpio_num = cfg.pinCs;
  io_config.dc_gpio_num = cfg.pinDc;
  io_config.spi_mode = 0;
  io_config.pclk_hz = spiHz;
  io_config.trans_queue_depth = 2;
  io_config.on_color_trans_done = doneCb;
  io_config.user_ctx = userCtx;
  io_config.lcd_cmd_bits = 8;
  io_config.lcd_param_bits = 8;

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
  // JD9853 driver does not read the field at all and its panel default is
  // likewise big-endian. Setting BIG is therefore correct on both and a no-op
  // on both - it documents the buffer's contract rather than changing anything.
  panel_config.data_endian = LCD_RGB_DATA_ENDIAN_BIG;
  panel_config.bits_per_pixel = 16;

  esp_lcd_panel_handle_t panel = nullptr;
  esp_err_t err;
  switch (cfg.driver) {
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

/// Apply orientation and the user's 180-degree mounting flip.
///
/// MADCTL affects how incoming pixel writes are addressed rather than scan-out,
/// so a change here becomes visible with the next drawn frame, not immediately.
///
///   portrait   MADCTL 0       flipped  MX|MY
///   landscape  MV|MX          flipped  MV|MY
///
/// The centring gap sits on the 172px axis, which is symmetric within the
/// 240-wide controller RAM, so mirroring does not move it.
///
/// This mapping is identical on both boards: it matches the rotation/gap matrix
/// in Waveshare's own ESP-IDF example for the JD9853 board, which drives the
/// same esp_lcd API. That is worth stating because the panels are different
/// controllers - the agreement was verified, not assumed.
inline void applyOrientation(esp_lcd_panel_handle_t panel,
                             const board::Config &cfg, bool landscape,
                             bool flip180) {
  bool mx = landscape ? !flip180 : flip180;
  bool my = flip180;
  esp_lcd_panel_swap_xy(panel, landscape);
  esp_lcd_panel_mirror(panel, mx, my);
  esp_lcd_panel_set_gap(panel, landscape ? 0 : cfg.colOffset,
                        landscape ? cfg.colOffset : 0);
}

}  // namespace boardpanel
