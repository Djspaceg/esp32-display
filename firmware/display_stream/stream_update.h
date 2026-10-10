// Firmware update over the stream channel: the packets, and the receiver's
// every decision. Pure and hardware-free, so the host tests drive the exact
// code the panel runs (test/test_stream_update.cpp).
//
// WHY THIS EXISTS. ArduinoOTA needs the panel to open a TCP connection back
// to the Mac, and a Mac whose firewall drops connections the LAN starts can
// never be updated that way. The stream channel is a flow the Mac starts
// (UDP to UDP_PORT, replies to its source endpoint), so it already passes.
// These packets ride that same flow, on the same socket the frames use.
//
// WHY NOT STOP-AND-WAIT. A lock-step transfer pays a WiFi round trip per
// chunk. Here the sender keeps a window of chunks in flight; the panel files
// each one into a slot by sequence number, acknowledges cumulatively plus a
// 64-chunk selective bitmap, and writes slots to flash in order from loop().
// Loss, duplication and reordering cost a retransmit of the missing chunk
// only. The window the panel advertises is the free slot space, so a flash
// erase stall throttles the sender instead of dropping its datagrams.
//
// SAFETY, in the order it is enforced:
//   - Nothing is buffered, let alone written, before the same PBKDF2-SHA256
//     challenge ArduinoOTA uses has been answered for this session.
//   - Every chunk carries a CRC32 of its payload and its exact length; a
//     mismatch is dropped unacknowledged, so the sender resends it.
//   - The image's SHA-256 travels in BEGIN. Every byte written is hashed in
//     order, and only a matching digest reaches Activate (Update.end, which
//     is where the boot partition changes). A mismatch reaches Abort.
//   - Update itself withholds the image's first byte until end() succeeds,
//     so a transfer that stops anywhere short of Activate is never bootable.
//
// Wire format, all integers little-endian, every packet "EUP?" + version 1:
//
//   Mac -> panel
//   EUPB begin  [4]ver [5]0 [6]session u16 [8]imageBytes u32
//               [12]chunkBytes u16 [14]0 u16 [16]sha256 x32          48 bytes
//   EUPA auth   [4]ver [5]0 [6]session [8]cnonce hex x64
//               [72]response hex x64                                136 bytes
//   EUPD data   [4]ver [5]0 [6]session [8]seq u32 [12]crc32 u32 [16]payload
//   EUPX abort  [4]ver [5]0 [6]session                                8 bytes
//
//   panel -> Mac
//   EUPC challenge [4]ver [5]0 [6]session [8]chunkBytes u16 [10]0 u16
//                  [12]nonce hex x64                                 76 bytes
//   EUPK ack    [4]ver [5]phase [6]session [8]cumulative u32 (next missing
//               seq) [12]windowEnd u32 (exclusive) [16]sack u64 (bit i is
//               seq cumulative+1+i) [24]bytesWritten u32               28 bytes
//   EUPS status [4]ver [5]code [6]session [8]value u32 [12]detailLen
//               [13]detail ASCII (<= 48)
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace streamupdate {

static const uint8_t VERSION = 1;
static const size_t BEGIN_BYTES = 48;
static const size_t AUTH_BYTES = 136;
static const size_t DATA_HEADER_BYTES = 16;
static const size_t ABORT_BYTES = 8;
static const size_t CHALLENGE_BYTES = 76;
static const size_t ACK_BYTES = 28;
static const size_t STATUS_HEADER_BYTES = 13;
static const size_t STATUS_DETAIL_MAX = 48;
static const size_t STATUS_MAX_BYTES = STATUS_HEADER_BYTES + STATUS_DETAIL_MAX;
static const size_t HEX_DIGEST_CHARS = 64;
static const size_t SHA256_BYTES = 32;
static const size_t SACK_BITS = 64;

/// The most payload one DATA datagram may carry: 1440 + 16 header = 1456,
/// under the 1472-byte ceiling every frame datagram already respects.
static const uint16_t MAX_CHUNK_BYTES = 1440;
/// Below this the per-datagram cost dominates; refused rather than honoured.
static const uint16_t MIN_CHUNK_BYTES = 256;

/// The same derivation ArduinoOTA uses (ArduinoOTA.cpp:293). Not negotiable:
/// the Mac computes the response with EspotaProtocol.authResponse unchanged.
static const uint32_t PBKDF2_ITERATIONS = 10000;

/// How long a session may sit with nothing from its sender before the panel
/// gives up on it. Long enough for a sender's retransmit backoff, short
/// enough that a vanished Mac does not leave the progress screen up.
static const uint32_t SESSION_IDLE_TIMEOUT_MS = 10000;
/// A finished session's verdict is kept this long so a sender whose status
/// datagram was lost can still learn it by asking again.
static const uint32_t RESULT_HOLD_MS = 30000;
/// Between "activated" going out and the restart, so the verdict has time to
/// leave and to be repeated to a few of the sender's probes if it was lost.
static const uint32_t REBOOT_DELAY_MS = 1000;
/// Acks: one per this many newly filed chunks, at once for anything out of
/// order, and at least this often while receiving (a lost window update must
/// not strand a sender whose window is closed).
static const uint32_t ACK_EVERY_CHUNKS = 2;
static const uint32_t ACK_KEEPALIVE_MS = 100;
/// Window updates from flash writes are batched to at most one per this
/// long; a sender whose window is closed is told at once instead.
static const uint32_t ACK_WINDOW_BATCH_MS = 5;
/// How often an unknown session or a finished verdict is repeated in answer
/// to a stream of data, so a flood is not answered datagram for datagram.
static const uint32_t REPEAT_STATUS_MS = 100;

enum class Status : uint8_t {
  AuthAccepted = 1,    // value = first windowEnd; data may flow
  AuthRefused = 2,     // the password was wrong; session closed
  Busy = 3,            // another session owns the update
  NotConfigured = 4,   // no OTA password stored
  BadRequest = 5,      // size or chunk size refused; detail says which
  BeginFailed = 6,     // Update.begin refused; detail is its error
  WriteFailed = 7,     // a flash write failed; detail is its error
  HashMismatch = 8,    // every byte arrived and the SHA-256 differed
  ImageRefused = 9,    // Update.end refused the image; detail is its error
  Activated = 10,      // boot partition switched; restarting
  Aborted = 11,        // the sender aborted, or the session timed out
  UnknownSession = 12, // no such session here (restarted, or expired)
};

enum class Phase : uint8_t {
  Idle = 0,
  AwaitingAuth = 1,
  VerifyingAuth = 2,
  Beginning = 3,
  Receiving = 4,
  Finalizing = 5,
  Done = 6,
};

// ---- primitives ---------------------------------------------------------

inline uint16_t readU16(const uint8_t *p) {
  return (uint16_t)p[0] | (uint16_t)(p[1] << 8);
}
inline uint32_t readU32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}
inline void writeU16(uint8_t *p, uint16_t v) {
  p[0] = (uint8_t)v;
  p[1] = (uint8_t)(v >> 8);
}
inline void writeU32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)v;
  p[1] = (uint8_t)(v >> 8);
  p[2] = (uint8_t)(v >> 16);
  p[3] = (uint8_t)(v >> 24);
}

