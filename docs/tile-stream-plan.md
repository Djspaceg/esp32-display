# Tile Stream: findings and implementation plan

A design and implementation plan for replacing the full-width band diffing
system with a tile/rectangle-based dirty-region protocol on the
ESP32-S3-Touch-AMOLED-1.75C (466x466 CO5300), targeting maximum throughput up
to 60fps for mixed content (UI, photos, video). Written to be sufficient for a
clean session to implement without re-deriving the analysis.

## 1. Goal and hard constraints

Goal: smooth, high-quality motion up to 60fps on the 466x466 panel, for all
content types (UI/text, photographs, video). Lossy compression is acceptable —
"JPEG q70" quality is the reference bar. C6 boards (172x320 rectangular) keep
the existing band protocol byte-for-byte; the new protocol is S3+square only.

Hard constraints, all previously measured or confirmed in this codebase:

| Constraint                     | Value                                     | Source                                                           |
| ------------------------------ | ----------------------------------------- | ---------------------------------------------------------------- |
| Frame size                     | 466x466 RGB565 = 434,312 B                | `bandproto::Geometry::frameBytes()`                              |
| Datagram receive ceiling       | ~1826 datagrams/s, flat                   | measured, noted in `device_protocol.h` at `CAP_COMPRESSED_BANDS` |
| Datagram size budget           | 1472 B (1500 MTU - IP - UDP)              | `MAX_PACKED_PACKET_BYTES`, `band_protocol.h`                     |
| Max ingest bandwidth           | 1826 x 1472 = ~2.69 MB/s                  | product of the two above                                         |
| S3 JPEG decode (JPEGDEC-class) | ~3.2 Mpx/s = ~68 ms/full frame            | atomic14 benchmark, 272x233 in 20ms on S3                        |
| No hardware JPEG/video decode  | S3 has none (P4 does)                     | Espressif docs                                                   |
| Frame buffers                  | bufA/bufB in PSRAM (octal), 434 KB each   | `display_stream.ino` ~line 341, `FRAME_BUF_CAPS`                 |
| Panel driver rectangle support | arbitrary (x0,y0)-(x1,y1) via CASET/RASET | `esp_lcd_co5300_spi.c`, `panel_co5300_draw_bitmap`               |
| DMA queue depth                | 2 transactions                            | panel init                                                       |

## 2. The budget math (read this first)

The packet-rate ceiling is the dominant constraint, not decode CPU and not
compression ratio in isolation. At ~2.69 MB/s ingest:

| Scenario                                 | Bytes/frame               | FPS ceiling                                 |
| ---------------------------------------- | ------------------------- | ------------------------------------------- |
| Raw full frame                           | 434 KB                    | ~6 fps                                      |
| RLE565 full frame (photo content ~= raw) | ~430 KB                   | ~6 fps                                      |
| BC1 full frame (fixed 4:1)               | ~109 KB + record overhead | ~23 fps                                     |
| JPEG q70 full frame (~10:1)              | ~43 KB                    | ~60 fps by bandwidth, ~14 fps by decode CPU |
| 60 fps budget                            | <= ~45 KB/frame           | needs <= ~40% of panel dirty at BC1 4:1     |

Conclusions that shape the whole design:

1. **60fps is achievable today only for partial-frame motion** (up to roughly
   40% of the panel changing per frame with BC1). Typical video-in-a-region,
   UI animation, and photo slideshows with transitions fit this.
2. **Full-frame 60fps motion requires raising the datagram ceiling** (see the
   receive-path workstream, section 7 phase 0/6) and/or adaptive degradation
   (half-resolution motion mode, section 6.8). Neither BC1 nor any codec the
   S3 can decode at 60fps fits full-frame 60 through a 1826/s packet ceiling
   alone.
3. JPEG fits the bandwidth budget but not the decode budget; BC1 fits the
   decode budget but not the full-frame bandwidth budget. There is no free
   codec choice: the design must combine per-tile diffing (to keep most frames
   far under full-frame cost) with BC1 (cheap decode) and attack the packet
   ceiling separately.

## 3. How the current band system works (what the redesign replaces)

All file references are to the repo as of commit `5a9c24b3`.

- **Wire**: `firmware/display_stream/band_protocol.h`. A band is a full-width
  strip of N rows where N = whole rows fitting a 1400 B packet budget. On
  466x466 that is N=1: a band is one 932 B row. Header is 6 bytes
  `[frame_id u16][band_index u16][dirty_count u16]`; `band_index` bit 15 marks
  a packed packet whose payload is `[band u16][len u16, bit15=compressed]
[payload]` records, walked by `forEachPackedRecord`. Reassembly is
  `bandproto::Reassembler`: frame-id wraparound-aware (signed 16-bit diff),
  stale-streak resync at `2 * maxBandCount()` chunks, duplicate suppression
  via bitmap, completion when `dirtyCount` distinct bands arrive.
