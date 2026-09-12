// Pure chunk planning for bounded panel staging. Kept Arduino-free so the
// host tests can prove every transfer fits the internal DMA buffer.
#pragma once

#include <stddef.h>

namespace paneltransfer {

constexpr size_t BYTES_PER_PIXEL = 2;
constexpr size_t STAGING_BYTES = (size_t)480 * 16 * BYTES_PER_PIXEL;

struct ChunkPlan {
  int y0;
  int y1;
  size_t sourceOffset;
  size_t byteCount;
};

inline size_t rowBytes(int width) {
  return width > 0 ? (size_t)width * BYTES_PER_PIXEL : 0;
}

inline int rowsPerChunk(int width, size_t stagingBytes) {
  const size_t bytes = rowBytes(width);
  return bytes != 0 ? (int)(stagingBytes / bytes) : 0;
}

inline bool planChunk(int rectY0, int rectY1, int width,
                      size_t stagingBytes, int rowOffset, ChunkPlan &out) {
  if (rectY0 < 0 || rectY1 <= rectY0 || rowOffset < 0) return false;
  const int maxRows = rowsPerChunk(width, stagingBytes);
  const int height = rectY1 - rectY0;
  if (maxRows <= 0 || rowOffset >= height) return false;

  int rows = height - rowOffset;
  if (rows > maxRows) rows = maxRows;
  const size_t bytesPerRow = rowBytes(width);
  out.y0 = rectY0 + rowOffset;
  out.y1 = out.y0 + rows;
  out.sourceOffset = (size_t)rowOffset * bytesPerRow;
  out.byteCount = (size_t)rows * bytesPerRow;
  return true;
}

}  // namespace paneltransfer
