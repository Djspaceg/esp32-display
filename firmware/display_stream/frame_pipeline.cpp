#include "frame_pipeline.h"

#include <Arduino.h>

#include "esp_heap_caps.h"
#include "esp_lcd_panel_ops.h"

#include "app_state.h"
#include "band_compress.h"
#include "band_protocol.h"
#include "bc1.h"
#include "display_power.h"
#include "dma_gate.h"
#include "orientation.h"
#include "panel_state.h"
#include "tile_protocol.h"
#include "ui_screens.h"

using namespace bandproto;


// ---- Buffers -----------------------------------------------------------
// bufA: persistent assembled frame, written by the UDP callback per band.
// bufB: DMA staging - dirty strips are memcpy'd here before queueing, so
//       SPI DMA never reads memory the network path is writing.
//
// Where they live is a per-chip fact. The C6's 110KB frames fit internal
// DMA-capable SRAM (and the C6 has no PSRAM anyway). A 466x466 frame is
// 434KB - two of them cannot fit the S3's 512KB SRAM, so they go to the
// stacked PSRAM, which the S3's GDMA can read. UNVERIFIED on hardware:
// sustained QSPI-from-PSRAM throughput and any alignment constraints need
// measuring on a real 1.75C before this is trusted.
#if defined(CONFIG_IDF_TARGET_ESP32S3)
const uint32_t FRAME_BUF_CAPS = MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT;
#else
const uint32_t FRAME_BUF_CAPS = MALLOC_CAP_DMA;
#endif
uint8_t *bufA = nullptr;
uint8_t *bufB = nullptr;

// Constructed from the board table rather than PANEL_GEOMETRY: this is
// namespace-scope dynamic initialization, and PANEL_GEOMETRY lives in
// another translation unit whose initialization order is unspecified.
// compiledPanelGeometry() reads only the constant-initialized table, so
// it is safe at any point of static initialization. Same value.
static Reassembler reassembler(compiledPanelGeometry());  // tested logic: band_protocol.h
bool bufLandscape = false;                // orientation of bufA's content

// Bands applied to bufA but not yet drawn. Accumulates across frames so
// bands from an abandoned partial frame still reach the panel with the next
// completed frame. Guarded by drawMux (UDP callback runs in the lwIP task).
static uint8_t pendingDrawBitmap[BITMAP_BYTES];
static portMUX_TYPE drawMux = portMUX_INITIALIZER_UNLOCKED;
static volatile uint32_t framesCompleted = 0;    // completion signal: UDP -> loop
static volatile bool pendingLandscape = false;   // orientation for the pending draw

#if defined(CONFIG_IDF_TARGET_ESP32S3)
// ---- Tile stream (CAP_TILE_STREAM, tile_protocol.h) ----------------------
// The band protocol's successor on this board: a 30x30 grid of 16x16 tiles,
// only dirty runs travel, each raw / RLE565 / BC1. S3-compile-gated AND
// variant-gated at runtime (tileStreamEnabled()) - the C6 binary carries
// none of this. Bit 15 of the header's third/fourth bytes means TILE packet
// on this board and PACKED BAND packet everywhere else; the two layouts are
// byte-ambiguous past the flag, which is why the board advertises exactly
// one of CAP_TILE_STREAM / CAP_COMPRESSED_BANDS, never both - see
// deviceCapabilities().
// Board-table derivation for the same initialization-order reason as
// `reassembler` above.
static const tileproto::TileGeometry TILE_GEOMETRY = {
    compiledPanelGeometry().width, compiledPanelGeometry().height};