- **Mac diff**: `BandProtocol.swift` `dirtyBands(new:previous:geometry:landscape:)`
  does a per-band `memcmp`; one changed pixel resends the whole 466px row.
  `FrameSender.send` sends all bands as a keyframe on first frame /
  orientation change / 2s interval; otherwise only dirty bands.
  `BandPacker.packets` (BandCompression.swift) RLE-encodes each band, keeps
  whichever of raw/RLE is smaller, greedily packs records into 1472 B
  datagrams. Only used when the panel advertises `CAP_COMPRESSED_BANDS`.
- **Compression**: `band_compress.h` / `BandCompression.swift` implement
  RLE565 (PackBits over 16-bit pixels; repeat runs 2-129 px in 3 B, literals
  1-128 px at 1 B overhead). The codec is buffer-agnostic — it will compress
  any contiguous byte range, so it transfers to tiles unchanged. Its decoder
  is a security boundary (unauthenticated datagram -> framebuffer write) and
  is tested with exact-size heap buffers under ASan, non-recovering.
- **Firmware draw**: UDP task writes decoded bands into `bufA` (persistent,
  always-current full framebuffer, PSRAM) and sets bits in
  `pendingDrawBitmap`; `loop()` walks contiguous dirty runs (`forEachRun`),
  memcpys each run `bufA -> bufB` (staging, so DMA never reads what the
  network task writes), and issues one full-width
  `esp_lcd_panel_draw_bitmap(panel, 0, yStart, w, yEnd, bufB+off)` per run.
- **Why bands fall short**: on this panel the band is already minimal in Y
  (1 row) and maximal in X (full width). One dirty pixel costs 932 bytes. A
  small moving element (clock, cursor, ticker) that spans 50 rows x 40 px
  costs 50 x 932 = 46.6 KB/frame when its true dirty area is 4 KB.

## 4. Verdicts on alternatives considered

| Approach                                 | Verdict                           | Reason                                                                                                                                                                                                                               |
| ---------------------------------------- | --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Full-frame JPEG (JPEGDEC/TJpgDec)        | rejected                          | ~68 ms/frame decode = ~14fps ceiling; no HW decode on S3                                                                                                                                                                             |
| Per-tile JPEG                            | rejected                          | per-tile header/table overhead exceeds payload at 16x16; needs custom shared-table decoder to be viable                                                                                                                              |
| `esp_new_jpeg` (Espressif 2025, S3 SIMD) | benchmark in phase 0, not primary | may be several times faster than JPEGDEC via S3 PIE/SIMD; if it decodes 466x466 in <= ~16ms it becomes a candidate for keyframes/slideshow mode, but per-tile use still has the table-overhead problem                               |
| zlib/LZ4 per tile                        | rejected as primary               | entropy coding decode cost on S3 for marginal gain over RLE on flat content, worse than BC1 on photos; LZ4 worth a phase-6 experiment layered over BC1 output (bc_crunch-style)                                                      |
| BC1/DXT1 block compression               | **chosen lossy codec**            | fixed 4:1, decode is palette lookup (no IDCT/entropy), proven real-time on 1990s hardware, operates natively on RGB565 endpoints, 4x4 blocks tile cleanly into 16x16 tiles                                                           |
| RLE565 (existing)                        | **kept for flat tiles**           | lossless, often beats 4:1 on UI/text/solid fills, zero new code                                                                                                                                                                      |
| Hextile/ZRLE (RFB)                       | pattern adopted, formats not      | 16x16 tile grid mirrors Hextile; their byte formats drag in palette machinery this doesn't need                                                                                                                                      |
| CopyRect (RFB)                           | deferred                          | scroll detection on the Mac is real work; note as future record type (the wire format reserves codec values)                                                                                                                         |
| Half-resolution motion mode              | **adopted as adaptive fallback**  | 233x233 sent, pixel-doubled on panel: 4x fewer pixels, combined with BC1 = 16:1, enables full-frame motion near 60fps within today's packet ceiling at a visible quality cost; engaged only when dirty area exceeds the 60fps budget |
| TCP transport                            | rejected                          | head-of-line blocking versus stale-frame-abandonment semantics the current design relies on                                                                                                                                          |
| Raising the datagram ceiling             | **workstream, phase 6**           | lwIP mbox size, WiFi RX buffer counts, AMPDU-RX, batching reads; the single highest-leverage unknown — every % here is a % on full-frame fps                                                                                         |

## 5. Scope and gating

- New capability bit `CAP_TILE_STREAM = 1u << 15` in `device_protocol.h`
  (next free after `CAP_POWER`). Mirrored as
  `DeviceProtocol.Capabilities.tileStream` (Swift) with the bit value pinned
  in both test suites, like `CAP_ROTATE`/`CAP_POWER` are.
- Firmware advertises it only when `bcfg->variant == board::Variant::AmoledCo5300`.
  Gate on the variant, not `panelW == panelH`: the scoping is "this board
  family (S3 + square)", and a hypothetical future square C6 board must not
  inherit it implicitly.
- The Mac sends tile-stream packets only to a panel advertising the bit;
  every other pairing takes the existing band path, byte-identical. This is
  the same additive-capability pattern `CAP_COMPRESSED_BANDS` shipped with —
  no `FRAME_PROTOCOL_VERSION` bump (the codebase explicitly reserves version
  bumps for breaking renegotiations; see the `EBAT` comment block).
