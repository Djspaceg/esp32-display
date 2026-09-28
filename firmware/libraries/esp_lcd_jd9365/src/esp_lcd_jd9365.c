// SPDX-License-Identifier: Apache-2.0
// JD9365 MIPI-DSI initialization adapted from Espressif's esp_lcd_jd9365
// component 2.0.2, with the 720x720 panel table from Waveshare's
// esp32_p4_wifi6_touch_lcd_xc BSP 3.0.1 (the CONFIG_BSP_LCD_TYPE_720_720_4_INCH
// branch, which is the ESP32-P4-WIFI6-Touch-LCD-4C's glass).
#include "esp_lcd_jd9365.h"

#include <stdlib.h>
#include <driver/gpio.h>
#include <esp_lcd_panel_commands.h>
#include <esp_lcd_panel_io.h>
#include <esp_lcd_panel_ops.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <soc/soc_caps.h>

#if SOC_MIPI_DSI_SUPPORTED

typedef struct {
  uint8_t cmd;
  const uint8_t *data;
  uint8_t length;
  uint16_t delay_ms;
} init_command_t;

#define BYTES(...) ((const uint8_t[]){__VA_ARGS__})

// Register 0xE0 selects the command page; every other entry writes the
// selected page. The table ends back on page 0 with sleep-out, display-on and
// tearing-effect-on.
static const init_command_t INIT[] = {
    {0xE0, BYTES(0x00), 1, 0},

    {0xE1, BYTES(0x93), 1, 0},
    {0xE2, BYTES(0x65), 1, 0},
    {0xE3, BYTES(0xF8), 1, 0},
    {0x80, BYTES(0x01), 1, 0},

    {0xE0, BYTES(0x01), 1, 0},

    {0x00, BYTES(0x00), 1, 0},
    {0x01, BYTES(0x41), 1, 0},
    {0x03, BYTES(0x10), 1, 0},
    {0x04, BYTES(0x44), 1, 0},

    {0x17, BYTES(0x00), 1, 0},
    {0x18, BYTES(0xD0), 1, 0},
    {0x19, BYTES(0x00), 1, 0},
    {0x1A, BYTES(0x00), 1, 0},
    {0x1B, BYTES(0xD0), 1, 0},
    {0x1C, BYTES(0x00), 1, 0},

    {0x24, BYTES(0xFE), 1, 0},
    {0x35, BYTES(0x26), 1, 0},

    {0x37, BYTES(0x09), 1, 0},

    {0x38, BYTES(0x04), 1, 0},
    {0x39, BYTES(0x08), 1, 0},
    {0x3A, BYTES(0x0A), 1, 0},
    {0x3C, BYTES(0x78), 1, 0},
    {0x3D, BYTES(0xFF), 1, 0},
    {0x3E, BYTES(0xFF), 1, 0},
    {0x3F, BYTES(0xFF), 1, 0},

    {0x40, BYTES(0x04), 1, 0},
    {0x41, BYTES(0x64), 1, 0},
    {0x42, BYTES(0xC7), 1, 0},
    {0x43, BYTES(0x18), 1, 0},
    {0x44, BYTES(0x0B), 1, 0},
    {0x45, BYTES(0x14), 1, 0},

    {0x55, BYTES(0x02), 1, 0},
    {0x57, BYTES(0x49), 1, 0},
    {0x59, BYTES(0x0A), 1, 0},
    {0x5A, BYTES(0x1B), 1, 0},
    {0x5B, BYTES(0x19), 1, 0},

    {0x5D, BYTES(0x7F), 1, 0},
    {0x5E, BYTES(0x56), 1, 0},
    {0x5F, BYTES(0x43), 1, 0},
    {0x60, BYTES(0x37), 1, 0},
    {0x61, BYTES(0x33), 1, 0},
    {0x62, BYTES(0x25), 1, 0},
    {0x63, BYTES(0x2A), 1, 0},
    {0x64, BYTES(0x16), 1, 0},
    {0x65, BYTES(0x30), 1, 0},
    {0x66, BYTES(0x2F), 1, 0},
    {0x67, BYTES(0x32), 1, 0},
    {0x68, BYTES(0x53), 1, 0},
    {0x69, BYTES(0x43), 1, 0},
    {0x6A, BYTES(0x4C), 1, 0},
    {0x6B, BYTES(0x40), 1, 0},
    {0x6C, BYTES(0x3D), 1, 0},
    {0x6D, BYTES(0x31), 1, 0},
    {0x6E, BYTES(0x20), 1, 0},
    {0x6F, BYTES(0x0F), 1, 0},

    {0x70, BYTES(0x7F), 1, 0},
    {0x71, BYTES(0x56), 1, 0},
    {0x72, BYTES(0x43), 1, 0},
    {0x73, BYTES(0x37), 1, 0},
    {0x74, BYTES(0x33), 1, 0},
    {0x75, BYTES(0x25), 1, 0},
    {0x76, BYTES(0x2A), 1, 0},
    {0x77, BYTES(0x16), 1, 0},
    {0x78, BYTES(0x30), 1, 0},
    {0x79, BYTES(0x2F), 1, 0},
    {0x7A, BYTES(0x32), 1, 0},
    {0x7B, BYTES(0x53), 1, 0},
    {0x7C, BYTES(0x43), 1, 0},
    {0x7D, BYTES(0x4C), 1, 0},
    {0x7E, BYTES(0x40), 1, 0},
    {0x7F, BYTES(0x3D), 1, 0},
    {0x80, BYTES(0x31), 1, 0},
    {0x81, BYTES(0x20), 1, 0},
    {0x82, BYTES(0x0F), 1, 0},

    {0xE0, BYTES(0x02), 1, 0},
    {0x00, BYTES(0x5F), 1, 0},
    {0x01, BYTES(0x5F), 1, 0},
    {0x02, BYTES(0x5E), 1, 0},
    {0x03, BYTES(0x5E), 1, 0},
    {0x04, BYTES(0x50), 1, 0},
    {0x05, BYTES(0x48), 1, 0},
    {0x06, BYTES(0x48), 1, 0},
    {0x07, BYTES(0x4A), 1, 0},
    {0x08, BYTES(0x4A), 1, 0},
    {0x09, BYTES(0x44), 1, 0},
    {0x0A, BYTES(0x44), 1, 0},
    {0x0B, BYTES(0x46), 1, 0},
    {0x0C, BYTES(0x46), 1, 0},
    {0x0D, BYTES(0x5F), 1, 0},
    {0x0E, BYTES(0x5F), 1, 0},
    {0x0F, BYTES(0x57), 1, 0},
    {0x10, BYTES(0x57), 1, 0},
    {0x11, BYTES(0x77), 1, 0},
    {0x12, BYTES(0x77), 1, 0},
    {0x13, BYTES(0x40), 1, 0},
    {0x14, BYTES(0x42), 1, 0},
    {0x15, BYTES(0x5F), 1, 0},

    {0x16, BYTES(0x5F), 1, 0},
    {0x17, BYTES(0x5F), 1, 0},
    {0x18, BYTES(0x5E), 1, 0},
    {0x19, BYTES(0x5E), 1, 0},
    {0x1A, BYTES(0x50), 1, 0},
    {0x1B, BYTES(0x49), 1, 0},
    {0x1C, BYTES(0x49), 1, 0},
    {0x1D, BYTES(0x4B), 1, 0},
    {0x1E, BYTES(0x4B), 1, 0},
    {0x1F, BYTES(0x45), 1, 0},
    {0x20, BYTES(0x45), 1, 0},
    {0x21, BYTES(0x47), 1, 0},
    {0x22, BYTES(0x47), 1, 0},
    {0x23, BYTES(0x5F), 1, 0},
    {0x24, BYTES(0x5F), 1, 0},
    {0x25, BYTES(0x57), 1, 0},
    {0x26, BYTES(0x57), 1, 0},
    {0x27, BYTES(0x77), 1, 0},
    {0x28, BYTES(0x77), 1, 0},
    {0x29, BYTES(0x41), 1, 0},
    {0x2A, BYTES(0x43), 1, 0},
    {0x2B, BYTES(0x5F), 1, 0},

    {0x2C, BYTES(0x1E), 1, 0},
    {0x2D, BYTES(0x1E), 1, 0},
    {0x2E, BYTES(0x1F), 1, 0},
    {0x2F, BYTES(0x1F), 1, 0},
    {0x30, BYTES(0x10), 1, 0},
    {0x31, BYTES(0x07), 1, 0},
    {0x32, BYTES(0x07), 1, 0},
    {0x33, BYTES(0x05), 1, 0},
    {0x34, BYTES(0x05), 1, 0},
    {0x35, BYTES(0x0B), 1, 0},
    {0x36, BYTES(0x0B), 1, 0},
    {0x37, BYTES(0x09), 1, 0},
    {0x38, BYTES(0x09), 1, 0},
    {0x39, BYTES(0x1F), 1, 0},
    {0x3A, BYTES(0x1F), 1, 0},
    {0x3B, BYTES(0x17), 1, 0},
    {0x3C, BYTES(0x17), 1, 0},
    {0x3D, BYTES(0x17), 1, 0},
    {0x3E, BYTES(0x17), 1, 0},
    {0x3F, BYTES(0x03), 1, 0},
    {0x40, BYTES(0x01), 1, 0},
    {0x41, BYTES(0x1F), 1, 0},

    {0x42, BYTES(0x1E), 1, 0},
    {0x43, BYTES(0x1E), 1, 0},
    {0x44, BYTES(0x1F), 1, 0},
    {0x45, BYTES(0x1F), 1, 0},
    {0x46, BYTES(0x10), 1, 0},
    {0x47, BYTES(0x06), 1, 0},
    {0x48, BYTES(0x06), 1, 0},
    {0x49, BYTES(0x04), 1, 0},
    {0x4A, BYTES(0x04), 1, 0},
    {0x4B, BYTES(0x0A), 1, 0},
    {0x4C, BYTES(0x0A), 1, 0},
    {0x4D, BYTES(0x08), 1, 0},
    {0x4E, BYTES(0x08), 1, 0},
    {0x4F, BYTES(0x1F), 1, 0},
    {0x50, BYTES(0x1F), 1, 0},
    {0x51, BYTES(0x17), 1, 0},
    {0x52, BYTES(0x17), 1, 0},
    {0x53, BYTES(0x17), 1, 0},
    {0x54, BYTES(0x17), 1, 0},
    {0x55, BYTES(0x02), 1, 0},
    {0x56, BYTES(0x00), 1, 0},
    {0x57, BYTES(0x1F), 1, 0},

    {0xE0, BYTES(0x02), 1, 0},
    {0x58, BYTES(0x40), 1, 0},
    {0x59, BYTES(0x00), 1, 0},
    {0x5A, BYTES(0x00), 1, 0},
    {0x5B, BYTES(0x30), 1, 0},
    {0x5C, BYTES(0x01), 1, 0},
    {0x5D, BYTES(0x30), 1, 0},
    {0x5E, BYTES(0x01), 1, 0},
    {0x5F, BYTES(0x02), 1, 0},
    {0x60, BYTES(0x30), 1, 0},
    {0x61, BYTES(0x03), 1, 0},
    {0x62, BYTES(0x04), 1, 0},
    {0x63, BYTES(0x04), 1, 0},
    {0x64, BYTES(0xA6), 1, 0},
    {0x65, BYTES(0x43), 1, 0},
    {0x66, BYTES(0x30), 1, 0},
    {0x67, BYTES(0x73), 1, 0},
    {0x68, BYTES(0x05), 1, 0},
    {0x69, BYTES(0x04), 1, 0},
    {0x6A, BYTES(0x7F), 1, 0},
    {0x6B, BYTES(0x08), 1, 0},
    {0x6C, BYTES(0x00), 1, 0},
    {0x6D, BYTES(0x04), 1, 0},
    {0x6E, BYTES(0x04), 1, 0},
    {0x6F, BYTES(0x88), 1, 0},

    {0x75, BYTES(0xD9), 1, 0},
    {0x76, BYTES(0x00), 1, 0},
    {0x77, BYTES(0x33), 1, 0},
    {0x78, BYTES(0x43), 1, 0},

    {0xE0, BYTES(0x00), 1, 0},
    {0x11, BYTES(0x00), 1, 120},

    {0x29, BYTES(0x00), 1, 20},
    {0x35, BYTES(0x00), 1, 0},
};

