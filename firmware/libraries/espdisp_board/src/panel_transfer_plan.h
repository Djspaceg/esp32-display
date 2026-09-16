// Pure chunk planning for bounded panel staging. Kept Arduino-free so the
// host tests can prove every transfer fits the internal DMA buffer.
#pragma once

#include <stddef.h>
#include <stdint.h>

namespace paneltransfer {

constexpr size_t BYTES_PER_PIXEL = 2;
constexpr size_t STAGING_BYTES = (size_t)480 * 16 * BYTES_PER_PIXEL;
constexpr uint8_t STAGING_SLOT_COUNT = 2;
constexpr uint8_t NO_STAGING_SLOT = 0xFF;

// The completion FIFO records every in-flight transfer that will fire the
// shared color-trans-done callback, in submission order - staged transfers as
// their slot index and non-staged transfers as NO_STAGING_SLOT. The panel IO
// completes transfers in submission order, so the head is always the oldest
// outstanding transfer; a completion releases a staging buffer only when the
// head it pops is a staging slot. This is why a non-staged transfer's
// completion can no longer hand back a staging buffer whose own DMA is still
// running: its FIFO entry is a marker, not a slot.
//
// Cap headroom beyond STAGING_SLOT_COUNT covers a non-staged transfer queued
// alongside both staging buffers plus the one entry pushed just before its
// (possibly blocking) submit call, which the panel IO's trans_queue_depth
// bounds well under this.
constexpr uint8_t TRANSFER_QUEUE_CAP = STAGING_SLOT_COUNT + 2;

struct ChunkPlan {
  int y0;
  int y1;
  size_t sourceOffset;
  size_t byteCount;
};

struct StagingOwnership {
  volatile uint8_t busyMask;
  volatile uint8_t queuedSlots[TRANSFER_QUEUE_CAP];
  volatile uint8_t queueHead;
  volatile uint8_t queueCount;
  volatile uint8_t nextSlot;
};

inline bool stagingSlotQueued(const volatile StagingOwnership &state,
                              uint8_t slot) {
  for (uint8_t i = 0; i < state.queueCount; ++i) {
    const uint8_t index =
        (uint8_t)((state.queueHead + i) % TRANSFER_QUEUE_CAP);
    if (state.queuedSlots[index] == slot) return true;
  }
  return false;
}

inline bool reserveStagingSlot(volatile StagingOwnership &state,
                               uint8_t &slot) {
  for (uint8_t offset = 0; offset < STAGING_SLOT_COUNT; ++offset) {
    const uint8_t candidate =
        (uint8_t)((state.nextSlot + offset) % STAGING_SLOT_COUNT);
    const uint8_t bit = (uint8_t)(1U << candidate);
    if ((state.busyMask & bit) != 0) continue;
    state.busyMask = (uint8_t)(state.busyMask | bit);
    state.nextSlot = (uint8_t)((candidate + 1) % STAGING_SLOT_COUNT);
    slot = candidate;
    return true;
  }
  return false;
}

inline bool queueStagingSlot(volatile StagingOwnership &state, uint8_t slot) {
  if (slot >= STAGING_SLOT_COUNT ||
      (state.busyMask & (uint8_t)(1U << slot)) == 0 ||
      state.queueCount >= TRANSFER_QUEUE_CAP ||
      stagingSlotQueued(state, slot)) {
    return false;
  }
  const uint8_t tail =
      (uint8_t)((state.queueHead + state.queueCount) % TRANSFER_QUEUE_CAP);
  state.queuedSlots[tail] = slot;
  state.queueCount = (uint8_t)(state.queueCount + 1);
  return true;
}

// Record a transfer that will fire the shared completion callback but does not
// own a staging buffer (a direct draw). Its FIFO entry is a marker, so the
// completion that pops it releases no staging buffer while keeping the FIFO's
// submission order aligned with the hardware's in-order completions.
inline bool queueDirectTransfer(volatile StagingOwnership &state) {
  if (state.queueCount >= TRANSFER_QUEUE_CAP) return false;
  const uint8_t tail =
      (uint8_t)((state.queueHead + state.queueCount) % TRANSFER_QUEUE_CAP);
  state.queuedSlots[tail] = NO_STAGING_SLOT;
  state.queueCount = (uint8_t)(state.queueCount + 1);
  return true;
}

inline bool cancelReservedStagingSlot(volatile StagingOwnership &state,
                                      uint8_t slot) {
  if (slot >= STAGING_SLOT_COUNT || stagingSlotQueued(state, slot)) {
    return false;
  }
  const uint8_t bit = (uint8_t)(1U << slot);
  if ((state.busyMask & bit) == 0) return false;
  state.busyMask = (uint8_t)(state.busyMask & (uint8_t)~bit);
  return true;
}

inline bool rollbackQueuedStagingSlot(volatile StagingOwnership &state,
                                      uint8_t slot) {
  uint8_t offset = NO_STAGING_SLOT;
  for (uint8_t i = 0; i < state.queueCount; ++i) {
    const uint8_t index =
        (uint8_t)((state.queueHead + i) % TRANSFER_QUEUE_CAP);
    if (state.queuedSlots[index] == slot) {
      offset = i;
      break;
    }
  }
  if (offset == NO_STAGING_SLOT) return false;

  for (uint8_t i = offset; i + 1 < state.queueCount; ++i) {
    const uint8_t destination =
        (uint8_t)((state.queueHead + i) % TRANSFER_QUEUE_CAP);
    const uint8_t source =
        (uint8_t)((state.queueHead + i + 1) % TRANSFER_QUEUE_CAP);
    state.queuedSlots[destination] = state.queuedSlots[source];
  }
  const uint8_t tail =
      (uint8_t)((state.queueHead + state.queueCount - 1) %
                TRANSFER_QUEUE_CAP);
  state.queuedSlots[tail] = NO_STAGING_SLOT;
  state.queueCount = (uint8_t)(state.queueCount - 1);
  state.busyMask =
      (uint8_t)(state.busyMask & (uint8_t)~(uint8_t)(1U << slot));
  return true;
}

// Pop the oldest outstanding transfer. Returns the staging slot it freed, or
// NO_STAGING_SLOT when the completing transfer was a non-staged marker (or the
// FIFO was empty) - in which case no staging buffer is released. The busy bit
// is cleared only for a real slot, so a non-staged completion cannot free a
// staging buffer whose transfer is still outstanding.
inline uint8_t completeQueuedStagingSlot(
    volatile StagingOwnership &state) {
  if (state.queueCount == 0) return NO_STAGING_SLOT;
  const uint8_t slot = state.queuedSlots[state.queueHead];
  state.queuedSlots[state.queueHead] = NO_STAGING_SLOT;
  state.queueHead =
      (uint8_t)((state.queueHead + 1) % TRANSFER_QUEUE_CAP);
  state.queueCount = (uint8_t)(state.queueCount - 1);
  if (slot >= STAGING_SLOT_COUNT) return NO_STAGING_SLOT;
  state.busyMask =
      (uint8_t)(state.busyMask & (uint8_t)~(uint8_t)(1U << slot));
  return slot;
}

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
