#include "dma_gate.h"

#include <Arduino.h>

#include "app_state.h"

volatile int32_t dmaInFlight = 0;  // queued strip draws not yet completed
uint32_t dmaQueuedAt = 0;          // for DMA-stall detection
// dmaInFlight is incremented by tasks and decremented by the SPI ISR, and a
// task-side read-modify-write interrupted by the ISR between its load and
// store silently discards the ISR's decrement - the counter then sits above
// zero with nothing in flight until the 500 ms stall failsafe reclaims it,
// and the panel draws NOTHING for that half second. Measured live on the
// 466x466 panel under real streaming: drawerr climbing ~1/s with
// gateblocked ~2000 per 5 s window - 4-5 wedges of ~450 blocked-millisecond
// iterations each, exactly the failsafe's 500 ms - costing ~40% of draw
// time (a reliable 25 fps stream degraded to ~15 with visibly stale
// regions). The race was always in this code; denser record traffic and the
// retuned pacing raised its hit rate from rare to constant.
//
// Masking interrupts around every task-side RMW makes it atomic against the
// ISR; the ISR's own RMW cannot be preempted by a task. The spinlock also
// keeps it sound if the ISR and a task ever land on different cores.
static portMUX_TYPE dmaCountMux = portMUX_INITIALIZER_UNLOCKED;
void dmaMarkQueued() {
  portENTER_CRITICAL(&dmaCountMux);
  dmaInFlight = dmaInFlight + 1;
  portEXIT_CRITICAL(&dmaCountMux);
  dmaQueuedAt = millis();
}
// A failed queue never fires the completion callback, so its increment is
// rolled back - through the same mask, or the rollback can itself lose a
// racing decrement.
void dmaUnmarkFailed() {
  portENTER_CRITICAL(&dmaCountMux);
  dmaInFlight = dmaInFlight - 1;
  portEXIT_CRITICAL(&dmaCountMux);
}

// ISR context: one queued strip transfer finished.
bool IRAM_ATTR onColorTransDone(esp_lcd_panel_io_handle_t,
                                       esp_lcd_panel_io_event_data_t *, void *) {
  // The ISR-safe critical section pairs with dmaMarkQueued/dmaUnmarkFailed:
  // see dmaCountMux for the lost-decrement race this closes.
  portENTER_CRITICAL_ISR(&dmaCountMux);
  if (dmaInFlight > 0) {
    dmaInFlight = dmaInFlight - 1;
  }
  portEXIT_CRITICAL_ISR(&dmaCountMux);
  return false;
}


#if defined(CONFIG_IDF_TARGET_ESP32S3)

// Spin until fewer than `level` DMA transfers are queued. The tile draw
// path's staging reuse gate: with two staging buffers alternating and the
// panel's 2-deep transaction queue, dmaInFlight < 2 means the only transfer
// possibly in flight is the OTHER buffer's, so writing this one is safe. A
// spin, not delay(2)-polling, because the wait is tens of microseconds and
// quantizing it to milliseconds would put a floor under the frame rate.
bool spinUntilDmaBelow(int32_t level, uint32_t maxUs) {
  uint32_t start = micros();
  while (dmaInFlight >= level) {
    if ((uint32_t)(micros() - start) > maxUs) {
      statDrawErrors = statDrawErrors + 1;
      dmaInFlight = 0;  // same reclaim as the loop's stall failsafe
      return false;
    }
  }
  return true;
}
#endif
// Wait for queued strip DMA to finish, bounded.
//
// Two callers, and the second is the reason this exists. Reusing bufB needs the
// previous transfer done (fillPanel achieves that with a flat delay(30)); an OTA
// write needs it for a sharper reason: on the S3 the frame buffers live in PSRAM,
// which shares its SPI controller with the flash the update is writing, and the
// cache goes down for the duration of an erase. A transfer still in flight when
// that happens is a hazard, so the progress screen drains before handing control
// back to the updater. UNVERIFIED on hardware (no board attached while this was
// written): written to be safe rather than measured.
void waitForDmaIdle(uint32_t maxMs) {
  uint32_t start = millis();
  while (dmaInFlight != 0 && millis() - start < maxMs) {
    delay(2);
  }
  if (dmaInFlight != 0) {
    // The same reclaim the loop's DMA-stall failsafe does: a lost completion
    // callback must not wedge the panel forever.
    statDrawErrors = statDrawErrors + 1;
    dmaInFlight = 0;
  }
}