- C6 firmware compiles the new headers (they're in the shared source set) but
  never executes them. Both firmware targets must stay compiling and all
  existing band tests must pass unchanged — pin "old wire format unaffected"
  with explicit tests.

## 6. Design

### 6.1 Tile grid

- 16x16 px tiles over the 466x466 native frame: 30 columns x 30 rows = 900
  tiles; the last column and last row are 2 px (466 = 29x16 + 2).
- Tile index = `tileY * 30 + tileX`, row-major, u16 on the wire (900 < 1024;
  10 bits used, matching the band index field width).
- Square panel: the grid is identical in both "orientations". The landscape
  bit is carried (header compatibility) but does not change geometry.
- Constants live in a new `firmware/display_stream/tile_protocol.h`
  (`namespace tileproto`), mirrored in a new Swift `TileProtocol.swift`.
  Grid math (tile rect from index, pixel offsets, edge-tile clamping) must be
  pure functions, host-tested on both sides.

### 6.2 Wire format

Packet header (6 bytes, deliberately shaped like the band header so transport
plumbing is reusable):

```
[frame_id u16 LE][first_tile u16 LE][dirty_count u16 LE]
```

- `first_tile` bit 15 = 1 always (distinguishes from any legacy packet; a
  tile-stream packet is never valid as a band packet because the firmware
  only enables one protocol per board). Bits 14..10 reserved-zero. Bits 9..0:
  index of the first record's starting tile (cross-check, like `first_band`).
- `dirty_count` bit 15 = landscape flag (carried for orientation bookkeeping);
  bits 14..0 = number of dirty TILES in this frame (used for completion).

Records, packed greedily to the 1472 B datagram budget:

```
[tile u16 LE: bits 9..0 start index, bits 14..10 run length - 1, bit 15 reserved-0]
[len u16 LE: bits 13..0 payload bytes, bits 15..14 codec]
[payload]
```

- **Run records**: a record covers `runLen` (1..30) horizontally adjacent
  tiles in one tile-row (never crossing a row boundary). 5 bits of run length
  (max 31 >= 30 columns). Runs cut per-record overhead and, more importantly,
  firmware draw calls. The payload is the run's rectangle rasterized row-major
  (width = sum of tile widths, height = tile height).
- **Codec field** (2 bits): 0 = raw RGB565, 1 = RLE565, 2 = BC1, 3 = reserved
  (future: CopyRect / half-res). `len` max 16383 covers the largest raw run
  (30 tiles x 512 B = 15,360 B) — but the packer splits runs so every record
  fits one datagram; a record never spans datagrams.
- Decoded size of any record is computable from the run geometry alone; a
  record whose payload does not decode to exactly that size is rejected
  (same posture as `rle565::decode`).

### 6.3 Codecs

Per run, the Mac encodes all applicable codecs and sends the smallest:

- **Raw**: always applicable; never worse than the alternatives + overhead.
- **RLE565**: existing codec, unchanged, applied to the run's raster bytes.
  Wins on flat/UI content, lossless.
- **BC1**: new. Per 4x4 block: two RGB565 endpoint colors (u16 LE each) then
  16 x 2-bit indices (4 bytes), 8 B total, blocks row-major within the run
  rect. Standard BC1 4-color mode only (c0 > c1; the 3-color+transparent mode
  is not used — encoder must ensure c0 >= c1, swapping if needed). Edge tiles
  (2 px): blocks cover `ceil(w/4) x ceil(h/4)`; the encoder pads by edge
  replication, the decoder clips writes to the true rect. Files:
  `firmware/display_stream/bc1.h` (`namespace bc1`, decode + encode, encode
  present for host round-trip tests exactly like `rle565::encode`) and Swift
  `BC1.swift`. The firmware decode is a **security boundary** — same
  contract as `rle565::decode`: never read/write out of bounds whatever the
  input claims, refuse rather than clamp, tested with exact-size heap buffers
  under ASan and mutation-tested (deliberately loosen each bounds check and
  confirm the suite catches it — see the RLE565 canary fix commit `f3078e5f`
  for the method).
- **Lossy/lossless policy knob**: the Mac chooses BC1 for a run only when
  (a) BC1 is the smallest encoding AND (b) the run's content variance exceeds
  a threshold, OR the frame is over its byte budget. A user-facing setting
  (SenderSettings) selects: `losslessOnly` / `auto` (default) / `aggressive`.
  This is the tunable quality lever replacing JPEG's percentage.

### 6.4 Reassembly (firmware)

`tileproto::Reassembler`, structurally identical to `bandproto::Reassembler`:
frame-id signed-diff ordering, stale-streak resync at `2 * 900` records,
duplicate suppression, completion at `dirty_count` distinct tiles. Bitmap is
113 bytes (900 bits). Every rule has a corresponding host test mirroring the
band reassembler's suite (wraparound, resync, duplicates, abandonment).

### 6.5 Firmware decode and draw path

- UDP task: for each record, decode into a small **internal-SRAM scratch**
  (max run raster = 15,360 B; use a static buffer, not PSRAM), then strided-
  copy the run's rows into `bufA` (row-major full-width, so a tile run's rows
  are at `bufA + (y * 466 + x0) * 2`, stride 932 B). Mark the run's tiles in
  a 900-bit `pendingDrawBitmap` equivalent under the existing `drawMux`.
