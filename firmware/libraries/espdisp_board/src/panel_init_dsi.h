// ESP32-P4 MIPI-DSI backend for the ST7703 and JD9365 panel profiles.
#pragma once

#if defined(CONFIG_IDF_TARGET_ESP32P4)
#include <Arduino.h>
#include <driver/gpio.h>
#include <driver/ledc.h>
#include <esp_heap_caps.h>
#include <esp_lcd_mipi_dsi.h>
#include <esp_lcd_panel_io.h>
#include <esp_lcd_panel_ops.h>
#include <esp_ldo_regulator.h>
#include <freertos/semphr.h>
#include <esp_lcd_jd9365.h>
#include <esp_lcd_st7703.h>

#include "board_config.h"
#include "panel_orientation.h"

namespace boardpaneldsi {

// Both Waveshare P4 carriers power the DSI PHY from the chip's LDO_VO3.
static const int PHY_LDO_CHANNEL = 3;
static const int PHY_LDO_MILLIVOLTS = 2500;

inline esp_lcd_dsi_bus_handle_t dsiBus = nullptr;
inline esp_lcd_panel_io_handle_t dbiIo = nullptr;
inline esp_ldo_channel_handle_t phyPower = nullptr;
inline esp_lcd_panel_io_color_trans_done_cb_t completion = nullptr;
inline void *completionContext = nullptr;
inline uint8_t *staging[2] = {nullptr, nullptr};
inline volatile bool stagingBusy[2] = {false, false};
inline uint8_t queue[2] = {0, 0};
inline volatile uint8_t queueHead = 0;
inline volatile uint8_t queueCount = 0;
inline portMUX_TYPE queueMux = portMUX_INITIALIZER_UNLOCKED;
inline uint8_t orientationQuadrant = 0;
inline uint16_t panelWidth = 0;
inline uint16_t panelHeight = 0;
inline int8_t backlightPin = board::NO_PIN;
inline int8_t backlightEnablePin = board::NO_PIN;

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
      (cfg.panel->driver != board::PanelDriver::St7703 &&
       cfg.panel->driver != board::PanelDriver::Jd9365)) {
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
  ldo.chan_id = PHY_LDO_CHANNEL;
  ldo.voltage_mv = PHY_LDO_MILLIVOLTS;
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

  esp_lcd_panel_dev_config_t dev = {};
  dev.reset_gpio_num = cfg.pinRst;
  dev.rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB;
  dev.bits_per_pixel = 16;
  esp_lcd_panel_handle_t panel = nullptr;
  if (cfg.panel->driver == board::PanelDriver::Jd9365) {
    const jd9365_glass_t glass =
        cfg.panel->profile == board::PanelProfile::Jd9365_800x800
            ? JD9365_GLASS_34C_800 : JD9365_GLASS_4C_720;
    jd9365_vendor_config_t vendor = {dsiBus, &dpi, glass};
    dev.vendor_config = &vendor;
    if (esp_lcd_new_panel_jd9365(dbiIo, &dev, &panel) != ESP_OK) return false;
  } else {
    st7703_vendor_config_t vendor = {dsiBus, &dpi};
    dev.vendor_config = &vendor;
    if (esp_lcd_new_panel_st7703(dbiIo, &dev, &panel) != ESP_OK) return false;
  }

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

/// Read the panel controller's DCS ID before any carrier is chosen: power the
/// PHY, bring up a command-mode DSI bus, pulse the panel reset line and read
/// three bytes. Everything is released again, so init() starts from scratch;
/// the reset line is left driven high, out of reset. Only the DSI pads, the
/// PHY LDO and the panel reset GPIO are touched, and every P4 carrier shares
/// them. Returns whether the read itself succeeded. Unbounded: the SDK waits
/// for a reply that an absent panel never sends, so call readPanelId().
inline bool readPanelIdBlocking(const boarddetectmodel::DsiIdProbePlan &plan,
                                uint8_t id[3]) {
  esp_ldo_channel_handle_t ldo = nullptr;
  esp_lcd_dsi_bus_handle_t bus = nullptr;
  esp_lcd_panel_io_handle_t io = nullptr;
  bool ok = false;
  esp_ldo_channel_config_t ldoConfig = {};
  ldoConfig.chan_id = PHY_LDO_CHANNEL;
  ldoConfig.voltage_mv = PHY_LDO_MILLIVOLTS;
  esp_lcd_dsi_bus_config_t busConfig = {};
  busConfig.bus_id = 0;
  busConfig.num_data_lanes = plan.dataLanes;
  busConfig.phy_clk_src = MIPI_DSI_PHY_CLK_SRC_DEFAULT;
  busConfig.lane_bit_rate_mbps = plan.laneMbps;
  esp_lcd_dbi_io_config_t dbi = {};
  dbi.virtual_channel = 0;
  dbi.lcd_cmd_bits = 8;
  dbi.lcd_param_bits = 8;
  if (esp_ldo_acquire_channel(&ldoConfig, &ldo) == ESP_OK &&
      esp_lcd_new_dsi_bus(&busConfig, &bus) == ESP_OK &&
      esp_lcd_new_panel_io_dbi(bus, &dbi, &io) == ESP_OK) {
    if (plan.resetPin != board::NO_PIN) {
      pinMode(plan.resetPin, OUTPUT);
      digitalWrite(plan.resetPin, HIGH);
      delay(5);
      digitalWrite(plan.resetPin, LOW);
      delay(plan.resetLowMs);
      digitalWrite(plan.resetPin, HIGH);
      delay(plan.resetReleaseWaitMs);
    }
    ok = esp_lcd_panel_io_rx_param(
             io, boarddetectmodel::DSI_PANEL_ID_COMMAND, id, 3) == ESP_OK;
  }
  if (io != nullptr) esp_lcd_panel_io_del(io);
  if (bus != nullptr) esp_lcd_del_dsi_bus(bus);
  if (ldo != nullptr) esp_ldo_release_channel(ldo);
  return ok;
}

/// Static so a read abandoned on timeout never writes into a dead frame.
struct PanelIdRead {
  boarddetectmodel::DsiIdProbePlan plan;
  uint8_t id[3];
  bool ok;
  SemaphoreHandle_t done;
};
inline PanelIdRead panelIdRead = {};

inline void panelIdTask(void *) {
  panelIdRead.ok = readPanelIdBlocking(panelIdRead.plan, panelIdRead.id);
  xSemaphoreGive(panelIdRead.done);
  // The caller deletes this task either way, so it never deletes itself and
  // the handle stays valid until then.
  vTaskSuspend(nullptr);
}

/// readPanelIdBlocking() with a deadline. The read runs in its own task; if
/// it has not finished in timeoutMs (the reset pulse takes about 135 ms of
/// that) the task is deleted where it waits and the read counts as failed,
/// so boot reaches serial-only CFGBOARD recovery instead of hanging. The
/// abandoned PHY LDO and DSI bus stay claimed, which is harmless there: that
/// path initializes no panel.
inline bool readPanelId(const boarddetectmodel::DsiIdProbePlan &plan,
                        uint8_t id[3], uint32_t timeoutMs = 1000) {
  if (panelIdRead.done == nullptr) {
    panelIdRead.done = xSemaphoreCreateBinary();
    if (panelIdRead.done == nullptr) return false;
  }
  // A read that finished just after an earlier deadline left the semaphore
  // given; clear it so this call waits for its own read.
  xSemaphoreTake(panelIdRead.done, 0);
  panelIdRead.plan = plan;
  panelIdRead.ok = false;
  TaskHandle_t task = nullptr;
  if (xTaskCreate(panelIdTask, "panelid", 4096, nullptr,
                  uxTaskPriorityGet(nullptr), &task) != pdPASS) {
    return false;
  }
  const bool finished =
      xSemaphoreTake(panelIdRead.done, pdMS_TO_TICKS(timeoutMs)) == pdTRUE;
  vTaskDelete(task);
  if (!finished) return false;
  for (int i = 0; i < 3; ++i) id[i] = panelIdRead.id[i];
  return panelIdRead.ok;
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
