// BC1 (DXT1) block codec for tile-stream run payloads: fixed 4:1 lossy
// compression of RGB565 rasters. Portable and hardware-free so it is unit
// tested on the host (see firmware/test/) and mirrored in Swift
// (mac/.../SenderProtocol/BC1.swift, its vectors asserted independently in
// SenderProtocolTests - never via a shared fixture).
//
// Encoded stream: ceil(w/4) x ceil(h/4) blocks, row-major, 8 bytes each:
//   [c0 u16 LE][c1 u16 LE][indices u32 LE]
// c0 and c1 are RGB565 endpoint colors. The index word carries 2 bits per
// pixel, row-major within the block, consumed from the least significant
// bits up (byte 4 covers block row 0, byte 5 row 1, ...). Each index picks
// from a 4-color palette: {c0, c1, (2*c0+c1)/3, (c0+2*c1)/3}, the
// interpolants computed per RGB565 channel in integer math - see palette().
//
// This is deliberately NOT general DXT1: the standard's 3-color+transparent
// mode (selected there by c0 <= c1) does not exist here. The encoder orders
// endpoints so c0 >= c1 always, and the decoder applies the 4-color palette
// unconditionally, so every possible block decodes to something well-defined
// and hostile input cannot select an unimplemented mode.
//
// Rasters are in the wire's pixel order - big-endian RGB565, hi byte first -
// matching band payloads, so decoded runs drop into the framebuffer as-is.
// Edge rasters (a tile run's last column/row can be 2 px on the 466x466
// grid) still occupy whole blocks: the encoder pads by replicating the last
// row/column, the decoder consumes the padding's indices but clips the
// writes to the true w x h rect.
//
// SECURITY: decode() writes into the receiver's frame buffer on the network
// path, from an unauthenticated datagram. It must never write outside the
// w*h*2-byte destination raster and never read outside [src, src+srcLen),
// whatever the input claims - a fault here is a remote-triggered buffer
// overflow. The encoded size of a w x h raster is a pure function of w and
// h (encodedBytes), so decode() refuses any srcLen that is not exactly
// that, and every edge-block write is clipped to the raster; the host tests
// prove the property with exact-size heap buffers under ASan.
#pragma once

#include <stddef.h>
#include <stdint.h>

