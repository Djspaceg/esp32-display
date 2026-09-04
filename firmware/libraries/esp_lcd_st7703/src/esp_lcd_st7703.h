#pragma once

#include <stdint.h>
#include <esp_err.h>
#include <esp_lcd_mipi_dsi.h>
#include <esp_lcd_panel_vendor.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  esp_lcd_dsi_bus_handle_t dsi_bus;
  const esp_lcd_dpi_panel_config_t *dpi_config;
} st7703_vendor_config_t;

// Creates the ST7703 command controller and DPI panel. The caller registers
// DPI callbacks and then calls esp_lcd_panel_init(), so completion interrupts
// are installed before scanout starts.
esp_err_t esp_lcd_new_panel_st7703(
    esp_lcd_panel_io_handle_t io,
    const esp_lcd_panel_dev_config_t *panel_config,
    esp_lcd_panel_handle_t *out_panel);

#ifdef __cplusplus
}
#endif
