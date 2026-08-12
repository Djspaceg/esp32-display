// Band-stream protocol logic, portable and hardware-free so it can be unit
// tested on the host (see firmware/test/). The Arduino sketch does the I/O
// (UDP, buffers, DMA); everything decision-shaped lives here.
//
// Wire format per packet:
//   [frame_id u16 LE][band_index u16 LE][dirty_count u16 LE][band payload]
// where bit 15 of dirty_count carries orientation (1 = landscape) and
// dirty_count is the number of bands in THIS frame. Bands are
// orientation-native so they align to whole rows.
//
// band_index uses only its low 10 bits for the index (MAX_BANDS is 512).
// Bit 15 set marks a PACKED packet - the payload is band records rather
// than one raw band; see "Packed band packets" below - and bits 14..10 are
// reserved and must be zero. A sender may only emit packed packets to a
// receiver advertising CAP_COMPRESSED_BANDS; everything else on the wire is
// byte-identical to the original format, which is what keeps old panels and
// old senders interoperating with no version bump.
//
// Band geometry is derived from panel dimensions rather than hardcoded, so
// one protocol serves panels of different resolutions (the 172x320 1.47"
// LCDs, the 466x466 AMOLEDs, and whatever comes next). Both ends run the
// same arithmetic: rows per band is however many whole rows fit the packet
// budget, and the last band may be short when the height does not divide
// evenly. For the original 172x320 panels the derived layout is byte
// identical to the historical hardcoded one (80 bands x 4 rows x 344B
// portrait, 86 x 2 x 640B landscape), which the host tests pin down so the
// generalization cannot silently change the wire format for shipped panels.
// The Mac mirrors this arithmetic in BandProtocol.swift.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace bandproto {

static const size_t HEADER_BYTES = 6;

/// Whole-packet budget, header included. Conservatively below the practical
/// WiFi UDP MTU. Both ends must agree on it because rows-per-band is derived
/// from it; changing it changes the wire format for every panel at once.
static const size_t MAX_PACKET_BYTES = 1400;

/// Ceiling on bands any supported geometry may produce, sizing the
/// reassembler bitmap. Panels wider than 348px take one-row bands, so band
/// count equals panel height there: 466x466 -> 466 bands, 480x480 -> 480.
/// 512 covers the roadmap and costs 64 bytes of bitmap.
static const uint16_t MAX_BANDS = 512;
static const size_t BITMAP_BYTES = (MAX_BANDS + 7) / 8;

/// A panel's native (portrait) pixel dimensions, plus the band layout that
/// follows from them. Pure arithmetic, cheap to pass by value.
///
/// Callers must only index bands below bandCount(); bandRows/bandPayloadBytes
/// do not range-check their index.
struct Geometry {
  uint16_t width;   // native (portrait) frame width, px
  uint16_t height;  // native frame height, px

  uint16_t frameWidth(bool landscape) const {
    return landscape ? height : width;
  }
  uint16_t frameHeight(bool landscape) const {
    return landscape ? width : height;
  }
  size_t rowBytes(bool landscape) const {
    return (size_t)frameWidth(landscape) * 2;  // RGB565
  }
  size_t frameBytes() const { return (size_t)width * (size_t)height * 2; }

  /// Whole rows per band: as many as fit the packet budget, at least one.
  int rowsPerBand(bool landscape) const {
    size_t fit = (MAX_PACKET_BYTES - HEADER_BYTES) / rowBytes(landscape);
    return fit < 1 ? 1 : (int)fit;
  }

  uint16_t bandCount(bool landscape) const {
    int rpb = rowsPerBand(landscape);
    return (uint16_t)(((int)frameHeight(landscape) + rpb - 1) / rpb);
  }

  /// Rows in one band: rowsPerBand everywhere except a final short band when
  /// the height does not divide evenly.
  int bandRows(uint16_t index, bool landscape) const {
    int rpb = rowsPerBand(landscape);
    uint16_t bands = bandCount(landscape);
    if ((uint16_t)(index + 1) < bands) return rpb;
    return (int)frameHeight(landscape) - (int)(bands - 1) * rpb;
  }

  size_t bandPayloadBytes(uint16_t index, bool landscape) const {
    return (size_t)bandRows(index, landscape) * rowBytes(landscape);
  }

  /// Byte offset of a band within the frame buffer. Bands are whole-row
  /// groups, so this is also a row-aligned pixel offset.
  size_t bandOffset(uint16_t index, bool landscape) const {
    return (size_t)index * (size_t)rowsPerBand(landscape) *
           rowBytes(landscape);
  }

  /// Largest band count across orientations. Per-band storage and the
  /// sender-restart resync threshold must cover whichever orientation
  /// produces more bands. Square panels produce the same count both ways.
  uint16_t maxBandCount() const {
    uint16_t p = bandCount(false);
    uint16_t l = bandCount(true);
    return p > l ? p : l;
  }

  /// Whether the protocol can carry this geometry at all: nonzero, every row
  /// fits a packet (width and height at most 697px), and the bitmap can track
  /// every band in either orientation.
  bool valid() const {
    if (width == 0 || height == 0) return false;
    if (rowBytes(false) > MAX_PACKET_BYTES - HEADER_BYTES) return false;
    if (rowBytes(true) > MAX_PACKET_BYTES - HEADER_BYTES) return false;
    return bandCount(false) <= MAX_BANDS && bandCount(true) <= MAX_BANDS;
  }
};

/// The original 1.47" panels (ESP32-C6-LCD-1.47 and -Touch-LCD-1.47). Named
/// here because the host tests pin its derived layout to the historic wire
/// format; the sketches take their geometry from the board table.
static const Geometry GEOMETRY_172X320 = {172, 320};