// Controller-level setup the Espressif driver sends before the vendor table:
// page 0, pixel order, RGB565 and the DSI lane count (0x80: 0x01 = two lanes).
static const uint8_t PAGE_SELECT = 0xE0;
static const uint8_t PAGE_USER = 0x00;
static const uint8_t DSI_LANE_CONFIG = 0x80;
static const uint8_t DSI_TWO_LANES = 0x01;
static const uint8_t COLMOD_RGB565 = 0x55;

esp_err_t esp_lcd_new_panel_jd9365(
    esp_lcd_panel_io_handle_t io,
    const esp_lcd_panel_dev_config_t *panel_config,
    esp_lcd_panel_handle_t *out_panel) {
  if (!io || !panel_config || !panel_config->vendor_config || !out_panel) {
    return ESP_ERR_INVALID_ARG;
  }
  const jd9365_vendor_config_t *vendor =
      (const jd9365_vendor_config_t *)panel_config->vendor_config;
  if (!vendor->dsi_bus || !vendor->dpi_config) return ESP_ERR_INVALID_ARG;
  if (panel_config->bits_per_pixel != 16) return ESP_ERR_NOT_SUPPORTED;

  if (panel_config->reset_gpio_num >= 0) {
    gpio_config_t gpio = {
        .pin_bit_mask = 1ULL << panel_config->reset_gpio_num,
        .mode = GPIO_MODE_OUTPUT,
    };
    esp_err_t err = gpio_config(&gpio);
    if (err != ESP_OK) return err;
    gpio_set_level(panel_config->reset_gpio_num, 1);
    vTaskDelay(pdMS_TO_TICKS(5));
    gpio_set_level(panel_config->reset_gpio_num, 0);
    vTaskDelay(pdMS_TO_TICKS(10));
    gpio_set_level(panel_config->reset_gpio_num, 1);
    vTaskDelay(pdMS_TO_TICKS(120));
  }

  const uint8_t madctl =
      panel_config->rgb_ele_order == LCD_RGB_ELEMENT_ORDER_BGR
          ? LCD_CMD_BGR_BIT : 0;
  esp_err_t err = esp_lcd_panel_io_tx_param(io, PAGE_SELECT, &PAGE_USER, 1);
  if (err == ESP_OK) {
    err = esp_lcd_panel_io_tx_param(io, LCD_CMD_MADCTL, &madctl, 1);
  }
  if (err == ESP_OK) {
    err = esp_lcd_panel_io_tx_param(io, LCD_CMD_COLMOD, &COLMOD_RGB565, 1);
  }
  if (err == ESP_OK) {
    err = esp_lcd_panel_io_tx_param(io, DSI_LANE_CONFIG, &DSI_TWO_LANES, 1);
  }
  if (err != ESP_OK) return err;
  for (size_t i = 0; i < sizeof(INIT) / sizeof(INIT[0]); ++i) {
    err = esp_lcd_panel_io_tx_param(
        io, INIT[i].cmd, INIT[i].data, INIT[i].length);
    if (err != ESP_OK) return err;
    if (INIT[i].delay_ms) vTaskDelay(pdMS_TO_TICKS(INIT[i].delay_ms));
  }

  esp_lcd_panel_handle_t panel = NULL;
  err = esp_lcd_new_panel_dpi(vendor->dsi_bus, vendor->dpi_config, &panel);
  if (err != ESP_OK) return err;
  *out_panel = panel;
  return ESP_OK;
}

#else
esp_err_t esp_lcd_new_panel_jd9365(
    esp_lcd_panel_io_handle_t io,
    const esp_lcd_panel_dev_config_t *panel_config,
    esp_lcd_panel_handle_t *out_panel) {
  (void)io;
  (void)panel_config;
  (void)out_panel;
  return ESP_ERR_NOT_SUPPORTED;
}
#endif
