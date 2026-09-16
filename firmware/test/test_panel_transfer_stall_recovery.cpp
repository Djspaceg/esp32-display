// Host-side falsifier for the "both staging slots wedge busy forever" theory
// behind the round CO5300/S3 panel going black mid-stream.
//
// test_panel_transfer_staging.cpp proves the OLD reuse hazard is gone: a
// software counter reset can no longer hand back a slot hardware still owns.
// This file asks the opposite question - once a wait has timed out and the
// draw has failed, can the system ever draw again? It asserts on the
// observable outcome (queuePanelBitmap returning ESP_OK) rather than on the
// internal ownership counters.
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include <Arduino.h>

#include "../display_stream/dma_gate.h"
#include "../display_stream/panel_transfer.h"

uint32_t fakeMicros = 0;
uint32_t fakeMicrosStep = 1;
FakeSerial Serial;
esp_err_t fakeDrawResult = ESP_OK;

volatile uint32_t statDrawErrors = 0;

static int failures = 0;

static void check(bool condition, const char *message) {
  if (!condition) {
    printf("FAIL: %s\n", message);
    failures++;
  }
}

// A rectangle small enough that one chunk covers it, so a single
// queuePanelBitmap call consumes exactly one staging slot.
static const int RECT_W = 8;
static const int RECT_H = 4;
static uint8_t sourcePixels[(size_t)RECT_W * RECT_H * 2];

static esp_err_t drawOnce(esp_lcd_panel_handle_t panel,
                          const board::Config &cfg) {
  return queuePanelBitmap(panel, cfg, 0, 0, RECT_W, RECT_H, sourcePixels);
}

// Make the 500 ms acquire deadline inside queuePanelBitmap expire in a few
// loop iterations instead of half a million.
static void useCoarseClock() { fakeMicrosStep = 200000; }
static void useFineClock() { fakeMicrosStep = 1; }

