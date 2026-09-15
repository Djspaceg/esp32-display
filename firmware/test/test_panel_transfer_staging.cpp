#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include <Arduino.h>

#include "../display_stream/panel_transfer.h"
#include "../display_stream/dma_gate.h"

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

int main() {
  volatile paneltransfer::StagingOwnership model = {
      0,
      {paneltransfer::NO_STAGING_SLOT, paneltransfer::NO_STAGING_SLOT},
      0,
      0,
      0,
  };
  uint8_t modelFirst = paneltransfer::NO_STAGING_SLOT;
  uint8_t modelSecond = paneltransfer::NO_STAGING_SLOT;
  uint8_t modelThird = paneltransfer::NO_STAGING_SLOT;
  check(paneltransfer::reserveStagingSlot(model, modelFirst),
        "model reserves slot 0");
  check(paneltransfer::reserveStagingSlot(model, modelSecond),
        "missing queue commit still leaves slot 0 reserved");
  check(modelSecond != modelFirst,
        "missing queue commit cannot reacquire the first slot");
  check(!paneltransfer::reserveStagingSlot(model, modelThird),
        "software counter state cannot release either reserved slot");

  board::Config config;
  esp_lcd_panel_handle_t panel = reinterpret_cast<void *>(1);
  PanelTransferStaging first;
  PanelTransferStaging second;
  PanelTransferStaging unavailable;

  check(acquirePanelTransferStaging(10, first),
        "production allocator reserves first slot");
  check(first.slot == 0, "first production reservation uses slot 0");
  check(queuePanelTransferStaging(panel, config, 0, 0, 1, 1, first) == ESP_OK,
        "first hardware queue succeeds");
  check(dmaInFlight == 1, "first hardware queue increments DMA gate");

  check(acquirePanelTransferStaging(10, second),
        "production allocator reserves second slot");
  check(second.slot == 1, "second production reservation uses slot 1");
  check(queuePanelTransferStaging(panel, config, 0, 1, 1, 2, second) == ESP_OK,
        "second hardware queue succeeds");
  check(dmaInFlight == 2, "second hardware queue increments DMA gate");

  fakeMicrosStep = 6;
  check(!acquirePanelTransferStaging(10, unavailable),
        "full production allocator times out");

  dmaInFlight = 0;
  fakeMicrosStep = 1;
  check(!acquirePanelTransferStaging(0, unavailable),
        "counter reset must not release hardware-owned slots");

  onColorTransDone(nullptr, nullptr, nullptr);
  PanelTransferStaging fifoReleased;
  check(acquirePanelTransferStaging(10, fifoReleased),
        "completion callback releases one queued slot");
  check(fifoReleased.slot == first.slot,
        "completion callback releases queued slots in FIFO order");

  fakeDrawResult = 99;
  check(queuePanelTransferStaging(panel, config, 0, 2, 1, 3, fifoReleased) ==
            fakeDrawResult,
        "failed hardware queue reports its error");
  fakeDrawResult = ESP_OK;

  PanelTransferStaging afterFailure;
  check(acquirePanelTransferStaging(10, afterFailure),
        "failed hardware queue releases its unowned reservation");
  check(queuePanelTransferStaging(panel, config, 0, 3, 1, 4, afterFailure) ==
            ESP_OK,
        "recycled reservation queues successfully");

  onColorTransDone(nullptr, nullptr, nullptr);
  PanelTransferStaging wrappedFifo;
  check(acquirePanelTransferStaging(10, wrappedFifo),
        "wrapped FIFO completion releases the oldest remaining slot");
  check(wrappedFifo.slot == second.slot,
        "wrapped FIFO preserves exact slot completion order");
  check(queuePanelTransferStaging(panel, config, 0, 4, 1, 5, wrappedFifo) ==
            ESP_OK,
        "wrapped FIFO slot queues again");
  onColorTransDone(nullptr, nullptr, nullptr);
  onColorTransDone(nullptr, nullptr, nullptr);

  PanelTransferStaging softwareOnly;
  check(acquirePanelTransferStaging(10, softwareOnly),
        "software-only reservation acquires a free slot");
  check(releasePanelTransferStagingReservation(softwareOnly),
        "software-only reservation can be released before hardware submission");
  PanelTransferStaging afterSoftwareRelease;
  check(acquirePanelTransferStaging(10, afterSoftwareRelease),
        "released software-only reservation becomes available");
  check(releasePanelTransferStagingReservation(afterSoftwareRelease),
        "second software-only reservation releases cleanly");

  if (failures != 0) {
    printf("FAIL: panel staging ownership failed %d transition checks\n",
           failures);
    return 1;
  }
  printf("OK: panel staging ownership transitions passed\n");
  return 0;
}
