# Doom Easter Egg

A playable Doom shareware Episode 1 easter egg for the
ESP32-S3-Touch-AMOLED-1.75C (`co5300`) and
ESP32-P4-WIFI6-Touch-LCD-4B (`st7703-4b`) profiles. It is linked into those
family artifacts through `ESPDISP_DOOM_RUNTIME` and remains runtime-gated to
the supported profiles. Heavy renderer arrays and mutable engine tables
allocate from PSRAM only when Doom starts.

## Play Doom

1. Start from the normal display firmware, then press BOOT three times within
   800 ms. The panel restarts, shows the Doom splash, and enters the title/demo
   loop.
2. Short-press BOOT or tap the screen to open the main menu.
3. Swipe up or down to move the menu cursor. Swipe left or right to change a
   highlighted slider, such as screen size, mouse sensitivity, or sound volume.
4. Short-press BOOT or tap to select the highlighted item. Hold BOOT for at
   least 0.6 seconds but less than 3 seconds, then release it, to return to the
   previous menu.
5. To start Episode 1, select **New Game**, **Knee-Deep in the Dead**, and a
   difficulty. Use up/down swipes to highlight each choice and a short BOOT
   press or tap to select it.
6. During play on the S3, tilt to move and drag anywhere to turn. On P4, drag
   on the left half to move and on the right half to turn. Right-side taps,
   double-taps, and vertical swipes fire, use/open, and cycle weapons. A second
   finger enables run.
7. Hold BOOT for 3 seconds to exit Doom. The panel restarts into the normal
   streaming firmware; release is not required once the threshold is reached.

## License

