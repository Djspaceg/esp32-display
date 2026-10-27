// In-house SSD1315 I2C OLED backend for the XIAOML Kit's 72x40 panel.
#pragma once

#include <Arduino.h>
#include <Wire.h>
#include <esp_err.h>
#include <esp_lcd_panel_io.h>
#include <esp_lcd_panel_ops.h>

#include "board_config.h"
#include "ssd1315_framebuffer.h"

namespace boardpaneli2c {

static constexpr uint8_t SSD1315_ADDRESS = 0x3C;
static constexpr uint8_t SSD1315_COLUMN_OFFSET = 28;
static constexpr uint32_t I2C_HZ = 400000;
static constexpr size_t DATA_CHUNK_BYTES = 24;

inline uint8_t framebuffer[ssd1315::FRAME_BYTES] = {};
inline uint8_t panelToken = 0;
inline bool ready = false;

inline bool write(uint8_t control, const uint8_t *data, size_t length) {
  if (data == nullptr || length == 0) return false;
  Wire.beginTransmission(SSD1315_ADDRESS);
  if (Wire.write(control) != 1) return false;
  if (Wire.write(data, length) != length) return false;
  return Wire.endTransmission() == 0;
}

inline bool command(const uint8_t *data, size_t length) {
  return write(0x00, data, length);
}

inline bool setOrientation(uint8_t rotation, bool mirrorX) {
  const bool halfTurn = (rotation & 3) == 2;
  const uint8_t commands[] = {
      (uint8_t)((halfTurn ^ mirrorX) ? 0xA0 : 0xA1),
      (uint8_t)(halfTurn ? 0xC0 : 0xC8),
  };
  return command(commands, sizeof(commands));
}

inline esp_err_t flush() {
  if (!ready) return ESP_ERR_INVALID_STATE;
  for (uint8_t page = 0; page < ssd1315::PAGES; ++page) {
    const uint8_t commands[] = {
        (uint8_t)(0xB0 | page),
        (uint8_t)(0x00 | (SSD1315_COLUMN_OFFSET & 0x0F)),
        (uint8_t)(0x10 | (SSD1315_COLUMN_OFFSET >> 4)),
    };
    if (!command(commands, sizeof(commands))) return ESP_FAIL;
    const uint8_t *row = framebuffer + (size_t)page * ssd1315::WIDTH;
    for (size_t offset = 0; offset < ssd1315::WIDTH;
         offset += DATA_CHUNK_BYTES) {
      const size_t bytes =
          ssd1315::WIDTH - offset < DATA_CHUNK_BYTES
              ? ssd1315::WIDTH - offset
              : DATA_CHUNK_BYTES;
      if (!write(0x40, row + offset, bytes)) return ESP_FAIL;
    }
  }
  return ESP_OK;
}

inline bool init(const board::Config &cfg, size_t,
                 esp_lcd_panel_io_color_trans_done_cb_t, void *,
                 esp_lcd_panel_io_handle_t *outIo,
                 esp_lcd_panel_handle_t *outPanel) {
  if (!cfg.isI2c() || cfg.panel == nullptr ||
      cfg.panel->driver != board::PanelDriver::Ssd1315 ||
      cfg.panel->width != ssd1315::WIDTH ||
      cfg.panel->height != ssd1315::HEIGHT ||
      cfg.pinMosi == board::NO_PIN || cfg.pinSclk == board::NO_PIN ||
      outPanel == nullptr) {
    return false;
  }
  if (!Wire.begin(cfg.pinMosi, cfg.pinSclk, I2C_HZ)) return false;

  // The 0.42-inch 72x40 glass sequence: SSD1315 accepts the SSD1306 command
  // set, but needs its 1/40 mux, internal IREF and panel-specific contrast.
  const uint8_t commands[] = {
      0xAE, 0xD5, 0x80, 0xA8, 0x27, 0xD3, 0x00, 0xAD, 0x30,
      0x8D, 0x14, 0x40, 0xA6, 0xA4, 0x20, 0x00, 0xDA, 0x12,
      0x81, 0xAF, 0xD9, 0x22, 0xDB, 0x20, 0x2E, 0xAF,
  };
  if (!command(commands, sizeof(commands)) || !setOrientation(0, false)) {
    Wire.end();
    return false;
  }
  ssd1315::clear(framebuffer);
  ready = true;
  if (flush() != ESP_OK) {
    ready = false;
    Wire.end();
    return false;
  }
  if (outIo != nullptr) *outIo = nullptr;
  *outPanel = reinterpret_cast<esp_lcd_panel_handle_t>(&panelToken);
  return true;
}

inline esp_err_t drawBitmap(const board::Config &cfg, int x0, int y0, int x1,
                            int y1, const void *pixels) {
  if (!cfg.isI2c() ||
      !ssd1315::copyRgb565Be(framebuffer, x0, y0, x1, y1, pixels)) {
    return ESP_ERR_INVALID_ARG;
  }
  return flush();
}

inline void applyOrientation(const board::Config &, uint8_t rotation,
                             bool installationMirrorX) {
  if (!ready) return;
  if (!setOrientation(rotation, installationMirrorX)) {
    Serial.println("panel: SSD1315 orientation command failed");
  }
}

inline bool setBrightness(uint8_t level) {
  const uint8_t commands[] = {0x81, level};
  return ready && command(commands, sizeof(commands));
}

inline esp_err_t setDisplayEnabled(bool enabled) {
  const uint8_t commandByte = enabled ? 0xAF : 0xAE;
  return ready && command(&commandByte, 1) ? ESP_OK : ESP_FAIL;
}

}  // namespace boardpaneli2c
