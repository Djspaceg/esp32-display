#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace audioproto {

static const uint16_t UDP_PORT = 5569;
static const uint8_t VERSION = 1;
static const uint8_t FLAG_PCM16_LE = 1u << 0;
static const size_t HEADER_BYTES = 28;
static const size_t MAX_PAYLOAD_BYTES = 1400;
static const size_t MAX_DATAGRAM_BYTES = HEADER_BYTES + MAX_PAYLOAD_BYTES;
static const size_t STATUS_PAYLOAD_BYTES = 32;

enum class DatagramKind : uint8_t {
  PcmDownlink = 1,
  PcmUplink = 2,
  Status = 3,
};

enum class ParseResult : uint8_t {
  Ok,
  Truncated,
  BadMagic,
  VersionMismatch,
  UnknownKind,
  BadFlags,
  BadFormat,
  BadLength,
};

struct PcmHeader {
  DatagramKind kind;
  uint16_t sequence;
  uint16_t streamGeneration;
  uint32_t sampleRateHz;
  uint32_t sampleCounter;
  uint32_t timestampMicros;
  uint16_t frameCount;
  uint8_t channels;
};

struct PcmDatagram {
  PcmHeader header;
  const uint8_t *payload;
  size_t payloadBytes;
};

struct Status {
  uint32_t fillFrames;
  uint32_t targetFrames;
  uint32_t underruns;
  uint32_t latePackets;
  uint32_t lostFrames;
  uint32_t hardCorrections;
  uint32_t queueDrops;
  uint32_t captureOverruns;
};

inline uint16_t readU16LE(const uint8_t *data) {
  return (uint16_t)data[0] | ((uint16_t)data[1] << 8);
}

inline uint32_t readU32LE(const uint8_t *data) {
  return (uint32_t)data[0] | ((uint32_t)data[1] << 8) |
         ((uint32_t)data[2] << 16) | ((uint32_t)data[3] << 24);
}

inline void writeU16LE(uint8_t *data, uint16_t value) {
  data[0] = (uint8_t)value;
  data[1] = (uint8_t)(value >> 8);
}

inline void writeU32LE(uint8_t *data, uint32_t value) {
  data[0] = (uint8_t)value;
  data[1] = (uint8_t)(value >> 8);
  data[2] = (uint8_t)(value >> 16);
  data[3] = (uint8_t)(value >> 24);
}

inline bool validRate(uint32_t sampleRateHz) {
  return sampleRateHz >= 8000 && sampleRateHz <= 96000;
}

inline bool hasAudioMagic(const uint8_t *data, size_t length) {
  return data != nullptr && length >= 4 && memcmp(data, "EAUD", 4) == 0;
}

inline bool peerVersionsCompatible(uint8_t localVersion,
                                   uint8_t remoteVersion,
                                   bool peerAdvertisedAudio) {
  return peerAdvertisedAudio && localVersion == remoteVersion;
}

inline size_t writePcm(uint8_t *output, size_t capacity,
                       const PcmHeader &header, const uint8_t *payload,
                       size_t payloadBytes) {
  if (output == nullptr || payload == nullptr ||
      (header.kind != DatagramKind::PcmDownlink &&
       header.kind != DatagramKind::PcmUplink) ||
      !validRate(header.sampleRateHz) || header.channels == 0 ||
      header.channels > 2 || header.frameCount == 0 ||
      payloadBytes > MAX_PAYLOAD_BYTES ||
      payloadBytes !=
          (size_t)header.frameCount * header.channels * sizeof(int16_t) ||
      capacity < HEADER_BYTES + payloadBytes) {
    return 0;
  }
  memcpy(output, "EAUD", 4);
  output[4] = VERSION;
  output[5] = (uint8_t)header.kind;
  output[6] = FLAG_PCM16_LE;
  output[7] = header.channels;
  writeU16LE(output + 8, header.sequence);
  writeU16LE(output + 10, header.streamGeneration);
  writeU32LE(output + 12, header.sampleRateHz);
  writeU32LE(output + 16, header.sampleCounter);
  writeU32LE(output + 20, header.timestampMicros);
  writeU16LE(output + 24, header.frameCount);
  writeU16LE(output + 26, (uint16_t)payloadBytes);
  memcpy(output + HEADER_BYTES, payload, payloadBytes);
  return HEADER_BYTES + payloadBytes;
}

inline ParseResult parsePcmDownlink(const uint8_t *data, size_t length,
                                    PcmDatagram &out) {
  if (data == nullptr || length < HEADER_BYTES) return ParseResult::Truncated;
  if (!hasAudioMagic(data, length)) return ParseResult::BadMagic;
  if (data[4] != VERSION) return ParseResult::VersionMismatch;
  if (data[5] != (uint8_t)DatagramKind::PcmDownlink) {
    return ParseResult::UnknownKind;
  }
  if (data[6] != FLAG_PCM16_LE) return ParseResult::BadFlags;
  const uint8_t channels = data[7];
  const uint32_t sampleRateHz = readU32LE(data + 12);
  const uint16_t frameCount = readU16LE(data + 24);
  const size_t payloadBytes = readU16LE(data + 26);
  if (channels == 0 || channels > 2 || !validRate(sampleRateHz) ||
      frameCount == 0) {
    return ParseResult::BadFormat;
  }
  const size_t expectedBytes =
      (size_t)frameCount * channels * sizeof(int16_t);
  if (payloadBytes > MAX_PAYLOAD_BYTES || payloadBytes != expectedBytes ||
      length != HEADER_BYTES + payloadBytes) {
    return ParseResult::BadLength;
  }
  out.header = {
      DatagramKind::PcmDownlink,
      readU16LE(data + 8),
      readU16LE(data + 10),
      sampleRateHz,
      readU32LE(data + 16),
      readU32LE(data + 20),
      frameCount,
      channels,
  };
  out.payload = data + HEADER_BYTES;
  out.payloadBytes = payloadBytes;
  return ParseResult::Ok;
}

inline size_t writeStatus(uint8_t *output, size_t capacity,
                          uint16_t sequence, uint16_t streamGeneration,
                          uint32_t sampleRateHz, uint32_t timestampMicros,
                          const Status &status) {
  if (output == nullptr ||
      capacity < HEADER_BYTES + STATUS_PAYLOAD_BYTES ||
      !validRate(sampleRateHz)) {
    return 0;
  }
  memcpy(output, "EAUD", 4);
  output[4] = VERSION;
  output[5] = (uint8_t)DatagramKind::Status;
  output[6] = 0;
  output[7] = 0;
  writeU16LE(output + 8, sequence);
  writeU16LE(output + 10, streamGeneration);
  writeU32LE(output + 12, sampleRateHz);
  writeU32LE(output + 16, 0);
  writeU32LE(output + 20, timestampMicros);
  writeU16LE(output + 24, 0);
  writeU16LE(output + 26, STATUS_PAYLOAD_BYTES);
  const uint32_t fields[] = {
      status.fillFrames, status.targetFrames, status.underruns,
      status.latePackets, status.lostFrames, status.hardCorrections,
      status.queueDrops, status.captureOverruns,
  };
  for (size_t i = 0; i < sizeof(fields) / sizeof(fields[0]); ++i) {
    writeU32LE(output + HEADER_BYTES + i * sizeof(uint32_t), fields[i]);
  }
  return HEADER_BYTES + STATUS_PAYLOAD_BYTES;
}

}  // namespace audioproto