- `loop()` draw: walk the tile bitmap per tile-row; merge horizontally
  adjacent dirty tiles into one rect per row (v1 does not merge vertically —
  measure first). For each rect: strided-copy `bufA ->` a small
  double-buffered internal-SRAM DMA staging buffer (NOT the full-frame PSRAM
  `bufB` — this cuts PSRAM traffic roughly in half and lets DMA read from
  internal RAM), then `esp_lcd_panel_draw_bitmap(panel, x0, y0, x1, y1, staging)`.
  Cap draw calls per loop iteration (start: 32) and carry the remainder to
  the next iteration, so a pathological checkerboard frame cannot starve
  touch/serial servicing; the DMA-stall failsafe and `dmaInFlight`
  bookkeeping carry over unchanged.
- The quick info bar's overlap-redraw hook (`redrawInfoBarOverRun` +
  `panelstate::rowRangeOverlaps`) must be honoured by the new draw path the
  same way the band path honours it.
- Keyframes: all 900 tiles as one frame (~81+ datagrams, ~50-60 ms at the
  current ceiling). Same triggers as today (first frame, orientation change,
  interval, loss recovery). Interval stays 2 s initially; revisit once loss
  behavior under the new protocol is measured.

### 6.6 Mac-side pipeline (per captured frame)

1. Diff against previous frame per 16x16 tile: strided `memcmp` of 16 rows
   x 32 B. Cost estimate ~1-2 ms worst case on Apple Silicon; optimize with
   64-bit word compares only if profiling demands.
2. Merge adjacent dirty tiles per tile-row into runs.
3. Budget check: if total estimated bytes (BC1 basis) exceed the per-frame
   budget (ingest ceiling / target fps, adaptively measured), degrade in
   order: (a) force BC1 on all runs, (b) engage half-res motion mode
   (section 6.8) if enabled, (c) drop to sending every other frame (30fps)
   rather than flooding — the panel's receive queue overflowing wastes more
   than pacing does.
4. Encode runs (raw/RLE565/BC1, smallest wins subject to the lossy policy),
   pack greedily into 1472 B datagrams, send with the existing pacing
   machinery (`FrameSender` heartbeat stats feedback loop).
5. Keep the existing send-rate feedback: heartbeats already report
   frames/dropped; extend the pacing to a datagrams/s token bucket calibrated
   to the measured ceiling with ~15% headroom.

### 6.7 Files

| New file                                    | Contents                                                   |
| ------------------------------------------- | ---------------------------------------------------------- |
| `firmware/display_stream/tile_protocol.h`   | grid math, header/record parse, packer walker, Reassembler |
| `firmware/display_stream/bc1.h`             | BC1 encode/decode, `maxEncodedBytes`-style bounds          |
| `mac/.../SenderProtocol/TileProtocol.swift` | grid math, record building, packer                         |
| `mac/.../SenderProtocol/BC1.swift`          | BC1 encode/decode                                          |
| `mac/.../SenderCore/` (FrameSender changes) | tile diff, budget/degradation policy, capability gating    |

Modified: `device_protocol.h` (+`CAP_TILE_STREAM`), `display_stream.ino`
(tile receive path + draw path, gated), `DeviceProtocol.swift` (+capability),
`FrameSender.swift` (protocol selection per panel), test files on both sides.

### 6.8 Half-resolution motion mode (adaptive, phase 5)

When engaged (frame over budget, or user setting): the Mac downsamples the
dirty region 2x, sends tiles flagged... — reserve codec value 3 as
`bc1HalfRes`: payload is BC1 for a rect at half dimensions; the firmware
decodes then pixel-doubles during the strided copy into `bufA`. 16:1 total
compression; full-frame motion at ~50-60fps becomes feasible within today's
packet ceiling. Visible softness is the cost; it disengages automatically
when the dirty area shrinks and full-res tiles overwrite. This is the
codec-value-3 future noted in 6.2 and is NOT in v1 — land it only after v1
is verified on hardware.

## 7. Phased implementation plan

**All phases are DONE. See section 12 for what shipped, the measured
outcome, and what is left.** The plan below is kept as written for the
reasoning behind each step; where the implementation departed from it,
section 12.1 says so.

Each phase ends green: all three suites pass, both firmware targets compile.
Commit per phase. Phases 0-2 involve no protocol commitment and de-risk
everything after.

- **Phase 0 — benchmark firmware. DONE — results in section 11.** A
  `CFGBENCH` serial command (S3 build only, gated on
  `CONFIG_IDF_TARGET_ESP32S3` in `display_stream.ino`) runs the on-board
  microbenchmarks; `tools/bench_serial.py <port>` triggers it and prints the
  results; `tools/bench_flood.py <ip> <size> <secs> [--rate N]` measures the
  datagram receive ceiling against the `badlen=` field of the 5s serial
  stats line. `esp_new_jpeg` was NOT measured: it is an ESP-IDF managed
  component not available to this Arduino-CLI build without vendoring, and
  the measured BC1 decode rate (17.2 Mpx/s, 5x the JPEG-class estimate) plus
  the discovery of the QSPI paint ceiling made JPEG's only advantage
  (compression ratio) unnecessary for the partial-frame-60fps target — door
  closed on different grounds than planned. Tile size 16 confirmed; run
  merging confirmed MANDATORY (see the draw-call fixed cost in section 11).
