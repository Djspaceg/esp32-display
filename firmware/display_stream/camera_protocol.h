// Versioned camera-control and JPEG-fragment protocol. Kept separate from
// EINF and EHB1 because their existing fixed-size readers must remain valid.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace cameraproto {

static const uint8_t VERSION = 1;
static const uint8_t COMMAND_CHALLENGE = 1;
static const uint8_t COMMAND_START = COMMAND_CHALLENGE;
static const uint8_t COMMAND_AUTH_START = 2;
static const uint8_t COMMAND_STOP = 3;
static const uint8_t FRAME_FRAGMENT = 0x80;
static const uint8_t CHALLENGE = 0x81;
static const uint8_t AUTH_REFUSED = 0x82;
static const uint8_t AUTH_UNAVAILABLE = 0x83;
static const size_t COMMAND_BYTES = 8;
static const size_t AUTH_BYTES = 136;
static const size_t CHALLENGE_BYTES = 72;
static const size_t FRAME_HEADER_BYTES = 14;
static const size_t MAX_FRAGMENT_PAYLOAD = 1200;
static const size_t MAX_FRAGMENTS = 256;

enum class Resolution : uint8_t {
  Qvga = 1,
  Vga = 2,
};

struct Command {
  uint8_t kind;
  Resolution resolution;
};

struct Authentication {
  Resolution resolution;
  char cnonce[65];
  char response[65];
};

inline uint16_t readU16LE(const uint8_t *p) {
  return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

inline void writeU16LE(uint8_t *p, uint16_t value) {
  p[0] = value & 0xFF;
  p[1] = value >> 8;
}

inline bool validResolution(uint8_t value) {
  return value == (uint8_t)Resolution::Qvga ||
         value == (uint8_t)Resolution::Vga;
}

inline bool parseCommand(const uint8_t *data, size_t len, Command &out) {
  if (len != COMMAND_BYTES || memcmp(data, "ECAM", 4) != 0 ||
      data[4] != VERSION ||
      (data[5] != COMMAND_CHALLENGE && data[5] != COMMAND_STOP) ||
      !validResolution(data[6]) || data[7] != 0) {
    return false;
  }
  out.kind = data[5];
  out.resolution = (Resolution)data[6];
  return true;
}

inline bool lowerHex(const uint8_t *value) {
  for (size_t i = 0; i < 64; ++i) {
    if (!((value[i] >= '0' && value[i] <= '9') ||
          (value[i] >= 'a' && value[i] <= 'f'))) return false;
  }
  return true;
}

inline bool parseAuthentication(const uint8_t *data, size_t len,
                                Authentication &out) {
  if (len != AUTH_BYTES || memcmp(data, "ECAM", 4) != 0 ||
      data[4] != VERSION || data[5] != COMMAND_AUTH_START ||
      !validResolution(data[6]) || data[7] != 0 ||
      !lowerHex(data + 8) || !lowerHex(data + 72)) {
    return false;
  }
  out.resolution = (Resolution)data[6];
  memcpy(out.cnonce, data + 8, 64);
  out.cnonce[64] = '\0';
  memcpy(out.response, data + 72, 64);
  out.response[64] = '\0';
  return true;
}

inline size_t writeChallenge(uint8_t *out, size_t capacity,
                             Resolution resolution, const char *nonce) {
  if (capacity < CHALLENGE_BYTES || nonce == nullptr) return 0;
  memcpy(out, "ECAM", 4);
  out[4] = VERSION;
  out[5] = CHALLENGE;
  out[6] = (uint8_t)resolution;
  out[7] = 0;
  memcpy(out + 8, nonce, 64);
  return CHALLENGE_BYTES;
}

inline size_t writeStatus(uint8_t *out, size_t capacity, uint8_t status,
                          Resolution resolution) {
  if (capacity < COMMAND_BYTES ||
      (status != AUTH_REFUSED && status != AUTH_UNAVAILABLE)) return 0;
  memcpy(out, "ECAM", 4);
  out[4] = VERSION;
  out[5] = status;
  out[6] = (uint8_t)resolution;
  out[7] = 0;
  return COMMAND_BYTES;
}

inline size_t writeFrameHeader(uint8_t *out, size_t capacity,
                               Resolution resolution, uint16_t frameId,
                               uint16_t fragmentIndex,
                               uint16_t fragmentCount) {
  if (capacity < FRAME_HEADER_BYTES || fragmentCount == 0 ||
      fragmentCount > MAX_FRAGMENTS ||
      fragmentIndex >= fragmentCount) {
    return 0;
  }
  memcpy(out, "ECAM", 4);
  out[4] = VERSION;
  out[5] = FRAME_FRAGMENT;
  out[6] = (uint8_t)resolution;
  out[7] = 0;
  writeU16LE(out + 8, frameId);
  writeU16LE(out + 10, fragmentIndex);
  writeU16LE(out + 12, fragmentCount);
  return FRAME_HEADER_BYTES;
}

}  // namespace cameraproto
