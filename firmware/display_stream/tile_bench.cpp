#include "tile_bench.h"

#include <Arduino.h>

#include "esp_lcd_panel_ops.h"
#include <esp_task_wdt.h>

#include "app_state.h"
#include <display_backend.h>
#include "band_compress.h"
#include "bc1.h"
#include "dma_gate.h"
#include "frame_pipeline.h"
#include "panel_transfer.h"

#if defined(CONFIG_IDF_TARGET_ESP32S3)
// ---- CFGBENCH: tile-stream phase-0 measurements (S3 only) ----------------
// On-target microbenchmarks feeding docs/tile-stream-plan.md's budget math:
// BC1 decode rate, RLE565 decode rate, strided SRAM<->PSRAM copies, and
// per-draw-call overhead for the arbitrary-rectangle draws the tile protocol
// needs. S3-gated because the tile protocol is scoped to this board and the
// C6 binary is at 89% flash. Kept (not reverted) so phase 6's receive-path
// tuning can re-measure with one serial command. The decoders measured are
// the real shipped ones (bc1.h, band_compress.h) since phase 1 landed.

static const int BENCH_RUN_W = 480;  // 30 tiles x 16 px, the max wire run
static const int BENCH_RUN_H = 16;
static const size_t BENCH_RUN_BYTES = (size_t)BENCH_RUN_W * BENCH_RUN_H * 2;
// Shared with the tile draw path's staging: same size by construction, same
// task (both run from loopTask), and the bench drains DMA around every use,
// so the two can never race. Saves 15 KB of internal SRAM.
static uint8_t *const benchStaging = panelTransferStaging[0];
static_assert(BENCH_RUN_BYTES == TILE_RUN_MAX_BYTES,
              "bench and tile staging must stay the same size to share");

// Spin (not delay(2)-poll like waitForDmaIdle) so the wait itself does not
// quantize per-call draw timings to milliseconds.
static bool benchSpinDmaIdle(uint32_t maxUs) {
  uint32_t start = micros();
  while (dmaInFlight != 0) {
    if ((uint32_t)(micros() - start) > maxUs) {
      dmaInFlight = 0;  // same reclaim as the loop()'s stall failsafe
      statDrawErrors = statDrawErrors + 1;
      return false;
    }
  }
  return true;
}

// One timed rect-draw pass: `reps` draws of w x h at (x,y), each serialized
// (issue, then wait for completion), sourcing benchStaging. Staging is filled
// from bufA first so the draws are visually invisible.
static void benchDrawRect(const char *label, int x, int y, int w, int h,
                          int reps) {
  for (int r = 0; r < h; r++) {
    memcpy(benchStaging + (size_t)r * w * 2,
           bufA + ((size_t)(y + r) * PANEL_W + x) * 2, (size_t)w * 2);
  }
  benchSpinDmaIdle(500000);
  uint32_t t0 = micros();
  int errors = 0;
  for (int i = 0; i < reps; i++) {
    dmaMarkQueued();
    if (boarddisplay::drawBitmap(panel, *bcfg, x, y, x + w, y + h, benchStaging) !=
        ESP_OK) {
      dmaUnmarkFailed();
      errors++;
      continue;
    }
    if (!benchSpinDmaIdle(500000)) errors++;
  }
  uint32_t us = micros() - t0;
  Serial.printf("bench: draw %s %dx%d x%d: %lu us total, %.1f us/call, "
                "%.0f calls/s, errors=%d\n",
                label, w, h, reps, (unsigned long)us, (double)us / reps,
                reps * 1e6 / (double)us, errors);
}

