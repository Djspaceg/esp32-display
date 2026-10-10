# Quake game mode

Quake shareware (id1/pak0.pak) on the three ESP32-P4 carriers (the 4B, the 4C
and the 3.4C) and on the ESP32-S3 boards with 32 MiB of flash and a panel that
holds a 320x240 frame (the AMOLED 1.75C and the LCD 1.85C). It sits beside Doom and starts the same way, from the boot-mode
menu, into an isolated boot with WiFi and streaming off. Any failure, and a
3 s BOOT hold, restarts into the normal firmware.

The engine is id's WinQuake software renderer through
[quakegeneric](https://github.com/erysdren/quakegeneric) at a pinned commit;
see `src/engine/UPSTREAM.md`. It is GPL-2.0 (`LICENSE-GPL2`); the P4 glue
(`quake_mode.cpp`, `platform/quake_hw_bridge.cpp`, the models) is MIT like the
rest of the repository, and `platform/quake_sys_esp32.c`, adapted from
upstream's system and video drivers, is GPL-2.0.

## Game data

The pak is never committed or bundled. Fetch it and write it to the board's
`quake_pak` partition over USB (18 MiB at 0xE00000 on a P4; on an S3, a raw
region of 18 MiB at 0x800000, just past the universal 8 MiB layout):

```sh
tools/fetch_game_data.sh --game quake
python3 tools/espdisp.py write-data quake_pak --port /dev/cu.usbmodemXXXX
```

A board on an older partition table needs one full USB flash of the current
bundle first; `write-data` refuses until then. On an S3 it also reads the chip's
flash size and refuses anything under 32 MiB.

### Which S3 boards

The pak is 18,689,235 bytes. Every S3 runs the same image, whose layout (two
app slots and the Doom WAD) fills the first 8 MiB, so the pak needs a chip of
at least 26 MiB: a 32 MiB one.

| Board | Flash | Panel | Quake |
| --- | --- | --- | --- |
| AMOLED 1.75C | 16 or 32 MiB (one unit here reads 32) | 466x466 | with 32 MiB |
| LCD 1.85C | 16 MiB | 360x360 | with 32 MiB |
| LCD 1.3, Touch LCD 1.54, ELECROW knob | 16 MiB | 240x240 | no: flash and panel |
| LCD 1.9 | 16 MiB | 170x320 | no: flash and panel |
| LCD 0.85 | 8 MiB | 128x128 | no: flash and panel |

The S3 image carries the engine on every board: 243 KB more app (1,781,298 of
the slot's 2,031,616 bytes) and 10,248 bytes more internal RAM. A Quake boot
on an S3 sizes its engine heap to what the 8 MB of PSRAM has left once 1 MiB is
kept back (id's floor is 5.3 MB) and puts the frame at 1x in the centre of the
panel, at an even origin for the CO5300. The firmware raises the flash driver's size from
the image header's 8 MiB to the chip's own before registering the region. Quake reads the partition with
`esp_partition_read()` through a read-only file system mounted at `/qdata`
(`platform/quake_pak_vfs.c`), so the pak may cross 16 MiB, past what this
core's flash cache can map.

## Play Quake

1. Open the boot-mode menu (power-on or reset, or a triple press of BOOT) and
   choose **QUAKE**. The menu offers it only when this image carries the Quake
   runtime and the partition holds a pack that passes the Quake boot's check.
2. Left alone, Quake plays its attract demos. A short BOOT press opens the
   menu (a tap during a demo fires, as in play).

| Input | In play | In a menu or the console |
| --- | --- | --- |
| Left-half drag | Move and strafe | Swipes are arrow keys |
| Right-half drag | Aim (free look) | Swipes are arrow keys |
| Right-half tap | Fire | Enter |
| Right-half double tap | Fire, then jump | Enter |
| Right-half swipe up/down | Next/previous weapon | Arrow keys |
| Second finger | Run | |
| BOOT short press | Escape | Escape |
| BOOT 0.6 to 3 s | Enter | Enter |
| BOOT 3 s hold | Leave Quake | Leave Quake |
| USB keyboard | Quake's bindings for the keys below, plus WASD | Letters and digits |
| USB mouse | Aim, left button fires, right jumps, wheel changes weapon | |

USB input uses Doom's host glue (`firmware/doom/src/platform/doom_usb_input.*`),
which is why Quake is built only alongside the Doom runtime. Its decoder passes
letters, digits, F1-F10, the arrows, Escape, Enter, Tab, Backspace, Pause,
Space, `. / , - =` and the modifiers; it has no `` ` `` (so a USB keyboard
cannot open the console), no `[ ] ; ' \`, no PgUp/PgDn/Home/End/Ins/Del and
no F11/F12. On the 4B the port does not supply 5 V; see
`docs/usb-host-ports.md`.

Every line typed on the serial port goes to the Quake console, so
`timedemo demo1` measures the frame rate. A line every 5 s reports the frame
rate, the time spent putting frames on the panel, and free memory.

Measured on a 4B (2026-10-06, attract demos and play, 83 five-second
windows): 12.3 to 26.3 fps, median 16.9. Putting a frame on the panel (the
palette conversion and the blocking 640x480 write) takes a steady 33 ms of
that; the engine renders a frame in about 27 ms. Overlapping that write with
the next frame is the obvious next speedup.

Saving is off: `/qdata` is read-only, so `save` and `config.cfg` report that
they cannot write and the game carries on.

## Memory

The P4 image carries the engine on every boot, streaming included, and the
prebuilt IDF cannot put static data in PSRAM. Upstream's ~670 KB of .bss is
therefore moved out of internal RAM: the 230 KB frame and depth buffers are
allocated when a Quake boot starts, `platform/quake_statics.h` turns the other
large arrays (about 430 KB) into pointers filled then too, and read-only
tables are `const`. About 10 KB stays in internal RAM (10,195 bytes in the
P4 link map): small globals and the 153 initialised cvars.

A Quake boot allocates a 16 MB engine heap, the 320x240 frame and depth
buffers, a ~600 KB surface cache, a 640x480 scaled frame and a 320 KB task
stack, the last three in PSRAM.

## Layout

```text
firmware/quake/
├── library.properties, LICENSE-GPL2, README.md
├── update_engine_units.sh   regenerates src/engine_units/
├── update_statics.py        regenerates src/platform/quake_statics_lists.h
└── src/
    ├── quake_build.h        whether this image carries Quake
    ├── quake_mode.h/.cpp    the Quake boot and its task
    ├── engine/              vendored quakegeneric (.c as .c.inc), UPSTREAM.md
    ├── engine_units/        one wrapper unit per engine source
    └── platform/            system/video layer, pak file system, input, models
```

The sketch side is `firmware/display_stream/quake_bridge.cpp` (panel writes and
the failure card) and the `quakeonce` branch in `display_stream.ino`.