The engine under `src/` is based on
[doomgeneric](https://github.com/ozkl/doomgeneric), derived from id Software's
[linuxdoom-1.10](https://github.com/id-Software/DOOM) release, and is licensed
under GPL-2.0; see `LICENSE-GPL2`. The ESP32 hardware bridge and mode controller
use the repository's MIT license.

## Runtime architecture

```text
Triple-tap BOOT
  → save one-shot `doomonce` request in NVS
  → restart
  → consume and remove request before normal setup
  → detect and require a supported runtime profile
  → initialize its existing display backend, boardtouch path, and Doom PSRAM
  → validate and memory-map the profile's WAD storage region
  → run doomgeneric with blocking, completion-tracked panel DMA
  → BOOT 3-second hold exits
  → restart into normal streaming firmware
```

The reboot boundary is intentional. Doom starts before normal frame buffers,
WiFi, mDNS, OTA, the UDP receive task, or the loop-task watchdog, so no other
application task can write the panel or compete for the same PSRAM. The request
is removed before initialization, so a missing WAD or a crash returns to normal
firmware rather than creating a boot loop.

Large renderer work arrays and mutable engine tables allocate from PSRAM only
when Doom starts. The normal streaming binary retains internal RAM for its DMA
staging and UDP codec scratch.

## Controls

| Input | Action |
| --- | --- |
| Tap on title/demo | Open the menu |
| Swipe in menu | Navigate up, down, left, or right by dominant axis |
| Tap in menu | Select the highlighted item |
| BOOT short press with menu closed | Open the menu |
| BOOT short press with menu open | Select the highlighted item |
| BOOT 0.6 to under 3-second hold | Return to the previous menu |
| BOOT 3-second hold | Exit and restart normally |
| Tilt forward/back during play | Move forward/backward |
| Tilt left/right during play | Strafe left/right |
| P4 left-half drag during play | Move/strafe |
| Touch drag in the aim zone | Turn |
| Tap in the aim zone | Fire |
| Double-tap in the aim zone | Use/open |
| Second finger during play | Run modifier |
| Swipe up during play | Next weapon |
| Swipe down during play | Previous weapon |

## Firmware and WAD delivery

`firmware/partitions_s3_doom.csv` is staged as `partitions.csv` only for the
initial developer setup of a recoverable CO5300 carrier. It provides equal
`0x5F0000` OTA app slots and a `0x401000` WAD partition at `0xBFF000`. The
canonical 4,196,020-byte shareware v1.9 IWAD fits with 2,380 bytes to spare.

The canonical universal S3 image uses the common 8 MiB partition table and
links Doom code but includes no WAD. At runtime the WAD loader falls back to the
raw `0xBFF000` flash region, which the CO5300's 16/32 MiB flash makes available
even under the 8 MiB partition table; a device only reaches Doom on the CO5300
profile. Keeping the WAD out of the artifact preserves the common 8 MiB layout
for every S3 carrier, and PSRAM-only Doom state preserves the internal RAM the
canonical streaming image's SPI DMA paths need.

The developer workflow downloads the WAD only when explicitly requested, then
requires all of the following before writing or packaging it:

* `IWAD` magic
* exactly 4,196,020 bytes
* SHA-256 `1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771`
* fit within the declared partition

The Doom WAD is a developer-installed payload for the S3 `co5300` runtime
profile. It is not embedded in the canonical S3 release because it does not fit
every supported S3 carrier. Development images must verify WAD magic, size,
hash, and storage capacity before any write.

The canonical family commands build and flash the universal S3 release only:

```sh
python3 tools/espdisp.py compile --family s3
python3 tools/espdisp.py flash --family s3 --port /dev/cu.usbmodemXXXX
```

Use the manual development build below only on a recoverable CO5300-profile
board. It is intentionally separate from `firmware-releases/` and from the
macOS app's embedded resources.

## Manual compile

The CLI is the source of truth. The equivalent compile from
`firmware/display_stream` is:

```sh
cp ../partitions_s3_doom.csv partitions.csv
arduino-cli compile \
  -b "esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi,PartitionScheme=custom" \
  --libraries ../libraries \
  --libraries .. \
  --build-property "compiler.c.extra_flags=-DESPDISP_DOOM_RUNTIME" \
  --build-property "compiler.cpp.extra_flags=-DESPDISP_DOOM_RUNTIME" \
  .
rm partitions.csv
```

`--libraries ..` is deliberate: Arduino expects a directory containing the
`doom` library. Passing `../doom` mis-detects `doom/src` as an old-format
library and omits the recursive `platform/doom_hw_bridge.cpp` source.

## Hardware test checklist

1. Use a recoverable CO5300-profile S3 device and USB, not OTA, for the first install.
2. Confirm the development partition table contains `doom_wad` at `0xBFF000`.
3. Flash only the listed development segments without whole-chip erase.
4. After normal streaming starts, triple-tap BOOT and confirm one reboot into
   the splash and title/demo loop.
5. Short-press BOOT and confirm the main menu opens from the title/demo.
6. Swipe in all four directions; confirm up/down move the cursor and left/right
   adjust slider items. Short-press BOOT to select and hold it for at least
   0.6 seconds but less than 3 seconds to return to the previous menu.
7. Start a game and check tap, double-tap, drag, vertical swipe,
   second-finger run, and tilt.
8. Hold BOOT for three seconds; confirm a reboot and normal streaming recovery.
9. Perform an OTA application update and confirm Doom still starts, proving the
   WAD partition was preserved.
10. Confirm non-CO5300 S3 profiles have no triple-tap activation.

## Directory layout

```text
firmware/doom/
├── library.properties
├── LICENSE-GPL2
├── README.md
└── src/
    ├── doom_mode.h
    ├── doom_mode.cpp
    ├── doom_config.h
    ├── doom_unity_build.c
    ├── platform/
    │   ├── doomgeneric_esp32.c.inc
    │   ├── w_file_esp32.c.inc
    │   ├── doom_hw_bridge.cpp
    │   ├── doom_esp32_stubs.c.inc
    │   └── doom_splash.h
    └── upstream Doom engine sources and headers
```