// Decode scratch for the UDP receive task: records decode here (internal
// SRAM - the codecs' inner loops must not run against PSRAM), then rows are
// strided-copied into bufA. Never touched by the draw path.
static uint8_t tileScratch[TILE_RUN_MAX_BYTES] __attribute__((aligned(4)));
// Second decode scratch, for TileCodec::HalfBc1 only: the half-resolution
// raster lands here and is pixel-doubled into tileScratch above. A quarter
// of TILE_RUN_MAX_BYTES by construction (both axes halved).
//
// A separate buffer rather than expanding in place inside tileScratch. The
// in-place version is possible - walk rows back to front, right to left -
// but its non-overlap argument is subtle, and this runs on the network path
// where being wrong is a remote write past a buffer. 3.8 KB of internal SRAM
// buys an obviously correct loop.
static const size_t TILE_HALF_MAX_BYTES = (size_t)240 * 8 * 2;
static uint8_t tileHalfScratch[TILE_HALF_MAX_BYTES] __attribute__((aligned(4)));
// DMA staging for the draw path, double-buffered: the next run's rows are
// gathered into one buffer while the previous run's transfer drains from
// the other. Internal SRAM instead of the band path's full-frame PSRAM
// bufB: phase 0 measured 340+ MB/s strided SRAM<->PSRAM against 22.3 MB/s
// PSRAM->PSRAM (docs/tile-stream-plan.md section 11), and it keeps DMA
// reads off PSRAM entirely.
uint8_t tileStaging[2][TILE_RUN_MAX_BYTES] __attribute__((aligned(4)));
static tileproto::Reassembler tileReassembler(TILE_GEOMETRY);
// Tiles applied to bufA but not yet drawn. Accumulates across frames like
// pendingDrawBitmap does (per-tile recency); guarded by drawMux.
static uint8_t pendingTileBitmap[tileproto::TILE_BITMAP_BYTES];
// Draw calls per loop iteration. Bounds a pathological checkerboard frame
// (up to 450 runs) so touch/serial/watchdog servicing cannot starve: 32
// calls is ~5-29 ms of panel time at the measured 150-900 us per call. The
// remainder is re-marked pending and finished next iteration.
// A variable, not a constant, so CFGTUNE can move it at runtime - see
// tuneRxDrainYieldEvery for why that matters for measurement.
int tuneDrawCallCap = 32;
// How long pending tiles may wait for their frame to complete before being
// drawn anyway. See the tilePartialDue block in loop() for why this exists:
// a full-panel update is ~66 datagrams, so a fraction of a percent of
// datagram loss stops a third of frames from ever completing, and the tiles
// are already in bufA by then. 40 ms is a frame at 25 fps - long enough that
// a merely-late frame still draws whole, short enough that a lossy stream
// keeps moving rather than freezing.
// Also CFGTUNE-settable, for the same measurement reason.
uint32_t tunePartialDrawMs = 40;
// Runs left unpainted because a pass hit tuneDrawCallCap, so another pass is
// owed. Its own flag rather than a bump of framesCompleted, which is what the
// deferral used to do: that made framesCompleted mean either "a frame's last
// tile arrived" or "come back for the rest", and once statFramesShown counted
// only true completions the overload started reporting more complete frames
// than the sender had sent (26.1/s against 15/s offered).
static volatile bool tileDrainPending = false;

// Draw-pass cost breakdown, reset every 5 s report (see the tiledraw= line in
// loop()). Section 16.5 measured ~42 ms per pass against phase 0's ~22 ms
// model and could not say where the difference went; phase 0 timed draw calls
// in isolation, with no network traffic and nothing else running, which is the
// same mistake that produced the ~2850 datagrams/s figure corrected in 15.2.
// So this measures the real pass, under load, decomposed.
//
// Written only by loop(); read by loop()'s reporter. Not volatile and not
// mutexed - the receive task never touches them.
static uint32_t tdPasses = 0;       // draw passes actually taken
static uint32_t tdCalls = 0;        // draw_bitmap calls issued
static uint32_t tdSpinUs = 0;       // spinUntilDmaBelow, waiting on the queue
static uint32_t tdGatherUs = 0;     // strided bufA -> staging memcpys
static uint32_t tdQueueUs = 0;      // draw_bitmap itself (queues, returns)
static uint32_t tdBarUs = 0;        // info-bar redraw over dirty rows
static uint32_t tdPassUs = 0;       // whole pass, wall clock
static uint32_t tdGateBlocked = 0;  // passes refused because DMA was busy
#endif

