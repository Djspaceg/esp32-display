// Tile-stream protocol logic, portable and hardware-free so it can be unit
// tested on the host (see firmware/test/). The Arduino sketch does the I/O
// (UDP, buffers, DMA); everything decision-shaped lives here. The Mac
// mirrors this arithmetic in TileProtocol.swift; both suites assert the
// wire independently, never via a shared fixture.
//
// This is the successor to the band protocol for square AMOLED panels
// (advertised by CAP_TILE_STREAM, gated on board::Variant::AmoledCo5300):
// instead of full-width one-row bands, the frame is a grid of 16x16 tiles
// and only dirty tiles travel, each run of adjacent dirty tiles encoded
// with whichever codec is smallest (raw, RLE565, or BC1). Panels without
// the capability keep the band protocol byte-for-byte; nothing here touches
// that wire format.
//
// Wire format per packet:
//   [frame_id u16 LE][first_tile u16 LE][dirty_count u16 LE]
// first_tile bit 15 is ALWAYS set (a tile packet is never a valid band
// packet; the firmware only enables one protocol per board, this is a
// cheap cross-check), bits 14..10 are reserved and must be zero, bits 9..0
// are the first record's starting tile - a cross-check against the first
// record, like the band header's first_band. dirty_count bit 15 carries
// orientation (1 = landscape; the square glass makes it bookkeeping, not
// geometry), bits 14..0 the number of dirty TILES in this frame.
//
// Then records, packed greedily to the datagram budget:
//   [tile u16 LE: bits 9..0 start index, bits 14..10 run length - 1,
//    bit 15 reserved-0]
//   [len u16 LE: bits 13..0 payload bytes, bits 15..14 codec]
//   [payload]
// A record covers 1..32 horizontally adjacent tiles in ONE tile-row (never
// crossing a row boundary), its payload the run's rectangle rasterized
// row-major in big-endian RGB565. Codecs: 0 = raw, 1 = RLE565, 2 = BC1,
// 3 = reserved (future: half-res motion mode). A record never spans
// datagrams - the sender splits runs so each record fits one packet.
//
// Tile geometry is derived from panel dimensions like band geometry is: a
// 466x466 panel gives a 30x30 grid whose last column and row are 2 px
// (466 = 29*16 + 2). The grid is orientation-independent - this protocol
// only ships on square glass, where rotation changes nothing about layout.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace tileproto {

static const size_t HEADER_BYTES = 6;

/// Whole-datagram budget, header included. Matches the packed band budget
/// (and the Ethernet MTU minus IP+UDP): the receive-path ceiling is
/// datagrams per second, so records are packed to fill this.
static const size_t MAX_PACKET_BYTES = 1472;

/// Tiles are 16x16 px (except the frame's last column/row, which may be
/// smaller). Chosen in docs/tile-stream-plan.md: small enough that a tiny
/// dirty region costs ~512 B instead of a 932 B full-width band, large
/// enough that record overhead stays negligible.
static const uint16_t TILE_DIM = 16;

/// Ceiling on tiles any supported geometry may produce, sizing the
/// reassembler bitmap and matching the 10-bit index field. A 466x466 or
/// 480x480 panel is 900 tiles; 1024 covers the roadmap in 128 bytes.
static const uint16_t MAX_TILES = 1024;
static const size_t TILE_BITMAP_BYTES = (MAX_TILES + 7) / 8;

/// Longest run one record can express: 5 bits of (length - 1). 32 covers
/// the 30-column grid of every square panel on the roadmap.
static const uint16_t MAX_RUN_TILES = 32;

static const uint16_t FIRST_TILE_STREAM_FLAG = 0x8000;
static const uint16_t FIRST_TILE_RESERVED_MASK = 0x7C00;  // must be zero
static const uint16_t TILE_INDEX_MASK = 0x03FF;

static const size_t RECORD_HEADER_BYTES = 4;
static const uint16_t RECORD_RESERVED_BIT = 0x8000;  // tile field bit 15
static const uint16_t RECORD_RUN_MASK = 0x7C00;
static const int RECORD_RUN_SHIFT = 10;
static const uint16_t RECORD_LENGTH_MASK = 0x3FFF;
static const int RECORD_CODEC_SHIFT = 14;