void runTileBench() {
  if (bufA == nullptr || bufB == nullptr || panel == nullptr) {
    Serial.println("CFGERR bench: buffers/panel not ready");
    return;
  }
  Serial.println("bench: starting (S3 tile-stream phase 0)");
  esp_task_wdt_reset();

  // Inputs live in internal SRAM (static/stack), like the real receive path's
  // scratch will. Fill deterministically, mid-entropy so RLE gets a realistic
  // mix of short runs and literals rather than an all-flat best case.
  static uint8_t bc1Input[(BENCH_RUN_W / 4) * (BENCH_RUN_H / 4) * 8]
      __attribute__((aligned(4)));
  uint32_t seed = 0x1234567;
  for (size_t i = 0; i < sizeof(bc1Input); i++) {
    seed = seed * 1664525u + 1013904223u;
    bc1Input[i] = (uint8_t)(seed >> 16);
  }
  static uint8_t rleInput[BENCH_RUN_BYTES + BENCH_RUN_BYTES / 256 + 8]
      __attribute__((aligned(4)));
  // Worst-case literal stream: control 0x7F + 128 distinct pixels, repeated.
  size_t rleLen = 0;
  {
    size_t px = 0;
    const size_t pixels = BENCH_RUN_W * BENCH_RUN_H;
    while (px < pixels) {
      size_t n = pixels - px < 128 ? pixels - px : 128;
      rleInput[rleLen++] = (uint8_t)(n - 1);
      for (size_t i = 0; i < n; i++) {
        rleInput[rleLen++] = (uint8_t)(px >> 8);
        rleInput[rleLen++] = (uint8_t)px;
        px++;
      }
    }
  }

  // (a) BC1 decode, SRAM -> SRAM. Phase 0 measured a bench stand-in; this
  // is now bc1.h's real hardened decoder, the one the receive path runs.
  {
    const int reps = 300;
    uint32_t t0 = micros();
    size_t px = 0;
    for (int i = 0; i < reps; i++) {
      if (bc1::decode(bc1Input, sizeof(bc1Input), benchStaging, BENCH_RUN_W,
                      BENCH_RUN_H)) {
        px += (size_t)BENCH_RUN_W * BENCH_RUN_H;
      }
    }
    uint32_t us = micros() - t0;
    Serial.printf("bench: bc1 decode %u px in %lu us -> %.2f Mpx/s\n",
                  (unsigned)px, (unsigned long)us, (double)px / us);
  }
  esp_task_wdt_reset();

  // (a2) RLE565 decode (worst-case all-literal), SRAM -> SRAM.
  {
    const int reps = 300;
    uint32_t t0 = micros();
    for (int i = 0; i < reps; i++) {
      rle565::decode(rleInput, rleLen, benchStaging, BENCH_RUN_BYTES);
    }
    uint32_t us = micros() - t0;
    const size_t px = (size_t)BENCH_RUN_W * BENCH_RUN_H * reps;
    Serial.printf("bench: rle565 decode %u px in %lu us -> %.2f Mpx/s\n",
                  (unsigned)px, (unsigned long)us, (double)px / us);
  }
  esp_task_wdt_reset();

  // (b) Strided copies between internal SRAM and PSRAM bufA, both directions,
  // 16 rows x 960 B at stride 932 px - the tile receive path's write and the
  // draw path's staging read.
  {
    const size_t rowBytes = (size_t)PANEL_W * 2;
    const int reps = 200;
    uint32_t t0 = micros();
    for (int i = 0; i < reps; i++) {
      for (int r = 0; r < BENCH_RUN_H; r++) {
        memcpy(bufA + (size_t)(100 + r) * rowBytes,
               benchStaging + (size_t)r * BENCH_RUN_W * 2, BENCH_RUN_W * 2);
      }
    }
    uint32_t us = micros() - t0;
    double mb = (double)BENCH_RUN_BYTES * reps / 1e6;
    Serial.printf("bench: strided write SRAM->PSRAM %.1f MB in %lu us -> "
                  "%.1f MB/s\n", mb, (unsigned long)us, mb * 1e6 / us);
    t0 = micros();
    for (int i = 0; i < reps; i++) {
      for (int r = 0; r < BENCH_RUN_H; r++) {
        memcpy(benchStaging + (size_t)r * BENCH_RUN_W * 2,
               bufA + (size_t)(100 + r) * rowBytes, BENCH_RUN_W * 2);
      }
    }
    us = micros() - t0;
    Serial.printf("bench: strided read PSRAM->SRAM %.1f MB in %lu us -> "
                  "%.1f MB/s\n", mb, (unsigned long)us, mb * 1e6 / us);
  }
  esp_task_wdt_reset();

  // (b2) Full-frame PSRAM -> PSRAM memcpy, the band path's bufA -> bufB cost.
  {
    const int reps = 5;
    uint32_t t0 = micros();
    for (int i = 0; i < reps; i++) memcpy(bufB, bufA, FRAME_BYTES);
    uint32_t us = micros() - t0;
    double mb = (double)FRAME_BYTES * reps / 1e6;
    Serial.printf("bench: memcpy PSRAM->PSRAM %.1f MB in %lu us -> %.1f MB/s\n",
                  mb, (unsigned long)us, mb * 1e6 / us);
  }
  esp_task_wdt_reset();

  // (c) Draw-call overhead: serialized rect draws of the three shapes the
  // tile draw path produces. Content is copied from bufA, so nothing visible
  // changes on the glass.
  benchDrawRect("tile", 200, 200, 16, 16, 200);
  esp_task_wdt_reset();
  benchDrawRect("run", 0, 200, BENCH_RUN_W, 16, 100);
  esp_task_wdt_reset();
  benchDrawRect("fullwidth", 0, 200, PANEL_W, 16, 100);
  esp_task_wdt_reset();

  // (c2) Pipelined 16x16 draws (no wait between issues, queue depth 2), the
  // throughput bound as opposed to the per-call latency above.
  {
    const int reps = 200;
    benchSpinDmaIdle(500000);
    uint32_t t0 = micros();
    int errors = 0;
    for (int i = 0; i < reps; i++) {
      dmaMarkQueued();
      if (boarddisplay::drawBitmap(panel, *bcfg, 200, 200, 216, 216, benchStaging) !=
          ESP_OK) {
        dmaUnmarkFailed();
        errors++;
      }
    }
    benchSpinDmaIdle(500000);
    uint32_t us = micros() - t0;
    Serial.printf("bench: draw tile 16x16 x%d pipelined: %lu us, %.1f us/call,"
                  " %.0f calls/s, errors=%d\n",
                  reps, (unsigned long)us, (double)us / reps,
                  reps * 1e6 / (double)us, errors);
  }
  Serial.println("CFGOK bench complete");
}
#endif  // CONFIG_IDF_TARGET_ESP32S3
