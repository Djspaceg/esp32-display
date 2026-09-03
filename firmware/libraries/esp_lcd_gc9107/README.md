# esp_lcd_gc9107 (vendored)

`esp_lcd` panel driver for the GC9107 LCD controller, which drives the
0.85-inch 128x128 panel on the **ESP32-S3-LCD-0.85** over 4-wire write-only
SPI. Vendored so the firmware can construct this panel through the same
`esp_lcd` API it uses for the ST7789, JD9853, CO5300, and ST77916 (see
`firmware/libraries/espdisp_board/src/board_config.h`).

It is a library rather than files copied into each sketch folder so that
`display_stream` and `display_test` share one copy.

## Provenance

Derived from Espressif's GC9107 `esp_lcd` component:

- Source: Espressif component registry
  <https://components.espressif.com/components/espressif/esp_lcd_gc9107>,
  component version 2.0.0 (per its `idf_component.yml`)
- Upstream repository: `components/display/lcd/esp_lcd_gc9107/` in
  <https://github.com/espressif/esp-iot-solution>
- Upstream copyright: Espressif Systems (Shanghai) CO LTD, 2023-2025
- License: Apache-2.0 (SPDX headers retained in all files; full licence text
  in `LICENSE` beside this file, since the rest of this repository is MIT)

The driver follows the same public API and panel-interface shape as the other
vendored Espressif single-lane SPI driver in this repository
(`esp_lcd_jd9853`): the `gc9107_lcd_init_cmd_t` / `gc9107_vendor_config_t`
structures and the `esp_lcd_new_panel_gc9107` constructor. Content from the web
sources was rephrased for compliance with licensing restrictions.

SHA-256 of the vendored files, so a reviewer can confirm nothing changed after
they were written into the tree:

- `src/esp_lcd_gc9107.c`: `44bfa7fe004a6938b6359ec0d54f91f8fde964f26822aac402cdfae1df5410c0`
- `src/esp_lcd_gc9107.h`: `476b75204365332ac2c315859cbebe34420af2970b87ce234e9fa5820468a1b9`

## Local modifications

1. `esp_lcd_gc9107.h`: added fallback definitions of
   `ESP_LCD_GC9107_VER_MAJOR/MINOR/PATCH` (2.0.0). Upstream generates these
   through `cu_pkg_define_version` in its CMake build, which the Arduino build
   does not run; without them the driver's creation log line fails to compile.
2. **Not vendored:** upstream's CMake-only files (`CMakeLists.txt`,
   `idf_component.yml`) and any test apps. The Arduino build resolves the
   library from `library.properties` and `src/` alone.

The panel-specific initialisation sequence is **not** baked into the driver:
the ESP32-S3-LCD-0.85 board passes Waveshare's own GC9107 command table through
`gc9107_vendor_config_t::init_cmds` from `panel_init.h`. The driver's built-in
`vendor_specific_init_default` is only a fallback (register unlock, RGB565,
inversion, sleep-out, display-on) used when a caller passes `NULL`.

## Notes for callers

- Construct with `esp_lcd_new_panel_gc9107(io, &panel_config, &panel)`. The IO
  is single-lane SPI with a D/C pin, `spi_mode = 0`, `lcd_cmd_bits = 8`,
  `lcd_param_bits = 8` - the same shape the JD9853 uses.
- The panel expects big-endian RGB565, which is the byte order this project's
  framebuffers already use, so the ESP32 never re-orders a pixel.
- Set `esp_lcd_panel_dev_config_t::rgb_ele_order = LCD_RGB_ELEMENT_ORDER_BGR`.
  The driver preserves that BGR bit while `panel_init.h` applies the board's
  `MY|MX` native-orientation offset.
- The GC9107 controller RAM is 128x160 while the visible glass is 128x128,
  offset by column 2 / row 1. The board table carries `colOffset = 2` and
  `rowOffset = 1`; `panel_init.h` feeds them to `esp_lcd_panel_set_gap`.
- The driver implements the full `esp_lcd` panel interface used by this
  project: `reset`, `init`, `draw_bitmap`, `invert_color`, `mirror`,
  `swap_xy`, `set_gap`, and `disp_on_off`.
- `reset()` drives the reset GPIO when one is configured (GPIO40 on this board).
