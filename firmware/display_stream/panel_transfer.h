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
extern uint8_t panelTransferStaging[2][PANEL_TRANSFER_STAGE_BYTES];

// Acquires the next safe staging buffer. Call commitPanelTransferStaging only
// after a transfer using the returned buffer was successfully queued.
uint8_t *acquirePanelTransferStaging(uint32_t maxUs);
void commitPanelTransferStaging();
#endif

esp_err_t queuePanelBitmap(esp_lcd_panel_handle_t panel,
                           const board::Config &cfg, int x0, int y0, int x1,
                           int y1, const void *pixels);