- **Phase 1 — BC1 codec, both languages, host-only.** `bc1.h` + `BC1.swift`,
  encode+decode, byte-identical formats asserted by independent vectors (no
  shared fixtures — repo rule). Round-trips, exact-size-buffer ASan tests,
  mutation-test every decoder bounds check. Quality spot-check: encode a real
  photo tile, eyeball decoded output in a host test harness (write a PPM).
- **Phase 2 — tile protocol, both languages, host-only.** `tile_protocol.h` +
  `TileProtocol.swift`: grid math (pin edge-tile sizes: tiles (29,y)/(x,29)
  are 2 px), header/record encode+parse with hostile-input refusals,
  Reassembler with the full band-reassembler test matrix ported, packer
  respecting the datagram budget. Pin `CAP_TILE_STREAM == 1 << 15` in both
  suites plus non-collision checks.
- **Phase 3 — firmware receive+draw path.** Wire into `display_stream.ino`
  behind the variant gate: scratch decode, strided `bufA` writes, per-row run
  merge, internal-SRAM staging draw with per-iteration draw-call cap, info-bar
  overlap redraw, capability advertisement. Compile both targets; C6 size
  must not grow more than trivially. Hardware smoke test: a hand-built test
  frame pushed from `tools/espdisp.py` (add a `tile-test` subcommand sending
  a few crafted records) before the Mac encoder exists.
- **Phase 4 — Mac encoder + integration.** Tile diff, run merge, codec
  choice, budget/pacing, capability-gated protocol selection in FrameSender.
  Keep the band path fully intact for non-tile panels; add tests proving a
  band-only panel's bytes are unchanged. Hardware verify end-to-end:
  correctness first (static screens pixel-perfect in lossless mode; no tile
  seams under motion; orientation/rotation; idle card; info bar), then
  throughput (measure fps via the existing `frames=` serial stat under: small
  motion region, ~40% dirty, full-frame motion) against the band-protocol
  baseline recorded beforehand.
- **Phase 5 — adaptive degradation.** Byte-budget policy, lossless/auto/
  aggressive setting in the app UI, optional half-res motion mode (codec 3),
  every-other-frame pacing fallback. Hardware verify with real video.
- **Phase 6 — receive-path ceiling workstream (parallel-capable).**
  Experiment on the S3 build: `CONFIG_LWIP_UDP_RECVMBOX_SIZE`, WiFi RX buffer
  counts (`WIFI_DYNAMIC_RX_BUFFER_NUM`, static RX buffers), AMPDU-RX
  settings, tight multi-recv loop in `udpReceiveTask`, larger socket buffer.
  Arduino-ESP32 pins much of this at core-build time — determine what is
  runtime-adjustable (`esp_wifi_set_config`-level) vs. needs `sdkconfig`
  control; if core rebuild is required, document and skip rather than fork
  the core. Every measured % gain here directly raises the full-frame fps
  ceiling. Re-measure the ceiling after each change; keep what helps.
- **Phase 7 — wrap-up.** Full suites, both compiles, update README protocol
  docs, record final measured fps table (small-motion / 40% / full-frame,
  lossless and lossy) in this document, commit.

## 8. Verification requirements (repo conventions — binding)

- Three suites must stay green at every commit:
  `firmware/test/run_tests.sh` (87,733 checks at plan time),
  `cd mac/ESPDisplaySender && swift test` (700),
  `python3 tools/test_espdisp.py` (465).
- Both firmware targets compile per commit:
  `python3 tools/espdisp.py compile --board s3` and `--board c6`.
  **Gotcha**: the Arduino build cache at
  `~/Library/Caches/arduino/sketches/3ACEEEC36ECE6F4CDED0E2E4F0F2CD89` is
  shared across boards keyed by sketch path — `rm -rf` it between board
  switches or the link step fails with "relocations in generic ELF".
- Flash: `python3 tools/espdisp.py flash --board s3 --port /dev/cu.usbmodemXXXX`
  (port re-enumerates between 101/1101 after reflashes — `ls /dev/cu.usbmodem*`).
  Board: `espdisplay-5594`, 192.168.1.180, `board=co5300`, OTA enabled
  (password in user's keychain; USB flash is the reliable path — OTA push had
  unresolved "No response from device" failures earlier).
