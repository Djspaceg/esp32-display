# esp_lcd_jd9365

Arduino-library adaptation of Espressif's JD9365 MIPI-DSI component, version 2.0.2 from esp-iot-solution commit `bd85f52467353dae3bd5f551054795287b0042a4`, carrying the 720x720 panel table from Waveshare's `esp32_p4_wifi6_touch_lcd_xc` BSP version 3.0.1 (its `CONFIG_BSP_LCD_TYPE_720_720_4_INCH` branch).

Sources:

- <https://components.espressif.com/components/espressif/esp_lcd_jd9365/versions/2.0.2>
- <https://components.espressif.com/components/waveshare/esp32_p4_wifi6_touch_lcd_xc/versions/3.0.1>

The 3.4-inch 800x800 sibling (ESP32-P4-WIFI6-Touch-LCD-3.4C) uses the same BSP. Its table differs in one byte, page 1 register 0x40 (0x00 instead of the 4C's 0x04), which the adapter supplies from `jd9365_vendor_config_t.glass`.

The initialization bytes are panel data. The controller setup (page 0, MADCTL, COLMOD RGB565, two-lane DSI) is the component's own sequence. The adapter exposes the same small factory as `esp_lcd_st7703` and keeps the ESP-IDF MIPI-DPI scanout path. Both upstream sources are Apache-2.0.