int main() {
  board::Config config;
  esp_lcd_panel_handle_t panel = reinterpret_cast<void *>(1);
  for (size_t i = 0; i < sizeof(sourcePixels); ++i) {
    sourcePixels[i] = (uint8_t)i;
  }

  // ---------------------------------------------------------------------
  // Scenario 1: both slots queued to hardware, no completion callback ever
  // arrives, the bounded wait gives up. Can a later draw still land?
  // ---------------------------------------------------------------------
  useFineClock();
  PanelTransferStaging queuedA;
  PanelTransferStaging queuedB;
  check(acquirePanelTransferStaging(10, queuedA), "slot A reserved");
  check(queuePanelTransferStaging(panel, config, 0, 0, RECT_W, RECT_H,
                                  queuedA) == ESP_OK,
        "slot A submitted to hardware");
  check(acquirePanelTransferStaging(10, queuedB), "slot B reserved");
  check(queuePanelTransferStaging(panel, config, 0, RECT_H, RECT_W,
                                  RECT_H * 2, queuedB) == ESP_OK,
        "slot B submitted to hardware");
  check(queuedA.slot != queuedB.slot, "the two reservations are distinct");
  check(dmaInFlight == 2, "both transfers counted in flight");

  // The completion callbacks are deliberately withheld here: this is the
  // dropped/missed-callback condition the theory needs.
  useCoarseClock();
  check(!waitForDmaIdle(50), "bounded wait reports a timeout");
  check(dmaInFlight == 2,
        "timeout retains ownership instead of zeroing the gate");

  // Every subsequent draw, for as long as no callback arrives - and with the
  // fake clock advanced far past any plausible watchdog horizon between
  // attempts - must be refused. There is no time-based reclaim left.
  bool anyDrawSucceeded = false;
  for (int attempt = 0; attempt < 64; ++attempt) {
    fakeMicros += 60u * 1000u * 1000u;  // jump a minute of fake time
    if (drawOnce(panel, config) == ESP_OK) anyDrawSucceeded = true;
  }
  check(!anyDrawSucceeded,
        "with no callback delivered, no draw can acquire a slot (expected: "
        "this is the stalled state, not yet a defect)");
  check(statDrawErrors > 0, "the stall is reported at least once");

  // ---------------------------------------------------------------------
  // Scenario 2 - THE FALSIFIER. A completion callback that arrives late,
  // after the wait already gave up and the draw already failed. If this
  // releases the slot, the wedge is transient and the permanent-deadlock
  // theory is wrong.
  // ---------------------------------------------------------------------
  useFineClock();
  onColorTransDone(nullptr, nullptr, nullptr);
  check(drawOnce(panel, config) == ESP_OK,
        "FALSIFIER: a late completion callback restores the ability to draw");
  check(dmaInFlight == 2,
        "late callback credited exactly one transfer, new draw queued one");

  // The second late callback must also land, restoring full capacity.
  onColorTransDone(nullptr, nullptr, nullptr);
  onColorTransDone(nullptr, nullptr, nullptr);
  check(dmaInFlight == 0, "both remaining transfers credited");
  PanelTransferStaging capacityA;
  PanelTransferStaging capacityB;
  check(acquirePanelTransferStaging(10, capacityA) &&
            acquirePanelTransferStaging(10, capacityB),
        "FALSIFIER: full two-slot capacity is restored after late callbacks");
  check(releasePanelTransferStagingReservation(capacityA) &&
            releasePanelTransferStagingReservation(capacityB),
        "probe reservations released");

  // ---------------------------------------------------------------------
  // Scenario 3: extra callbacks beyond the number of queued transfers must
  // not bank credit that later frees a slot hardware still owns.
  // ---------------------------------------------------------------------
  for (int i = 0; i < 8; ++i) onColorTransDone(nullptr, nullptr, nullptr);
  check(dmaInFlight == 0, "spurious callbacks cannot drive the gate negative");
  PanelTransferStaging bankedA;
  check(acquirePanelTransferStaging(10, bankedA), "slot reserved after spurious callbacks");
  check(queuePanelTransferStaging(panel, config, 0, 0, RECT_W, RECT_H,
                                  bankedA) == ESP_OK,
        "slot submitted after spurious callbacks");
  PanelTransferStaging bankedB;
  check(acquirePanelTransferStaging(10, bankedB),
        "the other slot is still available");
  check(bankedB.slot != bankedA.slot,
        "banked spurious callbacks did not release the queued slot early");
  check(releasePanelTransferStagingReservation(bankedB),
        "unsubmitted reservation released");
  onColorTransDone(nullptr, nullptr, nullptr);
  check(dmaInFlight == 0, "scenario 3 drained");

  // ---------------------------------------------------------------------
  // Scenario 4: a non-staged draw shares the same completion callback.
  // A direct draw (frame_pipeline.cpp's large-tile path calls dmaMarkQueued()
  // + boarddisplay::drawBitmap() directly, bypassing staging) still runs
  // onColorTransDone -> completePanelTransferStagingFromIsr. The panel IO
  // completes transfers in submission order, so submit the DIRECT one FIRST,
  // then a staged one; the direct transfer's completion arrives first while
  // the staged transfer is still outstanding. That completion must NOT release
  // the staged buffer.
  //
  // notePanelTransferDirectQueued() is the contract a direct draw follows so
  // its completion is attributed to a marker, not to a staging buffer. Without
  // it the shared callback pops the staging FIFO head and frees a buffer whose
  // own DMA is still running - the original reuse hazard, reached through the
  // bypass.
  // ---------------------------------------------------------------------
  notePanelTransferDirectQueued();  // direct draw registers itself, in order
  dmaMarkQueued();                  // ...then submits: direct transfer queued first
  PanelTransferStaging staged;
  check(acquirePanelTransferStaging(10, staged), "staged slot reserved");
  check(queuePanelTransferStaging(panel, config, 0, 0, RECT_W, RECT_H,
                                  staged) == ESP_OK,
        "staged slot submitted to hardware");
  check(dmaInFlight == 2, "one direct and one staged transfer in flight");

  // In submission order the direct transfer completes first.
  onColorTransDone(nullptr, nullptr, nullptr);
  check(dmaInFlight == 1,
        "the staged transfer is still outstanding in hardware");

  // Round-robin allocation hands out the other slot first, so asking once
  // proves nothing. Take both: with exactly one staged transfer outstanding,
  // exactly one slot may be handed out. If both come back, `staged` was
  // released while hardware still owned it - the original reuse hazard.
  PanelTransferStaging afterDirect;
  check(acquirePanelTransferStaging(10, afterDirect),
        "the free slot is available after the direct transfer completed");
  useCoarseClock();
  PanelTransferStaging mustNotBeAvailable;
  const bool releasedEarly =
      acquirePanelTransferStaging(500, mustNotBeAvailable);
  useFineClock();
  check(!releasedEarly,
        "a non-staged transfer's completion released the staging slot whose "
        "own DMA is still outstanding");
  if (releasedEarly) {
    printf(
        "       staged slot=%u was handed back while dmaInFlight=%ld; "
        "reacquired as slot=%u\n",
        (unsigned)staged.slot, (long)dmaInFlight,
        (unsigned)mustNotBeAvailable.slot);
  }

  // Drain scenario 4 so the gate starts clean: complete the staged transfer,
  // then release the probe reservation.
  onColorTransDone(nullptr, nullptr, nullptr);
  check(releasePanelTransferStagingReservation(afterDirect),
        "scenario 4 probe reservation released");
  if (releasedEarly) {
    (void)releasePanelTransferStagingReservation(mustNotBeAvailable);
  }
  dmaInFlight = 0;

  // ---------------------------------------------------------------------
  // Scenario 5: a single permanently lost completion callback. This merge
  // deleted the 500 ms failsafe that used to force dmaInFlight back to zero
  // (dma_gate.cpp:19-20); display_stream.ino:596-607 now only logs the stall.
  // frame_pipeline.cpp:579 and :771 refuse to start a draw while
  // dmaInFlight != 0. So: is dmaInFlight recoverable without the callback?
  // ---------------------------------------------------------------------
  dmaMarkQueued();  // a transfer whose completion interrupt is never delivered
  check(dmaInFlight == 1, "the lost transfer is counted in flight");
  useCoarseClock();
  for (int attempt = 0; attempt < 32; ++attempt) {
    fakeMicros += 60u * 1000u * 1000u;  // a minute of fake time per attempt
    check(!waitForDmaIdle(1000),
          "no elapsed-time path reclaims a lost completion");
  }
  check(dmaInFlight == 1,
        "dmaInFlight stays latched non-zero forever, and every draw gated on "
        "dmaInFlight == 0 is refused for the rest of the boot");
  useFineClock();
  onColorTransDone(nullptr, nullptr, nullptr);
  check(waitForDmaIdle(10),
        "only the completion callback itself can clear the gate");

  if (failures != 0) {
    printf("FAIL: panel staging stall recovery failed %d checks\n", failures);
    return 1;
  }
  printf("OK: panel staging stall recovery checks passed\n");
  return 0;
}
