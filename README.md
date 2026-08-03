# esp32-display

A wireless second display for macOS, built from a $10 ESP32-C6 board with a
1.47" LCD. The Mac captures screen content with ScreenCaptureKit, streams raw
RGB565 pixels over WiFi, and the board pushes them to its ST7789 panel over
80MHz SPI with DMA. No compression, no video codecs — at 172×320 the whole
frame is 110KB, so the pipeline stays simple and the latency stays low.

Hardware: [ESP32-C6-LCD-1.47](https://spotpear.com/shop/ESP32-C6-1.47-inch-LCD-Display-Screen-LVGL-SD-WIFI6-ST7789.html)
(Waveshare design — ESP32-C6, WiFi 6, 1.47" 172×320 IPS panel, ST7789 driver).

## What it does

Plug the board into USB power anywhere on your network. It joins WiFi,
announces itself over mDNS, and shows whatever you point it at:

- **A tiny extended desktop** — create a virtual display with
  [BetterDisplay](https://betterdisplay.dev) (free tier) and drag windows
  onto it.
- **A mirror of your screen** — use macOS's own "Entire Screen" mirroring;
  the sender follows the mirror relationship automatically.
- **A single window or app** — pick one in macOS's screen-sharing picker
  (Control Center), no configuration files or flags.

The panel follows macOS. Rotate the virtual display and the panel rotates
with it, re-laying-out in landscape or portrait. Change mirroring modes,
resize, close the window you were streaming — the sender notices within a
couple of seconds and reattaches on its own.

The board itself has two physical controls on its BOOT button: a short press
toggles backlight brightness, a long press flips the image 180° for
upside-down mounting.

## Performance

The panel's SPI bus tops out around 41 fps for full-frame pushes, and the
pipeline reaches it: full-motion content streams at 25-38 fps depending on
WiFi conditions. For normal desktop content it does much better than that
suggests, because only changed regions go over the wire — the frame is tiled
into row bands and diffed against the last one sent. A mostly-static screen
with a clock or a scrolling log touches ~3-5% of bands per frame, roughly a
25× traffic reduction, with a full keyframe every 2 seconds to bound
staleness from any lost packets.

Send pacing tunes itself. The device reports its displayed-frame rate back
to the Mac once a second, and the sender hill-climbs its per-packet spacing
to maximize actually-delivered frames — so it finds the best operating point
for whatever your WiFi looks like today, and re-finds it when conditions
change.

## Resilience

Both ends assume the other will misbehave, because during development they
did. Everything below exists because the failure actually happened:

- **Device heartbeats** (1Hz, with delivery stats) let the Mac detect a
  rebooted or readdressed device and reconnect with fresh mDNS resolution —
  and if mDNS itself is down (multicast dies before unicast on weak links),
  it falls back to the device's last known IP.
- **Display identity is anchored on the display UUID**, which survives the
  rotations, re-creations, and mirror-set changes that invalidate display
  IDs and NSScreen names. The UUID is cached to disk, so even a sender
  restart mid-mirror re-finds the display.
- **Capture watchdogs** restart the stream when macOS kills it silently
  (display reconfiguration and sleep/wake both do this without firing the
  delegate error).
- **The firmware heals its own radio**: a WiFi association that has rotted
  (still connected, delivering nothing) is re-associated, then escalated to
  a clean reboot — which the Mac rides through automatically.
- **A task watchdog** panics and reboots the firmware on any unforeseen
  hang; serial writes never block (a stalled USB host once froze the whole
  loop); DMA completions that go missing are reclaimed instead of wedging
  the pipeline.
- **The reassembler tolerates real WiFi behavior**: late retransmitted
  packets, duplicates, reordering, and sender restarts all resync instead
  of thrashing.

## How it works

```
[macOS display / window / picker selection]
   → ScreenCaptureKit capture, hardware-scaled to 172×320
   → BGRA → RGB565 (big-endian, panel byte order — the ESP32 never touches a pixel)
   → per-band diff against previous frame
   → dirty bands over UDP, paced, ~1.3KB per packet
   → ESP32-C6: reassemble into persistent framebuffer
   → coalesce dirty bands into strips, DMA to ST7789 at 80MHz SPI
```

Transport is UDP by design: a lost frame should be skipped, not replayed.
With band diffing, a lost band just stays stale until the next change or
keyframe touches it.

### Protocol (v2)

Each packet: `[frame_id u16][band_index u16][dirty_count u16][band payload]`,
little-endian, where bit 15 of `dirty_count` carries orientation. Bands are
orientation-native so they align to whole rows:

| Orientation | Band | Bands/frame | Packet size |
| ----------------- | ------------- | ----------- | ----------- |
| Portrait 172×320 | 4 rows × 344B | 80 | 1382B |
| Landscape 320×172 | 2 rows × 640B | 86 | 1286B |

The device replies with a 1Hz heartbeat (`EHB1` + frame/drop/packet/heap
counters) to whoever sent it packets last; the sender emits a 2s `EPNG`
keepalive so that address stays fresh through static screens.

## Repo layout

| Path | What |
| -------------------------- | ------------------------------------------------------------------------- |
| `firmware/display_stream/` | The real firmware: WiFi, mDNS, UDP receiver, esp_lcd DMA, button controls |
| `firmware/display_test/` | Standalone panel bring-up test (colors, offsets, SPI timing benchmark) |
| `firmware/board_probe/` | I2C-scan sketch that identifies which board variant you have |
| `mac/ESPDisplaySender/` | Swift CLI: capture, diff, pace, send, supervise |
| `tools/read_serial.py` | Serial monitor with optional hard-reset (native USB-Serial/JTAG) |
| `tools/sweep.py` | Pacing parameter sweep, measuring displayed fps from device stats |
| `docs/` | Original project plan |

## Getting started

Firmware (needs [arduino-cli](https://arduino.github.io/arduino-cli/) and the
esp32 core with the espressif board manager URL):

```sh
cd firmware/display_stream
cp wifi_config.h.example wifi_config.h   # fill in your 2.4GHz network
arduino-cli compile -b "esp32:esp32:esp32c6:CDCOnBoot=cdc,FlashSize=8M" .
arduino-cli upload  -b "esp32:esp32:esp32c6:CDCOnBoot=cdc,FlashSize=8M" -p /dev/cu.usbmodem* .
```

Mac sender:

```sh
cd mac/ESPDisplaySender
swift build
./.build/debug/ESPDisplaySender                  # auto mode: follows macOS
./.build/debug/ESPDisplaySender --list-displays  # see what's capturable
./.build/debug/ESPDisplaySender --help           # all options
```

Grant Screen Recording permission when prompted. For the extended-desktop
use case, create a virtual display in BetterDisplay sized to a multiple of
172×320 (e.g. 688×1280) — the sender finds it by name (default "Tiny
Monitor"), learns its UUID, and tracks it from then on.

## Status lights

The panel itself tells you where the firmware is: dark gray means alive and
waiting for WiFi, dark teal means connected and waiting for a stream.
