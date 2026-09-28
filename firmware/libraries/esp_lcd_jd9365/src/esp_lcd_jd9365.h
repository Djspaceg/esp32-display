#pragma once

#include <stdint.h>
#include <esp_err.h>
#include <esp_lcd_mipi_dsi.h>
#include <esp_lcd_panel_vendor.h>

#ifdef __cplusplus
extern "C" {
#endif

// Which Waveshare XC glass the table is for. The BSP's two tables differ in
// exactly one byte: page 1 register 0x40.
typedef enum {
  JD9365_GLASS_4C_720 = 0,   // ESP32-P4-WIFI6-Touch-LCD-4C, 720x720
  JD9365_GLASS_34C_800 = 1,  // ESP32-P4-WIFI6-Touch-LCD-3.4C, 800x800
} jd9365_glass_t;

typedef struct {
  esp_lcd_dsi_bus_handle_t dsi_bus;
  const esp_lcd_dpi_panel_config_t *dpi_config;
  jd9365_glass_t glass;
} jd9365_vendor_config_t;

// Creates the JD9365 command controller and DPI panel for two DSI lanes and
// RGB565. The caller registers DPI callbacks and then calls
// esp_lcd_panel_init(), so completion interrupts are installed before scanout
// starts.
esp_err_t esp_lcd_new_panel_jd9365(
    esp_lcd_panel_io_handle_t io,
    const esp_lcd_panel_dev_config_t *panel_config,
    esp_lcd_panel_handle_t *out_panel);

#ifdef __cplusplus
}
#endif
