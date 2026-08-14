# Doom Easter Egg

A playable Doom (shareware Episode 1) running on the ESP32-S3-Touch-AMOLED-1.75C
board, activated by triple-tapping the BOOT button.

## License

The Doom engine source code in `src/` is based on
[doomgeneric](https://github.com/ozkl/doomgeneric) by ozkl, which is derived
from the original [linuxdoom-1.10](https://github.com/id-Software/DOOM) source
release by id Software. It is licensed under **GPL-2.0** — see
[LICENSE-GPL2](LICENSE-GPL2).

The platform integration files in `platform/` and the mode controller
(`doom_mode.c`, `doom_mode.h`) are MIT-licensed, matching the rest of this
repository.

## Architecture

```
Triple-tap BOOT (GPIO0, 3 presses within 800ms)
  → display_stream suspends (UDP, mDNS, frame buffers freed)
  → doom_enter() takes control
  → doomgeneric game loop with ESP32-S3 platform functions:
      DG_DrawFrame → 320×200 XRGB8888 → RGB565 → scale to 466×466 → QSPI DMA
      DG_GetKey    → QMI8658 IMU tilt → movement keys
                   → CST9217 touch drag → turn keys
                   → CST9217 tap/double-tap → fire/use
  → BOOT long-press (3s) → doom_request_exit() → esp_restart()
```

## Controls

| Input | Action |
|---|---|
| Tilt forward/back | Move forward / backward |
| Tilt left/right | Strafe left / right |
| Touch drag | Turn / aim |
| Tap | Shoot |
| Double-tap | Use / open door |
| 2nd finger (hold) | Run modifier |
| BOOT short press | Cycle weapon |
| BOOT long press (3s) | Exit Doom → reboot |

## Flash Requirements

The doom1.wad shareware file (4,196,020 bytes) lives in a dedicated flash
partition. Use the custom partition table:

```
firmware/partitions_s3_doom.csv
```

Flash the WAD:
```sh
tools/espdisp.py flash-wad path/to/doom1.wad
```

## Building

The Doom engine compiles as part of the S3 firmware build. It is conditionally
included only when `CONFIG_IDF_TARGET_ESP32S3` is defined — the C6 binary is
completely unaffected.

```sh
tools/espdisp.py compile --board s3 --partition-table firmware/partitions_s3_doom.csv
tools/espdisp.py flash --board s3
tools/espdisp.py flash-wad doom1.wad
```

## WAD File

The Doom shareware WAD (`doom1.wad` v1.9, 4,196,020 bytes) is freely
redistributable. It contains Episode 1: "Knee-Deep in the Dead" (9 levels).
Download from [doomwiki.org](https://doomwiki.org/wiki/DOOM1.WAD) or various
mirrors.

The WAD is NOT included in this repository. You must provide your own copy and
flash it to the device.

## Directory Layout

```
firmware/doom/
├── doom_mode.h          # Public API (triple-tap, enter, exit) — MIT
├── doom_mode.c          # Mode controller — MIT
├── platform/
│   ├── doomgeneric_esp32s3.c  # DG_* implementations — GPL-2.0
│   └── w_file_esp32.c         # WAD partition access — GPL-2.0
├── src/                 # doomgeneric engine source — GPL-2.0
│   └── (to be populated from upstream ozkl/doomgeneric)
├── LICENSE-GPL2         # GPL-2.0 license text
└── README.md            # This file
```
