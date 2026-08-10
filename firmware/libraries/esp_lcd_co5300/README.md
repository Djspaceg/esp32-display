# esp_lcd_co5300 (vendored)

`esp_lcd` panel driver for the CO5300 AMOLED controller, which drives the
466x466 panel on the **ESP32-S3-Touch-AMOLED-1.75C** over QSPI. Vendored so
the firmware can construct this panel through the same `esp_lcd` API it uses
for the ST7789 and JD9853 (see
`firmware/libraries/espdisp_board/src/board_config.h`).

It is a library rather than files copied into each sketch folder so that
`display_stream` and `display_test` share one copy.

## Provenance

Extracted from Espressif's esp-iot-solution repository:

- Source: `components/display/lcd/esp_lcd_co5300/`, component version 2.1.0
  (per its `idf_component.yml`), fetched from the `master` branch on
  2026-08-10
- Repository: <https://github.com/espressif/esp-iot-solution>
- Upstream copyright: Espressif Systems (Shanghai) CO LTD, 2023-2025
- License: Apache-2.0 (SPDX headers retained in all files; full licence text
  in `LICENSE` beside this file, since the rest of this repository is MIT)

Original SHA-256 of the files as fetched, before local modification. The
upstream `include/` and `priv_include/` layout is flattened into `src/`, which
changes no file content:

| File                          | SHA-256                                                            |
| --- | --- |
| `esp_lcd_co5300.c`            | `51f9d68597758be5c9b82da62be59ad0e54c06a04b33ee2b8911a06d9c2ecd21` |
| `esp_lcd_co5300_spi.c`        | `c415dadcc75d4c3c90defe6ffa61db1587eefd7575cd7fdddd6ac7df02907aa5` |
| `esp_lcd_co5300.h`            | `9a6f6ae50339a3572c9b6cc7a32a5543414207ce24ec802a2662aa8e67b612db` |
| `esp_lcd_co5300_interface.h`  | `e341959b5e50bdc1bdf468274c4bd6689ec3f06c38756cab4ae12a76125c993d` |

## Local modifications

1. `esp_lcd_co5300.h`: added fallback definitions of
   `ESP_LCD_CO5300_VER_MAJOR/MINOR/PATCH` (2.1.0). Upstream generates these
   through `cu_pkg_define_version` in its CMake build, which the Arduino build
   does not run; without them the driver's creation log lines fail to compile.
2. **Not vendored:** `esp_lcd_co5300_mipi.c`. The MIPI-DSI path only compiles
   on chips with `SOC_MIPI_DSI_SUPPORTED` (ESP32-P4), which excludes every
   target this project builds for; the dispatcher's MIPI branch preprocesses
   away on the S3 and C6.

The vendor initialisation sequence is otherwise untouched, because it is the
part that is specific to this panel and cannot be derived from the datasheet
alone. Note its `0x2A`/`0x2B` entries pre-address columns 6..471 - the
CO5300 maps this 466px glass starting at column 6, which is also why the
board table carries `colOffset = 6`.

## Notes for callers

- Construct with `esp_lcd_new_panel_co5300(io, &panel_config, &panel)`. For
  QSPI the IO must be created with `flags.quad_mode = 1`, `lcd_cmd_bits = 32`,
  `lcd_param_bits = 8`, no D/C pin, and the panel's `vendor_config` must set
  `flags.use_qspi_interface = 1` - the driver then wraps every command in the
  QSPI envelope itself (`0x02 << 24 | cmd << 8` for commands, `0x32` for
  pixel data). Callers never build that envelope.
- Brightness is `esp_lcd_panel_co5300_set_brightness(panel, percent)` (0-100,
  panel command 0x51). AMOLEDs have no backlight; this is the only brightness
  control there is.
- The driver implements the full `esp_lcd` panel interface used by this
  project: `reset`, `init`, `draw_bitmap`, `invert_color`, `mirror`,
  `swap_xy`, `set_gap`, and `disp_on_off`.
- Like the vendored JD9853, it does **not** read
  `esp_lcd_panel_dev_config_t::data_endian`: the panel expects big-endian
  RGB565, which is the byte order this project's framebuffers already use.
- `reset()` drives the reset GPIO when one is configured. On the 1.75C the
  panel and touch controller share that line (GPIO2), so a panel reset also
  resets touch - bring up touch after the panel, and never pulse the line
  from the touch side.
