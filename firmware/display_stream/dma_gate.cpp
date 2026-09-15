#include "dma_gate.h"

#include <Arduino.h>

#if defined(ESPDISP_HOST_PANEL_TRANSFER_TEST)
extern volatile uint32_t statDrawErrors;
#else
#include "app_state.h"
#endif
#if defined(CONFIG_IDF_TARGET_ESP32S3)
#include "panel_transfer.h"
#endif

volatile int32_t dmaInFlight = 0;  // queued strip draws not yet completed
uint32_t dmaQueuedAt = 0;          // for DMA-stall detection
// dmaInFlight is incremented by tasks and decremented by the SPI ISR, and a
// task-side read-modify-write interrupted by the ISR between its load and
// store silently discards the ISR's decrement - the counter then sits above
// zero with nothing in flight. The old 500 ms stall failsafe forced the
// counter to zero, but elapsed time cannot prove a DMA source is reusable.
// Measured live on the
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
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  completePanelTransferStagingFromIsr();
#endif
  return false;
}


// Wait for queued strip DMA to finish, bounded. A timeout is an error report,
// never evidence that hardware released its source.
bool waitForDmaIdle(uint32_t maxMs) {
  uint32_t start = millis();
  while (dmaInFlight != 0 && millis() - start < maxMs) {
    delay(2);
  }
  if (dmaInFlight != 0) {
    statDrawErrors = statDrawErrors + 1;
    Serial.printf(
        "display: DMA completion timeout; ownership retained in_flight=%ld\n",
        (long)dmaInFlight);
    return false;
  }
  return true;
}