// Apply one band's payload to bufA and run the reassembly bookkeeping. The
// shared body of both packet layouts: the classic one-raw-band packet and
// each record of a packed packet. `countPacket` keeps the classic path's
// stats semantics (duplicates count in packets=); the packed path counts its
// datagram once, in its caller.
//
// A compressed payload is decoded straight into bufA at the band offset -
// this is the network receive path, so there is no scratch copy. rle565::
// decode is bounds-checked against exactly this band's length: whatever a
// datagram claims, nothing is written outside the band (see band_compress.h;
// a fault there would be a remote-triggered overflow). The decode runs after
// the reassembler classifies the chunk, so a stale or duplicate band never
// touches bufA; the cost is that a payload that then fails to decode leaves
// its band marked seen over the previous frame's rows - a torn band on a
// forged packet, healed by the next keyframe, and never memory-unsafe.
bool applyBandPayload(const bandproto::Header &h, bool compressed,
                             const uint8_t *payload, size_t payloadLen,
                             bool countPacket) {
  if (h.bandIndex >= PANEL_GEOMETRY.bandCount(h.landscape)) {
    return false;  // geometry mismatch - sender misconfigured
  }
  const size_t rawLen =
      PANEL_GEOMETRY.bandPayloadBytes(h.bandIndex, h.landscape);
  if (!compressed && payloadLen != rawLen) {
    statBadLen = statBadLen + 1;
    return false;
  }

  bool droppedFrame = false;
  ChunkAction action = reassembler.onChunk(h, droppedFrame);
  if (droppedFrame) {
    // Incomplete frame abandoned - but its bands are already applied to
    // bufA and marked in pendingDrawBitmap, so they still reach the panel
    // with the next completed frame (per-band recency).
    statFramesDropped = statFramesDropped + 1;
  }
  if (action == ChunkAction::Reject) {
    return false;  // geometry mismatch - sender misconfigured
  }
  if (countPacket) {
    statPackets = statPackets + 1;
  }
  if (action == ChunkAction::IgnoreStale || action == ChunkAction::Duplicate) {
    return true;
  }

  // A landscape/portrait change invalidates everything in bufA (band geometry
  // and pixel layout both change), so stale pending bands are dropped and the
  // keyframe the sender guarantees on an orientation change rebuilds it. Not to
  // be confused with the user's mounting rotation, which leaves bufA valid and
  // is repainted locally in loop() - see the madctlDirty block there.
  if (h.landscape != bufLandscape) {
    portENTER_CRITICAL(&drawMux);
    memset(pendingDrawBitmap, 0, sizeof(pendingDrawBitmap));
    portEXIT_CRITICAL(&drawMux);
    bufLandscape = h.landscape;
  }

  uint8_t *dst = bufA + PANEL_GEOMETRY.bandOffset(h.bandIndex, h.landscape);
  if (compressed) {
    if (!rle565::decode(payload, payloadLen, dst, rawLen)) {
      statBadLen = statBadLen + 1;
      return false;
    }
  } else {
    memcpy(dst, payload, rawLen);
  }
  portENTER_CRITICAL(&drawMux);
  pendingDrawBitmap[h.bandIndex >> 3] |= 1 << (h.bandIndex & 7);
  portEXIT_CRITICAL(&drawMux);

  if (action == ChunkAction::ApplyComplete) {
    pendingLandscape = h.landscape;
    framesCompleted = framesCompleted + 1;  // loop draws the pending bands
  }
  return true;
}