namespace bc1 {

/// Blocks are 4x4 pixels.
static const size_t BLOCK_DIM = 4;
/// Two RGB565 endpoints (u16 LE each) then 16 x 2-bit indices (u32 LE).
static const size_t BLOCK_BYTES = 8;
/// Sanity ceiling on either raster dimension. Far above any tile run (the
/// widest is 480 px) but low enough that every size computation in here
/// stays well inside 32 bits on the panel's size_t.
static const size_t MAX_DIM = 4096;

/// Exact encoded size of a w x h raster: ceil(w/4) x ceil(h/4) blocks of
/// BLOCK_BYTES. Zero when a dimension is zero or beyond MAX_DIM - callers
/// treat zero as refusal, the same convention as rle565::encode. BC1 is
/// fixed-rate, so unlike the RLE codec this is the size, not a ceiling.
inline size_t encodedBytes(size_t w, size_t h) {
  if (w == 0 || h == 0 || w > MAX_DIM || h > MAX_DIM) return 0;
  const size_t bw = (w + BLOCK_DIM - 1) / BLOCK_DIM;
  const size_t bh = (h + BLOCK_DIM - 1) / BLOCK_DIM;
  return bw * bh * BLOCK_BYTES;
}

/// The 4-color palette for a block: the two endpoints then the 1/3 and 2/3
/// interpolants, computed per RGB565 channel without unpacking to 888. Both
/// the decoder and the encoder's index selection use this exact function, so
/// the encoder optimizes against the palette the panel will actually apply.
inline void palette(uint16_t c0, uint16_t c1, uint16_t pal[4]) {
  pal[0] = c0;
  pal[1] = c1;
  const uint16_t r0 = c0 >> 11, g0 = (c0 >> 5) & 0x3F, b0 = c0 & 0x1F;
  const uint16_t r1 = c1 >> 11, g1 = (c1 >> 5) & 0x3F, b1 = c1 & 0x1F;
  pal[2] = (uint16_t)((((2 * r0 + r1) / 3) << 11) |
                      ((((2 * g0 + g1) / 3) & 0x3F) << 5) |
                      (((2 * b0 + b1) / 3) & 0x1F));
  pal[3] = (uint16_t)((((r0 + 2 * r1) / 3) << 11) |
                      ((((g0 + 2 * g1) / 3) & 0x3F) << 5) |
                      (((b0 + 2 * b1) / 3) & 0x1F));
}

/// Squared distance between two RGB565 colors in 888 space (channels
/// expanded by bit replication, so green's extra bit does not double its
/// weight relative to a straight 5/6/5 comparison).
inline uint32_t distance2(uint16_t a, uint16_t b) {
  const int32_t ar = ((a >> 11) << 3) | ((a >> 11) >> 2);
  const int32_t ag = (((a >> 5) & 0x3F) << 2) | (((a >> 5) & 0x3F) >> 4);
  const int32_t ab = ((a & 0x1F) << 3) | ((a & 0x1F) >> 2);
  const int32_t br = ((b >> 11) << 3) | ((b >> 11) >> 2);
  const int32_t bg = (((b >> 5) & 0x3F) << 2) | (((b >> 5) & 0x3F) >> 4);
  const int32_t bb = ((b & 0x1F) << 3) | ((b & 0x1F) >> 2);
  return (uint32_t)((ar - br) * (ar - br) + (ag - bg) * (ag - bg) +
                    (ab - bb) * (ab - bb));
}

/// Encode a w x h big-endian RGB565 raster into dst. Returns the encoded
/// size (always exactly encodedBytes(w, h)), or 0 when the dimensions are
/// invalid or the output would not fit dstCap.
///
/// Endpoints are the block's per-channel bounding box: c0 packs the channel
/// maxima, c1 the minima, which makes c0 >= c1 numerically by construction
/// (no swap needed), reproduces flat blocks exactly, and reproduces
/// two-tone blocks exactly when the two colors are channel-wise ordered
/// (black-on-white text is; the variance gate sends the rest lossless).
/// Each pixel then takes the palette index nearest in 888 space, first
/// index winning ties. Pixels past the raster's edge replicate the last
/// row/column so padding never drags the bounding box outward. The firmware
/// only decodes; encode lives here so the host tests can round-trip the
/// exact decoder the panel runs.
inline size_t encode(const uint8_t *src, size_t w, size_t h, uint8_t *dst,
                     size_t dstCap) {
  const size_t need = encodedBytes(w, h);
  if (need == 0 || need > dstCap) return 0;
  const size_t bw = (w + BLOCK_DIM - 1) / BLOCK_DIM;
  const size_t bh = (h + BLOCK_DIM - 1) / BLOCK_DIM;
  size_t out = 0;
  for (size_t by = 0; by < bh; by++) {
    for (size_t bx = 0; bx < bw; bx++) {
      // Gather the block, replicating the edge row/column as padding.
      uint16_t px[16];
      for (size_t py = 0; py < 4; py++) {
        size_t sy = by * 4 + py;
        if (sy >= h) sy = h - 1;
        for (size_t pxi = 0; pxi < 4; pxi++) {
          size_t sx = bx * 4 + pxi;
          if (sx >= w) sx = w - 1;
          const uint8_t *s = src + (sy * w + sx) * 2;
          px[py * 4 + pxi] = (uint16_t)(((uint16_t)s[0] << 8) | s[1]);
        }
      }
      // Bounding-box endpoints per channel.
      uint16_t rMin = 0x1F, rMax = 0, gMin = 0x3F, gMax = 0, bMin = 0x1F,
               bMax = 0;
      for (size_t i = 0; i < 16; i++) {
        const uint16_t r = px[i] >> 11, g = (px[i] >> 5) & 0x3F,
                       b = px[i] & 0x1F;
        if (r < rMin) rMin = r;
        if (r > rMax) rMax = r;
        if (g < gMin) gMin = g;
        if (g > gMax) gMax = g;
        if (b < bMin) bMin = b;
        if (b > bMax) bMax = b;
      }
      const uint16_t c0 = (uint16_t)((rMax << 11) | (gMax << 5) | bMax);
      const uint16_t c1 = (uint16_t)((rMin << 11) | (gMin << 5) | bMin);
      uint16_t pal[4];
      palette(c0, c1, pal);
      uint32_t idx = 0;
      for (size_t i = 0; i < 16; i++) {
        uint32_t best = distance2(px[i], pal[0]);
        uint32_t sel = 0;
        for (uint32_t p = 1; p < 4; p++) {
          const uint32_t d = distance2(px[i], pal[p]);
          if (d < best) {  // strict: first index wins ties
            best = d;
            sel = p;
          }
        }
        idx |= sel << (i * 2);
      }
      dst[out++] = (uint8_t)(c0 & 0xFF);
      dst[out++] = (uint8_t)(c0 >> 8);
      dst[out++] = (uint8_t)(c1 & 0xFF);
      dst[out++] = (uint8_t)(c1 >> 8);
      dst[out++] = (uint8_t)(idx & 0xFF);
      dst[out++] = (uint8_t)((idx >> 8) & 0xFF);
      dst[out++] = (uint8_t)((idx >> 16) & 0xFF);
      dst[out++] = (uint8_t)((idx >> 24) & 0xFF);
    }
  }
  return out;
}

/// Decode srcLen encoded bytes into a w x h big-endian RGB565 raster of
/// exactly w*h*2 bytes at dst.
///
/// Returns true only when srcLen is PRECISELY encodedBytes(w, h) - short
/// and long inputs are both refused, not clamped, mirroring rle565::decode's
/// posture. Edge blocks consume their full 16 indices but write only the
/// pixels inside the raster. On false nothing has been written.
inline bool decode(const uint8_t *src, size_t srcLen, uint8_t *dst, size_t w,
                   size_t h) {
  const size_t need = encodedBytes(w, h);
  if (need == 0 || srcLen != need) return false;
  const size_t bw = (w + BLOCK_DIM - 1) / BLOCK_DIM;
  const size_t bh = (h + BLOCK_DIM - 1) / BLOCK_DIM;
  for (size_t by = 0; by < bh; by++) {
    for (size_t bx = 0; bx < bw; bx++) {
      const uint8_t *b = src + (by * bw + bx) * BLOCK_BYTES;
      uint16_t pal[4];
      palette((uint16_t)(b[0] | ((uint16_t)b[1] << 8)),
              (uint16_t)(b[2] | ((uint16_t)b[3] << 8)), pal);
      uint32_t idx = (uint32_t)b[4] | ((uint32_t)b[5] << 8) |
                     ((uint32_t)b[6] << 16) | ((uint32_t)b[7] << 24);
      const size_t x0 = bx * 4, y0 = by * 4;
      if (x0 + 4 <= w && y0 + 4 <= h) {
        // Interior block: the unclipped path the panel runs almost always
        // (only the 2 px edge tiles of the 466x466 grid clip).
        for (size_t py = 0; py < 4; py++) {
          uint8_t *row = dst + ((y0 + py) * w + x0) * 2;
          for (size_t pxi = 0; pxi < 4; pxi++) {
            const uint16_t c = pal[idx & 3];
            idx >>= 2;
            row[pxi * 2] = (uint8_t)(c >> 8);  // wire order: big-endian
            row[pxi * 2 + 1] = (uint8_t)c;
          }
        }
      } else {
        // Edge block: consume every index, write only inside the raster.
        for (size_t py = 0; py < 4; py++) {
          for (size_t pxi = 0; pxi < 4; pxi++) {
            const uint16_t c = pal[idx & 3];
            idx >>= 2;
            if (x0 + pxi < w && y0 + py < h) {
              uint8_t *at = dst + ((y0 + py) * w + (x0 + pxi)) * 2;
              at[0] = (uint8_t)(c >> 8);
              at[1] = (uint8_t)c;
            }
          }
        }
      }
    }
  }
  return true;
}

}  // namespace bc1
