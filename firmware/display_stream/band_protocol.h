// Band-stream protocol logic, portable and hardware-free so it can be unit
// tested on the host (see firmware/test/). The Arduino sketch does the I/O
// (UDP, buffers, DMA); everything decision-shaped lives here.
//
// Wire format per packet:
//   [frame_id u16 LE][band_index u16 LE][dirty_count u16 LE][band payload]
// where bit 15 of dirty_count carries orientation (1 = landscape) and
// dirty_count is the number of bands in THIS frame. Bands are
// orientation-native so they align to whole rows.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace bandproto {

static const uint16_t BANDS_PORTRAIT = 80;   // 4 rows x 344B = 1376B
static const uint16_t BANDS_LANDSCAPE = 86;  // 2 rows x 640B = 1280B
static const size_t BAND_BYTES_PORTRAIT = 1376;
static const size_t BAND_BYTES_LANDSCAPE = 1280;
static const int ROWS_PER_BAND_PORTRAIT = 4;
static const int ROWS_PER_BAND_LANDSCAPE = 2;
static const uint16_t MAX_BANDS = 86;
static const size_t BITMAP_BYTES = (MAX_BANDS + 7) / 8;
static const size_t HEADER_BYTES = 6;

inline uint16_t bandCount(bool landscape) {
  return landscape ? BANDS_LANDSCAPE : BANDS_PORTRAIT;
}
inline size_t bandBytes(bool landscape) {
  return landscape ? BAND_BYTES_LANDSCAPE : BAND_BYTES_PORTRAIT;
}
inline int rowsPerBand(bool landscape) {
  return landscape ? ROWS_PER_BAND_LANDSCAPE : ROWS_PER_BAND_PORTRAIT;
}

struct Header {
  uint16_t frameId;
  uint16_t bandIndex;
  uint16_t dirtyCount;
  bool landscape;
};

inline Header parseHeader(const uint8_t *d) {
  Header h;
  h.frameId = (uint16_t)d[0] | ((uint16_t)d[1] << 8);
  h.bandIndex = (uint16_t)d[2] | ((uint16_t)d[3] << 8);
  uint16_t countField = (uint16_t)d[4] | ((uint16_t)d[5] << 8);
  h.landscape = (countField & 0x8000) != 0;
  h.dirtyCount = countField & 0x7FFF;
  return h;
}

enum class ChunkAction : uint8_t {
  Reject,         // geometry mismatch: drop silently
  IgnoreStale,    // late chunk of an already-superseded frame
  Duplicate,      // this band already arrived for the current frame
  Apply,          // copy the payload into the frame buffer
  ApplyComplete,  // as Apply, and the frame is now complete
};

// Tracks per-frame reassembly state. Encodes the hard-won rules:
// - Wraparound-aware ordering: only a NEWER frame id abandons the current
//   one; late WiFi retransmissions of older frames are ignored (adopting
//   them used to thrash reassembly and kill both frames).
// - A persistent stream of "stale" ids means the sender restarted (ids
//   reset to 0): force-resync instead of rejecting for up to 32k frames.
// - Duplicate bands (802.11 retry artifacts) must not double-count toward
//   completion.
class Reassembler {
 public:
  // droppedFrame is set when adopting a new frame abandoned a partial one
  // (its bands stay pending for drawing - per-band recency).
  ChunkAction onChunk(const Header &h, bool &droppedFrame) {
    droppedFrame = false;
    uint16_t totalBands = bandCount(h.landscape);
    if (h.dirtyCount == 0 || h.dirtyCount > totalBands ||
        h.bandIndex >= totalBands) {
      return ChunkAction::Reject;
    }

    if (!frameActive) {
      adopt(h);
    } else if (h.frameId != frameId) {
      int16_t diff = (int16_t)(h.frameId - frameId);
      if (diff <= 0) {
        if (++staleStreak < 2 * MAX_BANDS) {
          return ChunkAction::IgnoreStale;
        }
        // Sender restart: fall through and adopt.
      }
      if (bandsSeen > 0) {
        droppedFrame = true;
      }
      adopt(h);
    }
    staleStreak = 0;

    uint8_t mask = 1 << (h.bandIndex & 7);
    if (bitmap[h.bandIndex >> 3] & mask) {
      return ChunkAction::Duplicate;
    }
    bitmap[h.bandIndex >> 3] |= mask;
    bandsSeen++;

    if (bandsSeen >= bandsExpected) {
      frameActive = false;
      return ChunkAction::ApplyComplete;
    }
    return ChunkAction::Apply;
  }

  bool landscape() const { return frameLandscape; }

 private:
  void adopt(const Header &h) {
    frameId = h.frameId;
    bandsSeen = 0;
    bandsExpected = h.dirtyCount;
    frameLandscape = h.landscape;
    frameActive = true;
    memset(bitmap, 0, sizeof(bitmap));
  }

  uint16_t frameId = 0;
  uint16_t bandsSeen = 0;
  uint16_t bandsExpected = 0;
  uint16_t staleStreak = 0;
  bool frameActive = false;
  bool frameLandscape = false;
  uint8_t bitmap[BITMAP_BYTES] = {0};
};

// Invoke fn(startBand, endBandExclusive) for each contiguous run of set
// bits. Contiguous bands are contiguous in memory, so each run can become a
// single memcpy + DMA transfer.
template <typename F>
inline void forEachRun(const uint8_t *bits, int totalBands, F fn) {
  int i = 0;
  while (i < totalBands) {
    if (!(bits[i >> 3] & (1 << (i & 7)))) {
      i++;
      continue;
    }
    int start = i;
    while (i < totalBands && (bits[i >> 3] & (1 << (i & 7)))) {
      i++;
    }
    fn(start, i);
  }
}

}  // namespace bandproto