/// Codec values for a record's len field bits 15..14. All four are now
/// defined, so the field is full; a fifth codec would need a header change.
enum class TileCodec : uint8_t {
  Raw = 0,
  Rle565 = 1,
  Bc1 = 2,
  /// Half-resolution BC1 (docs/tile-stream-plan.md section 16): the payload
  /// is BC1 of a halfDim(w) x halfDim(h) raster, which the receiver decodes
  /// and PIXEL-DOUBLES to the run's true w x h. ~4x smaller than Bc1 for a
  /// ~16:1 total ratio, which is what makes majority-of-screen motion fit
  /// the datagram ceiling (66 datagrams per full frame becomes ~17).
  ///
  /// How the sender chose those half-res pixels is deliberately NOT part of
  /// the wire contract - it may decimate, box-filter, or anything else. The
  /// receiver's obligation is only the pixel-doubling, so the sender can
  /// improve its downsample filter without a protocol change. Gated by
  /// CAP_TILE_HALFRES: a sender must not emit this to a panel that did not
  /// advertise it, because older firmware rejects the record (and with it
  /// the whole datagram).
  HalfBc1 = 3,
};

/// Half-resolution size of one raster axis: ceil(d / 2). The one rounding
/// rule for HalfBc1, stated once so the encoder, the decoder, and both
/// suites cannot disagree about a 2 px edge tile (2 -> 1) or an odd width.
inline uint16_t halfDim(uint16_t d) { return (uint16_t)((d + 1) / 2); }

/// Expand a halfW x halfH big-endian RGB565 raster into a w x h one by
/// pixel-doubling: dst(x, y) = src(x / 2, y / 2). The receive half of
/// TileCodec::HalfBc1.
///
/// SECURITY: this runs on the network path, on dimensions derived from an
/// unauthenticated datagram's claimed run. Rather than trust that halfW and
/// halfH relate to w and h correctly, it REQUIRES the exact halfDim
/// relationship and refuses anything else - so a caller that computed the
/// half dimensions differently from the encoder gets a rejection, not a
/// buffer overrun. dst must have room for w * h * 2 bytes and src must hold
/// halfW * halfH * 2; given the dimension check, every read is inside src
/// and every write inside dst.
inline bool pixelDouble(const uint8_t *src, uint16_t halfW, uint16_t halfH,
                        uint8_t *dst, uint16_t w, uint16_t h) {
  if (w == 0 || h == 0) return false;
  if (halfW != halfDim(w) || halfH != halfDim(h)) return false;
  for (uint16_t r = 0; r < h; r++) {
    const uint8_t *srcRow = src + (size_t)(r / 2) * halfW * 2;
    uint8_t *dstRow = dst + (size_t)r * w * 2;
    for (uint16_t x = 0; x < w; x++) {
      const uint8_t *s = srcRow + (size_t)(x / 2) * 2;
      dstRow[(size_t)x * 2] = s[0];
      dstRow[(size_t)x * 2 + 1] = s[1];
    }
  }
  return true;
}

/// A panel's native pixel dimensions, plus the tile grid that follows from
/// them. Pure arithmetic, cheap to pass by value. Callers must only index
/// tiles below tileCount(); the per-tile accessors do not range-check.
struct TileGeometry {
  uint16_t width;
  uint16_t height;

  uint16_t tileCols() const {
    return (uint16_t)((width + TILE_DIM - 1) / TILE_DIM);
  }
  uint16_t tileRows() const {
    return (uint16_t)((height + TILE_DIM - 1) / TILE_DIM);
  }
  uint16_t tileCount() const { return (uint16_t)(tileCols() * tileRows()); }
  size_t frameBytes() const { return (size_t)width * (size_t)height * 2; }

  uint16_t col(uint16_t tile) const { return (uint16_t)(tile % tileCols()); }
  uint16_t row(uint16_t tile) const { return (uint16_t)(tile / tileCols()); }

  /// Pixel width of one tile column: TILE_DIM everywhere except a short
  /// last column when width does not divide evenly (466 -> 2 px).
  uint16_t colWidth(uint16_t c) const {
    uint16_t x0 = (uint16_t)(c * TILE_DIM);
    uint16_t remain = (uint16_t)(width - x0);
    return remain < TILE_DIM ? remain : TILE_DIM;
  }

  /// Pixel height of one tile row, same rule as colWidth.
  uint16_t rowHeight(uint16_t r) const {
    uint16_t y0 = (uint16_t)(r * TILE_DIM);
    uint16_t remain = (uint16_t)(height - y0);
    return remain < TILE_DIM ? remain : TILE_DIM;
  }

  /// Whether a record's run is expressible on this grid: a nonzero length
  /// that stays inside one tile-row. Everything a hostile record could
  /// claim about placement funnels through this one predicate.
  bool runValid(uint16_t startTile, uint16_t runLen) const {
    if (runLen == 0 || runLen > MAX_RUN_TILES) return false;
    if (startTile >= tileCount()) return false;
    return (uint16_t)(col(startTile) + runLen) <= tileCols();
  }

