// The DMA in-flight gate: one counter incremented when a strip draw is
// queued and decremented by the SPI completion ISR, with the critical-section
// discipline that closes the lost-decrement race (see dma_gate.cpp). Every
// module that queues esp_lcd draws goes through this.
#pragma once

#include <stdint.h>

#include "esp_lcd_panel_io.h"

extern volatile int32_t dmaInFlight;  // queued strip draws not yet completed
extern uint32_t dmaQueuedAt;          // for DMA-stall detection

void dmaMarkQueued();
void dmaUnmarkFailed();

// ISR context: one queued strip transfer finished. Registered by
// initDisplay() (app_state.cpp).
bool onColorTransDone(esp_lcd_panel_io_handle_t,
                      esp_lcd_panel_io_event_data_t *, void *);

// Wait for queued strip DMA to finish, bounded; reclaims on timeout.
void waitForDmaIdle(uint32_t maxMs);
