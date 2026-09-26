// The streaming pipeline: frame buffers, band/tile reassembly and appliers
// (network task), and the draw pass (loop task). Owns drawMux and the
// pending-band/tile bitmaps; the buffer-ownership invariant is unchanged
// from the monolith: the receive path writes bufA, the draw path reads bufA
// and writes bufB. S3 panel transfers then pass through bounded internal DMA
// staging (panel_transfer.h).
#pragma once

#include <stddef.h>
#include <stdint.h>

#include <panel_transfer_plan.h>

#include "band_protocol.h"

// bufB reaches the panel and therefore needs the draw capability; bufA only
// receives packets and is copied into bufB. C3 uses its non-DMA-capable SRAM
// for bufA so both 240x240 frames fit without PSRAM.
extern const uint32_t FRAME_BUF_CAPS;
extern const uint32_t FRAME_SOURCE_BUF_CAPS;
size_t frameSourceBytes();
size_t frameDrawBytes();
extern uint8_t *bufA;
extern uint8_t *bufB;
extern bool bufLandscape;  // orientation of bufA's content

// Bind protocol reassemblers to the runtime-selected profile geometry. Called
// once after configurePanelGeometry() and before any network packet can arrive.
bool initializeFramePipeline();

// Apply one band's payload to bufA and run the reassembly bookkeeping
// (called from the inbound dispatch in net_link.cpp).
bool applyBandPayload(const bandproto::Header &h, bool compressed,
                      const uint8_t *payload, size_t payloadLen,
                      bool countPacket);

#if defined(ESPDISP_LARGE_TILE_STREAM)
// One magic-prefixed ETL1 large-tile datagram.
void handleLargeTilePacket(const uint8_t *data, size_t len);
#endif

#if defined(CONFIG_IDF_TARGET_ESP32S3)
// One tile-stream datagram (bit 15 set, on a board where that means tiles).
void handleTilePacket(const uint8_t *data, size_t len);

// Sized for the widest run any roadmap square panel can produce (30 tiles x
// 16 px x 16 rows); the 466 panel's widest is 14,912 B. Decode scratch and
// panel DMA staging intentionally share the same established upper bound.
constexpr size_t TILE_RUN_MAX_BYTES = paneltransfer::STAGING_BYTES;

// CFGTUNE knobs (serial_config.cpp); see their definitions for the
// measurement discipline they exist for.
extern int tuneDrawCallCap;
extern uint32_t tunePartialDrawMs;

// The tiledraw half of loop()'s 5-second serial report.
void reportTileDrawStats();
#endif

// Fill the whole panel with one RGB565 color (boot status feedback).
void fillPanel(uint16_t rgb565);

// loop()'s two draw-side service calls: reapply a pending rotation and
// repaint from cache, then run the streaming draw pass (which also owns the
// delay(1) idle pacing).
void serviceRotationRepaint();
void serviceStreamDraw();
