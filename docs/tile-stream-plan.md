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

```plain
[frame_id u16 LE][first_tile u16 LE][dirty_count u16 LE]
```

- `first_tile` bit 15 = 1 always (distinguishes from any legacy packet; a
  tile-stream packet is never valid as a band packet because the firmware
  only enables one protocol per board). Bits 14..10 reserved-zero. Bits 9..0:
  index of the first record's starting tile (cross-check, like `first_band`).
- `dirty_count` bit 15 = landscape flag (carried for orientation bookkeeping);
  bits 14..0 = number of dirty TILES in this frame (used for completion).

Records, packed greedily to the 1472 B datagram budget:

```plain
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

```plain
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

**Correction (see section 15.2): the datagram figures below measure packets
the firmware REJECTS instantly, i.e. the receive path with no decode and no
draw. Real tile datagrams carrying BC1 tiles top out at ~1,350-1,500/s. The
phase-6 improvement is real; the absolute number does not describe
end-to-end capacity.**

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

## 13. Round-glass masking (phase 8, shipped 2026-08-13)

The panel's glass is round. Every protocol above it — the band system, then
the tile system — has been faithfully delivering the corners of a square
framebuffer to a display that physically cannot show them. That is 181 of
the 900 tiles, and it was being paid for on every keyframe and every frame
whose changes touched a corner.

Nothing in sections 1-12 noticed this. It is not a compression idea or a
protocol idea; it is the observation that a fifth of the pixels were never
addressable in the first place.

### 13.1 The geometry

A pixel is visible when its centre lies inside the frame's inscribed circle
(radius 233 on 466x466). A tile is skippable only when its NEAREST pixel to
the centre is still outside — a tile straddling the boundary holds visible
pixels and must be sent whole.

| Class                     | Tiles       | Note                      |
| ------------------------- | ----------- | ------------------------- |
| Fully outside (skippable) | 181 (20.1%) | never sent again          |
| Straddling the boundary   | 106         | sent whole, partly wasted |
| Fully inside              | 613         |                           |
| Sent per keyframe         | 719         | was 900                   |

Tile granularity costs almost nothing: the circle is 78.6% of the frame's
area (π/4, as it must be), and the kept tiles cover 83.7% — so the mask
captures 20.1 of the 21.4 percentage points theoretically available. 16 px
tiles are simply small against a 233 px radius.

Two properties make this cheaper than expected:

- **A circle's intersection with a tile-row is convex**, so every row's
  visible tiles form ONE contiguous span (row 0 is columns 9..19, row 1 is
  7..21, ... row 29 is 12..16). Masking therefore never fragments a run and
  never adds a draw call: 30 rows before, 30 rows after.
- **It is sender-only.** The firmware needed no receive-path or draw-path
  change at all, because `dirty_count` is sender-declared and the
  reassembler completes at whatever the frame promised. A 719-tile keyframe
  already worked. The only firmware change is one bit of advertisement.

### 13.2 Why it attacks the case sections 12.3/12.4 could not

Section 12.3 listed the ~38.9 fps QSPI paint ceiling as limit 1 and said
"no protocol beats this". True, and irrelevant: masking is not a protocol
change, it is a smaller frame. The panel paints only what the sender marks,
so skipping 181 tiles removes their paint time too.

| Path                             | Before             | After                  |
| -------------------------------- | ------------------ | ---------------------- |
| Full-frame paint (phase-0 model) | 25.7 ms → 38.9 fps | 22.2 ms → **45.0 fps** |
| Keyframe tiles                   | 900                | 719                    |
| Wire bytes, full frame           | 100%               | ~84%                   |

So the one scenario still failing — majority-of-screen motion — gets ~20%
relief on both axes at once, with no quality cost and no protocol change.
It is not a fix for that case; it is a fifth of one.

### 13.3 How the mask was made safe

Skipping a tile that turns out to be visible is not like dropping a packet.
It is permanent: no keyframe heals it, because keyframes skip it too. So
every choice errs toward sending.

- The predicate skips only tiles whose nearest pixel is outside.
- A round flag on non-square geometry is declined outright.
- The mask stays off until an EINF advertises `CAP_ROUND_DISPLAY`; a sender
  that never learns is correct, merely slower.
- **It was verified against the physical glass before anything relied on
  it.** `espdisp.py tile-test --round-mask` paints the 181 skippable tiles
  magenta, the 106 boundary tiles green, the interior grey, and sends all
  900 — nothing masked — so a wrong mask appears as visible magenta rather
  than as silence. Result on hardware: no magenta anywhere, and the green
  ring reaching the bezel, i.e. the boundary sits exactly at the rim with
  no margin wasted in either direction.
- After enabling it, a window dragged to the rim rendered complete, with no
  stale arc or frozen patch (user-verified).

`CAP_ROUND_DISPLAY = 1u << 16` carries the one fact the sender cannot
otherwise know, read from `board::Config::roundDisplay` (only the CO5300
entry sets it). The 181/106/613 split is pinned independently in Swift
(`TileMask`), Python (`tile_visibility`), and the C++ suite, per the
no-shared-fixture rule.

### 13.4 What was measured, and what was not

Live window with the mask active, ordinary desktop content: ~20-26 fps at
~66-140 datagrams/s, 0-2 dropped frames per 5 s window, `badlen` 0. The
pre-mask session on comparable-but-not-identical content read ~24-27 fps at
~450-550 datagrams/s with 5-12 drops per window.

**That is not a controlled A/B and should not be read as one** — screen
content cannot be replayed identically between runs, and the earlier
measurement was taken during heavier use. What is exact is the arithmetic
the suites pin (719 tiles per keyframe instead of 900, corner changes never
reported dirty) and the paint figure projected from phase 0's measured
per-call model. A genuine A/B would need the same content driven twice with
the capability bit toggled between runs; it has not been done.

### 13.5 What this leaves for the majority-of-motion case

Still open, and still the next conversation:

- **Boundary-tile flattening.** The 719 kept tiles still contain 11,244
  invisible pixels (6.2% of what is sent) in the boundary ring. Zeroing
  them before encoding would help RLE compress them — but it stretches
  BC1's endpoint bounding box and would degrade the _visible_ pixels of the
  same tile, so it is only sound applied to the RLE candidate alone. Modest,
  with a trap in it.
