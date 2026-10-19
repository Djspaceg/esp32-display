# Tiny TFT carrier

A small two-layer board that holds a Seeed XIAO ESP32-S3 (or XIAO ESP32-C6)
next to the Questwise 0.42" 96x54 TFT breakout, so the screen needs no wires.

## The pick

**Seeed XIAO ESP32-S3**, on a carrier. The XIAO ESP32-C6 fits the same
carrier with no changes, because both XIAOs share one footprint and every pin
the carrier uses is a plain GPIO on both chips. The test sketch picks the GPIO
numbers for whichever board it is built for. Our firmware already supports
both chip families.

No common small ESP32 board takes the screen directly. The screen has two rows
of four pins (3V3, SCLK, SDIN, GND on one row; BL, DC, RES, CS on the other), so
3V3 and GND sit three pins apart on the same row. The XIAO and the Waveshare
Zero boards both put 5V, GND and 3V3 next to each other, so the screen cannot
plug onto them. The carrier puts the pins in the right order.

**A C3 would mean:** the XIAO ESP32-C3 also fits this carrier, but its D8
(SCLK here) is GPIO8, a C3 strapping pin. The screen's SCLK input should not
pull it, so it ought to boot, but that is untested. Our firmware does have a C3
family already (the 2424S012 board).

## Pin map

| Screen pin | XIAO pin | ESP32-S3 | ESP32-C6 | Note |
|---|---|---|---|---|
| 3V3 | 3V3 | - | - | XIAO 3.3 V output (S3: up to 700 mA per Seeed) |
| GND | GND | - | - | |
| SCLK | D8 | GPIO7 | GPIO19 | XIAO's own SCK label |
| SDIN | D10 | GPIO9 | GPIO18 | XIAO's own MOSI label |
| DC | D3 | GPIO4 | GPIO21 | |
| RES | D4 | GPIO5 | GPIO22 | |
| CS | D5 | GPIO6 | GPIO23 | |
| BL | D1 via JP1 | GPIO2 | GPIO1 | only when JP1 is bridged |

Left free on purpose: D0, D2 (GPIO3, an S3 strapping pin), D6 and D7 (UART0,
which prints boot messages), D9, and 5V. None of the pins used is a strapping,
boot or USB pin on the S3 or the C6. On a XIAO ESP32-S3 **Sense**, the add-on
board's SD card shares D8/D9/D10; leave the SD card out or keep its CS high.

## Board

- Size **36.5 x 23.0 mm**, two layers, 1.6 mm thick. No vias. No copper fill,
  so there is no antenna area to keep clear.
- XIAO at the right-hand end. Its USB-C socket hangs 1.5 mm past the board
  edge, so a cable plugs in freely. The reset and boot buttons stay on top.
- Screen at the left-hand end, **face up, with its flex cable at the end away
  from the XIAO** (silk marks that end with a line). Pin labels are printed
  beside each screen hole.
- Every trace but one runs on the bottom layer. SCLK runs on the top layer,
  along the bottom edge, outside the XIAO.

## How the parts mount

