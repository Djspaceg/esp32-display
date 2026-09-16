#include "panel_transfer.h"

#include <Arduino.h>
#include <string.h>

#include <display_backend.h>
#include <esp_attr.h>
#include <esp_heap_caps.h>
#include <esp_memory_utils.h>

#include "dma_gate.h"

#if !defined(CONFIG_IDF_TARGET_ESP32S3)
static esp_err_t queueDirect(esp_lcd_panel_handle_t panel,
                             const board::Config &cfg, int x0, int y0, int x1,
                             int y1, const void *pixels) {
  dmaMarkQueued();
  const esp_err_t err =
      boarddisplay::drawBitmap(panel, cfg, x0, y0, x1, y1, pixels);
  if (err != ESP_OK) dmaUnmarkFailed();
  return err;
}
#endif

#if defined(CONFIG_IDF_TARGET_ESP32S3)
DMA_ATTR uint8_t
    panelTransferStaging[paneltransfer::STAGING_SLOT_COUNT]
                        [PANEL_TRANSFER_STAGE_BYTES];
static volatile paneltransfer::StagingOwnership stagingOwnership = {
    0,
    {paneltransfer::NO_STAGING_SLOT, paneltransfer::NO_STAGING_SLOT,
     paneltransfer::NO_STAGING_SLOT, paneltransfer::NO_STAGING_SLOT},
    0,
    0,
    0,
};
static portMUX_TYPE stagingOwnershipMux = portMUX_INITIALIZER_UNLOCKED;

bool acquirePanelTransferStaging(uint32_t maxUs, PanelTransferStaging &out) {
  out.pixels = nullptr;
  out.slot = paneltransfer::NO_STAGING_SLOT;
  const uint32_t startedAt = micros();
  while (true) {
    uint8_t slot = paneltransfer::NO_STAGING_SLOT;
    portENTER_CRITICAL(&stagingOwnershipMux);
    const bool reserved =
        paneltransfer::reserveStagingSlot(stagingOwnership, slot);
    portEXIT_CRITICAL(&stagingOwnershipMux);
    if (reserved) {
      out.pixels = panelTransferStaging[slot];
      out.slot = slot;
      return true;
    }
    if ((uint32_t)(micros() - startedAt) > maxUs) return false;
  }
}

bool releasePanelTransferStagingReservation(
    const PanelTransferStaging &staging) {
  if (staging.slot >= paneltransfer::STAGING_SLOT_COUNT ||
      staging.pixels != panelTransferStaging[staging.slot]) {
    return false;
  }
  portENTER_CRITICAL(&stagingOwnershipMux);
  const bool released = paneltransfer::cancelReservedStagingSlot(
      stagingOwnership, staging.slot);
  portEXIT_CRITICAL(&stagingOwnershipMux);
  return released;
}

esp_err_t queuePanelTransferStaging(
    esp_lcd_panel_handle_t panel, const board::Config &cfg, int x0, int y0,
    int x1, int y1, const PanelTransferStaging &staging) {
  if (staging.slot >= paneltransfer::STAGING_SLOT_COUNT ||
      staging.pixels != panelTransferStaging[staging.slot]) {
    return ESP_ERR_INVALID_ARG;
  }

  portENTER_CRITICAL(&stagingOwnershipMux);
  const bool queued =
      paneltransfer::queueStagingSlot(stagingOwnership, staging.slot);
  if (!queued) {
    paneltransfer::cancelReservedStagingSlot(stagingOwnership, staging.slot);
  }
  portEXIT_CRITICAL(&stagingOwnershipMux);
  if (!queued) return ESP_ERR_INVALID_STATE;

  dmaMarkQueued();
  const esp_err_t err = boarddisplay::drawBitmap(
      panel, cfg, x0, y0, x1, y1, staging.pixels);
  if (err != ESP_OK) {
    dmaUnmarkFailed();
    portENTER_CRITICAL(&stagingOwnershipMux);
    paneltransfer::rollbackQueuedStagingSlot(stagingOwnership, staging.slot);
    portEXIT_CRITICAL(&stagingOwnershipMux);
  }
  return err;
}

void notePanelTransferDirectQueued() {
  portENTER_CRITICAL(&stagingOwnershipMux);
  paneltransfer::queueDirectTransfer(stagingOwnership);
  portEXIT_CRITICAL(&stagingOwnershipMux);
}

void IRAM_ATTR completePanelTransferStagingFromIsr() {
  portENTER_CRITICAL_ISR(&stagingOwnershipMux);
  paneltransfer::completeQueuedStagingSlot(stagingOwnership);
  portEXIT_CRITICAL_ISR(&stagingOwnershipMux);
}

static const char *sourceTier(const void *pixels) {
  if (esp_ptr_external_ram(pixels)) return "psram";
  if (esp_ptr_internal(pixels)) return "internal";
  return "other";
}

static void logFailure(esp_err_t err, size_t attemptedBytes,
                       const void *pixels) {
  const uint32_t dmaCaps = MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA;
  Serial.printf(
      "display: staged queue failed err=%d bytes=%u source=%s "
      "dma_free=%u dma_largest=%u\n",
      (int)err, (unsigned)attemptedBytes, sourceTier(pixels),
      (unsigned)heap_caps_get_free_size(dmaCaps),
      (unsigned)heap_caps_get_largest_free_block(dmaCaps));
}
#endif

esp_err_t queuePanelBitmap(esp_lcd_panel_handle_t panel,
                           const board::Config &cfg, int x0, int y0, int x1,
                           int y1, const void *pixels) {
  if (panel == nullptr || pixels == nullptr || x0 < 0 || y0 < 0 || x1 <= x0 ||
      y1 <= y0) {
    return ESP_ERR_INVALID_ARG;
  }

#if defined(CONFIG_IDF_TARGET_ESP32S3)
  const int width = x1 - x0;
  if (paneltransfer::rowsPerChunk(width, PANEL_TRANSFER_STAGE_BYTES) <= 0) {
    return ESP_ERR_INVALID_SIZE;
  }

  const uint8_t *source = static_cast<const uint8_t *>(pixels);
  const int height = y1 - y0;
  for (int rowOffset = 0; rowOffset < height;) {
    paneltransfer::ChunkPlan chunk;
    if (!paneltransfer::planChunk(y0, y1, width,
                                  PANEL_TRANSFER_STAGE_BYTES, rowOffset,
                                  chunk)) {
      return ESP_ERR_INVALID_SIZE;
    }

    PanelTransferStaging staging;
    if (!acquirePanelTransferStaging(500000, staging)) {
      logFailure(ESP_ERR_TIMEOUT, chunk.byteCount, pixels);
      return ESP_ERR_TIMEOUT;
    }
    memcpy(staging.pixels, source + chunk.sourceOffset, chunk.byteCount);
    const esp_err_t err = queuePanelTransferStaging(
        panel, cfg, x0, chunk.y0, x1, chunk.y1, staging);
    if (err != ESP_OK) {
      logFailure(err, chunk.byteCount, pixels);
      return err;
    }
    rowOffset += chunk.y1 - chunk.y0;
  }
  return ESP_OK;
#else
  return queueDirect(panel, cfg, x0, y0, x1, y1, pixels);
#endif
}
