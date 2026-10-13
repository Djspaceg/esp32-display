# Quake game mode

Quake shareware (id1/pak0.pak) on the three ESP32-P4 carriers (the 4B, the 4C
and the 3.4C) and on the ESP32-S3 boards with 32 MiB of flash and a panel that
holds a 320x240 frame (the AMOLED 1.75C and the LCD 1.85C). It sits beside
Doom and starts the same way, from the boot-mode menu, into an isolated boot with WiFi and streaming off. Any failure, and a
3 s BOOT hold, restarts into the normal firmware.

The engine is id's WinQuake software renderer through
[quakegeneric](https://github.com/erysdren/quakegeneric) at a pinned commit;
see `src/engine/UPSTREAM.md`. It is GPL-2.0 (`LICENSE-GPL2`); the P4 glue
(`quake_mode.cpp`, `platform/quake_hw_bridge.cpp`, the models) is MIT like the
rest of the repository, and `platform/quake_sys_esp32.c` and
`platform/quake_snd_esp32.c`, adapted from upstream's system, video and sound
drivers, are GPL-2.0. The sound mixer is id's own WinQuake code, which
quakegeneric leaves out.

## Game data

The paks are never committed or bundled. They live in the board's game store
(`docs/game-store.md`): the 18 MiB `quake_pak` partition at 0xE00000 on a P4,
and on an S3 the flash past its 8 MiB table. Put them there from the Mac app: a
P4 or S3 display's Firmware section has a **Games data** row whose **Install
Game Data…** sheet downloads the shareware `pak0.pak`, takes your own
`pak0.pak` or `pak1.pak` with **Choose…**, shows whether the board already holds
each one and how much room is left, and writes the checked ones over USB.

Quake loads `id1/pak0.pak`, then `pak1.pak` and on, each from its slot in the
store, so a set runs from `pak0.pak` without a gap. A registered `pak1.pak`
(about 34 MB) fits no board.

### Which S3 boards

The shareware `pak0.pak` is 18,689,235 bytes. Every S3 runs the same image,
whose layout (two app slots and the Doom WAD) fills the first 8 MiB, and its
game store is what the chip has past that, up to 18 MiB: the pak needs a
32 MiB chip. A 16 MiB chip's 8 MiB store holds WADs, or only a small pak.

| Board | Flash | Panel | Quake |
| --- | --- | --- | --- |
| AMOLED 1.75C | 16 or 32 MiB (one unit here reads 32) | 466x466 | with 32 MiB |
| LCD 1.85C | 16 MiB | 360x360 | with 32 MiB |
| LCD 1.3, Touch LCD 1.54, ELECROW knob | 16 MiB | 240x240 | no: flash and panel |
| LCD 1.9 | 16 MiB | 170x320 | no: flash and panel |
| LCD 0.85 | 8 MiB | 128x128 | no: flash and panel |

The S3 image carries the engine on every board: 243 KB more app (1,781,298 of
the slot's 2,031,616 bytes) and 10,248 bytes more internal RAM. A Quake boot
on an S3 renders 372x280 at 1x, centred at (46,92) on the 1.75C's round glass
(the CO5300 takes only even origins); `QUAKE_RENDER_WIDTH`/`HEIGHT` in
`src/quake_mode.h` choose another size, 0x0 for the whole panel. Only that
window is written to the panel, from a task on core 0 while the engine draws
the next frame into a second page.

Measured on the 1.75C (2026-10-11, `timedemo` demo1/demo2/demo3 back to back):

| Render size | demo1 | demo2 | demo3 | render, ms/frame |
| --- | --- | --- | --- | --- |
| 466x466 | 9.0 | 10.6 | 8.6 | 91 |
| 372x280 | 15.3 | 16.8 | 14.5 | 63 |
| 320x240 | 18.5 | 19.8 | 17.5 | 60 |

The panel write (31, 16 and 12 ms) runs beside the render and costs nothing.
With `r_dspeeds 1` the 5 s line breaks the render down by stage. The firmware raises the flash driver's size from
the image header's 8 MiB to the chip's own before registering the store. Quake
reads its paks with `esp_partition_read()` through a read-only file system
mounted at `/qdata` (`platform/quake_pak_vfs.c`), so a pak may cross 16 MiB,
past what this core's flash cache can map.

## Play Quake

1. Open the boot-mode menu (power-on or reset, or a triple press of BOOT) and
   choose **QUAKE**. The menu offers it only when this image carries the Quake
   runtime and the game store holds a `pak0.pak` that passes the Quake boot's
   check. `CFGGAME QUAKE` over serial chooses it the same way.
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

Settings and saves are kept across restarts and firmware updates. Every file
Quake writes under `/qdata` that is not a pak (`id1/config.cfg`, the menu's
`id1/s0.sav` to `s11.sav`) goes to the saved-games store, the 60 KB beside
`doom_wad` that Doom's settings and saves share (`firmware/doom/README.md`).
`config.cfg` is read at start as always, and written within 10 s of a change,
on a BOOT hold to leave, on a render size change and on `quit`. Files are
deflated; a save the store cannot hold prints `ERROR: not saved, no room in
the save area.` and the slot keeps what it had. `ERROR: not saved, the save
area could not be written.` is a flash error, which on a full store saving
over a slot in place can have cost that slot (see the Doom README).

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
stack, the last three in PSRAM. On an S3 the frame buffers come first, and the heap
is what the 8 MB of PSRAM has left less 64 KB: 6,144 KB at 372x280, 5,376 KB at
466x466. The S3's floor is 5 MB instead of id's 5.3 MB; the shareware demos use
at most 2.5 MB of the heap.

## Sound

Quake's own mixer (`snd_dma.c`, `snd_mix.c`, `snd_mem.c`) mixes into a
4096-frame ring in PSRAM, 200 ms ahead of where Doom's sound bridge
(`display_stream/doom_audio.cpp`) is reading it out to the codec from core 0.
Sounds play at the codec's rate, resampled from Quake's 11 kHz when a level
loads. A board without usable audio plays silent, and so does every board
while `CFGQUIET 1` is stored (the log says `sound: off, quiet mode`).

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
