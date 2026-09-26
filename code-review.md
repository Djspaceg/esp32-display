# Independent adversarial review: C3 round-panel support

This is an independent review of branch `add-c3-2424s012-board` at
`b5c95d5`. It replaces the previous `code-review.md`, a reconciliation review
record written by the change-authoring session. That record did not satisfy the
need for an independent review of the final branch tip.

## Verdict

No open findings. (One Medium descriptor finding was withdrawn; see below.) I found no serious defect in the
C3 compact-framebuffer mapping after auditing its allocation, all direct buffer
accesses, boundary rows, packet ordering, and compile-time isolation.

## Findings

### Medium: the descriptor disables the physical BOOT button

**WITHDRAWN.** The board owner confirmed that this board has no physical buttons, so
`pin_boot = -1` is correct. The pin map this finding relied on describes the board
family, not this board. A fix that set GPIO9 (ad7729f, 5e1935f) was reverted before
it reached any board or main. Declaring a button pin on a board with no button makes
the firmware watch an unconnected strapping pin, which can read phantom presses.

**Location:** `boards/c3-2424s012.toml:86`

The 2424S012 board's published pin mappings place its BOOT button on GPIO9, but
the descriptor sets `pin_boot = -1`. The generated `Config` consequently also
contains `pinBootButton = -1` at
`firmware/libraries/espdisp_board/src/generated_board_configs.h:71`.

After normal boot, pressing the physical BOOT button therefore produces no
firmware action: `initializeButtonInput()` returns before configuring GPIO9 or
attaching its interrupt when `hasBootButton()` is false
(`firmware/display_stream/input_button.cpp:102-112`). This removes the board's
short-press brightness control, long-press rotation, and extra-long manual
display-off control. The C3-specific survey restriction does not justify
omitting the button; the same handler still supports the other three actions.

**Confidence:** High that GPIO9 is the declared button pin; High that this
descriptor makes all post-boot button features unreachable.

## Compact framebuffer review

### Storage geometry and circle edge arithmetic

I independently reimplemented the row-span math used by
`configureC3CircleStorage()` (`firmware/display_stream/frame_pipeline.cpp:53-75`).
It produces exactly 45,244 pixels and 90,488 bytes, with monotonically
contiguous row offsets. The narrowest rows are both edge rows, `y=0` and
`y=239`, each covering `x=109..130` inclusive (22 pixels). Every row has a
non-empty, in-range span; the maximum span is 240 pixels.

I then simulated all 120 two-row bands arriving in reverse order with each
square source pixel encoded by its original coordinate. Every retained circle
pixel landed at its matching compact offset. The source and destination ranges
used by `storeC3Band()` are bounded by the 240-pixel wire row and the
precomputed row offset respectively
(`firmware/display_stream/frame_pipeline.cpp:77-83`).

Pixels addressed by the sender outside the circle are intentionally dropped:
the copy begins at `c3RowStart[y]` and has exactly `c3RowPixels[y]` pixels. No
off-circle wire coordinate is converted into a compact-buffer destination.

### Packet validation, partial frames, and ordering

`applyBandPayload()` validates the band index and exact raw payload length
before classifying or copying a packet
(`firmware/display_stream/frame_pipeline.cpp:226-237`). The reassembler rejects
invalid geometry, stale packets, and duplicates before the C3 scratch buffer is
written (`:239-255`). For an accepted C3 packet, raw and RLE payloads both first
produce an exact-band scratch image, then `storeC3Band()` selects only visible
spans (`:269-280`).

Out-of-order bands are accepted by the shared reassembler. An incomplete frame
superseded by a newer one increments the dropped-frame statistic while retaining
already accepted dirty rows for the next completed draw, matching the established
band-path behavior (`:239-245`, `:292-300`). A frame that never completes is
not drawn prematurely on C3; that is the same completion policy as the existing
band protocol, not the S3 tile partial-draw policy.

### Draw and status paths

The C3 fill path emits one visible row at a time into the 480-byte DMA staging
buffer and stops on a DMA timeout, so that buffer cannot be reused while its
transfer remains in flight
(`firmware/display_stream/frame_pipeline.cpp:715-733`).

The streamed draw path likewise copies one compact row into that staging buffer,
draws only its visible span, and requeues the band then stops if completion
times out (`:912-938`). It does not use `FRAME_BYTES`, `y * 240 + x`, or a
240-pixel stride to index `bufA`.

I enumerated every remaining direct `bufA` or `bufB` access that assumes a full
rectangle:

| Call site | C3 result |
| --- | --- |
| `display_stream.ino:370-383` | Allocates 90,488-byte compact `bufA`, 480-byte row-staging `bufB`, and clears only compact `bufA`. |
| `frame_pipeline.cpp:47-101, 269-280, 715-733, 912-938` | The only C3 buffer read/write path; all use row spans and offsets. |
| `ui_screens.cpp:74-187` | Idle card returns at compile time on C3 before full-frame copy/draw. |
| `ui_screens.cpp:278-383, 516-577` | Wi-Fi selector and survey return at compile time on C3. Their entry points also reject C3. |
| `ui_screens.cpp:616-708, 719-799` | Info bar and OTA screens return at compile time on C3 before rectangular accesses. |
| `tile_bench.cpp:16-244` | Entire benchmark is compiled only for ESP32-S3. |
| `frame_pipeline.cpp:281-290, 939-968` | Existing square-buffer writes and coalesced band draws are in the non-C3 branch. |

The compact layout is gated by `CONFIG_IDF_TARGET_ESP32C3`; C6, S3, and P4
retain `FRAME_BYTES` allocation and their existing rectangular paths
(`firmware/display_stream/frame_pipeline.cpp:87-100, 269-291, 912-969`).

## Other review checks

### Host serial partial writes

The new writer advances by the actual return count, retains the unsent tail,
and rejects zero or negative progress
(`tools/espdisp.py:940-962`). Repeated `BlockingIOError` events are bounded by
the deadline (`:952-957`), so the new loop has a timeout rather than an
unbounded retry. I independently exercised repeated short writes and a
zero-progress write: the former preserved the complete payload and the latter
raised `Fail`. The repository regression test covers the partial-write sequence
at `tools/test_espdisp.py:6471-6486`.

### Descriptor and generated configuration

The descriptor schema admits `c3` as a target (`boards/schema-v1.json:66`), its
GPIO validator limits C3 values to 0 through 21
(`tools/board_descriptor.py:204`), and the generated C3 config correctly
carries the declared panel pins 6/7/10/2/3 and CST816 pins 4/5/1/0. The missing
GPIO9 BOOT assignment above is the exception found in this cross-check.

### Audio merge

I compared the merge commit with both parents. The audio implementation and its
host tests remain present from main; the final branch's delta from main changes
only C3 integration and generated/catalog artifacts around that area, rather
than deleting audio source or test files. The C3 descriptor explicitly carries
no audio hardware, and the generated audio table preserves that distinction.
No audio feature drop was found.

## Deliberately not re-run

Per the review brief, I did not re-run the eight already-verified gate lanes,
regenerate release bundles, flash or connect to a board, access a serial port,
or build/install/launch the macOS app. I also did not claim those prior checks
as independent review evidence.