/// IEEE 802.3 CRC-32 (reflected, 0xEDB88320), the zlib/PNG one. Bitwise
/// rather than tabled: 1440 bytes is ~12k shifts, a few microseconds here.
inline uint32_t crc32(const uint8_t *data, size_t len) {
  uint32_t crc = 0xFFFFFFFFu;
  for (size_t i = 0; i < len; i++) {
    crc ^= data[i];
    for (int bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
  }
  return ~crc;
}

/// Bound on how far a stamp may run ahead of "now" and still read as 0 ms.
static const int32_t CLOCK_SKEW_MS = 1000;

/// Milliseconds from `then` to `now`, with a short backward skew read as 0.
///
/// The receiver is stamped from two tasks. Before this was fixed, loop()
/// sampled millis() before taking the lock, so a chunk the receive task filed
/// in between was stamped AFTER the loop's "now", and a plain `now - then`
/// wrapped to ~4.29e9: ten seconds of silence, read off a flooding sender,
/// which ended both WiFi updates on the 4C (2026-10-10). The service now reads
/// the clock under the lock, and this guards any skew that remains. Only a
/// skew under a second is clamped: a stamp more than 24.8 days old also looks
/// "ahead" in signed terms, and it must read as the long time it is.
inline uint32_t elapsedMs(uint32_t now, uint32_t then) {
  const int32_t d = (int32_t)(now - then);
  return (d < 0 && d > -CLOCK_SKEW_MS) ? 0u : now - then;
}

inline bool isLowerHex(const char *text, size_t len) {
  for (size_t i = 0; i < len; i++) {
    const char c = text[i];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
  }
  return true;
}

inline void toHex(const uint8_t *bytes, size_t len, char *out) {
  static const char digits[] = "0123456789abcdef";
  for (size_t i = 0; i < len; i++) {
    out[2 * i] = digits[bytes[i] >> 4];
    out[2 * i + 1] = digits[bytes[i] & 0x0F];
  }
  out[2 * len] = '\0';
}

/// Equal-time comparison of two 64-character responses, so how long the
/// refusal takes says nothing about how many leading characters were right.
inline bool sameDigestHex(const char *a, const char *b) {
  uint8_t diff = 0;
  for (size_t i = 0; i < HEX_DIGEST_CHARS; i++) {
    diff |= (uint8_t)(a[i] ^ b[i]);
  }
  return diff == 0;
}

/// The PBKDF2 salt, `nonce ":" cnonce`, exactly as ArduinoOTA builds it.
/// Returns the length written (129) or 0 if `capacity` cannot hold it.
inline size_t authSalt(char *out, size_t capacity, const char *nonce,
                       const char *cnonce) {
  const size_t needed = 2 * HEX_DIGEST_CHARS + 1;
  if (capacity < needed + 1) return 0;
  memcpy(out, nonce, HEX_DIGEST_CHARS);
  out[HEX_DIGEST_CHARS] = ':';
  memcpy(out + HEX_DIGEST_CHARS + 1, cnonce, HEX_DIGEST_CHARS);
  out[needed] = '\0';
  return needed;
}

/// What is hashed for the expected response, `derivedHex ":" nonce ":"
/// cnonce`. The derived key's HEX SPELLING is what goes in, as in the core.
inline size_t authChallenge(char *out, size_t capacity, const char *derivedHex,
                            const char *nonce, const char *cnonce) {
  const size_t needed = 3 * HEX_DIGEST_CHARS + 2;
  if (capacity < needed + 1) return 0;
  memcpy(out, derivedHex, HEX_DIGEST_CHARS);
  out[HEX_DIGEST_CHARS] = ':';
  memcpy(out + HEX_DIGEST_CHARS + 1, nonce, HEX_DIGEST_CHARS);
  out[2 * HEX_DIGEST_CHARS + 1] = ':';
  memcpy(out + 2 * HEX_DIGEST_CHARS + 2, cnonce, HEX_DIGEST_CHARS);
  out[needed] = '\0';
  return needed;
}

/// What the cnonce must be the SHA-256 hex of: `imageSha256Hex ":" nonce`.
/// ArduinoOTA lets the cnonce be anything; binding it to the image the BEGIN
/// named means the password-derived response also vouches for that image,
/// so a BEGIN swapped in before the answer cannot borrow the answer.
/// EspotaProtocol.authResponse is unchanged; only its cnonce input is fixed.
inline size_t cnonceSeed(char *out, size_t capacity, const char *imageHex,
                         const char *nonce) {
  const size_t needed = 2 * HEX_DIGEST_CHARS + 1;
  if (capacity < needed + 1) return 0;
  memcpy(out, imageHex, HEX_DIGEST_CHARS);
  out[HEX_DIGEST_CHARS] = ':';
  memcpy(out + HEX_DIGEST_CHARS + 1, nonce, HEX_DIGEST_CHARS);
  out[needed] = '\0';
  return needed;
}

// ---- packets ------------------------------------------------------------

inline bool hasMagic(const uint8_t *data, size_t len) {
  return len >= 4 && data[0] == 'E' && data[1] == 'U' && data[2] == 'P';
}

inline void writeHead(uint8_t *out, char kind, uint8_t byte5,
                      uint16_t session) {
  out[0] = 'E';
  out[1] = 'U';
  out[2] = 'P';
  out[3] = (uint8_t)kind;
  out[4] = VERSION;
  out[5] = byte5;
  writeU16(out + 6, session);
}

inline bool headIs(const uint8_t *data, size_t len, char kind, size_t minLen) {
  return len >= minLen && hasMagic(data, len) && data[3] == (uint8_t)kind &&
         data[4] == VERSION;
}

struct Begin {
  uint16_t session;
  uint32_t imageBytes;
  uint16_t chunkBytes;
  uint8_t sha256[SHA256_BYTES];
};

inline size_t writeBegin(uint8_t out[BEGIN_BYTES], const Begin &b) {
  writeHead(out, 'B', 0, b.session);
  writeU32(out + 8, b.imageBytes);
  writeU16(out + 12, b.chunkBytes);
  writeU16(out + 14, 0);
  memcpy(out + 16, b.sha256, SHA256_BYTES);
  return BEGIN_BYTES;
}

inline bool parseBegin(const uint8_t *data, size_t len, Begin &out) {
  if (!headIs(data, len, 'B', BEGIN_BYTES) || len != BEGIN_BYTES) return false;
  out.session = readU16(data + 6);
  out.imageBytes = readU32(data + 8);
  out.chunkBytes = readU16(data + 12);
  memcpy(out.sha256, data + 16, SHA256_BYTES);
  return true;
}

struct Auth {
  uint16_t session;
  char cnonce[HEX_DIGEST_CHARS + 1];
  char response[HEX_DIGEST_CHARS + 1];
};

inline size_t writeAuth(uint8_t out[AUTH_BYTES], uint16_t session,
                        const char *cnonce, const char *response) {
  writeHead(out, 'A', 0, session);
  memcpy(out + 8, cnonce, HEX_DIGEST_CHARS);
  memcpy(out + 72, response, HEX_DIGEST_CHARS);
  return AUTH_BYTES;
}

/// Refuses anything but 64 lowercase hex digits in each field: the panel's
/// digests are lowercase, and a response that cannot match is not worth a
/// second of PBKDF2.
inline bool parseAuth(const uint8_t *data, size_t len, Auth &out) {
  if (!headIs(data, len, 'A', AUTH_BYTES) || len != AUTH_BYTES) return false;
  const char *cnonce = (const char *)data + 8;
  const char *response = (const char *)data + 72;
  if (!isLowerHex(cnonce, HEX_DIGEST_CHARS) ||
      !isLowerHex(response, HEX_DIGEST_CHARS)) {
    return false;
  }
  out.session = readU16(data + 6);
  memcpy(out.cnonce, cnonce, HEX_DIGEST_CHARS);
  out.cnonce[HEX_DIGEST_CHARS] = '\0';
  memcpy(out.response, response, HEX_DIGEST_CHARS);
  out.response[HEX_DIGEST_CHARS] = '\0';
  return true;
}

inline size_t writeDataHeader(uint8_t out[DATA_HEADER_BYTES], uint16_t session,
                              uint32_t seq, const uint8_t *payload,
                              size_t payloadLen) {
  writeHead(out, 'D', 0, session);
  writeU32(out + 8, seq);
  writeU32(out + 12, crc32(payload, payloadLen));
  return DATA_HEADER_BYTES;
}

inline size_t writeAbort(uint8_t out[ABORT_BYTES], uint16_t session) {
  writeHead(out, 'X', 0, session);
  return ABORT_BYTES;
}

inline size_t writeChallenge(uint8_t out[CHALLENGE_BYTES], uint16_t session,
                             uint16_t chunkBytes, const char *nonce) {
  writeHead(out, 'C', 0, session);
  writeU16(out + 8, chunkBytes);
  writeU16(out + 10, 0);
  memcpy(out + 12, nonce, HEX_DIGEST_CHARS);
  return CHALLENGE_BYTES;
}

struct Ack {
  Phase phase;
  uint16_t session;
  uint32_t cumulative;
  uint32_t windowEnd;
  uint64_t sack;
  uint32_t bytesWritten;
};

inline size_t writeAck(uint8_t out[ACK_BYTES], const Ack &a) {
  writeHead(out, 'K', (uint8_t)a.phase, a.session);
  writeU32(out + 8, a.cumulative);
  writeU32(out + 12, a.windowEnd);
  writeU32(out + 16, (uint32_t)a.sack);
  writeU32(out + 20, (uint32_t)(a.sack >> 32));
  writeU32(out + 24, a.bytesWritten);
  return ACK_BYTES;
}

inline bool parseAck(const uint8_t *data, size_t len, Ack &out) {
  if (!headIs(data, len, 'K', ACK_BYTES) || len != ACK_BYTES) return false;
  out.phase = (Phase)data[5];
  out.session = readU16(data + 6);
  out.cumulative = readU32(data + 8);
  out.windowEnd = readU32(data + 12);
  out.sack = (uint64_t)readU32(data + 16) | ((uint64_t)readU32(data + 20) << 32);
  out.bytesWritten = readU32(data + 24);
  return true;
}

/// Detail is clipped to STATUS_DETAIL_MAX and to printable ASCII, since it is
/// shown to the user verbatim.
inline size_t writeStatus(uint8_t *out, size_t capacity, Status code,
                          uint16_t session, uint32_t value,
                          const char *detail) {
  if (capacity < STATUS_MAX_BYTES) return 0;
  writeHead(out, 'S', (uint8_t)code, session);
  writeU32(out + 8, value);
  size_t n = 0;
  if (detail != nullptr) {
    while (n < STATUS_DETAIL_MAX && detail[n] != '\0') {
      const char c = detail[n];
      out[STATUS_HEADER_BYTES + n] = (c >= 0x20 && c <= 0x7E) ? (uint8_t)c : '?';
      n++;
    }
  }
  out[12] = (uint8_t)n;
  return STATUS_HEADER_BYTES + n;
}

struct StatusReply {
  Status code;
  uint16_t session;
  uint32_t value;
  char detail[STATUS_DETAIL_MAX + 1];
};

inline bool parseStatus(const uint8_t *data, size_t len, StatusReply &out) {
  if (!headIs(data, len, 'S', STATUS_HEADER_BYTES)) return false;
  const size_t n = data[12];
  if (n > STATUS_DETAIL_MAX || len != STATUS_HEADER_BYTES + n) return false;
  out.code = (Status)data[5];
  out.session = readU16(data + 6);
  out.value = readU32(data + 8);
  memcpy(out.detail, data + STATUS_HEADER_BYTES, n);
  out.detail[n] = '\0';
  return true;
}

// ---- the receiver -------------------------------------------------------

struct Endpoint {
  uint32_t ip = 0;
  uint16_t port = 0;
  bool operator==(const Endpoint &o) const {
    return ip == o.ip && port == o.port;
  }
  bool operator!=(const Endpoint &o) const { return !(*this == o); }
};

/// The image hash, over every byte in the order it is written. An interface
/// so the panel can use mbedtls and the host tests a reference digest.
class Hasher {
 public:
  virtual ~Hasher() {}
  virtual void reset() = 0;
  virtual void update(const uint8_t *data, size_t len) = 0;
  virtual void finish(uint8_t out[SHA256_BYTES]) = 0;
};

/// What loop() must do next, outside the lock. Exactly one kind at a time.
enum class Work : uint8_t {
  None,
  // PBKDF2 the stored hash against nonce/cnonce and compare with response,
  // then finishAuth(). Seconds of SHA-256; never on the receive path.
  VerifyAuth,
  // Allocate `slots` slots of slotBytes and Update.begin(imageBytes), then
  // finishBegin().
  Begin,
  // Update.write(data, len), then finishWrite(). The bytes are already
  // hashed; the slot is stable until finishWrite releases it.
  Write,
  // Update.end(): the digest matched. Then finishActivate().
  Activate,
  // Update.abort(), then finishAbort(). Reached from a digest mismatch, a
  // failed write, a sender abort or a timeout, whenever begin succeeded.
  Abort,
};

struct WorkItem {
  Work kind = Work::None;
  // VerifyAuth
  const char *nonce = nullptr;
  const char *cnonce = nullptr;
  const char *response = nullptr;
  // The cnonce must equal sha256hex(cnonceSeed(expectedHex, nonce)).
  const char *expectedHex = nullptr;
  // Begin
  uint32_t imageBytes = 0;
  uint16_t slots = 0;
  uint16_t slotBytes = 0;
  // Write
  uint32_t seq = 0;
  const uint8_t *data = nullptr;
  size_t len = 0;
};

/// Counters for the serial line and the tests; never on the wire.
struct Stats {
  uint32_t chunksFiled = 0;
  uint32_t duplicates = 0;
  uint32_t outOfOrder = 0;
  uint32_t outsideWindow = 0;
  uint32_t badChunks = 0;          // wrong length or CRC
  uint32_t refusedBeforeAuth = 0;  // data for a session not yet authenticated
  uint32_t foreign = 0;            // wrong session or endpoint
};

class Receiver {
 public:
  static const size_t OUTBOX_DEPTH = 6;

  struct Outgoing {
    Endpoint to;
    size_t len = 0;
    uint8_t bytes[STATUS_MAX_BYTES > CHALLENGE_BYTES ? STATUS_MAX_BYTES
                                                     : CHALLENGE_BYTES];
  };

  /// `maxImageBytes` is the inactive slot's size; `slotsWanted` how many
  /// chunks may be buffered ahead of flash. Neither changes per session.
  void configure(uint32_t maxImageBytes, uint16_t slotsWanted, Hasher *hasher) {
    maxImageBytes_ = maxImageBytes;
    slotsWanted_ = slotsWanted;
    hasher_ = hasher;
  }

  /// Arms the receiver with the stored password's SHA-256 hex, which is all
  /// ArduinoOTA keeps of it too. Nullptr disarms: every BEGIN is refused.
  void setPasswordHash(const char *hex) {
    if (hex == nullptr || strlen(hex) != HEX_DIGEST_CHARS) {
      armed_ = false;
      return;
    }
    memcpy(passwordHash_, hex, HEX_DIGEST_CHARS);
    passwordHash_[HEX_DIGEST_CHARS] = '\0';
    armed_ = true;
  }
  bool armed() const { return armed_; }
  const char *passwordHash() const { return passwordHash_; }

  // ---- the receive path ----

  /// Handle one datagram that hasMagic() claimed. `random32` is 32 fresh
  /// random bytes, used only if this turns out to be a new BEGIN. Replies
  /// are queued; drain them with popOutgoing() after releasing the lock.
  void onPacket(const uint8_t *data, size_t len, Endpoint from, uint32_t nowMs,
                const uint8_t random32[32]) {
    if (len < 8) return;
    switch (data[3]) {
      case 'B':
        onBegin(data, len, from, nowMs, random32);
        return;
      case 'A':
        onAuth(data, len, from, nowMs);
        return;
      case 'D':
        onData(data, len, from, nowMs);
        return;
      case 'X':
        onAbort(data, len, from, nowMs);
        return;
      default:
        return;  // a panel never receives C/K/S; an unknown kind is ignored
    }
  }

  bool popOutgoing(Outgoing &out) {
    if (outCount_ == 0) return false;
    out = outbox_[outHead_];
    outHead_ = (outHead_ + 1) % OUTBOX_DEPTH;
    outCount_--;
    return true;
  }

  // ---- the loop side ----

  /// Timeouts, keepalive acks, and the next piece of work, if any.
  WorkItem takeWork(uint32_t nowMs) {
    WorkItem item;
    expire(nowMs);
    if (workInFlight_) return item;
    switch (phase_) {
      case Phase::VerifyingAuth:
        item.kind = Work::VerifyAuth;
        item.nonce = nonce_;
        item.cnonce = cnonce_;
        item.response = response_;
        item.expectedHex = expectedHex_;
        break;
      case Phase::Beginning:
        item.kind = Work::Begin;
        item.imageBytes = imageBytes_;
        item.slots = slotsWanted_;
        item.slotBytes = chunkBytes_;
        break;
      case Phase::Receiving:
        if (writeBase_ < cumulative_) {
          const uint16_t slot = (uint16_t)(writeBase_ % slots_);
          item.kind = Work::Write;
          item.seq = writeBase_;
          item.data = slotMemory_ + (size_t)slot * chunkBytes_;
          item.len = chunkLength(writeBase_);
          if (hasher_ != nullptr) hasher_->update(item.data, item.len);
        } else if (writeBase_ == chunkCount_) {
          // Every byte is written and hashed. The digest decides, here and
          // nowhere else, whether Activate is ever offered.
          uint8_t digest[SHA256_BYTES] = {};
          if (hasher_ != nullptr) hasher_->finish(digest);
          toHex(digest, SHA256_BYTES, actualHex_);
          phase_ = Phase::Finalizing;
          if (memcmp(digest, expected_, SHA256_BYTES) == 0) {
            digestMatched_ = true;
            item.kind = Work::Activate;
          } else {
            digestMatched_ = false;
            fail(Status::HashMismatch, "image SHA-256 differs", nowMs);
            item.kind = Work::Abort;
          }
        }
        if (phase_ == Phase::Receiving) maybeKeepaliveAck(nowMs);
        break;
      case Phase::Done:
        if (abortOwed_) item.kind = Work::Abort;
        break;
      default:
        break;
    }
    if (item.kind != Work::None) workInFlight_ = true;
    return item;
  }

  void finishAuth(bool accepted, uint32_t nowMs) {
    workInFlight_ = false;
    if (phase_ != Phase::VerifyingAuth) return;
    lastHeardMs_ = nowMs;
    if (!accepted) {
      queueStatus(Status::AuthRefused, 0, "Authentication Failed");
      // Kept so a resent AUTH, whose refusal was lost, hears it again
      // instead of silence.
      refusedSession_ = session_;
      refusedPeer_ = peer_;
      memcpy(refusedResponse_, response_, sizeof(refusedResponse_));
      refusedAtMs_ = nowMs;
      phase_ = Phase::Idle;
      session_ = 0;
      authFailures_++;
      return;
    }
    authAccepted_ = true;
    phase_ = Phase::Beginning;
  }

  /// `slotMemory` must hold `slots * slotBytes` (as the Begin work asked)
  /// and stays the caller's; it is not touched again once the session ends.
  void finishBegin(bool ok, const char *error, uint8_t *slotMemory,
                   uint16_t slots, uint32_t nowMs) {
    workInFlight_ = false;
    if (phase_ != Phase::Beginning) {
      // The session ended (an abort, a timeout) while Update.begin ran. If
      // begin succeeded, Update is open and must be released, or every later
      // update - this path's and ArduinoOTA's - is refused until a reboot.
      if (ok) {
        sinkOpen_ = true;
        abortOwed_ = true;
      }
      return;
    }
    lastHeardMs_ = nowMs;
    if (!ok || slotMemory == nullptr || slots == 0) {
      if (ok) sinkOpen_ = true;  // begun but no memory: owes an abort
      fail(Status::BeginFailed, error ? error : "could not start the update",
           nowMs);
      return;
    }
    sinkOpen_ = true;
    slotMemory_ = slotMemory;
    slots_ = slots;
    if (slots_ > slotsWanted_) slots_ = slotsWanted_;
    memset(present_, 0, sizeof(present_));
    if (hasher_ != nullptr) hasher_->reset();
    phase_ = Phase::Receiving;
    queueStatus(Status::AuthAccepted, windowEnd(), "");
  }

  void finishWrite(uint32_t seq, bool ok, const char *error, uint32_t nowMs) {
    workInFlight_ = false;
    if (phase_ != Phase::Receiving || seq != writeBase_) return;
    if (!ok) {
      fail(Status::WriteFailed, error ? error : "flash write failed", nowMs);
      return;
    }
    setPresent(seq, false);
    bytesWritten_ += (uint32_t)chunkLength(seq);
    writeBase_++;
    // The window just opened by one slot: tell the sender, now if its view
    // is closed (everything it may send has been filed), else batched.
    windowMoved_ = true;
    slotsFreedSinceAck_++;
    if (cumulative_ >= windowEnd() - 1) ackDue_ = true;
    maybeAck(nowMs);
  }

  void finishActivate(bool ok, const char *error, uint32_t nowMs) {
    workInFlight_ = false;
    if (phase_ != Phase::Finalizing) return;
    sinkOpen_ = false;
    if (!ok) {
      // Update.end() failing resets the updater itself; nothing to abort.
      fail(Status::ImageRefused, error ? error : "image refused", nowMs);
      abortOwed_ = false;
      return;
    }
    finish(Status::Activated, bytesWritten_, "", nowMs);
    rebootAtMs_ = nowMs + REBOOT_DELAY_MS;
    rebootPending_ = true;
  }

  void finishAbort(uint32_t) {
    workInFlight_ = false;
    sinkOpen_ = false;
    abortOwed_ = false;
  }

  // ---- what the wrapper shows and logs ----

  Phase phase() const { return phase_; }
  /// True while an authenticated update owns the panel: frames are refused
  /// and loop() does nothing but service the update.
  bool ownsPanel() const {
    return phase_ == Phase::Beginning || phase_ == Phase::Receiving ||
           phase_ == Phase::Finalizing || rebootPending_ || abortOwed_;
  }
  /// Whether slot memory is still referenced. Free it only when false.
  bool usingSlots() const {
    return phase_ == Phase::Receiving || phase_ == Phase::Finalizing ||
           workInFlight_;
  }
  bool rebootDue(uint32_t nowMs) const {
    return rebootPending_ && (int32_t)(nowMs - rebootAtMs_) >= 0;
  }
  uint16_t session() const { return session_; }
  Endpoint peer() const { return peer_; }
  uint32_t imageBytes() const { return imageBytes_; }
  uint32_t bytesWritten() const { return bytesWritten_; }
  uint32_t cumulative() const { return cumulative_; }
  uint32_t windowEnd() const { return writeBase_ + slots_; }
  uint16_t slots() const { return slots_; }
  uint16_t chunkBytes() const { return chunkBytes_; }
  bool authAccepted() const { return authAccepted_; }
  bool digestMatched() const { return digestMatched_; }
  const char *expectedHex() const { return expectedHex_; }
  const char *actualHex() const { return actualHex_; }
  Status result() const { return result_; }
  const char *resultDetail() const { return resultDetail_; }
  bool hasResult() const { return hasResult_; }
  uint32_t authFailures() const { return authFailures_; }
  const Stats &stats() const { return stats_; }

 private:
  // ---- packets in ----

  void onBegin(const uint8_t *data, size_t len, Endpoint from, uint32_t nowMs,
               const uint8_t random32[32]) {
    Begin begin;
    if (!parseBegin(data, len, begin)) return;
    expire(nowMs);
    if (!armed_) {
      queueStatusTo(from, Status::NotConfigured, begin.session, 0,
                    "no OTA password is set on this panel");
      return;
    }
    // A retransmitted BEGIN for the session already waiting on its answer
    // gets the same challenge again: the first reply was lost, and a fresh
    // nonce would orphan an AUTH that may already be in flight.
    if (phase_ == Phase::AwaitingAuth && begin.session == session_ &&
        from == peer_ && begin.imageBytes == imageBytes_ &&
        memcmp(begin.sha256, expected_, SHA256_BYTES) == 0) {
      lastHeardMs_ = nowMs;
      queueChallenge();
      return;
    }
    // Once authenticated work is under way nothing displaces it but its own
    // sender's abort or a timeout. A session still waiting on its password
    // can be replaced - it has proven nothing and must not hold the panel.
    if (phase_ != Phase::Idle && phase_ != Phase::Done &&
        phase_ != Phase::AwaitingAuth) {
      if (begin.session == session_ && from == peer_) return;  // late dup
      queueStatusTo(from, Status::Busy, begin.session, 0,
                    "another update is in progress");
      return;
    }
    if (rebootPending_ || abortOwed_ || workInFlight_) {
      queueStatusTo(from, Status::Busy, begin.session, 0,
                    "the previous update is still finishing");
      return;
    }
    if (begin.session == 0) {
      queueStatusTo(from, Status::BadRequest, 0, 0, "session 0 is reserved");
      return;
    }
    if (begin.imageBytes == 0 || begin.imageBytes > maxImageBytes_) {
      queueStatusTo(from, Status::BadRequest, begin.session, maxImageBytes_,
                    "image does not fit the inactive slot");
      return;
    }
    if (begin.chunkBytes < MIN_CHUNK_BYTES ||
        begin.chunkBytes > MAX_CHUNK_BYTES) {
      queueStatusTo(from, Status::BadRequest, begin.session, MAX_CHUNK_BYTES,
                    "chunk size out of range");
      return;
    }
    resetSession();
    phase_ = Phase::AwaitingAuth;
    session_ = begin.session;
    peer_ = from;
    imageBytes_ = begin.imageBytes;
    chunkBytes_ = begin.chunkBytes;
    chunkCount_ = (imageBytes_ + chunkBytes_ - 1) / chunkBytes_;
    memcpy(expected_, begin.sha256, SHA256_BYTES);
    toHex(expected_, SHA256_BYTES, expectedHex_);
    toHex(random32, 32, nonce_);
    lastHeardMs_ = nowMs;
    queueChallenge();
  }

  void onAuth(const uint8_t *data, size_t len, Endpoint from, uint32_t nowMs) {
    Auth auth;
    if (!parseAuth(data, len, auth)) return;
    if (refusedSession_ != 0 && auth.session == refusedSession_ &&
        from == refusedPeer_ && elapsedMs(nowMs, refusedAtMs_) <= RESULT_HOLD_MS &&
        sameDigestHex(auth.response, refusedResponse_)) {
      queueStatusTo(from, Status::AuthRefused, auth.session, 0,
                    "Authentication Failed");
      return;
    }
    if (auth.session != session_ || from != peer_ || session_ == 0) {
      stats_.foreign++;
      return;
    }
    if (phase_ == Phase::AwaitingAuth) {
      memcpy(cnonce_, auth.cnonce, sizeof(cnonce_));
      memcpy(response_, auth.response, sizeof(response_));
      phase_ = Phase::VerifyingAuth;
      lastHeardMs_ = nowMs;
      return;
    }
    // The accept was lost: answer the same response the same way again.
    if (phase_ == Phase::Receiving && authAccepted_ &&
        sameDigestHex(auth.response, response_)) {
      lastHeardMs_ = nowMs;
      queueStatus(Status::AuthAccepted, windowEnd(), "");
    }
  }

  void onData(const uint8_t *data, size_t len, Endpoint from, uint32_t nowMs) {
    if (!headIs(data, len, 'D', DATA_HEADER_BYTES)) return;
    const uint16_t session = readU16(data + 6);
    if (session == 0 || session != session_ || from != peer_) {
      stats_.foreign++;
      repeatStatus(from, Status::UnknownSession, session, nowMs);
      return;
    }
    if (phase_ == Phase::Done) {
      // The verdict was lost; data still arriving is the sender asking.
      lastHeardMs_ = nowMs;
      if (hasResult_) repeatStatus(peer_, result_, session_, nowMs);
      return;
    }
    if (phase_ == Phase::Finalizing) {
      lastHeardMs_ = nowMs;
      ackDue_ = true;
      maybeAck(nowMs);
      return;
    }
    if (phase_ != Phase::Receiving) {
      // Not authenticated, or authenticated but not yet begun. Refused
      // outright: no slot, no ack, nothing written.
      stats_.refusedBeforeAuth++;
      return;
    }
    lastHeardMs_ = nowMs;
    const uint32_t seq = readU32(data + 8);
    const uint32_t crc = readU32(data + 12);
    const uint8_t *payload = data + DATA_HEADER_BYTES;
    const size_t payloadLen = len - DATA_HEADER_BYTES;
    if (seq >= chunkCount_ || payloadLen != chunkLength(seq) ||
        crc32(payload, payloadLen) != crc) {
      stats_.badChunks++;
      return;
    }
    if (seq < cumulative_ || (seq < windowEnd() && isPresent(seq))) {
      stats_.duplicates++;
      ackDue_ = true;
      maybeAck(nowMs);
      return;
    }
    if (seq >= windowEnd()) {
      stats_.outsideWindow++;
      ackDue_ = true;
      maybeAck(nowMs);
      return;
    }
    if (seq != cumulative_) {
      stats_.outOfOrder++;
      ackDue_ = true;  // a hole: say so now, the sender may resend at once
    }
    memcpy(slotMemory_ + (size_t)(seq % slots_) * chunkBytes_, payload,
           payloadLen);
    setPresent(seq, true);
    stats_.chunksFiled++;
    const uint32_t before = cumulative_;
    while (cumulative_ < chunkCount_ && cumulative_ < windowEnd() &&
           isPresent(cumulative_)) {
      cumulative_++;
    }
    if (seq == before && sackBits() != 0) ackDue_ = true;  // a hole filled
    if (cumulative_ == chunkCount_) ackDue_ = true;
    // Every slot the sender may use is now filled: it can send nothing more
    // until it hears, and loop() may be inside a block erase for hundreds of
    // milliseconds, so it hears now rather than at the next batch.
    if (cumulative_ >= windowEnd()) ackDue_ = true;
    filedSinceAck_++;
    maybeAck(nowMs);
  }

  void onAbort(const uint8_t *data, size_t len, Endpoint from, uint32_t nowMs) {
    if (!headIs(data, len, 'X', ABORT_BYTES) || len != ABORT_BYTES) return;
    const uint16_t session = readU16(data + 6);
    if (session == 0 || session != session_ || from != peer_) {
      stats_.foreign++;
      return;
    }
    if (phase_ == Phase::Done || phase_ == Phase::Idle) {
      if (hasResult_) repeatStatus(peer_, result_, session_, nowMs);
      return;
    }
    if (phase_ == Phase::Finalizing && digestMatched_) {
      return;  // Update.end is already running; its verdict will answer
    }
    fail(Status::Aborted, "the sender cancelled the update", nowMs);
  }

  // ---- state ----

  void resetSession() {
    phase_ = Phase::Idle;
    session_ = 0;
    peer_ = Endpoint();
    imageBytes_ = chunkCount_ = cumulative_ = writeBase_ = bytesWritten_ = 0;
    chunkBytes_ = 0;
    slots_ = 0;
    slotMemory_ = nullptr;
    memset(present_, 0, sizeof(present_));
    memset(expected_, 0, sizeof(expected_));
    expectedHex_[0] = actualHex_[0] = '\0';
    nonce_[0] = cnonce_[0] = response_[0] = '\0';
    authAccepted_ = digestMatched_ = false;
    ackDue_ = windowMoved_ = false;
    filedSinceAck_ = slotsFreedSinceAck_ = 0;
    hasResult_ = false;
    result_ = Status::Aborted;
    resultDetail_[0] = '\0';
    stats_ = Stats();
  }

  /// The session failed: record why, tell the sender, and owe an abort if
  /// Update.begin had succeeded. Slot memory is dropped at once.
  void fail(Status why, const char *detail, uint32_t nowMs) {
    if (sinkOpen_) abortOwed_ = true;
    finish(why, bytesWritten_, detail, nowMs);
  }

  void finish(Status why, uint32_t value, const char *detail, uint32_t nowMs) {
    phase_ = Phase::Done;
    result_ = why;
    resultValue_ = value;
    hasResult_ = true;
    size_t n = detail ? strlen(detail) : 0;
    if (n > STATUS_DETAIL_MAX) n = STATUS_DETAIL_MAX;
    if (n) memcpy(resultDetail_, detail, n);
    resultDetail_[n] = '\0';
    doneAtMs_ = nowMs;
    slotMemory_ = nullptr;
    slots_ = 0;
    queueStatus(why, value, resultDetail_);
    lastRepeatMs_ = nowMs;
  }

  void expire(uint32_t nowMs) {
    if (phase_ == Phase::AwaitingAuth &&
        elapsedMs(nowMs, lastHeardMs_) > SESSION_IDLE_TIMEOUT_MS) {
      resetSession();
      return;
    }
    if ((phase_ == Phase::Receiving || phase_ == Phase::Beginning) &&
        !workInFlight_ && elapsedMs(nowMs, lastHeardMs_) > SESSION_IDLE_TIMEOUT_MS) {
      fail(Status::Aborted, "the sender went silent", nowMs);
      return;
    }
    if (phase_ == Phase::Done && !abortOwed_ && !rebootPending_ &&
        !workInFlight_ && elapsedMs(nowMs, doneAtMs_) > RESULT_HOLD_MS) {
      resetSession();
    }
  }

  uint32_t chunkLength(uint32_t seq) const {
    const uint32_t start = seq * (uint32_t)chunkBytes_;
    const uint32_t left = imageBytes_ - start;
    return left < chunkBytes_ ? left : chunkBytes_;
  }

  // One bit per slot, indexed by seq % slots.
  static const size_t MAX_SLOTS = 256;
  bool isPresent(uint32_t seq) const {
    const uint32_t s = seq % slots_;
    return (present_[s / 8] >> (s % 8)) & 1;
  }
  void setPresent(uint32_t seq, bool on) {
    const uint32_t s = seq % slots_;
    if (on) {
      present_[s / 8] |= (uint8_t)(1u << (s % 8));
    } else {
      present_[s / 8] &= (uint8_t)~(1u << (s % 8));
    }
  }

  uint64_t sackBits() const {
    uint64_t bits = 0;
    for (uint32_t i = 0; i < SACK_BITS; i++) {
      const uint32_t seq = cumulative_ + 1 + i;
      if (seq >= windowEnd() || seq >= chunkCount_) break;
      if (isPresent(seq)) bits |= (uint64_t)1 << i;
    }
    return bits;
  }

  void maybeAck(uint32_t nowMs) {
    if (ackDue_ || filedSinceAck_ >= ACK_EVERY_CHUNKS) {
      queueAck(nowMs);
    }
  }

  void maybeKeepaliveAck(uint32_t nowMs) {
    if (slotsFreedSinceAck_ >= ACK_EVERY_CHUNKS ||
        (windowMoved_ && elapsedMs(nowMs, lastAckMs_) >= ACK_WINDOW_BATCH_MS) ||
        elapsedMs(nowMs, lastAckMs_) >= ACK_KEEPALIVE_MS) {
      queueAck(nowMs);
    }
  }

  void queueAck(uint32_t nowMs) {
    Ack ack;
    ack.phase = phase_;
    ack.session = session_;
    ack.cumulative = cumulative_;
    ack.windowEnd = windowEnd();
    ack.sack = sackBits();
    ack.bytesWritten = bytesWritten_;
    Outgoing &out = reserve(peer_);
    out.len = writeAck(out.bytes, ack);
    ackDue_ = windowMoved_ = false;
    filedSinceAck_ = 0;
    slotsFreedSinceAck_ = 0;
    lastAckMs_ = nowMs;
  }

  void queueChallenge() {
    Outgoing &out = reserve(peer_);
    out.len = writeChallenge(out.bytes, session_, chunkBytes_, nonce_);
  }

  void queueStatus(Status code, uint32_t value, const char *detail) {
    queueStatusTo(peer_, code, session_, value, detail);
  }

  void queueStatusTo(Endpoint to, Status code, uint16_t session, uint32_t value,
                     const char *detail) {
    Outgoing &out = reserve(to);
    out.len = writeStatus(out.bytes, sizeof(out.bytes), code, session, value,
                          detail);
  }

  void repeatStatus(Endpoint to, Status code, uint16_t session,
                    uint32_t nowMs) {
    if (elapsedMs(nowMs, lastRepeatMs_) < REPEAT_STATUS_MS) return;
    lastRepeatMs_ = nowMs;
    if (code == result_ && session == session_ && hasResult_) {
      queueStatusTo(to, code, session, resultValue_, resultDetail_);
    } else {
      queueStatusTo(to, code, session, 0, "no such update session");
    }
  }

  /// The next outbox entry. When full, the oldest is overwritten: acks
  /// supersede each other and every status is repeated on request.
  Outgoing &reserve(Endpoint to) {
    if (outCount_ == OUTBOX_DEPTH) {
      outHead_ = (outHead_ + 1) % OUTBOX_DEPTH;
      outCount_--;
    }
    Outgoing &out = outbox_[(outHead_ + outCount_) % OUTBOX_DEPTH];
    outCount_++;
    out.to = to;
    out.len = 0;
    return out;
  }

  // Configuration.
  uint32_t maxImageBytes_ = 0;
  uint16_t slotsWanted_ = 0;
  Hasher *hasher_ = nullptr;
  bool armed_ = false;
  char passwordHash_[HEX_DIGEST_CHARS + 1] = {};

  // Session.
  Phase phase_ = Phase::Idle;
  uint16_t session_ = 0;
  Endpoint peer_;
  uint32_t imageBytes_ = 0;
  uint16_t chunkBytes_ = 0;
  uint32_t chunkCount_ = 0;
  uint8_t expected_[SHA256_BYTES] = {};
  char expectedHex_[HEX_DIGEST_CHARS + 1] = {};
  char actualHex_[HEX_DIGEST_CHARS + 1] = {};
  char nonce_[HEX_DIGEST_CHARS + 1] = {};
  char cnonce_[HEX_DIGEST_CHARS + 1] = {};
  char response_[HEX_DIGEST_CHARS + 1] = {};
  bool authAccepted_ = false;
  bool digestMatched_ = false;
  uint32_t authFailures_ = 0;
  uint16_t refusedSession_ = 0;
  Endpoint refusedPeer_;
  char refusedResponse_[HEX_DIGEST_CHARS + 1] = {};
  uint32_t refusedAtMs_ = 0;

  // Window.
  uint8_t *slotMemory_ = nullptr;
  uint16_t slots_ = 0;
  uint8_t present_[MAX_SLOTS / 8] = {};
  uint32_t cumulative_ = 0;  // every seq below is filed (or written)
  uint32_t writeBase_ = 0;   // every seq below is written to flash
  uint32_t bytesWritten_ = 0;

  // Loop-side bookkeeping.
  bool workInFlight_ = false;
  bool sinkOpen_ = false;
  bool abortOwed_ = false;
  bool rebootPending_ = false;
  uint32_t rebootAtMs_ = 0;
  uint32_t lastHeardMs_ = 0;
  uint32_t doneAtMs_ = 0;

  // Acks and statuses.
  bool ackDue_ = false;
  bool windowMoved_ = false;
  uint32_t filedSinceAck_ = 0;
  uint32_t slotsFreedSinceAck_ = 0;
  uint32_t lastAckMs_ = 0;
  uint32_t lastRepeatMs_ = 0;
  bool hasResult_ = false;
  Status result_ = Status::Aborted;
  uint32_t resultValue_ = 0;
  char resultDetail_[STATUS_DETAIL_MAX + 1] = {};

  Outgoing outbox_[OUTBOX_DEPTH];
  size_t outHead_ = 0;
  size_t outCount_ = 0;

  Stats stats_;

 public:
  /// The most slots the present bitmap can track.
  static uint16_t maxSlots() { return (uint16_t)MAX_SLOTS; }
};

}  // namespace streamupdate