  /// Pixel width of a run: the sum of its tile column widths (only the
  /// frame's last column can be short, so this is a clamp, not a loop).
  uint16_t runPixelWidth(uint16_t startTile, uint16_t runLen) const {
    uint16_t x0 = (uint16_t)(col(startTile) * TILE_DIM);
    uint32_t x1 = (uint32_t)(col(startTile) + runLen) * TILE_DIM;
    if (x1 > width) x1 = width;
    return (uint16_t)(x1 - x0);
  }

  /// Raw (decoded) byte size of a run's raster: width x row height x 2.
  /// Computable from geometry alone, which is what lets the receiver
  /// refuse any payload that does not decode to exactly this size.
  size_t runRawBytes(uint16_t startTile, uint16_t runLen) const {
    return (size_t)runPixelWidth(startTile, runLen) *
           rowHeight(row(startTile)) * 2;
  }

  /// Whether the protocol can carry this geometry: nonzero dimensions, the
  /// grid fits the 10-bit index space, a full row of tiles is expressible
  /// as one run length, and the widest possible raw run fits a record's
  /// 14-bit length field (so "raw, always applicable" stays true).
  bool valid() const {
    if (width == 0 || height == 0) return false;
    if (tileCols() > MAX_RUN_TILES) return false;
    if (tileCount() > MAX_TILES) return false;
    return (size_t)width * TILE_DIM * 2 <= RECORD_LENGTH_MASK;
  }
};

/// The 1.75" AMOLED (ESP32-S3-Touch-AMOLED-1.75C), the only board that
/// advertises CAP_TILE_STREAM today. Named because the host tests pin its
/// derived grid; the sketch takes its geometry from the board table.
static const TileGeometry GEOMETRY_466X466 = {466, 466};

struct TileHeader {
  uint16_t frameId;
  uint16_t firstTile;    // low 10 bits only; flag/reserved bits stripped
  uint16_t dirtyCount;   // dirty TILES in this frame
  bool landscape;
  bool streamFlagSet;    // first_tile bit 15: must be set on every packet
  bool reservedBitsSet;  // first_tile bits 14..10 nonzero: reject
};

inline TileHeader parseHeader(const uint8_t *d) {
  TileHeader h;
  h.frameId = (uint16_t)d[0] | ((uint16_t)d[1] << 8);
  uint16_t tileField = (uint16_t)d[2] | ((uint16_t)d[3] << 8);
  h.streamFlagSet = (tileField & FIRST_TILE_STREAM_FLAG) != 0;
  h.reservedBitsSet = (tileField & FIRST_TILE_RESERVED_MASK) != 0;
  h.firstTile = tileField & TILE_INDEX_MASK;
  uint16_t countField = (uint16_t)d[4] | ((uint16_t)d[5] << 8);
  h.landscape = (countField & 0x8000) != 0;
  h.dirtyCount = countField & 0x7FFF;
  return h;
}

/// Walk the records of a packet payload (the bytes after the 6-byte
/// header). Calls fn(startTile, runLen, codec, payload, payloadLen) per
/// record; fn returns false to reject the record, which aborts the walk.
///
/// Returns false when the payload is structurally invalid - empty, a
/// record header that overruns, the reserved tile bit set, a record body
/// past the end, a zero-length body - or when fn rejected one. Structural
/// checks happen per record BEFORE fn sees it, so a decoder behind fn is
/// never handed a length that lies about the buffer. Geometry-dependent
/// validity (run inside the grid, payload decodes to the run's size) is
/// fn's business - the walker knows bytes, not panels.
template <typename F>
inline bool forEachRecord(const uint8_t *payload, size_t len, F fn) {
  if (len < RECORD_HEADER_BYTES) return false;
  size_t at = 0;
  while (at < len) {
    if (at + RECORD_HEADER_BYTES > len) return false;
    uint16_t tileField =
        (uint16_t)payload[at] | ((uint16_t)payload[at + 1] << 8);
    uint16_t lenField =
        (uint16_t)payload[at + 2] | ((uint16_t)payload[at + 3] << 8);
    if ((tileField & RECORD_RESERVED_BIT) != 0) return false;
    const uint16_t startTile = tileField & TILE_INDEX_MASK;
    const uint16_t runLen =
        (uint16_t)(((tileField & RECORD_RUN_MASK) >> RECORD_RUN_SHIFT) + 1);
    const TileCodec codec = (TileCodec)(lenField >> RECORD_CODEC_SHIFT);
    const size_t bodyLen = lenField & RECORD_LENGTH_MASK;
    at += RECORD_HEADER_BYTES;
    if (bodyLen == 0 || at + bodyLen > len) return false;
    if (!fn(startTile, runLen, codec, payload + at, bodyLen)) return false;
    at += bodyLen;
  }
  return true;
}

