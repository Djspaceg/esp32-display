// ESP32-P4 MIPI-DSI backend for reusable ST7703 panel profiles.
#pragma once

#if defined(CONFIG_IDF_TARGET_ESP32P4)
#include <Arduino.h>
#include <driver/gpio.h>
#include <driver/ledc.h>
#include <esp_heap_caps.h>
#include <esp_lcd_mipi_dsi.h>
#include <esp_lcd_panel_ops.h>
#include <esp_ldo_regulator.h>
#include <esp_lcd_st7703.h>

#include "board_config.h"
#include "panel_orientation.h"

namespace boardpaneldsi {

static esp_lcd_dsi_bus_handle_t dsiBus = nullptr;
static esp_lcd_panel_io_handle_t dbiIo = nullptr;
static esp_ldo_channel_handle_t phyPower = nullptr;
static esp_lcd_panel_io_color_trans_done_cb_t completion = nullptr;
static void *completionContext = nullptr;
static uint8_t *staging[2] = {nullptr, nullptr};
static volatile bool stagingBusy[2] = {false, false};
static uint8_t queue[2] = {0, 0};
static volatile uint8_t queueHead = 0;
static volatile uint8_t queueCount = 0;
static portMUX_TYPE queueMux = portMUX_INITIALIZER_UNLOCKED;
static uint8_t orientationQuadrant = 0;
static uint16_t panelWidth = 0;
static uint16_t panelHeight = 0;
static int8_t backlightPin = board::NO_PIN;
static int8_t backlightEnablePin = board::NO_PIN;

static bool IRAM_ATTR onColorDone(esp_lcd_panel_handle_t,
                                  esp_lcd_dpi_panel_event_data_t *, void *) {
  portENTER_CRITICAL_ISR(&queueMux);
  if (queueCount > 0) {
    const uint8_t slot = queue[queueHead];
    stagingBusy[slot] = false;
    queueHead = (uint8_t)((queueHead + 1) & 1);
    queueCount--;
  }
  portEXIT_CRITICAL_ISR(&queueMux);
  return completion ? completion(nullptr, nullptr, completionContext) : false;
}

inline bool init(const board::Config &cfg, size_t maxTransfer,
                 esp_lcd_panel_io_color_trans_done_cb_t doneCb, void *userCtx,
                 esp_lcd_panel_io_handle_t *outIo,
                 esp_lcd_panel_handle_t *outPanel) {
  if (!cfg.isDsi() || cfg.panel == nullptr ||
      cfg.panel->driver != board::PanelDriver::St7703) {
    return false;
  }
  completion = doneCb;
  completionContext = userCtx;
  panelWidth = cfg.panel->width;
  panelHeight = cfg.panel->height;
  backlightPin = cfg.pinBl;
  backlightEnablePin = cfg.pinBlEnable;

  if (backlightEnablePin != board::NO_PIN) {
    pinMode(backlightEnablePin, OUTPUT);
    digitalWrite(backlightEnablePin, LOW);
  }
  ledc_timer_config_t timer = {};
  timer.speed_mode = LEDC_LOW_SPEED_MODE;
  timer.duty_resolution = LEDC_TIMER_10_BIT;
  timer.timer_num = LEDC_TIMER_0;
  timer.freq_hz = 5000;
  timer.clk_cfg = LEDC_AUTO_CLK;
  if (ledc_timer_config(&timer) != ESP_OK) return false;
  ledc_channel_config_t channel = {};
  channel.gpio_num = backlightPin;
  channel.speed_mode = LEDC_LOW_SPEED_MODE;
  channel.channel = LEDC_CHANNEL_0;
  channel.intr_type = LEDC_INTR_DISABLE;
  channel.timer_sel = LEDC_TIMER_0;
  channel.duty = 0;
  channel.flags.output_invert = cfg.backlightInverted ? 1 : 0;
  if (ledc_channel_config(&channel) != ESP_OK) return false;

  esp_ldo_channel_config_t ldo = {};
  ldo.chan_id = 3;
  ldo.voltage_mv = 2500;
  if (esp_ldo_acquire_channel(&ldo, &phyPower) != ESP_OK) return false;

  esp_lcd_dsi_bus_config_t bus = {};
  bus.bus_id = 0;
  bus.num_data_lanes = cfg.panel->dsiDataLanes;
  bus.phy_clk_src = MIPI_DSI_PHY_CLK_SRC_DEFAULT;
  bus.lane_bit_rate_mbps = cfg.panel->dsiLaneMbps;
  if (esp_lcd_new_dsi_bus(&bus, &dsiBus) != ESP_OK) return false;

  esp_lcd_dbi_io_config_t dbi = {};
  dbi.virtual_channel = 0;
  dbi.lcd_cmd_bits = 8;
  dbi.lcd_param_bits = 8;
  if (esp_lcd_new_panel_io_dbi(dsiBus, &dbi, &dbiIo) != ESP_OK) return false;

  esp_lcd_dpi_panel_config_t dpi = {};
  dpi.virtual_channel = 0;
  dpi.dpi_clk_src = MIPI_DSI_DPI_CLK_SRC_DEFAULT;
  dpi.dpi_clock_freq_mhz = cfg.panel->pixelClockHz / 1000000.0f;
  dpi.pixel_format = LCD_COLOR_PIXEL_FORMAT_RGB565;
  dpi.num_fbs = 1;
  dpi.video_timing.h_size = cfg.panel->width;
  dpi.video_timing.v_size = cfg.panel->height;
  dpi.video_timing.hsync_back_porch = cfg.panel->hsyncBackPorch;
  dpi.video_timing.hsync_pulse_width = cfg.panel->hsyncPulseWidth;
  dpi.video_timing.hsync_front_porch = cfg.panel->hsyncFrontPorch;
  dpi.video_timing.vsync_back_porch = cfg.panel->vsyncBackPorch;
  dpi.video_timing.vsync_pulse_width = cfg.panel->vsyncPulseWidth;
  dpi.video_timing.vsync_front_porch = cfg.panel->vsyncFrontPorch;
  dpi.flags.use_dma2d = 1;

  st7703_vendor_config_t vendor = {dsiBus, &dpi};
  esp_lcd_panel_dev_config_t dev = {};
  dev.reset_gpio_num = cfg.pinRst;
  dev.rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB;
  dev.bits_per_pixel = 16;
  dev.vendor_config = &vendor;
  esp_lcd_panel_handle_t panel = nullptr;
  if (esp_lcd_new_panel_st7703(dbiIo, &dev, &panel) != ESP_OK) return false;

  esp_lcd_dpi_panel_event_callbacks_t callbacks = {};
  callbacks.on_color_trans_done = onColorDone;
  if (esp_lcd_dpi_panel_register_event_callbacks(panel, &callbacks, nullptr) !=
      ESP_OK) {
    return false;
  }
  // Register completion before panel init starts scanout. This ordering is
  // required for the first full-frame transfer to release its source buffer.
  if (esp_lcd_panel_init(panel) != ESP_OK) return false;

  const size_t stageBytes = maxTransfer < (size_t)panelWidth * panelHeight * 2
                                ? (size_t)panelWidth * panelHeight * 2
                                : maxTransfer;
  for (int i = 0; i < 2; ++i) {
    staging[i] = (uint8_t *)heap_caps_malloc(
        stageBytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!staging[i]) return false;
  }
  if (backlightEnablePin != board::NO_PIN) digitalWrite(backlightEnablePin, HIGH);
  if (outIo) *outIo = dbiIo;
  *outPanel = panel;
  return true;
}

inline esp_err_t drawBitmap(esp_lcd_panel_handle_t panel, int x0, int y0,
                            int x1, int y1, const void *pixels) {
  if (!panel || !pixels || x0 < 0 || y0 < 0 || x1 <= x0 || y1 <= y0 ||
      x1 > panelWidth || y1 > panelHeight) {
    return ESP_ERR_INVALID_ARG;
  }
  int slot = -1;
  const uint32_t started = millis();
  while (slot < 0) {
    portENTER_CRITICAL(&queueMux);
    for (int i = 0; i < 2; ++i) {
      if (!stagingBusy[i]) {
        stagingBusy[i] = true;
        slot = i;
        break;
      }
    }
    portEXIT_CRITICAL(&queueMux);
    if (slot < 0) {
      if ((uint32_t)(millis() - started) > 500) return ESP_ERR_TIMEOUT;
      delay(1);
    }
  }

  const int w = x1 - x0;
  const int h = y1 - y0;
  int dx0 = x0, dy0 = y0, dw = w, dh = h;
  switch (orientationQuadrant & 3) {
    case 1: dx0 = panelWidth - y1; dy0 = x0; dw = h; dh = w; break;
    case 2: dx0 = panelWidth - x1; dy0 = panelHeight - y1; break;
    case 3: dx0 = y0; dy0 = panelHeight - x1; dw = h; dh = w; break;
    default: break;
  }
  const uint8_t *src = static_cast<const uint8_t *>(pixels);
  uint8_t *dst = staging[slot];
  for (int sy = 0; sy < h; ++sy) {
    for (int sx = 0; sx < w; ++sx) {
      int ox = sx, oy = sy;
      switch (orientationQuadrant & 3) {
        case 1: ox = h - 1 - sy; oy = sx; break;
        case 2: ox = w - 1 - sx; oy = h - 1 - sy; break;
        case 3: ox = sy; oy = w - 1 - sx; break;
        default: break;
      }
      const size_t from = ((size_t)sy * w + sx) * 2;
      const size_t to = ((size_t)oy * dw + ox) * 2;
      // The wire/cache is RGB565 big-endian; the DPI framebuffer is native
      // little-endian RGB565 on P4.
      dst[to] = src[from + 1];
      dst[to + 1] = src[from];
    }
  }

  portENTER_CRITICAL(&queueMux);
  queue[(queueHead + queueCount) & 1] = (uint8_t)slot;
  queueCount++;
  portEXIT_CRITICAL(&queueMux);
  const esp_err_t err = esp_lcd_panel_draw_bitmap(
      panel, dx0, dy0, dx0 + dw, dy0 + dh, dst);
  if (err != ESP_OK) {
    portENTER_CRITICAL(&queueMux);
    if (queueCount > 0) queueCount--;
    stagingBusy[slot] = false;
    portEXIT_CRITICAL(&queueMux);
  }
  return err;
}

inline void applyOrientation(const board::Config &cfg, bool landscape,
                             uint8_t rotation) {
  orientationQuadrant = panelorient::quadrant(
      (uint8_t)(rotation + cfg.panel->orientationOffset), landscape);
}

inline bool setBrightness(uint8_t level) {
  if (backlightPin == board::NO_PIN) return false;
  const uint32_t duty = ((uint32_t)level * 1023u) / 255u;
  if (backlightEnablePin != board::NO_PIN) {
    digitalWrite(backlightEnablePin, level == 0 ? LOW : HIGH);
  }
  return ledc_set_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, duty) == ESP_OK &&
         ledc_update_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0) == ESP_OK;
}

}  // namespace boardpaneldsi
#endif
