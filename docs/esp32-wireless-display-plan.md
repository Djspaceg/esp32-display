# ESP32-C6 Wireless macOS Extended Display — Project Plan

## Goal

Turn the ESP32-C6 1.47" LCD board (172×320 ST7789 panel) into a small wireless
second display for macOS, prioritizing frame rate and pixel fidelity over
generality. Not a full Sidecar/AirPlay-style display — a custom capture →
stream → render pipeline for a single fixed-size panel.

## Hardware

- Board: ESP32-C6, 1.47" ST7789 LCD (172×320), soldered on-board (no external
  wiring needed — SPI/backlight/reset are internal to the board).
- No PSRAM on this chip — rules out anything memory-heavy (e.g. Doom); fine
  for this project since frame buffers at this resolution are small.
- Display native color depth: RGB565 (16-bit). This is the actual quality
  ceiling regardless of source format — no point sending anything higher
  fidelity than this.

## Key architectural decisions (from design discussion)

1. **No JPEG / no compression.** Raw RGB565 frames only. At 172×320 a full
   frame is ~110KB; even at 50fps that's ~5.5MB/s, well within local WiFi6
   throughput. JPEG's decode cost on the ESP32's single RISC-V core is the
   actual bottleneck we're avoiding — compression was solving a bandwidth
   problem we don't have, at the cost of a CPU problem we do have.
2. **UDP, not TCP.** This is a live video-like stream — a dropped frame
   should just be skipped, not stall every subsequent frame behind a
   retransmit (which is what TCP would do).
3. **Double-buffer on the ESP32.** Receive frame N+1 over WiFi into buffer B
   while DMA is still pushing frame N out of buffer A over SPI. Overlaps
   network and display time instead of serializing them.
4. **SPI clock as high as the board tolerates** — try 80MHz, verify against
   the seller's wiki/schematic for this specific board revision since some
   clones only guarantee 40MHz.
5. **Known hard ceiling: ~40-50fps**, set by SPI bus time to push a full
   172×320 RGB565 frame to the panel — this is a physical limit of the
   display bus, not something software can push past. Target this as the
   realistic max, not 60fps+.
6. **Virtual display, not full desktop mirror.** Use BetterDisplay
   (free, https://betterdisplay.dev) to create a dummy display sized to
   172×320 (or a clean multiple, downscaled). Render only intended content
   there — don't capture the whole physical desktop.

## Architecture

```
[macOS: BetterDisplay virtual screen, 172x320]
   → [ScreenCaptureKit capture loop, targeting that SCDisplay]
   → [convert frame to RGB565, no compression]
   → [UDP send, length/frame-number header + raw pixel payload]
   → [ESP32-C6: WiFi receive into buffer B]
   → [DMA push buffer A to ST7789 over SPI while B fills]
   → [swap buffers, repeat]
```

## Protocol spec (for implementation)

- Transport: UDP, ESP32 as receiver.
- Frame payload: raw RGB565, 172×320×2 = 110,080 bytes. Will need
  packetizing/chunking since this exceeds typical UDP-safe payload sizes
  (~1400 bytes per packet under standard MTU) — chunk with a small header
  per packet: `[frame_id: uint16][chunk_index: uint16][chunk_count: uint16][payload]`.
- ESP32 reassembles chunks into the inactive buffer; if a chunk is missing
  when the next frame starts arriving, drop the incomplete frame rather than
  waiting (favor recency over completeness).
- Discovery: ESP32 advertises via mDNS (`ESPmDNS` library) so the Mac side
  doesn't need a hardcoded IP.

## Components to build

### 1. ESP32 firmware (Arduino, C++)

- WiFi connect + mDNS advertise.
- UDP listener, chunk reassembly into double buffer.
- `Arduino_GFX` (or `TFT_eSPI`) driver for ST7789, SPI clock pushed to
  80MHz if stable, DMA-driven pushes.
- Buffer swap logic once a full frame is reassembled.

### 2. macOS capture tool (Swift, command-line)

- Requires BetterDisplay installed and a 172×320 virtual display created
  and named/identified.
- `ScreenCaptureKit` (macOS 13+) targeting that specific `SCDisplay`.
- Per-frame: grab pixel buffer → convert to RGB565 → chunk → UDP send to
  the ESP32's mDNS-resolved address.
- Frame rate: as fast as capture allows, capped naturally by the ESP32's
  ~40-50fps SPI ceiling — no need to over-engineer beyond that.

## What to render on the virtual display (content ideas from earlier discussion)

- System stats dashboard (CPU/network/build status) — reuses well with
  raw RGB565 + UDP since it's mostly static content with periodic updates.
- Could later share code/patterns with the existing Arduino RC controller
  project's telemetry display idea (same "small live status panel" shape,
  different transport).

## Stretch goals (not required for v1, but natural next steps)

- **Dirty-rectangle diffing**: only send the region of the frame that
  changed since the last frame (like VNC/RFB), instead of full frames every
  time. Biggest possible efficiency win for mostly-static UI content —
  worth doing once the raw pipeline works end-to-end.
- Adaptive frame rate: send less often when nothing changed.

## Open questions to verify before/during implementation
steps)

- **Dirty-rectangle diffing**: only send the region of the frame that
  changed since the last frame (like VNC/RFB), instead of full frames every
  time. Biggest possible efficiency win for mostly-static UI content —
  worth doing once the raw pipeline works end-to-end.
- Adaptive frame rate: send less often when nothing changed.

## Open questions to verify before/during implementation

- Confirm this board's actual max stable SPI clock (check seller's
  GitHub/wiki link from the listing) — 80MHz is a target, not guaranteed.
- Confirm exact ST7789 pin mapping for this specific board revision if not
  using a pre-made board definition.
- Decide on UDP chunk size based on real-world MTU on the target WiFi
  network (1400 bytes is a safe default assumption).