#if defined(CONFIG_IDF_TARGET_ESP32S3)
// Apply one tile record to bufA and run the reassembly bookkeeping - the
// tile path's applyBandPayload. Same ordering rules: cheap shape checks,
// then the reassembler classifies (stale/duplicate never touch bufA), then
// decode. Decode goes into internal-SRAM tileScratch first because a run's
// rows are NOT contiguous in the row-major frame buffer the way a band's
// are - the strided copy below is the price of tiles, paid at the measured
// 340+ MB/s, not the feared PSRAM-to-PSRAM rate.
//
// Both decoders are bounds-checked against exactly this run's raster
// (rle565::decode refuses anything but an exact fill; bc1::decode refuses
// any input length but encodedBytes(w,h) and clips edge blocks), so
// whatever a datagram claims, nothing is written outside tileScratch. A
// payload that fails decode after the reassembler counted its tiles leaves
// them marked seen over the previous frame's pixels - a torn run on a
// forged packet, healed by the next keyframe, never memory-unsafe: the
// same accepted posture as the band path.
static bool applyTileRecord(const tileproto::TileHeader &h,
                            uint16_t startTile, uint16_t runLen,
                            bool visibleSpans, tileproto::TileCodec codec,
                            const uint8_t *payload, size_t payloadLen) {
  const size_t rawLen = TILE_GEOMETRY.runRawBytes(startTile, runLen);
  if (rawLen == 0 || rawLen > TILE_RUN_MAX_BYTES) {
    return false;  // inexpressible run; onRecord would reject it too
  }
  const uint16_t runW = TILE_GEOMETRY.runPixelWidth(startTile, runLen);
  const uint16_t runH = TILE_GEOMETRY.rowHeight(TILE_GEOMETRY.row(startTile));
  tileproto::VisibleSpanPlan spanPlan = {0, 0};
  if (visibleSpans) {
    if ((codec != tileproto::TileCodec::Raw &&
         codec != tileproto::TileCodec::Rle565) ||
        !tileproto::parseVisibleSpanPlan(payload, payloadLen, runW, runH,
                                         spanPlan) ||
        spanPlan.rawBytes > TILE_RUN_MAX_BYTES ||
        (codec == tileproto::TileCodec::Raw &&
         payloadLen != spanPlan.descriptorBytes + spanPlan.rawBytes)) {
      statBadLen = statBadLen + 1;
      return false;
    }
  } else if (codec == tileproto::TileCodec::Raw && payloadLen != rawLen) {
    statBadLen = statBadLen + 1;
    return false;
  }

  bool droppedFrame = false;
  tileproto::RecordAction action =
      tileReassembler.onRecord(h, startTile, runLen, droppedFrame);
  if (droppedFrame) {
    // Incomplete frame abandoned - its tiles are already in bufA and marked
    // pending, so they still reach the panel with the next completed frame.
    statFramesDropped = statFramesDropped + 1;
  }
  if (action == tileproto::RecordAction::Reject) {
    return false;  // grid mismatch - sender misconfigured
  }
  if (action == tileproto::RecordAction::IgnoreStale ||
      action == tileproto::RecordAction::Duplicate) {
    return true;
  }

  // Orientation bookkeeping, mirroring the band path. On this square glass
  // the grid is identical both ways, but the sender's keyframe-on-change
  // contract and the pending-set flush must behave the same.
  if (h.landscape != bufLandscape) {
    portENTER_CRITICAL(&drawMux);
    memset(pendingTileBitmap, 0, sizeof(pendingTileBitmap));
    memset(pendingDrawBitmap, 0, sizeof(pendingDrawBitmap));
    portEXIT_CRITICAL(&drawMux);
    bufLandscape = h.landscape;
  }

  const uint8_t *encoded = payload;
  size_t encodedLen = payloadLen;
  size_t decodedLen = rawLen;
  if (visibleSpans) {
    encoded += spanPlan.descriptorBytes;
    encodedLen -= spanPlan.descriptorBytes;
    decodedLen = spanPlan.rawBytes;
  }
  switch (codec) {
    case tileproto::TileCodec::Raw:
      memcpy(tileScratch, encoded, decodedLen);
      break;
    case tileproto::TileCodec::Rle565:
      if (!rle565::decode(encoded, encodedLen, tileScratch, decodedLen)) {
        statBadLen = statBadLen + 1;
        return false;
      }
      break;
    case tileproto::TileCodec::Bc1:
      if (!bc1::decode(encoded, encodedLen, tileScratch, runW, runH)) {
        statBadLen = statBadLen + 1;
        return false;
      }
      break;
    case tileproto::TileCodec::HalfBc1: {
      // Half-res: BC1 at half the run's dimensions, then pixel-doubled up to
      // the run's true raster so everything downstream - the strided copy
      // below, the draw path, bufA itself - stays unaware this tile ever
      // travelled small. Ordered so nothing decodes until the destination is
      // known to fit: bc1::decode then rejects any payloadLen that is not
      // exactly encodedBytes(halfW, halfH), and pixelDouble re-derives the
      // half dimensions itself rather than trusting the pair passed in.
      const uint16_t halfW = tileproto::halfDim(runW);
      const uint16_t halfH = tileproto::halfDim(runH);
      if ((size_t)halfW * halfH * 2 > sizeof(tileHalfScratch) ||
          !bc1::decode(encoded, encodedLen, tileHalfScratch, halfW, halfH) ||
          !tileproto::pixelDouble(tileHalfScratch, halfW, halfH, tileScratch,
                                  runW, runH)) {
        statBadLen = statBadLen + 1;
        return false;
      }
      break;
    }
    default:
      // Unreachable: the codec came from a 2-bit field and all four values
      // are handled. Kept so adding a fifth cannot silently fall through.
      return false;
  }

  // Strided copy into the row-major frame: the run's rows sit at the frame
  // width's stride. Square panel, so the stride is PANEL_W both ways.
  const size_t frameRowBytes =
      (size_t)PANEL_GEOMETRY.frameWidth(h.landscape) * 2;
  const size_t x0 =
      (size_t)TILE_GEOMETRY.col(startTile) * tileproto::TILE_DIM;
  const size_t y0 =
      (size_t)TILE_GEOMETRY.row(startTile) * tileproto::TILE_DIM;
  if (visibleSpans) {
    size_t compactOffset = 0;
    for (uint16_t r = 0; r < runH; r++) {
      const uint16_t offset = tileproto::visibleSpanOffset(payload, r);
      const uint16_t count = tileproto::visibleSpanCount(payload, r);
      const size_t bytes = (size_t)count * 2;
      if (bytes > 0) {
        memcpy(bufA + (y0 + r) * frameRowBytes + (x0 + offset) * 2,
               tileScratch + compactOffset, bytes);
      }
      compactOffset += bytes;
    }
  } else {
    for (uint16_t r = 0; r < runH; r++) {
      memcpy(bufA + (y0 + r) * frameRowBytes + x0 * 2,
             tileScratch + (size_t)r * runW * 2, (size_t)runW * 2);
    }
  }

  portENTER_CRITICAL(&drawMux);
  for (uint16_t t = startTile; t < (uint16_t)(startTile + runLen); t++) {
    pendingTileBitmap[t >> 3] |= (uint8_t)(1 << (t & 7));
  }
  portEXIT_CRITICAL(&drawMux);

  if (action == tileproto::RecordAction::ApplyComplete) {
    pendingLandscape = h.landscape;
    framesCompleted = framesCompleted + 1;  // loop draws the pending tiles
  }
  return true;
}

