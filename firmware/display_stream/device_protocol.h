// Versioned device telemetry and management protocol. This file is portable
// and hardware-free so Swift and firmware can share exact byte-vector tests.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace deviceproto {

static const uint8_t INFO_VERSION = 1;
static const uint8_t FRAME_PROTOCOL_VERSION = 2;
static const uint8_t CONTROL_PROTOCOL_VERSION = 1;
static const size_t INFO_PREFIX_BYTES = 27;
static const size_t CONTROL_PACKET_BYTES = 12;
static const size_t ACK_PACKET_BYTES = 12;

enum Capability : uint32_t {
  CAP_BRIGHTNESS = 1u << 0,
  CAP_FLIP = 1u << 1,
  CAP_IDENTIFY = 1u << 2,
  CAP_RESTART = 1u << 3,
  CAP_OTA = 1u << 4,
  CAP_SLEEP_SYNC = 1u << 5,
  CAP_TELEMETRY = 1u << 6,
  // Accepts BrightnessLevel, i.e. any level rather than only high/low.
  // Advertised separately from CAP_BRIGHTNESS so a sender can offer a slider
  // to firmware that supports it and the old toggle to firmware that does
  // not, without either side needing a protocol version bump.
  CAP_BRIGHTNESS_LEVEL = 1u << 7,
};

enum class ControlOpcode : uint8_t {
  Brightness = 1,
  Flip = 2,
  Identify = 3,
  Restart = 4,
  BrightnessLevel = 5,
};

struct ControlCommand {
  ControlOpcode opcode;
  uint16_t sequence;
  int32_t value;
};

inline uint16_t readU16LE(const uint8_t *p) {
  return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

inline uint32_t readU32LE(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
         ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

inline void writeU16LE(uint8_t *p, uint16_t value) {
  p[0] = value & 0xFF;
  p[1] = value >> 8;
}

inline void writeU32LE(uint8_t *p, uint32_t value) {
  p[0] = value & 0xFF;
  p[1] = (value >> 8) & 0xFF;
  p[2] = (value >> 16) & 0xFF;
  p[3] = (value >> 24) & 0xFF;
}

// Lowest and highest backlight level a BrightnessLevel command may request.
// Zero is excluded deliberately: a black backlight is indistinguishable from a
// broken panel, and turning the display off already has its own command.
static const int32_t BRIGHTNESS_LEVEL_MIN = 1;
static const int32_t BRIGHTNESS_LEVEL_MAX = 255;

// How long an Identify may light the LED for.
static const int32_t IDENTIFY_SECONDS_MIN = 1;
static const int32_t IDENTIFY_SECONDS_MAX = 30;

inline bool validControlValue(ControlOpcode opcode, int32_t value) {
  switch (opcode) {
    case ControlOpcode::Brightness:
    case ControlOpcode::Flip:
      return value == 0 || value == 1;
    case ControlOpcode::Identify:
      return value >= IDENTIFY_SECONDS_MIN && value <= IDENTIFY_SECONDS_MAX;
    case ControlOpcode::Restart:
      return value == 1;
    case ControlOpcode::BrightnessLevel:
      return value >= BRIGHTNESS_LEVEL_MIN && value <= BRIGHTNESS_LEVEL_MAX;
  }
  return false;
}

inline bool parseControl(const uint8_t *data, size_t len, ControlCommand &out) {
  if (len != CONTROL_PACKET_BYTES || memcmp(data, "ECTL", 4) != 0 ||
      data[4] != CONTROL_PROTOCOL_VERSION) {
    return false;
  }
  if (data[5] < (uint8_t)ControlOpcode::Brightness ||
      data[5] > (uint8_t)ControlOpcode::BrightnessLevel) {
    return false;
  }
  out.opcode = (ControlOpcode)data[5];
  out.sequence = readU16LE(data + 6);
  out.value = (int32_t)readU32LE(data + 8);
  return validControlValue(out.opcode, out.value);
}

// EINF fixed prefix followed by UTF-8 name and firmware version bytes.
inline size_t writeInfo(uint8_t *out, size_t capacity, uint8_t flags,
                        uint32_t capabilities, uint32_t uptimeSeconds,
                        int16_t rssi, uint8_t brightness,
                        const uint8_t deviceId[6], const char *name,
                        const char *firmwareVersion) {
  size_t nameLen = strnlen(name, 33);
  size_t firmwareLen = strnlen(firmwareVersion, 25);
  if (nameLen > 32 || firmwareLen > 24 ||
      capacity < INFO_PREFIX_BYTES + nameLen + firmwareLen) {
    return 0;
  }
  memcpy(out, "EINF", 4);
  out[4] = INFO_VERSION;
  out[5] = FRAME_PROTOCOL_VERSION;
  out[6] = CONTROL_PROTOCOL_VERSION;
  out[7] = flags;
  writeU32LE(out + 8, capabilities);
  writeU32LE(out + 12, uptimeSeconds);
  writeU16LE(out + 16, (uint16_t)rssi);
  out[18] = brightness;
  out[19] = (uint8_t)nameLen;
  out[20] = (uint8_t)firmwareLen;
  memcpy(out + 21, deviceId, 6);
  memcpy(out + INFO_PREFIX_BYTES, name, nameLen);
  memcpy(out + INFO_PREFIX_BYTES + nameLen, firmwareVersion, firmwareLen);
  return INFO_PREFIX_BYTES + nameLen + firmwareLen;
}

inline size_t writeAck(uint8_t out[ACK_PACKET_BYTES], ControlOpcode opcode,
                       uint16_t sequence, uint8_t status, uint8_t flags,
                       uint8_t brightness) {
  memcpy(out, "EACK", 4);
  out[4] = CONTROL_PROTOCOL_VERSION;
  out[5] = (uint8_t)opcode;
  writeU16LE(out + 6, sequence);
  out[8] = status;
  out[9] = flags;
  out[10] = brightness;
  out[11] = 0;
  return ACK_PACKET_BYTES;
}

}  // namespace deviceproto
