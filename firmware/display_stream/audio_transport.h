#pragma once

#include <stddef.h>
#include <stdint.h>

#include <Arduino.h>
#include <board_config.h>

#include "audio_protocol.h"

namespace audiotransport {

static const size_t QUEUE_DEPTH = 12;

struct Packet {
  audioproto::PcmHeader header;
  uint16_t payloadBytes;
  uint32_t remoteIp;
  uint16_t remotePort;
  int16_t samples[audioproto::MAX_PAYLOAD_BYTES / sizeof(int16_t)];
};

struct Stats {
  volatile uint32_t badDatagrams = 0;
  volatile uint32_t versionMismatches = 0;
  volatile uint32_t oversizedDatagrams = 0;
  volatile uint32_t queueDrops = 0;
  volatile uint32_t ingressDrops = 0;
  volatile uint32_t uplinkErrors = 0;
};

bool start(const board::Config &config);
void stop();
bool available();
bool receive(Packet &packet, TickType_t waitTicks);
void claimPeer(const Packet &packet);
bool sendCapture(const int16_t *samples, uint16_t frameCount,
                 uint8_t channels, uint32_t sampleRateHz,
                 uint16_t streamGeneration, uint32_t sampleCounter);
bool sendStatus(uint16_t streamGeneration, uint32_t sampleRateHz,
                const audioproto::Status &status);
bool setReceiveBufferBytes(int bytes);
const Stats &stats();

extern int tuneReceiveBufferBytes;
extern TaskHandle_t receiveTaskHandle;

#if defined(ESPDISP_HOST_AUDIO_TEST)
void hostReceiveBurst();
void hostResetStats();
#endif

}  // namespace audiotransport