// One tile-stream datagram (bit 15 set, on a board where that means tiles).
// The walker validates each record's framing before applyTileRecord sees
// it; the header's first_tile must name the first record's start tile, the
// same cross-check the packed band path runs.
void handleTilePacket(const uint8_t *data, size_t len) {
  tileproto::TileHeader h = tileproto::parseHeader(data);
  if (!h.streamFlagSet || h.reservedBitsSet) {
    statBadLen = statBadLen + 1;
    return;
  }
  bool first = true;
  bool ok = tileproto::forEachRecord(
      data + tileproto::HEADER_BYTES, len - tileproto::HEADER_BYTES,
      [&](uint16_t startTile, uint16_t runLen, bool visibleSpans,
          tileproto::TileCodec codec, const uint8_t *payload,
          size_t payloadLen) {
        if (first) {
          if (startTile != h.firstTile) return false;
          first = false;
        }
        return applyTileRecord(h, startTile, runLen, visibleSpans, codec,
                               payload, payloadLen);
      });
  if (!ok) {
    statBadLen = statBadLen + 1;
    return;
  }
  statPackets = statPackets + 1;  // one datagram, one count, like packing
}
#endif

// Fill the whole panel with one RGB565 color (used for status feedback).
// Draws from staging (bufB) - bufA belongs to the network path.
void fillPanel(uint16_t rgb565) {
  uint8_t hi = rgb565 >> 8, lo = rgb565 & 0xFF;
  for (size_t i = 0; i < FRAME_BYTES; i += 2) {
    bufB[i] = hi;
    bufB[i + 1] = lo;
  }
  dmaMarkQueued();  // its completion fires onColorTransDone
  if (esp_lcd_panel_draw_bitmap(panel, 0, 0, PANEL_W, PANEL_H, bufB) != ESP_OK) {
    dmaUnmarkFailed();
  }
  delay(30);  // let DMA finish before bufB is reused
}
// Reapply a pending user/motion rotation and repaint the whole screen from
// what is already cached. Body and reasoning moved verbatim from loop().
void serviceRotationRepaint() {
  // Reapply a pending rotation now, and repaint the whole screen from what is
  // already cached instead of waiting for a frame to arrive.
  //
  // A rotation changes MADCTL, which makes the panel re-address the pixels
  // already in its memory in the new direction. Every pixel on screen is
  // therefore wrong the moment it takes effect - including the parts no
  // incoming band will touch. Reapplying only on the next completed frame and
  // then redrawing just that frame's dirty bands left the image healing a band
  // at a time, and left a static screen upside-down until the sender's 5s full
  // refresh.
  //
  // This is fixable locally because a user rotation leaves bufA valid: a 180
  // changes only the scan direction, and a quarter turn is only reachable on
  // square glass, where the band geometry is orientation-symmetric - either
  // way the bands in bufA still tile the frame and the new MADCTL re-addresses
  // them. A landscape change is not, so one still mid-flight here
  // (bufLandscape not yet agreeing with the completed frame) only reapplies
  // the config and leaves the repaint to the keyframe the sender guarantees.
  //
  // The Mac-commanded rotation never had this problem because
  // DeviceSession.setFlip/setRotation force a keyframe. A BOOT-button turn is
  // invisible to the sender, so nothing asked for one.
  if (madctlDirty && dmaInFlight == 0) {
    bool orientationSettled = (bufLandscape == pendingLandscape);
    applyPanelConfig(bufLandscape);
    const char *repainted;
    if (surveyActive) {
      // The survey card must turn with the glass like everything else.
      // MADCTL only affects writes, so the pixels already on the panel keep
      // their old orientation until redrawn - redraw now rather than leaving
      // it to the 500 ms tick, which reads as the meter lagging the picture.
      drawSurveyScreen();
      repainted = "survey card";
    } else if (idleActive) {
      drawIdleScreen();  // composes the card over bufA and pushes all of it
      repainted = "status card";
    } else if (orientationSettled && statFramesShown != 0) {
      // Mark every band and hand it to the existing draw path rather than
      // duplicating the staging and DMA logic. Bits past bandCount are ignored:
      // forEachRun bounds its walk by the count it is given.
      portENTER_CRITICAL(&drawMux);
      memset(pendingDrawBitmap, 0xFF, sizeof(pendingDrawBitmap));
      portEXIT_CRITICAL(&drawMux);
      framesCompleted = framesCompleted + 1;  // drawn below, same iteration
      repainted = "cached frame";
    } else {
      // Either a landscape change is mid-flight (the sender's keyframe repaints
      // it), or nothing but a boot fill has ever been on screen - and a uniform
      // fill looks the same either way up, so there is nothing to correct.
      repainted = "nothing to repaint";
    }
    Serial.printf("rotation manual=%u auto=%u effective=%u applied (%s)\n",
                  panelRotation, automaticRotation, appliedPanelRotation,
                  repainted);
  }
}