// ---- Packed band packets -------------------------------------------------
// With RLE compression a band is variable-length, so one datagram can carry
// several. A packed packet (band_index bit 15 set) holds records for its
// frame's bands, each record its own band index - dirty bands are usually
// scattered, so consecutive-only packing would waste most of the win:
//
//   [frame_id u16][first_band | 0x8000 u16][dirty_count u16, bit15=landscape]
//   then per record:
//     [band u16 LE, bits 15..10 zero][len u16 LE, bit15 = compressed]
//     [len & 0x7FFF payload bytes]
//
// A compressed record's payload is rle565 data that must decode to exactly
// the band's raw size; a raw record's length must equal it. first_band must
// equal the first record's band, a cheap cross-check on the two layouts
// agreeing. The packed budget is larger than MAX_PACKET_BYTES: that constant
// derives band geometry and cannot move without changing every panel's wire
// format, whereas this one only bounds a datagram no old peer ever sees.
// 1472 = the conservative 1500-byte Ethernet MTU minus IP+UDP headers.
static const size_t MAX_PACKED_PACKET_BYTES = 1472;
static const uint16_t BAND_INDEX_PACKED = 0x8000;
static const uint16_t BAND_INDEX_RESERVED_MASK = 0x7C00;  // must be zero
static const uint16_t BAND_INDEX_VALUE_MASK = 0x03FF;
static const size_t RECORD_HEADER_BYTES = 4;
static const uint16_t RECORD_COMPRESSED = 0x8000;
static const uint16_t RECORD_LENGTH_MASK = 0x7FFF;

struct Header {
  uint16_t frameId;
  uint16_t bandIndex;   // low 10 bits only; flag/reserved bits stripped
  uint16_t dirtyCount;
  bool landscape;
  bool packed;          // band_index bit 15: payload is band records
  bool reservedBitsSet; // band_index bits 14..10 nonzero: reject the packet
};

inline Header parseHeader(const uint8_t *d) {
  Header h;
  h.frameId = (uint16_t)d[0] | ((uint16_t)d[1] << 8);
  uint16_t indexField = (uint16_t)d[2] | ((uint16_t)d[3] << 8);
  h.packed = (indexField & BAND_INDEX_PACKED) != 0;
  h.reservedBitsSet = (indexField & BAND_INDEX_RESERVED_MASK) != 0;
  h.bandIndex = indexField & BAND_INDEX_VALUE_MASK;
  uint16_t countField = (uint16_t)d[4] | ((uint16_t)d[5] << 8);
  h.landscape = (countField & 0x8000) != 0;
  h.dirtyCount = countField & 0x7FFF;
  return h;
}

/// Walk the records of a packed payload (the bytes after the 6-byte packet
/// header). Calls fn(bandIndex, compressed, payload, payloadLen) per record;
/// fn returns false to reject the record, which aborts the walk.
///
/// Returns false when the payload is structurally invalid - empty, a record
/// header that overruns, reserved band bits set, a record body past the end,
/// trailing bytes shorter than a record header - or when fn rejected one.
/// Structural checks happen per record BEFORE fn sees it, so a decoder
/// behind fn is never handed a length that lies about the buffer.
template <typename F>
inline bool forEachPackedRecord(const uint8_t *payload, size_t len, F fn) {
  if (len < RECORD_HEADER_BYTES) return false;
  size_t at = 0;
  while (at < len) {
    if (at + RECORD_HEADER_BYTES > len) return false;
    uint16_t bandField =
        (uint16_t)payload[at] | ((uint16_t)payload[at + 1] << 8);
    uint16_t lenField =
        (uint16_t)payload[at + 2] | ((uint16_t)payload[at + 3] << 8);
    if ((bandField & ~BAND_INDEX_VALUE_MASK) != 0) return false;
    const bool compressed = (lenField & RECORD_COMPRESSED) != 0;
    const size_t bodyLen = lenField & RECORD_LENGTH_MASK;
    at += RECORD_HEADER_BYTES;
    if (bodyLen == 0 || at + bodyLen > len) return false;
    if (!fn(bandField, compressed, payload + at, bodyLen)) return false;
    at += bodyLen;
  }
  return true;
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
//   "Persistent" is two frames' worth of chunks for THIS panel's geometry,
//   so the timeout scales with resolution instead of stretching on big
//   panels or hair-triggering on small ones.
// - Duplicate bands (802.11 retry artifacts) must not double-count toward
//   completion.
class Reassembler {
 public:
  explicit Reassembler(Geometry geometry)
      : geo(geometry),
        geoValid(geometry.valid()),
        resyncAfter((uint16_t)(2 * geometry.maxBandCount())) {}

  // droppedFrame is set when adopting a new frame abandoned a partial one
  // (its bands stay pending for drawing - per-band recency).
  ChunkAction onChunk(const Header &h, bool &droppedFrame) {
    droppedFrame = false;
    if (!geoValid) {
      return ChunkAction::Reject;
    }
    uint16_t totalBands = geo.bandCount(h.landscape);
    if (h.dirtyCount == 0 || h.dirtyCount > totalBands ||
        h.bandIndex >= totalBands) {
      return ChunkAction::Reject;
    }

    if (!frameActive) {
      adopt(h);
    } else if (h.frameId != frameId) {
      int16_t diff = (int16_t)(h.frameId - frameId);
      if (diff <= 0) {
        if (++staleStreak < resyncAfter) {
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
  const Geometry &geometry() const { return geo; }

 private:
  void adopt(const Header &h) {
    frameId = h.frameId;
    bandsSeen = 0;
    bandsExpected = h.dirtyCount;
    frameLandscape = h.landscape;
    frameActive = true;
    memset(bitmap, 0, sizeof(bitmap));
  }

  const Geometry geo;
  const bool geoValid;
  const uint16_t resyncAfter;
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
