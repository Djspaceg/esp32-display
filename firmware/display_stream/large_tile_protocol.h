// Magic-prefixed large-tile stream for panels beyond tile v1's 10-bit grid.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace largetileproto {

static const uint8_t MAGIC[4] = {'E', 'T', 'L', '1'};
static const size_t HEADER_BYTES = 10;
static const size_t RECORD_HEADER_BYTES = 6;
static const size_t MAX_PACKET_BYTES = 1472;
static const uint16_t TILE_DIM = 16;
static const uint16_t MAX_TILES = 4096;
static const size_t BITMAP_BYTES = MAX_TILES / 8;
static const uint8_t FLAG_LANDSCAPE = 0x01;
static const uint8_t FLAG_MASK = FLAG_LANDSCAPE;
static const uint8_t CODEC_MASK = 0x03;
static const uint8_t CODEC_VISIBLE_SPANS = 0x04;
static const uint8_t CODEC_RESERVED_MASK = 0xF8;

enum class Codec : uint8_t { Raw = 0, Rle565 = 1, Bc1 = 2, HalfBc1 = 3 };

inline uint16_t readU16(const uint8_t *p) {
  return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

struct Header {
  uint16_t frameId;
  uint16_t dirtyTileCount;
  bool landscape;
};

inline bool parseHeader(const uint8_t *data, size_t len, Header &out) {
  if (data == nullptr || len < HEADER_BYTES ||
      memcmp(data, MAGIC, sizeof(MAGIC)) != 0 || data[9] != 0 ||
      (data[8] & ~FLAG_MASK) != 0) {
    return false;
  }
  out.frameId = readU16(data + 4);
  out.dirtyTileCount = readU16(data + 6);
  out.landscape = (data[8] & FLAG_LANDSCAPE) != 0;
  return true;
}

struct Geometry {
  uint16_t width;
  uint16_t height;
  uint16_t tileCols() const { return (width + TILE_DIM - 1) / TILE_DIM; }
  uint16_t tileRows() const { return (height + TILE_DIM - 1) / TILE_DIM; }
  uint16_t tileCount() const { return (uint16_t)(tileCols() * tileRows()); }
  uint16_t col(uint16_t tile) const { return tile % tileCols(); }
  uint16_t row(uint16_t tile) const { return tile / tileCols(); }
  uint16_t colWidth(uint16_t c) const {
    const uint16_t remain = width - c * TILE_DIM;
    return remain < TILE_DIM ? remain : TILE_DIM;
  }
  uint16_t rowHeight(uint16_t r) const {
    const uint16_t remain = height - r * TILE_DIM;
    return remain < TILE_DIM ? remain : TILE_DIM;
  }
  bool valid() const {
    return width > 0 && height > 0 && tileCount() > 0 &&
           tileCount() <= MAX_TILES && tileCols() <= 255;
  }
  bool runValid(uint16_t start, uint8_t length) const {
    return length > 0 && start < tileCount() &&
           (uint16_t)(col(start) + length) <= tileCols();
  }
  uint16_t runPixelWidth(uint16_t start, uint8_t length) const {
    uint32_t end = (uint32_t)(col(start) + length) * TILE_DIM;
    if (end > width) end = width;
    return (uint16_t)(end - col(start) * TILE_DIM);
  }
  size_t runRawBytes(uint16_t start, uint8_t length) const {
    return (size_t)runPixelWidth(start, length) * rowHeight(row(start)) * 2;
  }
};

struct Record {
  uint16_t startTile;
  uint8_t runLength;
  Codec codec;
  bool visibleSpans;
  const uint8_t *payload;
  size_t payloadLength;
};

template <typename F>
inline bool forEachRecord(const uint8_t *data, size_t len, F fn) {
  if (data == nullptr || len < HEADER_BYTES + RECORD_HEADER_BYTES) return false;
  size_t at = HEADER_BYTES;
  while (at < len) {
    if (at + RECORD_HEADER_BYTES > len) return false;
    Record record;
    record.startTile = readU16(data + at);
    record.runLength = data[at + 2];
    const uint8_t flags = data[at + 3];
    if ((flags & CODEC_RESERVED_MASK) != 0) return false;
    record.codec = (Codec)(flags & CODEC_MASK);
    record.visibleSpans = (flags & CODEC_VISIBLE_SPANS) != 0;
    record.payloadLength = readU16(data + at + 4);
    at += RECORD_HEADER_BYTES;
    if (record.payloadLength == 0 || at + record.payloadLength > len) {
      return false;
    }
    record.payload = data + at;
    if (!fn(record)) return false;
    at += record.payloadLength;
  }
  return at == len;
}

enum class DrawReason : uint8_t { None, Complete, Partial };

/// Decide whether pending tiles may be painted now. Completion always wins;
/// otherwise a bounded deadline prevents one lost UDP record from freezing all
/// successfully received tiles. `pendingSince` is the first accepted tile's
/// timestamp and zero when the pending bitmap is empty.
inline DrawReason pendingDrawReason(uint32_t now, uint32_t pendingSince,
                                    uint32_t completed,
                                    uint32_t lastCompleted,
                                    bool hasPending, uint32_t deadlineMs) {
  if (!hasPending) return DrawReason::None;
  if (completed != lastCompleted) return DrawReason::Complete;
  if (pendingSince != 0 && (uint32_t)(now - pendingSince) >= deadlineMs) {
    return DrawReason::Partial;
  }
  return DrawReason::None;
}

enum class Action : uint8_t {
  Reject,
  IgnoreStale,
  Duplicate,
  Apply,
  ApplyComplete,
};

class Reassembler {
 public:
  explicit Reassembler(Geometry geometry)
      : geo(geometry), geoValid(geometry.valid()),
        resyncAfter((uint16_t)(2 * geometry.tileCount())) {}

  /// Validate/decode a record before mutating frame-completion state. A bad
  /// payload can therefore be retried without being misclassified as a
  /// duplicate or contributing to a false completed frame.
  template <typename Validate>
  Action onRecordIfValid(const Header &h, uint16_t start, uint8_t length,
                         Validate validate, bool &droppedFrame) {
    droppedFrame = false;
    if (!validate()) return Action::Reject;
    return onRecord(h, start, length, droppedFrame);
  }

  Action onRecord(const Header &h, uint16_t start, uint8_t length,
                  bool &droppedFrame) {
    droppedFrame = false;
    if (!geoValid || h.dirtyTileCount == 0 ||
        h.dirtyTileCount > geo.tileCount() || !geo.runValid(start, length)) {
      return Action::Reject;
    }
    if (!active) {
      adopt(h);
    } else if (h.frameId != frameId) {
      const int16_t diff = (int16_t)(h.frameId - frameId);
      if (diff <= 0 && ++staleStreak < resyncAfter) {
        return Action::IgnoreStale;
      }
      droppedFrame = seen > 0;
      adopt(h);
    } else if (h.dirtyTileCount != expected || h.landscape != landscape) {
      return Action::Reject;
    }
    staleStreak = 0;
    uint16_t added = 0;
    for (uint16_t tile = start; tile < (uint16_t)(start + length); ++tile) {
      const uint8_t bit = (uint8_t)(1u << (tile & 7));
      if ((bitmap[tile >> 3] & bit) == 0) ++added;
    }
    if (added == 0) return Action::Duplicate;
    if ((uint32_t)seen + added > expected) return Action::Reject;
    for (uint16_t tile = start; tile < (uint16_t)(start + length); ++tile) {
      bitmap[tile >> 3] |= (uint8_t)(1u << (tile & 7));
    }
    seen = (uint16_t)(seen + added);
    if (seen >= expected) {
      active = false;
      return Action::ApplyComplete;
    }
    return Action::Apply;
  }

 private:
  void adopt(const Header &h) {
    frameId = h.frameId;
    expected = h.dirtyTileCount;
    seen = 0;
    landscape = h.landscape;
    active = true;
    memset(bitmap, 0, sizeof(bitmap));
  }
  Geometry geo;
  bool geoValid;
  uint16_t resyncAfter;
  uint16_t frameId = 0;
  uint16_t expected = 0;
  uint16_t seen = 0;
  uint16_t staleStreak = 0;
  bool active = false;
  bool landscape = false;
  uint8_t bitmap[BITMAP_BYTES] = {0};
};

template <typename F>
inline void forEachRowRun(const uint8_t *bitmap, const Geometry &geometry,
                          F fn) {
  for (uint16_t row = 0; row < geometry.tileRows(); ++row) {
    uint16_t col = 0;
    while (col < geometry.tileCols()) {
      uint16_t tile = (uint16_t)(row * geometry.tileCols() + col);
      if ((bitmap[tile >> 3] & (1u << (tile & 7))) == 0) {
        ++col;
        continue;
      }
      const uint16_t start = col;
      while (col < geometry.tileCols()) {
        tile = (uint16_t)(row * geometry.tileCols() + col);
        if ((bitmap[tile >> 3] & (1u << (tile & 7))) == 0) break;
        ++col;
      }
      fn(row, start, col);
    }
  }
}

}  // namespace largetileproto
