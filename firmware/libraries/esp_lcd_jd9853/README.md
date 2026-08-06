# esp_lcd_jd9853 (vendored)

`esp_lcd` panel driver for the JD9853 LCD controller, which drives the panel on
the **ESP32-C6-Touch-LCD-1.47**. The ESP32 Arduino core ships an ST7789 driver
but no JD9853 one, and this project needs both in a single binary so the
firmware can pick a panel driver at runtime (see
`firmware/libraries/espdisp_board/src/board_config.h`).

It is a library rather than files copied into each sketch folder so that
`display_stream` and `display_test` share one copy.

## Provenance

Extracted from Waveshare's official demo archive for the board:

- Source: `ESP32-C6-Touch-LCD-1.47-Demo.zip`, path
  `ESP-IDF/01_factory/components/esp_lcd_jd9853/`
- Downloaded from
  <https://files.waveshare.com/wiki/ESP32-C6-Touch-LCD-1.47/ESP32-C6-Touch-LCD-1.47-Demo.zip>
- Upstream copyright: Espressif Systems (Shanghai) CO LTD, 2022-2023
- License: Apache-2.0 (SPDX headers retained in both files; full licence text in
  `LICENSE` beside this file, since the rest of this repository is MIT)

Original SHA-256 of the files as extracted, before local modification:

| File               | SHA-256                                                            |
| ------------------ | ------------------------------------------------------------------ |
| `esp_lcd_jd9853.c` | `62b669405e3c009a4e4034b20d1343823d6b11f1528b572a84a074e2b1c5a128` |
| `esp_lcd_jd9853.h` | `d67ecbb84b1d180117f3f38cc89acd92b8c3f6e9fd4c5dea76f944997e448cf9` |

## Local modifications

1. `esp_lcd_jd9853.h`: removed `#include "hal/spi_ll.h"`. Neither the header nor
   the driver references `spi_ll`, and under an Arduino build that header
   resolves only through the chip-specific path
   `hal/esp32c6/include/hal/spi_ll.h`, which is not on the sketch include path.

The vendor initialisation sequence is otherwise untouched, because it is the
part that is specific to this panel and cannot be derived from the datasheet
alone.

## Notes for callers

- The driver implements the full `esp_lcd` panel interface used by this project:
  `reset`, `init`, `draw_bitmap`, `invert_color`, `mirror`, `swap_xy`,
  `set_gap`, and `disp_on_off`.
- It does **not** read `esp_lcd_panel_dev_config_t::data_endian`. That is
  harmless here: the core's ST7789 driver defaults to big-endian and only
  changes behaviour when `data_endian` is explicitly `LCD_RGB_DATA_ENDIAN_LITTLE`,
  so a big-endian (panel-ready) framebuffer is what both drivers expect.
- It reads the deprecated `rgb_endian` union member rather than `rgb_ele_order`.
  Those alias the same storage in `esp_lcd_panel_dev_config_t`, so setting
  `rgb_ele_order` at the call site works as expected.