// The streaming draw pass, called once per loop() iteration. Owns the
// pending-band/tile snapshot, the DMA gate, and the delay(1) idle pacing
// (the else branch) exactly as loop() did before the split.
void serviceStreamDraw() {
  static uint32_t lastCompleted = 0;
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  // Draw the tiles we have even when no frame ever completes.
  //
  // A frame is only "complete" once every tile it promised has arrived, and
  // a full-panel update is ~66 datagrams, so half a percent of datagram loss
  // becomes a THIRD of frames never completing - measured with
  // `espdisp.py tile-motion`: at 20 full frames/s offered, 59% of frames
  // never completed and the panel showed 5.5 fps; at 45, none completed and
  // it showed NOTHING while receiving 1342 datagrams/s. That is the
  // majority-of-screen-motion failure, and the pixels were never the
  // problem: applyTileRecord has already written them into bufA, and the
  // reassembler was the only thing withholding them.
  //
  // So if tiles are pending and nothing has completed for a while, draw what
  // arrived. A partially updated frame during motion is imperceptible next to
  // a frozen panel, and any tile still missing is corrected by the next frame
  // that covers it - or by the 2-second keyframe at worst. Tile streams only:
  // a band frame is few enough datagrams that completion is not the binding
  // constraint there, and that path's behaviour is deliberately untouched.
  static uint32_t lastTileDrawAt = 0;
  bool tilePartialDue = false;
  if (tileStreamEnabled() && (uint32_t)(millis() - lastTileDrawAt) >=
                                 tunePartialDrawMs) {
    portENTER_CRITICAL(&drawMux);
    for (size_t i = 0; i < sizeof(pendingTileBitmap); i++) {
      if (pendingTileBitmap[i] != 0) {
        tilePartialDue = true;
        break;
      }
    }
    portEXIT_CRITICAL(&drawMux);
  }
  if (tilePartialDue) lastTileDrawAt = millis();
#else
  const bool tilePartialDue = false;
#endif
  // Where a draw pass's time actually goes (section 16.5 asked): the
  // measured ~42 ms per pass is 16 ms more than phase 0's per-call model
  // predicts, and draw_bitmap is ASYNC - it queues DMA and returns - so the
  // paint itself is NOT inside the pass. It drains afterward and surfaces
  // here, as this gate refusing to start the next pass while dmaInFlight is
  // nonzero. That refusal has to be counted separately or the paint time is
  // invisible to any timer placed inside the block below.
  const bool wantDraw = (framesCompleted != lastCompleted || tilePartialDue
#if defined(CONFIG_IDF_TARGET_ESP32S3)
                         || tileDrainPending
#endif
                        );
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  if (wantDraw && dmaInFlight != 0) {
    tdGateBlocked = tdGateBlocked + 1;  // each such iteration delay(1)s below
  }
  const uint32_t tdPassStart = micros();
#endif
  if (wantDraw && dmaInFlight == 0 && !surveyActive) {
    // Which kind of pass this is, captured before lastCompleted moves. A frame
    // completing outranks the partial timer: if both are true the pass paints a
    // whole frame and counts as one.
    const bool frameCompleted = (framesCompleted != lastCompleted);
    lastCompleted = framesCompleted;

    // Snapshot-and-clear the pending set; the UDP task keeps marking bands
    // for the next frame while we draw this one.
    uint8_t bands[BITMAP_BYTES];
#if defined(CONFIG_IDF_TARGET_ESP32S3)
    uint8_t tiles[tileproto::TILE_BITMAP_BYTES];
#endif
    portENTER_CRITICAL(&drawMux);
    memcpy(bands, pendingDrawBitmap, sizeof(bands));
    memset(pendingDrawBitmap, 0, sizeof(pendingDrawBitmap));
#if defined(CONFIG_IDF_TARGET_ESP32S3)
    memcpy(tiles, pendingTileBitmap, sizeof(tiles));
    memset(pendingTileBitmap, 0, sizeof(pendingTileBitmap));
#endif
    bool landscape = pendingLandscape;
    portEXIT_CRITICAL(&drawMux);

    if (landscape != panelLandscape || madctlDirty) {
      applyPanelConfig(landscape);
    }

    int drawWidth = PANEL_GEOMETRY.frameWidth(landscape);
    const int frameRows = PANEL_GEOMETRY.frameHeight(landscape);
    const int bandRows = PANEL_GEOMETRY.rowsPerBand(landscape);
    const uint16_t totalBands = PANEL_GEOMETRY.bandCount(landscape);

    // Coalesce runs of contiguous dirty bands into single DMA transfers.
    // Contiguous bands are contiguous in memory, so a run needs just one
    // memcpy to staging and one draw_bitmap. Staging (bufB) keeps DMA reads
    // off the buffer the network task writes. The last band may be short
    // (bandOffset of the end marker would overshoot the frame), so a run
    // that reaches the end sizes itself against the frame instead.
    bool drewAny = false;
    forEachRun(bands, totalBands, [&](int runStart, int runEnd) {
      size_t off = PANEL_GEOMETRY.bandOffset((uint16_t)runStart, landscape);
      size_t bytes =
          (runEnd >= (int)totalBands)
              ? FRAME_BYTES - off
              : PANEL_GEOMETRY.bandOffset((uint16_t)runEnd, landscape) - off;
      int yEnd = runEnd * bandRows;
      if (yEnd > frameRows) yEnd = frameRows;
      memcpy(bufB + off, bufA + off, bytes);
      dmaMarkQueued();
      // Queues async; blocks briefly only if the 2-deep transaction queue
      // is full. A failed queue never fires the completion callback, so
      // roll the counter back to avoid a permanent wedge.
      esp_err_t err = esp_lcd_panel_draw_bitmap(
          panel, 0, runStart * bandRows, drawWidth, yEnd, bufB + off);
      if (err != ESP_OK) {
        statDrawErrors = statDrawErrors + 1;
        dmaUnmarkFailed();
      } else {
        drewAny = true;
        // This run just overwrote the panel's pixels for its own row range
        // with bufA's fresh content - if the info bar is up and any of its
        // rows fell inside that range, the bar is now gone from the glass
        // and has to be redrawn on top before this run's DMA transfer
        // completes, or the panel briefly (or, if no later run touches
        // those rows again, permanently until the bar's window elapses)
        // shows the stream instead of the bar a moment after showing it.
        if (infoBarActive() &&
            panelstate::rowRangeOverlaps(runStart * bandRows, yEnd, infoBarY0,
                                        infoBarY1)) {
          waitForDmaIdle(200);
          redrawInfoBarOverRun();
        }
      }
    });

#if defined(CONFIG_IDF_TARGET_ESP32S3)
    // Tile runs (CAP_TILE_STREAM): merged horizontal rects, each one strided
    // gather from bufA into internal-SRAM staging then one clipped
    // draw_bitmap. Staging instead of bufB for the reasons at tileStaging's
    // declaration; double-buffered so the next run's gather overlaps the
    // previous run's transfer. Runs never cross a tile-row (forEachRowRun),
    // and run merging is what keeps the ~150 us fixed per-call cost paid
    // per REGION, not per tile.
    {
      static int tileStagingIdx = 0;
      int tileDrawCalls = 0;
      bool tileDeferred = false;
      tileproto::forEachRowRun(tiles, TILE_GEOMETRY, [&](uint16_t row,
                                                         uint16_t colStart,
                                                         uint16_t colEnd) {
        if (tileDrawCalls >= tuneDrawCallCap) {
          // Budget spent this iteration: put the run back and finish next
          // time, so a pathological checkerboard cannot starve touch,
          // serial, or the watchdog. bufA already holds the pixels; only
          // the panel push is deferred.
          portENTER_CRITICAL(&drawMux);
          for (uint16_t c = colStart; c < colEnd; c++) {
            const uint16_t t =
                (uint16_t)(row * TILE_GEOMETRY.tileCols() + c);
            pendingTileBitmap[t >> 3] |= (uint8_t)(1 << (t & 7));
          }
          portEXIT_CRITICAL(&drawMux);
          tileDeferred = true;
          return;
        }
        const int x0 = (int)colStart * tileproto::TILE_DIM;
        const int y0 = (int)row * tileproto::TILE_DIM;
        int x1 = (int)colEnd * tileproto::TILE_DIM;
        if (x1 > (int)TILE_GEOMETRY.width) x1 = TILE_GEOMETRY.width;
        const int w = x1 - x0;
        const int hgt = TILE_GEOMETRY.rowHeight(row);
        // Reusing a staging buffer requires its previous transfer done:
        // two buffers alternating against the 2-deep queue means
        // dmaInFlight < 2 leaves only the OTHER buffer possibly in flight.
        const uint32_t tSpin = micros();
        spinUntilDmaBelow(2, 500000);
        const uint32_t tGather = micros();
        tdSpinUs += tGather - tSpin;
        // Every run stages into internal SRAM, INCLUDING full-width ones whose
        // rows are already contiguous in bufA and could in principle be handed
        // to DMA in place. Phase 12 tried exactly that, on the reasoning that
        // the gather is 4.2 ms of an 8.6 ms call (section 17.2) and a
        // byte-identical rectangle does not need copying.
        //
        // Measured on a quiet panel, at the 15 fps offered where this board
        // delivers best: staging 13.7 complete frames a second at 2.8% loss,
        // direct-from-bufA 7.1 at 47.5%. The decisive number is the datagrams
        // the panel ACCEPTED - 269 of 270 offered with staging against 185
        // without it. Drawing from PSRAM does not just cost the draw; it starves
        // the receive path of the same bus, so tiles never arrive and frames
        // never complete.
        //
        // So the copy is not overhead, it is a memory-tier move: PSRAM's
        // ~22.3 MB/s (phase 0) is barely above what the panel needs and is
        // shared with the receive task's writes, while a strided SRAM copy runs
        // at 340+ MB/s and leaves the transfer reading fast memory uncontended.
        // Paying 4.2 ms to make the other 4.4 ms cheap, and to leave the radio
        // its bandwidth. That is what tileStaging's declaration means by "keeps
        // DMA reads off PSRAM entirely" - the load-bearing clause.
        uint8_t *source = tileStaging[tileStagingIdx];
        tileStagingIdx ^= 1;
        for (int r = 0; r < hgt; r++) {
          memcpy(source + (size_t)r * w * 2,
                 bufA + ((size_t)(y0 + r) * drawWidth + x0) * 2,
                 (size_t)w * 2);
        }
        const uint32_t tQueue = micros();
        tdGatherUs += tQueue - tGather;
        dmaMarkQueued();
        esp_err_t err = esp_lcd_panel_draw_bitmap(panel, x0, y0, x0 + w,
                                                  y0 + hgt, source);
        tdQueueUs += micros() - tQueue;
        if (err != ESP_OK) {
          statDrawErrors = statDrawErrors + 1;
          dmaUnmarkFailed();
        } else {
          drewAny = true;
          tileDrawCalls++;
          tdCalls = tdCalls + 1;
          // Same rule as the band runs: fresh pixels over the info bar's
          // rows would erase it, so redraw the bar on top.
          if (infoBarActive() &&
              panelstate::rowRangeOverlaps(y0, y0 + hgt, infoBarY0,
                                           infoBarY1)) {
            const uint32_t tBar = micros();
            waitForDmaIdle(200);
            redrawInfoBarOverRun();
            tdBarUs += micros() - tBar;
          }
        }
      });
      // Ask for another pass without pretending a frame completed.
      tileDrainPending = tileDeferred;
    }
#endif

#if defined(CONFIG_IDF_TARGET_ESP32S3)
    if (drewAny) {
      tdPasses = tdPasses + 1;
      tdPassUs += micros() - tdPassStart;
    }
#endif

    if (drewAny) {
      // `shown` is COMPLETE frames only, which is what it meant before
      // section 15.3 and what the sender's hill-climb assumes it means.
      if (frameCompleted) {
        statFramesShown = statFramesShown + 1;
      } else {
        statFramesPartial = statFramesPartial + 1;
      }
      // A drawn frame implies the sender is present and the Mac's displays
      // are awake, so leave both dimmed states - and the signal survey,
      // which a resumed stream has just painted over anyway.
      if (idleActive || displaySleeping || surveyActive) {
        idleActive = false;
        displaySleeping = false;
        surveyActive = false;
        applyBacklight();
      }
    }
  } else {
    delay(1);
  }
}