enum class RecordAction : uint8_t {
  Reject,         // invalid run/count for this geometry: drop silently
  IgnoreStale,    // late record of an already-superseded frame
  Duplicate,      // every tile of this run already arrived for this frame
  Apply,          // copy the payload into the frame buffer
  ApplyComplete,  // as Apply, and the frame is now complete
};

// Tracks per-frame reassembly state. Same hard-won rules as
// bandproto::Reassembler, restated per record instead of per band:
// - Wraparound-aware ordering: only a NEWER frame id abandons the current
//   one; late WiFi retransmissions of older frames are ignored.
// - A persistent stream of "stale" ids means the sender restarted: force
//   resync after two frames' worth of records for THIS panel's grid.
// - Duplicate runs (802.11 retry artifacts) must not double-count toward
//   completion; a run only counts the tiles it newly covers.
class Reassembler {
 public:
  explicit Reassembler(TileGeometry geometry)
      : geo(geometry),
        geoValid(geometry.valid()),
        resyncAfter((uint16_t)(2 * geometry.tileCount())) {}

  // droppedFrame is set when adopting a new frame abandoned a partial one
  // (its tiles stay pending for drawing - per-tile recency).
  RecordAction onRecord(const TileHeader &h, uint16_t startTile,
                        uint16_t runLen, bool &droppedFrame) {
    droppedFrame = false;
    if (!geoValid) {
      return RecordAction::Reject;
    }
    if (h.dirtyCount == 0 || h.dirtyCount > geo.tileCount() ||
        !geo.runValid(startTile, runLen)) {
      return RecordAction::Reject;
    }

    if (!frameActive) {
      adopt(h);
    } else if (h.frameId != frameId) {
      int16_t diff = (int16_t)(h.frameId - frameId);
      if (diff <= 0) {
        if (++staleStreak < resyncAfter) {
          return RecordAction::IgnoreStale;
        }
        // Sender restart: fall through and adopt.
      }
      if (tilesSeen > 0) {
        droppedFrame = true;
      }
      adopt(h);
    }
    staleStreak = 0;

    uint16_t newlyCovered = 0;
    for (uint16_t t = startTile; t < startTile + runLen; t++) {
      uint8_t mask = (uint8_t)(1 << (t & 7));
      if (!(bitmap[t >> 3] & mask)) {
        bitmap[t >> 3] |= mask;
        newlyCovered++;
      }
    }
    if (newlyCovered == 0) {
      return RecordAction::Duplicate;
    }
    tilesSeen = (uint16_t)(tilesSeen + newlyCovered);

    if (tilesSeen >= tilesExpected) {
      frameActive = false;
      return RecordAction::ApplyComplete;
    }
    return RecordAction::Apply;
  }

  bool landscape() const { return frameLandscape; }
  const TileGeometry &geometry() const { return geo; }

 private:
  void adopt(const TileHeader &h) {
    frameId = h.frameId;
    tilesSeen = 0;
    tilesExpected = h.dirtyCount;
    frameLandscape = h.landscape;
    frameActive = true;
    memset(bitmap, 0, sizeof(bitmap));
  }

  const TileGeometry geo;
  const bool geoValid;
  const uint16_t resyncAfter;
  uint16_t frameId = 0;
  uint16_t tilesSeen = 0;
  uint16_t tilesExpected = 0;
  uint16_t staleStreak = 0;
  bool frameActive = false;
  bool frameLandscape = false;
  uint8_t bitmap[TILE_BITMAP_BYTES] = {0};
};

/// Invoke fn(row, colStart, colEndExclusive) for each horizontal run of set
/// bits within each tile-row of a tile bitmap. Runs never cross a tile-row
/// boundary - each becomes one strided copy + one draw_bitmap rect, which
/// is what makes the ~150 us fixed draw-call cost affordable (phase 0
/// measured 900 per-tile draws at 7 fps; merged runs are mandatory).
template <typename F>
inline void forEachRowRun(const uint8_t *bits, const TileGeometry &geo,
                          F fn) {
  const uint16_t cols = geo.tileCols();
  const uint16_t rows = geo.tileRows();
  for (uint16_t r = 0; r < rows; r++) {
    uint16_t c = 0;
    while (c < cols) {
      const uint16_t tile = (uint16_t)(r * cols + c);
      if (!(bits[tile >> 3] & (1 << (tile & 7)))) {
        c++;
        continue;
      }
      uint16_t start = c;
      while (c < cols) {
        const uint16_t t = (uint16_t)(r * cols + c);
        if (!(bits[t >> 3] & (1 << (t & 7)))) break;
        c++;
      }
      fn(r, start, c);
    }
  }
}

}  // namespace tileproto