- **XIAO: soldered flat** onto the edge pads (the XIAO's half-holes), which
  is thinnest and most solid. The same pads also have through-holes, so male
  headers or sockets work too if you want to remove the XIAO later.
- **Screen: its pins go straight through J1 and get soldered.** The plastic
  strip on its pins holds it about 2.5 mm off the carrier (estimate). To make it
  removable, fit two 1x4 female 2.54 mm sockets instead.

## Backlight

The screen pulls BL high on its own, so the backlight is always on. **JP1**,
a solder jumper on the back, is open as made. Bridge it with a blob of solder
to switch the backlight from D1 (high = on, low = off).

## Parts

| Qty | Part | Note |
|---|---|---|
| 1 | This carrier PCB | Gerbers and drill file in `fab/` |
| 1 | Seeed XIAO ESP32-S3 (or ESP32-C6) | |
| 1 | Questwise 0.42" 96x54 TFT breakout | |
| 0-2 | 1x4 female socket, 2.54 mm | only if the screen should come off |
| 0-2 | 1x7 female socket, 2.54 mm | only if the XIAO should come off |

Nothing else: no resistors, capacitors or regulator. The XIAO supplies 3.3 V.

## To measure (before ordering)

The seller publishes no drawing. These come from the seller's photos, using a
US quarter for scale:

| What | Value used | Why it matters |
|---|---|---|
| Distance between the screen's two pin rows | **15.24 mm** (0.6") | Wrong value: the screen will not fit the holes |
| Pin pitch within a row | 2.54 mm | same |
| Breakout outline | about 12.9 x 20.8 mm | only needs to clear the XIAO (2 mm gap at this size) |
| Flex cable fold under the breakout | not known | must clear the carrier when soldered down |

If a value differs, change it at the top of `generate.py`, then run
`python3 generate.py` and the checks below again.

## Checks run

kicad-cli 10.0.7, headless only (the KiCad app was never opened):

- Schematic ERC: 0 errors, 0 warnings (`checks/erc.log`).
- PCB DRC with schematic parity: 0 violations, 0 unconnected, 0 parity
  issues (`checks/drc.log`).
- Gerbers plus Excellon drill and drill map exported to `fab/`.
- The exported netlist was checked against the pin map above.
- The test sketch compiles for `esp32:esp32:XIAO_ESP32S3` and
  `esp32:esp32:XIAO_ESP32C6` (`checks/sketch-compile.log`). It has not been
  run on a board.

Not done: no board has been made, nothing has been fitted together, no 3D
check. The XIAO footprint was drawn from Seeed's published pad positions, not
copied from Seeed's file.

```sh
K=/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli
$K sch erc --severity-all -o checks/erc.log tiny-tft-carrier.kicad_sch
$K pcb drc --schematic-parity --severity-all -o checks/drc.log tiny-tft-carrier.kicad_pcb
$K pcb export gerbers -l F.Cu,B.Cu,F.Mask,B.Mask,F.SilkS,B.SilkS,F.Paste,B.Paste,Edge.Cuts -o fab/ tiny-tft-carrier.kicad_pcb
$K pcb export drill --generate-map --map-format pdf -o fab/ tiny-tft-carrier.kicad_pcb
```

## Test sketch

`tft_test/tft_test.ino` uses Arduino_GFX with the seller's settings: rotation
0, column offset 16, row offset 0, BGR, no inversion. It also sends the seller
library's power and gamma registers, which Arduino_GFX's own ST7735 start-up
skips. SPI runs at 15 MHz, the ST7735 datasheet limit. It draws a one-pixel
white frame (if a side is missing, an offset is wrong), RGB bars and
"96x54". With JP1 bridged it also blinks the backlight every 2 s. The offsets for
the other rotations are worked out, not tested.

## Files

- `generate.py`: writes every file below. Change dimensions here.
- `tiny-tft-carrier.kicad_pro`, `.kicad_sch`, `.kicad_pcb`: the project.
- `tiny-tft-carrier.kicad_sym`, `tiny-tft-carrier.pretty/`, `sym-lib-table`,
  `fp-lib-table`: the project's own symbols and footprints.
- `fab/`: Gerbers, drill file, drill map.
- `checks/`: rule-check reports, sketch compile log, layout plot, schematic PDF.

## Sources

- Screen pins, order, 3.3 V only: [Questwise Tindie page](https://www.tindie.com/products/questwise-ventures/miniature-042-rgb-color-tft-96x54-screen-display/) and its photos.
- Controller set-up (green tab, offset 16/0, init registers): [Questwise library](https://github.com/questwiseventures/TFT_ST7735_96x54_Color_TFT) (`User_Setup.h`, `TFT_ST7735.cpp`).
- XIAO ESP32-S3 pins, strapping pins, 21 x 17.8 mm, 3V3 700 mA: [Seeed wiki](https://wiki.seeedstudio.com/xiao_esp32s3_getting_started/).
- XIAO ESP32-C6 pins: [Seeed wiki](https://wiki.seeedstudio.com/xiao_esp32c6_getting_started/).
- XIAO ESP32-C3 pins and strapping pins: [Seeed wiki](https://wiki.seeedstudio.com/XIAO_ESP32C3_Getting_Started/).
- XIAO pad positions (2.54 mm pitch, rows 15.24 mm apart, edge pads): [Seeed XIAO KiCad footprints](https://files.seeedstudio.com/wiki/XIAO-KiCad-Library/New_XIAO_Series_Footprints.zip).
- Waveshare ESP32-C6-Zero pins and 18 x 23.5 mm: [Waveshare wiki](https://www.waveshare.com/wiki/ESP32-C6-Zero) (pinout and dimension images).