#if defined(CONFIG_IDF_TARGET_ESP32S3)
// The tiledraw half of loop()'s 5-second serial report.
void reportTileDrawStats() {
    // Where a draw pass's time goes, averaged over the window. Only when
    // something was drawn, so an idle panel stays quiet. `gateblocked` is the
    // one to read first: draw_bitmap is async, so the PAINT is not inside the
    // pass - it drains afterward, and blocks the next pass at the dmaInFlight
    // gate. A large gateblocked with a small pass total means the panel is
    // bus-bound, not CPU-bound, and no amount of protocol work will help.
    if (tdPasses > 0) {
      Serial.printf(
          "tiledraw: %lu passes, %lu calls, %lu gateblocked | per pass: "
          "%lu us total = spin %lu + gather %lu + queue %lu + bar %lu\n",
          (unsigned long)tdPasses, (unsigned long)tdCalls,
          (unsigned long)tdGateBlocked,
          (unsigned long)(tdPassUs / tdPasses),
          (unsigned long)(tdSpinUs / tdPasses),
          (unsigned long)(tdGatherUs / tdPasses),
          (unsigned long)(tdQueueUs / tdPasses),
          (unsigned long)(tdBarUs / tdPasses));
      tdPasses = tdCalls = tdGateBlocked = 0;
      tdPassUs = tdSpinUs = tdGatherUs = tdQueueUs = tdBarUs = 0;
    }
}
#endif
