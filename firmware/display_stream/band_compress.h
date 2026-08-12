// RLE codec for band payloads: PackBits adapted to 16-bit RGB565 pixels.
// Portable and hardware-free so it is unit tested on the host (see
// firmware/test/) and mirrored byte-for-byte in Swift
// (mac/.../SenderProtocol/BandCompression.swift, its vectors asserted
// independently in SenderProtocolTests - never via a shared fixture).
//
// Encoded stream: a sequence of chunks, each one control byte then data.
//   control 0x00..0x7F: literal run of (control + 1) pixels; the next
//                       2*(control+1) bytes are those pixels verbatim.
//   control 0x80..0xFF: repeat run of (control - 0x80 + 2) copies of the
//                       ONE pixel (2 bytes) that follows.
// A pixel is two bytes and is never split; the codec treats the pair as
// opaque, so it works on the wire's big-endian RGB565 without knowing it.
//
// Run lengths: a repeat encodes 2..129 pixels in 3 bytes, a literal carries
// 1..128 pixels at 1 byte of overhead. Runs of one pixel go into literals -
// encoding them as repeats would grow (3 bytes vs 3 bytes, but it would
// split surrounding literals). Worst case (no two adjacent pixels equal) is
// all-literal: 1 extra byte per 128 pixels, bounded by maxEncodedBytes().
//
// SECURITY: decode() writes into the receiver's frame buffer on the network
// path, from an unauthenticated datagram. It must never write outside
// [dst, dst+dstLen) and never read outside [src, src+srcLen), whatever the
// input claims - a fault here is a remote-triggered buffer overflow. Every
// bound is checked before the copy it guards; the host tests prove the
// property with canary bytes on both sides of both buffers.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace rle565 {

/// Largest literal run one control byte can carry, in pixels.
static const size_t MAX_LITERAL_PIXELS = 128;
/// Largest repeat run one control byte can carry, in pixels.
static const size_t MAX_RUN_PIXELS = 129;
/// Shortest run worth encoding as a repeat.
static const size_t MIN_RUN_PIXELS = 2;

/// Ceiling on encode() output for a given raw payload size: one control byte
/// per full-or-partial literal of MAX_LITERAL_PIXELS. The encoder never does
/// worse than this, which the host tests pin so a codec change cannot
/// silently break the sender's "compressed or raw, whichever is smaller"
/// buffer sizing.
inline size_t maxEncodedBytes(size_t rawBytes) {
  size_t pixels = rawBytes / 2;
  return rawBytes + (pixels + MAX_LITERAL_PIXELS - 1) / MAX_LITERAL_PIXELS;
}

/// Encode rawLen bytes (must be even: whole pixels) into dst. Returns the
/// encoded size, or 0 when the input is not whole pixels, is empty, or the
/// output would not fit dstCap. The firmware only decodes; encode lives here
/// so the host tests can round-trip the exact decoder the panel runs.
inline size_t encode(const uint8_t *src, size_t rawLen, uint8_t *dst,
                     size_t dstCap) {
  if (rawLen == 0 || (rawLen & 1) != 0) return 0;
  const size_t pixels = rawLen / 2;
  size_t in = 0;   // pixel index
  size_t out = 0;  // byte offset into dst
  while (in < pixels) {
    // Length of the repeat run starting at `in`.
    size_t run = 1;
    while (in + run < pixels && run < MAX_RUN_PIXELS &&
           src[(in + run) * 2] == src[in * 2] &&
           src[(in + run) * 2 + 1] == src[in * 2 + 1]) {
      run++;
    }
    if (run >= MIN_RUN_PIXELS) {
      if (out + 3 > dstCap) return 0;
      dst[out++] = (uint8_t)(0x80 + (run - MIN_RUN_PIXELS));
      dst[out++] = src[in * 2];
      dst[out++] = src[in * 2 + 1];
      in += run;
      continue;
    }
    // Literal: scan forward until a run of MIN_RUN_PIXELS begins or the
    // literal is full.
    size_t start = in;
    in++;  // the pixel that failed the run test is literal by definition
    while (in < pixels && (in - start) < MAX_LITERAL_PIXELS) {
      if (in + 1 < pixels && src[in * 2] == src[(in + 1) * 2] &&
          src[in * 2 + 1] == src[(in + 1) * 2 + 1]) {
        break;  // a repeat starts here; end the literal before it
      }
      in++;
    }
    size_t count = in - start;
    if (out + 1 + count * 2 > dstCap) return 0;
    dst[out++] = (uint8_t)(count - 1);
    memcpy(dst + out, src + start * 2, count * 2);
    out += count * 2;
  }
  return out;
}

/// Decode srcLen encoded bytes into exactly dstLen output bytes.
///
/// Returns true only when the input decodes to PRECISELY dstLen bytes with
/// nothing left over. Every failure mode is refused, not clamped: a chunk
/// that would overrun the output, an input that ends mid-chunk, an input
/// that ends short of dstLen, and trailing bytes after dstLen is reached all
/// return false. On false the destination contents are unspecified but
/// nothing outside [dst, dst+dstLen) has been written.
inline bool decode(const uint8_t *src, size_t srcLen, uint8_t *dst,
                   size_t dstLen) {
  size_t in = 0;
  size_t out = 0;
  while (in < srcLen) {
    const uint8_t control = src[in++];
    if (control < 0x80) {
      const size_t bytes = ((size_t)control + 1) * 2;
      if (in + bytes > srcLen) return false;   // truncated literal
      if (out + bytes > dstLen) return false;  // would overrun the band
      memcpy(dst + out, src + in, bytes);
      in += bytes;
      out += bytes;
    } else {
      const size_t run = (size_t)control - 0x80 + MIN_RUN_PIXELS;
      if (in + 2 > srcLen) return false;           // truncated repeat pixel
      if (out + run * 2 > dstLen) return false;    // would overrun the band
      const uint8_t hi = src[in];
      const uint8_t lo = src[in + 1];
      in += 2;
      for (size_t i = 0; i < run; i++) {
        dst[out++] = hi;
        dst[out++] = lo;
      }
    }
  }
  return out == dstLen;
}

}  // namespace rle565