- **Half-res motion mode** (codec 3, section 6.8) and **vertical run
  merging**, both still unbuilt.
- **Sender-side profiling** — limit 3 from section 12.3, still never done,
  still the cheapest remaining unknown.

## 14. Sender-side profiling (phase 9, 2026-08-13)

Section 12.3 listed three limits and named the third — "un-profiled
sender-side capture/encode cadence" — as the cheapest remaining unknown.
It was, and it was also the largest. Instrumenting the send path
(`FrameSender.reportTileStatsIfDue`, a `tile:` line every 5 s) found two
separate defects and one configuration mistake, none of which were where
the guesses pointed.

### 14.1 What the guesses got wrong

The plan had assumed BC1 encode was the sender's expensive step
(section 9 risk row: "BC1 encode is ~10 ops/px scalar; ~2-4 ms/full frame
... profile in phase 4"). Phase 4 deferred that profiling and nothing
since had looked. Measured, per full keyframe of 719 tiles:

| Stage                   | First measurement | Suspected?                           |
| ----------------------- | ----------------- | ------------------------------------ |
| tile diff               | 0.23 ms           | feared ~1-2 ms; it is free           |
| encode                  | 20.4 ms           | yes — but not for the reason assumed |
| send                    | 103.3 ms          | never suspected at all               |
| — of which pacing sleep | 100.6 ms          | —                                    |

Pacing was 83% of a frame's cost and had never been measured once.

### 14.2 Defect 1: sub-millisecond `usleep` cannot pace datagrams

The send loop slept `spacingMicros` after every datagram. With spacing at
333 µs, the measured cost was **890 µs per datagram**, and in the worst
windows 2.5 ms against a 429 µs ceiling — a 6x overshoot. A
sub-millisecond sleep is dominated by syscall cost and macOS timer
coalescing, not by the interval requested. `sendQueue` was already
`.userInteractive`, so QoS was not the cause.

Consequence: the sender emitted at most ~1,120 datagrams/s while the
panel accepts ~2,850/s (section 12.2). **Every earlier ceiling blamed on
ingest was actually the sender's own pacing loop.** Phase 6 raised the
panel's receive ceiling by 40% into headroom the sender could not use.

Fix: send in bursts of 8 and sleep once per burst against an absolute
deadline, so an overlong sleep shortens the next one instead of
accumulating, and the datagram rate is honoured across frame boundaries
rather than only within a frame. The burst is bounded well under the
~44 datagrams the panel's 64 KB socket buffer absorbs — phase 6 is what
makes bursting safe rather than lossy, so the two changes compound.

Result: **890 µs → 225 µs per datagram**, i.e. ~4,440/s achievable,
comfortably above the panel's ceiling. The sender is no longer the
constraint on anything.

### 14.3 Defect 2: the variance scan ran when it could not matter

Encode's 20 ms was not BC1. On flat desktop content under `.auto`, the
variance gate rejects BC1 — so BC1 was rarely encoded — but
`runVariance` was computed for EVERY run first, a full pass with
multiplies over each raster, to decide something that was already
decided.

BC1 is fixed-rate, so its encoded size is known from the run's
dimensions without encoding anything. When the lossless winner is
already at least as small, BC1 cannot win, and neither it nor the
variance scan needs to run. Reordering `TilePacker.prepare` to check
that first skips both in the common case.

Also hoisted: `BC1.encode` re-expanded the same four palette colours to
888 on every one of its 64 per-block distance comparisons. Expanding
once per block is a pure algebraic hoist — the byte-for-byte wire
vectors still pass unchanged.

### 14.4 Mistake 3: the frame-rate default was the cap

`SenderSettings.fps` defaulted to 40, and that value becomes
ScreenCaptureKit's `minimumFrameInterval`. The ~35 fps that section 12.3
recorded as a mysterious sender-side limit was **87% of a configured
40 fps cap**. No amount of protocol work could ever have reached 60.

Raised to 60. The default is now `SenderSettings.defaultFps`, because it
has to agree in three places — the property, the explicit `init`'s
parameter default, and the decode fallback — and the explicit init
SHADOWS the property, so the first attempt at this change (editing only
the property) compiled, passed, and did nothing. The test asserts the
literal, not the constant, so that state cannot pass again.

### 14.5 Measured after

Same board, ordinary desktop content, capture at 60 fps, ~9% dirty:

| Stage           | Before phase 9 | After             |
| --------------- | -------------- | ----------------- |
| diff            | 0.23 ms        | 0.35 ms           |
| encode          | 20.4 ms        | **0.44 ms**       |
| send            | 103.3 ms       | **6.4 ms**        |
| per datagram    | 890 µs         | **225 µs**        |
| send-path total | ~124 ms/frame  | **~7.2 ms/frame** |

~7.2 ms per frame is ~139 fps of send-path headroom. The panel's `shown`
counter tracks the sender almost exactly (124 frames per 5 s window), so
frames are not being lost downstream either.

### 14.6 Where the ceiling actually sits now

~20-24 fps on desktop content, and **the send path is no longer why**.
ScreenCaptureKit delivers frames only when content CHANGES; on a desktop
with modest motion, 20-24 changed frames per second is what exists to
send. That is correct behaviour, not a limit — and it means the honest
statement of the remaining ceiling is:

1. **~45 fps** full-frame QSPI paint (section 13.2, after round masking).
2. **~2,850 datagrams/s** ingest, now genuinely reachable by the sender.
3. **Content change rate**, which no amount of engineering raises.

Untested: whether genuine 60 fps content (a 60 fps video) now delivers
60 fps end to end. Everything measured says the pipeline has the
headroom; nobody has watched it. That is the next measurement, and it
needs 60 fps source material rather than a desk.

## 15. Full-frame motion: what was actually wrong (phase 10, 2026-08-13)

The user's report was that majority-of-screen motion "fully fails" while
partial motion looks great. Section 13.5 planned to answer that with
half-res mode. Measuring it first found two defects and one wrong number,
and none of them needed a new codec.

### 15.1 A benchmark that does not need the Mac's screen

`espdisp.py tile-motion <ip> --target-fps N` streams synthetic full-frame
BC1 updates — every one of the round mask's 719 visible tiles, valid BC1
noise at the real 8 bytes per block, packed to the datagram budget: 66
datagrams and 94 KB per frame. It reads the panel's own EHB1 heartbeats on
its sending socket (the panel replies to whoever spoke last, and a flood
wins that race, so a separate listener sees nothing) and reports offered
and achieved rates together. No serial cable, which matters because this
board's USB CDC drops out repeatedly, and no dependence on what happens
to be on screen.

This is the measurement section 10 asked for and never got.

### 15.2 Wrong number: the ~2,850 datagrams/s ceiling

Sections 12.2 and 14 cite ~2,850 datagrams/s. That figure came from
`bench_flood.py`, whose packets set a reserved header bit so the firmware
counts and DISCARDS them immediately. It measures the receive path with
zero decode and zero draw.

Real tile datagrams carry ~11 BC1 tiles each and must be decoded and
copied. Measured with `tile-motion`, the panel accepts **~1,350-1,500
datagrams/s** of real work — about half. The old figure was not wrong
about what it measured; it was generalized past what it supported, and
the phase-6 gain it reported (~40%) is real but applies to the
receive-path cost, not to end-to-end capacity.

### 15.3 Defect: frame completion is all-or-nothing over 66 datagrams

A frame draws only once every tile it promised has arrived. Full-panel
updates are 66 datagrams, so completion probability is `(1-p)^66`.

Measured loss on this link is about **0.5% per datagram** — a good link.
Over 66 datagrams that becomes a third of frames never completing, and it
compounds as the rate climbs:

| Offered | Accepted dgram/s | Shown fps | Frames never completed |
| ------- | ---------------- | --------- | ---------------------- |
| 10      | 579              | 6.8       | 31.5%                  |
| 15      | 962              | 10.9      | 26.8%                  |
| 20      | 1029             | 5.5       | 59.2%                  |
| 45      | 1342             | **0.0**   | **100%**               |

At 45 fps offered the panel accepted 1,342 datagrams/s and displayed
NOTHING. That is the reported failure, and the pixels were never missing:
`applyTileRecord` writes each tile into bufA as it arrives, so the panel
held nearly a complete frame and the reassembler was the only thing
withholding it.

Fix: if tiles are pending and no frame has completed for
`TILE_PARTIAL_DRAW_MS` (40 ms), draw what arrived. A partially updated
frame during motion is imperceptible next to a frozen panel, and any
missing tile is corrected by the next frame covering it, or by the
2-second keyframe at worst. Tile path only — a band frame is few enough
datagrams that completion is not its binding constraint.

### 15.4 Defect: the phase-6 drain loop starved the draw task

Phase 6's `MSG_DONTWAIT` drain loop keeps pulling while datagrams keep
arriving, and `udpReceiveTask` runs at priority 9 against loop()'s 1.
Under sustained load the socket never empties, so the draw never happens:
at 30 full frames/s the panel accepted 1,519 datagrams/s and drew 5.4
times a second. Neither the blocking `recvfrom` nor `MSG_DONTWAIT` yields
while data is queued, so the yield has to be explicit — 24 datagrams
between `vTaskDelay(1)` calls, a ceiling far above the radio's while
bounding how long drawing waits.

### 15.5 Result

| Offered | Before            | + partial draw | + yield          |
| ------- | ----------------- | -------------- | ---------------- |
| 15      | 10.9 (26.8% lost) | 23.2 (36.4%)   | **13.5 (18.2%)** |
| 20      | 5.5 (59.2%)       | 18.9 (49.0%)   | **13.8 (46.6%)** |
| 30      | —                 | 5.4 (84.7%)    | 6.2 (83.0%)      |
| 45      | **0.0** (100%)    | 3.7 (92.4%)    | **6.8 (86.7%)**  |

Full-frame motion goes from collapsing to zero to sustaining ~14 fps,
and frame loss at 15 fps halves. Note the metric: `statFramesShown` now
counts DRAW PASSES on the tile path, so a partial draw inflates it — that
is why the middle column reads 23.2 for 15 offered. The yield's apparent
regression there is the opposite: fewer partial draws were needed because
more frames completed whole.

### 15.6 Why half-res mode is now justified

The ceiling is arithmetic: ~1,500 accepted datagrams/s over 66 datagrams
per frame is 22.7 fps at zero loss, and loss holds it near 14. Both terms
are the frame's SIZE, and both improve together if the frame gets smaller.

Half-res (codec 3, section 6.8) sends 719 tiles at quarter resolution:
~32 bytes per tile, so roughly a quarter of the payload and a quarter of
the decode work, with far better completion odds per frame. This is the
one remaining change that attacks every term at once, and unlike before,
there is now a measurement saying so rather than an estimate.

(Shipped in section 16. The estimate above was close but optimistic in
one detail: a tile's 4-byte record header does NOT shrink with its
payload, so 132 B per tile becomes 36 B - a 3.65x saving, not 4x - and a
full frame is **18 datagrams, 25.8 KB**, not the 17 and ~23 KB predicted
here. The `(0.995)^n` completion argument holds at n=18.)

Still open, unchanged: vertical run merging, boundary-tile RLE flattening
(RLE candidate only — it would degrade BC1's visible pixels), the untuned
`autoVarianceThreshold`, and whether genuine 60 fps source material
delivers 60 fps end to end.

## 16. Half-resolution BC1, codec 3 (phase 11, 2026-08-13)

Section 15.6 argued that majority-of-screen motion is bound by the frame's
SIZE in two ways at once - the datagram rate it demands, and the
`(1-p)^n` completion probability over n datagrams - and that both improve
together if the frame gets smaller. This is that change: the codec value
reserved since section 6.8, finally defined.

### 16.1 What is on the wire

A record with codec 3 carries BC1 of a `halfDim(w) x halfDim(h)` raster,
where `halfDim(d) = ceil(d/2)`. The receiver decodes it and PIXEL-DOUBLES
it to the run's true `w x h` before the usual strided write into bufA.
Everything downstream - the draw path, run merging, the partial-draw
fallback - is unchanged and unaware the tile travelled small.

Rounding UP is load-bearing. The 466 grid's last column and row are 2 px,
which halves to 1; rounding down would give 0 and there would be nothing
to double. On this panel `runW` is always even (a run is either a multiple
of 16 or `466 - col*16`, which is 2 mod 16) and `runH` is 16 or 2, but the
implementation is general and the odd cases are tested.

What is deliberately NOT on the wire: **how the sender picked those
half-res pixels.** The panel's only obligation is the pixel-doubling, so
the sender's filter is a quality choice it can improve without a protocol
change or a firmware update. Today it is a 2x2 box average in the native
5/6/5 channel space, chosen over decimation because dropping 3 of every 4
pixels aliases hardest on exactly the content that triggers half-res -
video and scrolling text - and the cost is trivial beside BC1's own encode.

Per-tile sizes, which is where the earlier estimate went slightly wrong:

| Codec        | 16x16 tile | + record header | Full frame (719 tiles)    |
| ------------ | ---------- | --------------- | ------------------------- |
| Raw          | 512 B      | 516 B           | ~370 KB                   |
| BC1          | 128 B      | 132 B           | 94.3 KB, 66 datagrams     |
| Half-res BC1 | 32 B       | 36 B            | 25.8 KB, **18 datagrams** |

The saving is **3.65x, not 4x**: the payload quarters but the 4-byte
record header does not. Section 15.6 predicted 17 datagrams from the 4x
figure; the wire needs 18.

### 16.2 It is never chosen for being small

Every other codec here competes on size and wins when it is smallest.
Half-res cannot be allowed to, because it is ALWAYS smallest - so
`.aggressive` would pick it for every run on screen and static UI would
sit there permanently soft. Resolution is a different currency from the
colour precision BC1 spends, and a user who cannot see the difference in
a still window will certainly see this one.

So codec 3 is chosen only when the frame-level degradation ladder asks
for it, and even then only if it still beats the lossless winner on size -
which is what keeps flat runs, already a handful of RLE bytes, at full
resolution. The ladder (section 6.6) gains the rung it was always missing:

| Rung | Condition                           | Action                           |
| ---- | ----------------------------------- | -------------------------------- |
| a    | raw estimate over budget            | force BC1 regardless of variance |
| b    | even all-BC1 over budget            | **force half-res (new)**         |
| c    | even the cheapest codec over budget | skip the next diff frame         |

Before this, the ladder went straight from "force BC1" to "send fewer
frames", which is why full-res motion capped at ~14 fps. Rung (b) also
skips the BC1 encode it supersedes - encoding 719 tiles at ~30 us each
only to discard the result would have added ~21 ms to precisely the frames
the ladder is trying to cheapen.

`.losslessOnly` forbids rung (b) outright: dropping resolution is the
largest possible violation of what that setting promises.

### 16.3 Negotiated, because guessing is worse than degrading

`CAP_TILE_HALFRES` (bit 17). Tile firmware predating this rejects codec 3,
and because a rejected record aborts its whole datagram, a sender that
guessed would lose entire frames - turning a quality degradation into a
worse outage than the one being fixed. So the sender emits codec 3 only
where the bit was advertised.

The bit is folded into the existing `tileStreamEnabled()` ternary rather
than added as its own, so the C6 - where that predicate is always false -
emits nothing extra for a capability it can never advertise.

### 16.4 Measured on hardware

Same board, same session, RSSI **-80** (much weaker than section 15's -56
to -62, so these absolute numbers are NOT comparable with that table -
only with each other). `espdisp.py tile-motion [--half]`:

| Mode     | Offered fps | Offered dgram/s | Accepted | Frames dropped |
| -------- | ----------- | --------------- | -------- | -------------- |
| Full-res | 20          | 1,320           | 1,091    | 44.4%          |
| Full-res | 45          | 2,970           | 656      | 66.4%          |
| Half-res | 20          | 360             | 350      | **20.0%**      |
| Half-res | 45          | 810             | 990      | **42.7%**      |
| Half-res | 60          | 1,080           | 868      | **40.7%**      |

Frame loss roughly HALVES at matched offered rates (44.4 -> 20.0 at 20 fps,
66.4 -> 42.7 at 45 fps), which is the `(1-p)^n` effect of 18 datagrams
instead of 66 showing up exactly where predicted.

The structural result is the arithmetic, though, not the drop rate.
Offering 60 fps full-res demands 3,960 datagrams/s against a measured
ceiling of ~1,350-1,500 (section 15.2) - not marginal, impossible by a
factor of 2.6. Half-res demands 1,080, which fits. Full-res 45 fps got
656 of the 2,970 datagrams/s it needed, 22%; half-res 45 fps got
essentially all of its 810.

One measurement caveat: **accepted can exceed offered** (990 against 810
at 45 fps) because 802.11 retry duplicates reach `applyTileRecord`, get
classified `Duplicate`, and still count in `statPackets`. Duplicates are
correctly not applied to bufA and not counted toward completion; only the
packet counter sees them.

### 16.5 The ceiling moved to the paint, and half-res cannot help it

Every run above 20 fps offered reads 20-24 fps shown, in BOTH codecs. The
first explanation written here was that `TILE_PARTIAL_DRAW_MS` (40 ms) caps
the counter at ~25/s. That is wrong, and wrong in a way worth recording:
the partial-draw timer only ever ADDS draw passes, so it cannot cap
anything. 25 and the observed 23.5 are close enough that the coincidence
was persuasive.

Comparing `shown` against the frames that actually completed - offered fps
times (1 - drop rate) - says what is really happening:

| Mode, offered | Completed/s | Shown | Reading                                       |
| ------------- | ----------- | ----- | --------------------------------------------- |
| Half-res 20   | 16.0        | 18.1  | shown ABOVE completed: the timer adding draws |
| Half-res 45   | 25.8        | 23.6  | about equal                                   |
| Half-res 60   | 35.6        | 23.5  | shown BELOW completed: draws being missed     |
| Full-res 20   | 11.1        | 24.4  | same plateau                                  |

At 60 fps offered, 35.6 frames per second completed and only 23.5 draw
passes happened. Completion is no longer the constraint - the draw is.

And this is the part that bounds what half-res was ever going to buy:
**a half-res frame paints exactly as many pixels as a full-res one.** The
doubling happens before bufA, so the panel pushes all 719 tiles either
way. Paint cost is identical, which is precisely why both codecs plateau
in the same place. Half-res fixed the side it could - datagram demand and
completion probability, both roughly halved - and handed the bottleneck to
the QSPI bus.

That plateau also does not match the model. Section 13.6 predicted 22.2 ms
per masked full frame (45.0 fps) from phase 0's per-call figures; the
measured plateau of ~23.5 fps implies ~42 ms. Something costs ~16 ms a pass
that the per-call model does not account for - candidates, none of them
measured yet: `spinUntilDmaBelow` waiting on the 2-deep queue, the staging
memcpys, info-bar redraws over dirty rows, or the receive task now taking
CPU at the yield points added in section 15.4. Phase 0 measured draw calls
in isolation, with no network traffic and nothing else running; this is the
same category of error as the ~2,850 datagrams/s figure corrected in 15.2,
and it should be measured under load before anything is built on it.

So the next lever for full-frame motion is paint time, not bytes. Nothing
in the protocol can move it.

### 16.6 What is verified and what is not

Verified: the firmware decode path against synthetic codec-3 frames on
real glass (16.4); `pixelDouble` and the rounding rule in the host suite,
including the refusal to trust a half/full dimension pair that disagrees
with `halfDim`, since on the network path that pair decides how far reads
go; the sender's encode, gating, and ladder in the Swift suite - notably
that codec 3 appears under no policy without the flag, and never under
`.losslessOnly`; the wire bytes in the Python suite.

Verified on the glass by eye: half-res frames render correctly, with none
of the horizontal smearing or diagonal skew a wrong stride or a mismatched
half/full dimension pair would produce - which is the one property no
amount of host testing can establish, because both sides could agree on
the same wrong arithmetic.

NOT verified: the ladder's rung-(b) THRESHOLD firing from the real Mac app
against real screen content. The benchmark drives the firmware directly, so
what remains untested is whether `bc1Estimate > budgetBytes` trips at a
sensible moment during genuine motion. The threshold is the first thing to
tune if half-res engages too eagerly or too late.

Still open from 13.5: vertical run merging, boundary-tile RLE flattening
(RLE candidate only), and the untuned `autoVarianceThreshold`.

The 60 fps end-to-end question is now answerable in principle - half-res
makes 60 fps arithmetically deliverable over the wire for the first time -
but 16.5 says it would still land on a paint ceiling, so the next
measurement worth taking is where the time in a draw pass actually goes.

(Taken, in section 17. Two things there supersede this section's guesses:
the plateau is contention, not a fixed paint cost, and the panel actually
delivers LESS as it is offered more - so the ~23.5 fps figure above is a
property of that particular load, not a ceiling. Vertical run merging,
which 16.5 promoted, turns out not to be the fix.)

## 17. The panel is congestion-collapsing (phase 12, 2026-08-13)

Section 16.5 said the next lever was paint time and named four candidates
for the ~16 ms a pass that phase 0's model did not explain. Measuring it
found something bigger than a missing 16 ms: **offering the panel more
work makes it deliver strictly less**, and the "receive ceiling" every
earlier phase has quoted describes a state in which the panel is barely
drawing at all.

### 17.1 The instrumentation

`tiledraw:` on the 5 s serial line, S3 only, decomposing each draw pass
into `spin` (waiting on the DMA queue), `gather` (the strided bufA ->
staging memcpys), `queue` (`draw_bitmap` itself) and `bar` (info-bar
redraw), plus `gateblocked` - iterations that wanted to draw but found
`dmaInFlight` nonzero.

`gateblocked` exists because `draw_bitmap` is asynchronous: it queues DMA
and returns, so the paint is NOT inside the pass. It drains afterward and
blocks the NEXT pass at that gate. A timer placed only inside the block
would never see it.

### 17.2 Per-call cost rises about tenfold under load

Measured with `tile-motion --half`, RSSI -60 to -62 throughout:

| Offered fps | Accepted dgram/s | Calls/pass | gather+queue per call |
| ----------- | ---------------- | ---------- | --------------------- |
| 8           | 176              | 8.7        | **904 us**            |
| 25          | 427              | 26.4       | 2,665 us              |
| 60          | 569              | 25.6       | **8,616 us**          |

At 176 datagrams/s a call costs 904 us, which is phase 0's 875 us figure
essentially exactly - the isolated bench was right about the isolated case.
At flood the same call costs 8,616 us. Nothing about the call changed; the
only variable is how much network traffic the panel is servicing while it
draws.

`spin` stays negligible (19-181 us) and `gateblocked` stays at 0-4, so the
2-deep DMA queue is NOT the constraint. Both halves of the pass inflate:
`gather` 322 -> 4,200 us and `queue` 582 -> 4,400 us.

The mechanism is contention, on both resources at once. `udpReceiveTask`
runs at priority 9 against loop()'s 1, so it preempts the gather; and it
writes decoded tiles into bufA in PSRAM while the gather reads bufA from
PSRAM, so they compete for the same bus. `queue` inflating too fits the
same story - with 26 calls issued back to back the 2-deep queue is always
full, so `draw_bitmap` blocks on DMA that is itself contending for PSRAM.

Phase 0 measured draw calls with no network traffic and nothing else
running. That is the third time in this project a clean-room number has
been generalized past what it supported (the ~2,850 datagrams/s of 15.2,
the 45 fps paint model of 13.6, and now this), and the pattern is worth
naming: **on this board, any figure measured without concurrent load is a
best case that the loaded system does not approach.**

### 17.3 Delivered frames peak and then collapse

Frames actually delivered = offered x (1 - drop rate):

| Offered fps | Accepted dgram/s | Shown fps | Dropped | Delivered/s |
| ----------- | ---------------- | --------- | ------- | ----------- |
| 8           | 176              | 30.8      | 2.4%    | 7.8         |
| 15          | 296              | 33.4      | 6.4%    | 14.0        |
| 25          | 427              | 12.2      | 38.6%   | **15.4**    |
| 35          | 575              | 4.1       | 83.3%   | 5.8         |
| 60          | 569              | 2.3       | 96.3%   | 2.2         |

Delivery peaks around 25 fps offered and falls off a cliff after it: 60 fps
offered delivers 2.2 frames a second, a seventh of what 15 fps offered
delivers. This is textbook congestion collapse, and it means the sender can
make the panel worse by trying harder.

(Both right-hand columns above are approximations, superseded by 17.7. The
`Shown fps` column is the inflated pre-fix counter, and `Delivered/s`
counts frames that COMPLETED rather than frames that reached the glass.
The collapse is unaffected, but the peak moves.)

It also explains a result from section 16.4 that looked perverse. There, at
RSSI **-80**, 60 fps offered dropped 40.7% and showed 23.5 fps. Here, at
RSSI -60, the same offer drops 96.3% and shows 2.3. The better radio is
worse **because** it is better: more datagrams survive the air, so more
reach the receive task, so it steals more time from the draw. The weak link
had been throttling the sender on the panel's behalf.

### 17.4 So the real ceiling is ~300 datagrams/s, not ~1,500

Section 15.2 corrected the receive ceiling to ~1,350-1,500 datagrams/s and
was careful to say the earlier ~2,850 measured rejected packets. It is
still not the number that matters. At 1,350 datagrams/s the panel is
accepting datagrams and NOT drawing - that figure is the socket's capacity,
not the system's.

The rate at which this panel can accept datagrams **and** paint what they
carry is about **300/s** (6.4% loss, 14 fps delivered), degrading through
430/s (38.6% loss) to useless past ~570/s. Every budget in the sender
computed from the old figure is therefore roughly 4x too generous.

Concretely, the degradation ladder's budget is
`1472 * 1e6 / spacingMicros` bytes per second, which at the default 200 us
spacing claims 7.36 MB/s. The panel's usable rate is closer to
300 x 1472 = 0.44 MB/s. Rung (c) can essentially never fire, because the
ladder believes there is 16x more headroom than exists.

### 17.5 Two consequences for work already done

**Vertical run merging is not the fix, and it was the plan.** Section 16.5
promoted it on the reasoning that fewer draw calls beat fewer bytes. That
holds when per-call cost is dominated by fixed overhead - phase 0's ~150 us

- but at load a call costs 8,616 us to move a 15 KB strip, which is
  throughput-bound, not overhead-bound. Merging 26 calls into 13 of double
  size moves identical bytes through the identical contended bus. It should
  be dropped from the roadmap until contention is fixed, at which point its
  case can be re-argued on the ~150 us figure.

**The pacing hill-climb is optimizing a corrupted signal.** It does
`climbFrames += shownDelta` - the delta of the panel's `statFramesShown` -
and since section 15.3 that counter includes partial draws. At 8 fps
offered it reads 30.8 against 7.8 frames actually delivered, inflated
roughly fourfold, because clean low-rate delivery is exactly when the
40 ms partial timer fires most. The climb is steering on a number that is
most wrong where it is most confident.

By luck it is not far off: `shown` peaks at 15 fps offered while delivery
peaks at 25, so the climb settles near 14.0 delivered against a reachable
15.4, about 10% short. That is a small penalty on top of a real problem -
a control loop should not be fed a metric that conflates a drawn frame
with a partial repaint of one.

### 17.6 What to do next, in order

1. **Stop overfeeding.** The cheapest large win available: cap the offered
   datagram rate near what the panel can absorb. Raising default spacing
   from 200 us toward ~2,500 us moves the operating point from the collapse
   region to the peak - measured here as 2.2 -> 14+ frames a second
   delivered. Needs care against the hill-climb, which will try to tighten
   it again for the reason in 17.5.
2. **Separate the counters.** `statFramesShown` should count complete
   frames, with partial draws counted separately, so both the doc and the
   hill-climb stop conflating them. EHB1's five slots are full and EINF
   cannot be extended (device_protocol.h is explicit that appending fields
   makes shipped senders reject every packet), so this wants its own packet
   type on the EBAT precedent.
3. **Then attack contention itself.** Options not yet measured: lowering
   `udpReceiveTask` below loop(), giving the draw its own task at a
   comparable priority, bounding drained datagrams per unit time rather
   than per loop, or getting the gather off PSRAM. Whichever is chosen must
   be measured under load, which is now possible.
4. Only after that: revisit vertical run merging, `autoVarianceThreshold`,
   and boundary-tile RLE flattening.

### 17.7 Complete frames and partial draws, split (and re-measured)

`statFramesShown` now counts COMPLETE frames only. Partial draws get their
own counter, transmitted in EHB1's third u32 - the slot the
never-incremented `statFramesSkipped` occupied, which has always sent zero,
so no real value was displaced and older firmware reads correctly as "no
partial draws".

Re-measured with the split, `tile-motion --half`, RSSI -60 to -62:

| Offered fps | Complete fps | Partial draws/s | Accepted dgram/s | Dropped |
| ----------- | ------------ | --------------- | ---------------- | ------- |
| 8           | 8.0          | 23.6            | 173              | 6.2%    |
| 15          | **14.2**     | 20.2            | 292              | 7.3%    |
| 25          | 8.6          | 2.1             | 448              | 37.8%   |
| 60          | 0.3          | 9.0             | 405              | 99.4%   |

The split checks out against the old counter: 8.0 + 23.6 = 31.6 against the
30.8 measured before, and 14.2 + 20.2 = 34.4 against 33.4. The old number
was the sum, exactly as 17.5 said.

**The peak is 14.2 fps at 15 fps offered**, not 15.4 at 25. Section 17.3's
`Delivered/s` overstated the 25 fps case because it counted COMPLETIONS
while this counts DISPLAYS, and those differ: when several frames complete
between two draw passes, they collapse into one paint. That is not a bug -
you cannot show two frames in one paint - but it means completions are an
upper bound on what the glass ever shows, and the gap widens exactly where
the panel is behind. At 25 fps offered, 15.6 frames a second completed and
8.6 were displayed.

So there are three different rates worth keeping distinct, and this project
has conflated them at least once each: datagrams accepted, frames
completed, and frames displayed. Only the last is what anybody sees.

Partial draws are highest where delivery is cleanest (23.6/s at 8 fps
offered) because slow arrivals give the 40 ms timer the most chances to
fire between frames. That is the mechanism behind the fourfold inflation in
17.5 - the old counter was most wrong precisely where the panel was
healthiest, and the hill-climb was reading it there.

### 17.8 The hill-climb may now fix the overfeeding by itself

17.6 listed "stop overfeeding" first, by raising default spacing. That may
no longer need doing by hand. The climb sums `shownDelta`, which is now
displayed frames, and displayed frames collapse hard past the peak - 14.2
at 15 fps offered against 0.3 at 60. A gradient that steep is exactly what
a hill-climb is for, and it was previously being fed a signal that barely
moved across that range (33.4 down to 2.3, but reading 30-34 across the
whole healthy region).

Untested: whether it actually settles near 15 fps offered from the app
against real content, and how long it takes to get there. That needs a live
run with the app streaming, watching where `spacingMicros` lands - not a
synthetic benchmark, because the benchmark bypasses the sender entirely.
If it does settle there, item 1 of 17.6 is already done and the default
spacing can stay where it is.

### 17.9 Two defects the split exposed, and a measurement hazard

**framesCompleted meant two things.** The draw loop's deferral path - runs
left over when a pass hits `TILE_DRAW_CALL_CAP` - asked for another pass by
incrementing `framesCompleted`, the same variable `applyTileRecord` bumps
when a frame's last tile arrives. Harmless while `statFramesShown` counted
every draw pass; wrong the moment it counted only completions, because the
panel then reported more complete frames than the sender had sent (26.1/s
against 15/s offered). Deferral now sets its own `tileDrainPending` flag
and the gate checks it alongside the partial-draw timer. A drain-only pass
counts as a partial draw, which it is.

**The benchmark and the app fight over the panel.** `tile-motion` numbers
are only meaningful with ESPDisplaySender NOT streaming to the same panel.
Two senders means two independent frame-id sequences arriving interleaved,
so the reassembler abandons a frame nearly every record, and both
`dropped` and `shown` inflate wildly - 506 dropped frames against 120
offered in one run here. Anything reporting more dropped frames than were
sent, or more complete frames than were offered, is this. Check with
`pgrep -fl ESPDisplaySender` before trusting a number, and prefer quitting
the app outright over hoping a static screen keeps it quiet.

This invalidated the first attempt at measuring whether full-width runs
could skip staging, which is redone properly in 17.10.

### 17.10 Staging into SRAM earns its 4.2 ms (measured, quietly)

A full-width run is already contiguous in bufA, so its staging copy
produces a byte-identical rectangle - and that copy is 4.2 ms of an 8.6 ms
call (17.2). Skipping it for those runs looks like free money. It is not.

Both builds, app quit, RSSI -60 to -62:

| Offered fps | Staging: complete | Direct: complete | Staging: lost | Direct: lost |
| ----------- | ----------------- | ---------------- | ------------- | ------------ |
| 8           | 7.9               | 7.1              | 0.8%          | 11.7%        |
| 15          | **13.7**          | **7.1**          | **2.8%**      | **47.5%**    |
| 25          | 4.8               | 8.8              | 22.3%         | 24.4%        |
| 60          | 0.2               | 0.0              | 99.6%         | 100.0%       |

At 15 fps offered - where this board delivers best - dropping the copy
halves delivered frames and multiplies loss seventeenfold. The 25 fps row
reverses, but that staging sample accepted only 181 of 450 offered datagrams
where its 15 fps sample took 269 of 270, so it is a bad sample rather than a
crossover; single runs in the collapse region are not worth much.

The decisive column is neither of the ones above. It is the datagrams the
panel ACCEPTED at 15 fps offered: 269 of 270 with staging, 185 without.
Drawing from PSRAM does not merely cost the draw, it starves the RECEIVE
path of the same bus, so tiles never arrive and frames cannot complete. The
draw and the radio are competing for PSRAM, and staging is what keeps them
apart.

That also sharpens 17.2's reading. `gather` and `queue` both inflating
tenfold under load is not two independent contentions; it is one bus
oversubscribed by three parties - the receive task writing tiles, the gather
reading them, and DMA streaming pixels out. Staging removes the third from
PSRAM entirely, which is why it is worth 4.2 ms.

So contention is confirmed as the mechanism, and the fix is not to remove
work from the draw path but to keep PSRAM traffic off it. Remaining ideas
from 17.6 item 3 in that light: lowering `udpReceiveTask`'s priority does
nothing for bus pressure and is now the least promising; bounding drained
datagrams per unit time is more interesting, because it would leave the
gather uninterrupted windows; and moving bufA itself, or double-buffering
tiles through SRAM on the receive side, attacks the root.

### 17.11 Yielding harder while drawing: UNPROVEN, and how the noise fooled me

17.10 identified PSRAM as the contended resource. The cheapest test of that
reading: have the receive task yield harder while a pass is painting, so the
gather gets quieter windows. Implemented as a `tileDrawActive` flag around
the tile run loop and a 4-datagram drain interval instead of 24 while set -
the 64 KB `SO_RCVBUF` holds ~44 datagrams and a pass moves ~20, so the burst
buffers rather than being lost.

Three runs each at 15 fps offered looked like a clear win:

| Yield interval while drawing | Complete fps     | Mean | Spread |
| ---------------------------- | ---------------- | ---- | ------ |
| 24 (unchanged)               | 13.7, 9.9, 12.4  | 12.0 | 3.8    |
| 4                            | 14.8, 14.1, 14.5 | 14.5 | 0.7    |

+21% on the mean, and the spread apparently collapsing from 3.8 to 0.7 -
which read as the yield keeping the panel out of the loss spiral that
produced the 9.9.

Then a confirmation run on the SAME 4-datagram binary returned 10.4 fps at
23.2% loss. Four more runs of that identical binary: 13.6, 14.7, 14.3, 13.9.

| Series                                    | Values                       | Range   |
| ----------------------------------------- | ---------------------------- | ------- |
| Between builds (what I was measuring)     | 12.0 vs 14.5                 | 2.5     |
| Within ONE binary (what noise alone does) | 10.4, 13.6, 14.7, 14.3, 13.9 | **4.3** |

**The within-binary range exceeds the effect.** The tight 0.7 spread was a
lucky consecutive triple, not a property of the build. The change is
unproven and has been reverted rather than shipped on the strength of a
mechanism that sounds right - which is precisely how the ~2,850 datagrams/s
figure and the 45 fps paint model got into this document.

The methodology error is worth more than the experiment. Both arms were
sampled in BLOCKS - three runs of one build, reflash, three of the other -
so any drift in radio conditions over those minutes is indistinguishable
from a build difference, and RSSI on this link wanders between -59 and -80
across a session. Blocked sampling attributes drift to whatever changed
between the blocks.

So, for any future A/B on this hardware:

- The noise floor at the operating point is about **4 fps peak-to-peak**.
  An effect smaller than that cannot be resolved by a handful of runs.
- Interleave the arms rather than blocking them, which needs the parameter
  runtime-settable (a `CFG` command) instead of compiled in - a reflash per
  swap makes interleaving cost ~2 minutes a sample and so guarantees blocked
  sampling.
- Report the within-arm spread alongside any claimed difference. A mean
  without a spread is not a measurement.

The 17.2 numbers still stand as the size of the prize - a gather costing
322 us idle and 4,200 us loaded - and 17.10 still stands as evidence that
the bus is what is contended, because its effect (13.7 against 7.1, 269
accepted against 185) is far outside this noise floor. What is not
established is that finer CPU interleaving recovers any of it. Attacking the
root instead - bufA off PSRAM, or tiles staged through SRAM on the receive
side - would produce an effect large enough to measure with the sampling
discipline this project actually has.

### 17.12 The sender could not leave the collapse region

17.8 hoped the hill-climb would fix the overfeeding by itself once it was
reading displayed frames instead of draw passes. It cannot, and the reason
is a bound rather than a signal.

`FrameSender.spacingBounds(for:)` caps how loosely the climb may pace, by
keeping `minWorstCaseFps * bandCount` datagrams a second flowing - the fix
for an older bug where a fixed 2500 us ceiling parked the 466-band panel at
~1 fps. On this panel that gives:

```plain
ceiling = 1_000_000 / (5 fps x 466 bands) = 429 us = 2331 datagrams/s
```

The panel absorbs ~300 datagrams/s while painting (17.3). So the climb's
loosest permitted pacing offers **almost eight times what the panel can
use**, and the app log confirms it was pinned there: `pacing=429us`, having
backed off as far as allowed and still wanting more. Whatever the climb
measured, it was structurally unable to leave the collapse region.

The bound is not wrong, it is aimed at the band protocol. It assumes one
datagram per band - ~466 for a keyframe here - where a tile keyframe is 18
(half-res) to 66 (BC1). And at this scale its premise fails outright: a
large keyframe CANNOT reach 5 fps at the absorbable rate, so pacing tighter
does not deliver it sooner, it delivers it into the queue that drops it.

So tile panels get a ceiling derived from the measured absorbable rate
instead - `tileAbsorbablePacketsPerSecond = 300`, i.e. 3333 us - applied as
`max(bandCeiling, tileCeiling)` so it only ever widens the range, and only
when the panel actually advertised `tileStream`. `spacingRange`'s upper
bound moves 2500 -> 4000 so the value is expressible at all; the settings
slider and `setSpacingMicros` clamp to that same range, and would otherwise
have clamped the controller's own ceiling away.

Convergence is not instant. Loosening is multiplicative: ~12 probe windows
at x1.18 to walk 429 -> 3333, roughly 37 s, or ~6 steps at the x1.4 rate the
drop-ratio branch uses when a window loses more than half its frames. Fast
enough to matter, slow enough that a brief burst of motion will not swing it.

Unverified: whether the climb actually settles near the 15 fps-offered peak
from the app against real content. The unit tests pin the arithmetic - that
the band ceiling is 429 us and demonstrably the problem, that the tile
ceiling expresses 300/s exactly, that band panels are untouched - but
convergence is runtime behaviour and needs the app streaming with the log
watched for where `pacing=` lands. The installed app also needs rebuilding
to carry this; the source change alone does not reach it.

### 17.13 Live verification, and the ladder finally gets tests

The app rebuilt with 17.12's ceiling (`mac/make-app.sh`), run against the
panel on ordinary desktop content:

| Measure        | Result                                               |
| -------------- | ---------------------------------------------------- |
| Delivered      | 56.5-57.4 fps, sustained over minutes                |
| Device `shown` | advancing ~57/s - the panel is DISPLAYING them       |
| `dropped`      | ~1.7/s, about 3%                                     |
| Pacing         | oscillates 150-340 us                                |
| Send path      | diff 0.04 ms, encode 0.08 ms, send 0.10 ms per frame |

The climb stays TIGHT and never approaches the new 3333 us ceiling, which is
correct rather than disappointing: at 1.4 packets a frame and 57 fps the
sender offers ~97 datagrams/s, a third of what the panel absorbs, so there is
no congestion to retreat from and tight pacing buys lower latency. The wider
ceiling is there for heavy motion, and heavy motion is what still needs a live
test. What this run does establish is that the change is inert when it should
be - no regression on the common case.

**57 fps displayed is itself the news.** Section 14.6 recorded ~20-24 fps and
attributed the ceiling to ScreenCaptureKit's change-driven delivery, i.e. to
content rather than engineering. That was measured before the fps default rose
to 60 and before the send path was fixed; with both, the same class of content
displays at 57. The three limits 14.6 listed were real, but the one it called
immovable had a configuration in front of it.

#### The ladder, extracted and tested

`FrameSender.degradationRungs(dirtyTiles:spacingMicros:policy:halfResAvailable:)`
is now a pure static function, lifted out of `sendTileFrame`. It shipped in
phase 5, gained rung (b) in phase 11, and had never had a test either time -
its behaviour was only ever inferred from hardware frame rates. Eight tests
now pin the engagement points, and writing them corrected two things I
believed:

**The rungs are relative to pacing, not to dirty area.** A full frame of all
719 visible tiles at 400 us pacing engages rung (a) and stops there: the
budget is ~123 KB and 719 BC1 tiles are 92 KB, so full resolution fits.
Half-res engages only once the climb has backed off toward the absorbable
rate, where the budget is ~14.7 KB. "Most of the screen changed" is not what
triggers resolution loss; "most of the screen changed AND we are pacing
slowly" is.

**Thresholds are ~4x apart, not exactly 4x.** Each codec is a quarter of the
one above, but the budget is not a multiple of every per-tile size, so integer
division leaves a few tiles of slack (7,666 against 7,664 at 200 us). The test
asserts the ratio and bounds the slack rather than claiming equality.

One consistency check fell out of it. At the absorbable-rate ceiling a
full-motion frame engages every rung including frame skipping, which halves
the ladder's 30 fps target to 15 - and section 17.7 measured the displayed
peak at 14.2. The sender's arithmetic and the panel's behaviour agree, having
been derived independently and never fitted to each other.
