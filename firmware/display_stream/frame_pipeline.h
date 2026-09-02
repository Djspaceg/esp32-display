// The streaming pipeline: frame buffers, band/tile reassembly and appliers
// (network task), and the draw pass (loop task). Owns drawMux and the
// pending-band/tile bitmaps; the buffer-ownership invariant is unchanged
// from the monolith: the receive path writes bufA, the draw path reads bufA
// and writes bufB / the tile staging buffers.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "band_protocol.h"

// Where the frame buffers live is a per-chip fact (PSRAM on the S3, internal
// DMA-capable SRAM on the C6); setup() allocates them with these caps.
extern const uint32_t FRAME_BUF_CAPS;
extern uint8_t *bufA;
extern uint8_t *bufB;
extern bool bufLandscape;  // orientation of bufA's content

// Apply one band's payload to bufA and run the reassembly bookkeeping
// (called from the inbound dispatch in net_link.cpp).
bool applyBandPayload(const bandproto::Header &h, bool compressed,
                      const uint8_t *payload, size_t payloadLen,
                      bool countPacket);

#if defined(CONFIG_IDF_TARGET_ESP32S3)
// One tile-stream datagram (bit 15 set, on a board where that means tiles).
void handleTilePacket(const uint8_t *data, size_t len);

// Sized for the widest run any roadmap square panel can produce (30 tiles x
// 16 px x 16 rows); the 466 panel's widest is 14,912 B. Also the size of
// the CFGBENCH staging buffer these are shared with (tile_bench.cpp).
constexpr size_t TILE_RUN_MAX_BYTES = (size_t)480 * 16 * 2;
extern uint8_t tileStaging[2][TILE_RUN_MAX_BYTES];

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