- Serial watching: `/tmp/watch_serial3.py <port> <seconds>` (termios-based;
  recreate from `tools/espdisp.py`'s `open_serial` if missing). Never run two
  processes against the same port simultaneously.
- Hardware claims require hardware evidence: serial logs, CFGSHOW, dns-sd, or
  the user's own eyes on the panel. Anything not actually verified is marked
  UNVERIFIED explicitly. The user checks this.
- Security decoders (BC1 decode, record walker) get exact-size heap buffers
  under ASan non-recovering AND mutation testing: loosen each bounds check by
  one, confirm the suite aborts, revert. See commit `f3078e5f` for the method.
- No shared test fixtures across C++/Swift — each side hand-writes its wire
  vectors so drift fails a test instead of agreeing with itself.
- Conventional commits, imperative mood, wrapped bodies; build before commit.

## 9. Risks and open questions

| Risk                                                                 | Mitigation                                                                                                                                                                    |
| -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Datagram ceiling immovable                                           | 60fps stays partial-frame-only; half-res mode covers full-frame motion; set user expectations in-app (show measured fps)                                                      |
| Draw-call overhead makes many small rects slower than few big strips | Phase 0 measures it; per-row run merging bounds it; fallback is vertical merging or reverting dense frames to full-width strips (the band draw path stays in the binary)      |
| PSRAM bandwidth contention (bufA writes + staging reads + WiFi)      | internal-SRAM staging halves PSRAM traffic vs. band path's full-frame bufB; phase 0 measures the strided-copy cost                                                            |
| BC1 quality on gradients (banding at 4:1, 16-bit endpoints)          | lossless/auto/aggressive knob; RLE wins flat tiles anyway; half-res mode is the only place quality drops further and it is opt-in                                             |
| Tile seams under lossy encoding                                      | BC1 blocks are independent — no inter-block prediction — so seams only appear if encoder endpoints differ across a flat boundary; the variance gate sends flat tiles lossless |
| 2 px edge tiles complicate BC1                                       | encoder pads by replication, decoder clips; pinned in phase 1/2 tests                                                                                                         |
| Mac encode cost at 60fps                                             | BC1 encode is ~10 ops/px scalar; ~2-4 ms/full frame on Apple Silicon, less for partial frames; profile in phase 4, Accelerate/SIMD only if needed                             |

## 10. Success criteria

- Correctness: pixel-perfect static content in lossless mode; no visible tile
  seams or stale tiles under motion; orientation, rotation, idle card, info
  bar, touch, OTA all unaffected; C6 boards byte-identical on the wire.
- Throughput (measured on hardware, recorded here in phase 7):
  small-motion content at 60fps; >= 40% dirty at 60fps with BC1;
  full-frame motion >= 23fps full-res (>= 50fps with half-res mode if built).
- All suites green, both targets compile, per-phase commits.

## 11. Phase 0 results (measured 2026-08-12, espdisplay-5594, fw 1.3.0)

On-board microbenchmarks via `CFGBENCH` (`tools/bench_serial.py`), board on
USB power, WiFi associated at RSSI -62 to -68, sender app quit. Raw output:

```
bench: bc1 decode 2304000 px in 133949 us -> 17.20 Mpx/s
bench: rle565 decode 2304000 px in 20202 us -> 114.05 Mpx/s
bench: strided write SRAM->PSRAM 3.1 MB in 9020 us -> 340.6 MB/s
bench: strided read PSRAM->SRAM 3.1 MB in 8639 us -> 355.6 MB/s
bench: memcpy PSRAM->PSRAM 2.2 MB in 97568 us -> 22.3 MB/s
bench: draw tile 16x16 x200: 152.8 us/call, 6543 calls/s
bench: draw run 480x16 x100: 899.4 us/call, 1112 calls/s
bench: draw fullwidth 466x16 x100: 874.7 us/call, 1143 calls/s
bench: draw tile 16x16 x200 pipelined: 154.5 us/call, 6472 calls/s
```

### 11.1 Interpretation

| Measurement                            | Value                                                                     | Consequence                                                                                                                                                                                                                    |
| -------------------------------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| BC1 decode (SRAM->SRAM, bench decoder) | 17.2 Mpx/s                                                                | full 466x466 frame = 12.6 ms; NOT the 60fps bottleneck for partial frames (45 KB/frame budget = ~90 Kpx = ~5.2 ms)                                                                                                             |
| RLE565 decode (worst-case all-literal) | 114 Mpx/s                                                                 | negligible; effectively memcpy speed                                                                                                                                                                                           |
| Strided copies SRAM<->PSRAM            | 340-356 MB/s                                                              | far faster than feared; strided tile writes to bufA and staging reads are non-issues                                                                                                                                           |
| Full-frame memcpy PSRAM->PSRAM         | 22.3 MB/s                                                                 | the band path's bufA->bufB full-frame copy costs ~19.5 ms — by itself under 51 fps. Internal-SRAM staging (section 6.5) is VALIDATED as necessary, not just nice                                                               |
| Draw call, 16x16 (512 B)               | 152.8 us/call, no pipelining gain                                         | fixed overhead ~140 us/call dominates small draws. 900 separate tile draws = 137 ms = 7 fps. **Run merging is mandatory, not an optimization**                                                                                 |
| Draw call, 480x16 (15,360 B)           | 899.4 us/call                                                             | implies ~20.5 MB/s QSPI pixel rate + ~150 us fixed. Full frame painted as 30 full-width strips = ~26 ms = **~38 fps full-frame paint ceiling** (466x16: 874.7 us x 30 = 26.2 ms)                                               |
| Datagram receive ceiling               | best 5s windows ~2,350-2,400/s (1472 B and 512 B alike); size-independent | ~3.5 MB/s max ingest at 1472 B. Slightly better than the historical 1,826/s. Sustained rates during floods were radio-limited (RSSI degraded to -70..-80 mid-test), not board-limited — re-measure closer to the AP in phase 6 |

Flood method note: unpaced floods (72k datagrams/s offered = ~850 Mbps at
1472 B against a 2.4GHz-only radio) collapse the AP queue and produce
erratic 300-2,300/s windows; paced floods (`--rate` bracketing the ceiling)
gave the clean readings. The ceiling is per-datagram, not per-byte: 512 B
and 1472 B floods peaked within noise of each other, confirming that
fewer/denser packets remains the right lever.

### 11.2 Revised budget (measured numbers replacing section 2's estimates)

Ingest at 2,400/s x 1472 B = ~3.5 MB/s. Per-frame budgets at 60 fps:

| Path                                      | Cost per 60fps frame               | Verdict                                                                             |
| ----------------------------------------- | ---------------------------------- | ----------------------------------------------------------------------------------- |
| Network ingest                            | 58.8 KB/frame max (~40 datagrams)  | = ~54% of panel dirty at BC1 4:1, ~13% raw lossless                                 |
| BC1 decode                                | 5.2 ms per 45 KB (90 Kpx)          | fits alongside everything else                                                      |
| Strided bufA writes                       | ~0.5 ms                            | negligible                                                                          |
| Draw (merged runs, staging reads)         | ~150 us + 49 us/KB per merged rect | e.g. 15 merged runs x ~250 us avg = ~3.8 ms; fits                                   |
| Full-frame paint (all 30 tile-rows dirty) | ~26 ms                             | **hard ~38 fps ceiling for full-frame updates — QSPI bus, no protocol can beat it** |

Revised conclusions:

1. 60 fps is confirmed feasible for motion touching up to roughly HALF the
   panel per frame (BC1), better than the pre-measurement estimate (~40%).
2. Full-frame motion is capped at ~38 fps by the QSPI pixel bus alone
   (paint time), before network enters into it; with ingest at ~2,400
   datagrams/s, BC1 full frames land at ~29 fps (109 KB / 1472 B = 75
   datagrams = 31 ms + paint overlap). Raising the datagram ceiling
   (phase 6) pushes toward the paint ceiling; nothing pushes past ~38 fps
   full-frame except the half-res mode (section 6.8), whose quarter-size
   paints also quarter the paint time.
3. The per-draw fixed cost (~140-150 us) makes run merging load-bearing:
   the draw path must never issue per-tile draws for dense regions. The
   per-loop draw-call cap (section 6.5) should be set against this number:
   32 calls = ~4.8 ms minimum.
4. The band path's own PSRAM full-frame memcpy (~19.5 ms) explains a chunk
   of today's frame-rate ceiling independent of the network. The tile
   path's internal-SRAM staging removes it entirely.

### 11.3 Bench tooling (kept in-tree for phase 6 re-measurement)

| Tool                                                 | Use                                                                                                                      |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `CFGBENCH` serial command                            | S3-only, in `display_stream.ino`; runs decode/copy/draw benches, ~3 s, visually invisible (draws copy bufA content back) |
| `tools/bench_serial.py <port> [secs]`                | sends CFGBENCH, prints results                                                                                           |
| `tools/bench_flood.py <ip> <size> <secs> [--rate N]` | offered-rate flood; read `badlen=` deltas from the 5 s serial stats for the receive rate                                 |

## 12. Outcome (phases 1-7 shipped 2026-08-13)

All seven phases are implemented, hardware-verified on espdisplay-5594, and
committed. What shipped, and what the numbers actually turned out to be.

### 12.1 What shipped

| Phase | Commit    | Contents                                                                                                    |
| ----- | --------- | ----------------------------------------------------------------------------------------------------------- |
| 0     | `68e72e0` | `CFGBENCH` on-board benchmarks, `bench_serial.py`, `bench_flood.py`, section 11                             |
| 1     | `79586e5` | `bc1.h` + `BC1.swift`: BC1 encode/decode, mutation-tested decoder                                           |
| 2     | `f4f7dc6` | `tile_protocol.h` + `TileProtocol.swift`: grid, wire format, walker, reassembler, packer; `CAP_TILE_STREAM` |
| 3     | `97596d6` | Firmware receive + draw path (S3-gated), capability advertisement, `espdisp.py tile-test`                   |
| 4     | `2914773` | Mac tile diff + `sendTileFrame`, capability-gated protocol selection                                        |
| 5     | `bc72342` | Variance gate, degradation ladder, Lossless/Automatic/Aggressive setting                                    |
| 6     | `ed29514` | Receive-path drain loop + 64 KB `SO_RCVBUF`                                                                 |

Deviations from the plan as written:

- **Codec exclusivity was not anticipated.** Tile packets and packed band
  packets both claim bit 15 of the header's second field and are ambiguous
  past it, so a board advertises exactly one of `CAP_TILE_STREAM` /
  `CAP_COMPRESSED_BANDS` rather than both (section 5 assumed the new bit was
  purely additive). Classic unpacked band packets stay accepted everywhere,
  so an older sender still drives the tile panel - verified live at ~29fps
  during phase 3.
- **`esp_new_jpeg` was never measured** (section 7 phase 0 explains why: not
  available to this Arduino-CLI build, and the measured BC1 rate made its
  only advantage moot).
- **Half-resolution motion mode (codec 3) was not built.** Still reserved,
  still the only path past the QSPI paint ceiling. See 12.4.
- **Vertical run merging was not built.** Per-row merging alone brought the
  draw cost inside budget.

### 12.2 Measured results

Receive ceiling, paced floods at 1472 B, same session, RSSI -56 to -62:

| Receive path   | Sustained accepted                    | Ingest    |
| -------------- | ------------------------------------- | --------- |
| Before phase 6 | ~1,977-2,460/s (peak window 3,173/s)  | ~3.0 MB/s |
| After phase 6  | ~2,700-2,880/s at 3,000-5,000 offered | ~4.2 MB/s |

End-to-end, tile protocol against the band-protocol baseline on the same
board and content:

| Content                   | Band protocol               | Tile protocol                      |
| ------------------------- | --------------------------- | ---------------------------------- |
| Light / mostly static     | ~29 fps at ~300 datagrams/s | ~35 fps at ~70 datagrams/s         |
| Ordinary desktop use      | not measured                | ~24-27 fps at ~450-550 datagrams/s |
| Video in a window         | unusable                    | smooth (user-verified)             |
| Majority-of-screen motion | unusable                    | still saturates - see 12.4         |

BC1 quality: PSNR 39.1 dB at 4:1 on photo-like content (gradients + noise +
a sharp edge), max per-channel error 9/255 - above the JPEG-q70 bar the
project set. On-target decode of the shipped decoder: 15.51 Mpx/s (12.6 ms
for a full frame), against 17.20 for the phase-0 stand-in.

Suite growth across the work: firmware 87,733 -> 103,417 checks, Swift 700
-> 730 tests, Python 465 -> 567 checks. S3 binary 1,062,102 -> 1,064,374 B
(81% of flash). C6 binary grew 16 bytes total, all of it the capability
conditional; its wire format is untouched.

### 12.3 Success criteria, honestly scored

| Criterion (section 10)                                            | Result                                                                                                                             |
| ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Pixel-perfect static content in lossless mode                     | met                                                                                                                                |
| No tile seams or stale tiles under motion                         | met (user-verified)                                                                                                                |
| Orientation, rotation, idle card, info bar, touch, OTA unaffected | met                                                                                                                                |
| C6 boards byte-identical on the wire                              | met                                                                                                                                |
| Small-motion content at 60fps                                     | NOT met - ~35 fps on light content; the ceiling is the sender's own capture/encode cadence and the datagram rate, not the protocol |
| >= 40% dirty at 60fps                                             | NOT met                                                                                                                            |
| Full-frame motion >= 23fps full-res                               | partially - holds for moderate motion, saturates when most of the panel changes every frame                                        |
| All suites green, both targets compile, per-phase commits         | met                                                                                                                                |

The 60fps target was not reached. The protocol work did what section 2's
math said it would - the wire cost per frame is now near-minimal for
partial-frame motion, and the receive ceiling is 40% higher - but three
hard limits remain, and none of them are the diffing engine:

1. **QSPI paint: ~38 fps full-frame**, measured in phase 0. No protocol
   beats this.
2. **Datagram rate: ~2,850/s**, i.e. ~70 KB per frame at 60fps. A frame
   where most tiles are dirty exceeds that even at BC1's 4:1.
3. **Sender-side cadence.** Capture, diff, and encode all sit on one
   pacing loop; light content measured ~35 fps, not the 60 the budget
   allows. This was never profiled - phase 4 deferred it and nothing since
   has looked. It is the cheapest remaining unknown.

### 12.4 What is left

- **Majority-of-screen motion still fails.** The user has a proposal for
  this case, not yet discussed or designed; it is the next conversation.
  The mechanisms already reserved for it: half-res mode (codec 3, section
  6.8), which quarters both wire bytes and paint time, and vertical run
  merging.
- **Sender-side profiling** (limit 3 above): where the ~35 fps light-content
  ceiling actually goes - capture, diff, BC1 encode, or the pacing sleep.
- **`autoVarianceThreshold` = 400 is a first guess.** It has never been
  tuned against real content; it is one named constant in `TilePacker`.
- **`drawerr` climbs slowly under sustained saturation** (~10/hour observed
  during video): the DMA-stall failsafe reclaiming a lost completion.
  Harmless, self-healing, unexplained.
- **sdkconfig-locked receive knobs** (`CONFIG_LWIP_UDP_RECVMBOX_SIZE`, WiFi
  RX buffer counts, AMPDU-RX): would need an Arduino core rebuild, skipped
  per the plan's own decide-and-skip rule.
