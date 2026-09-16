// Panel writes with a stable source-lifetime contract.
//
// On S3, every rectangle is copied through bounded internal DMA staging before
// it reaches esp_lcd. The caller may therefore supply PSRAM and may reuse that
// source as soon as queuePanelBitmap returns. C6 uses internal frame buffers
// already, while P4's DSI backend owns its own staging.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include <board_config.h>
#include <esp_err.h>
#include <esp_lcd_panel_ops.h>
#include <panel_transfer_plan.h>

#if defined(CONFIG_IDF_TARGET_ESP32S3)
// Wide enough for 16 rows of the largest supported S3 panel (466 pixels).
// The 480-pixel allowance also preserves the tile benchmark's established
// staging shape.
constexpr size_t PANEL_TRANSFER_STAGE_BYTES = paneltransfer::STAGING_BYTES;
extern uint8_t
    panelTransferStaging[paneltransfer::STAGING_SLOT_COUNT]
                        [PANEL_TRANSFER_STAGE_BYTES];

struct PanelTransferStaging {
  uint8_t *pixels;
  uint8_t slot;
};

// Reserves a free slot before returning its pointer. A timeout leaves all
// ownership unchanged.
bool acquirePanelTransferStaging(uint32_t maxUs, PanelTransferStaging &out);

// Releases a reservation that was never submitted to hardware.
bool releasePanelTransferStagingReservation(
    const PanelTransferStaging &staging);

// Registers the reserved slot in callback order before submitting it to
// hardware. A failed submission rolls the reservation back because hardware
// never accepted it.
esp_err_t queuePanelTransferStaging(
    esp_lcd_panel_handle_t panel, const board::Config &cfg, int x0, int y0,
    int x1, int y1, const PanelTransferStaging &staging);

// Records a transfer that shares the completion callback but owns no staging
// buffer (a direct draw), so its completion pops a marker and releases no
// staging buffer. Any transfer submitted outside queuePanelTransferStaging
// that will fire on_color_trans_done MUST call this first, in submission
// order, or the shared completion callback will attribute its completion to a
// staging buffer that is still in use.
void notePanelTransferDirectQueued();

// ISR context: releases exactly the oldest successfully queued staging slot,
// or nothing when the oldest outstanding transfer was a direct draw.
void completePanelTransferStagingFromIsr();
#endif

esp_err_t queuePanelBitmap(esp_lcd_panel_handle_t panel,
                           const board::Config &cfg, int x0, int y0, int x1,
                           int y1, const void *pixels);
