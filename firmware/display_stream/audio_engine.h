#pragma once

#include <Arduino.h>
#include <board_config.h>

namespace audiotransport {
struct Packet;
}

namespace audioengine {

bool start(const board::Config &config);
void stop();
bool available();
bool shouldSuppressVideo();
bool streamActive();
void setLocalTestActive(bool active);

extern uint32_t tuneLowWatermarkMs;
extern uint32_t tuneTargetWatermarkMs;
extern uint32_t tuneHighWatermarkMs;
extern int32_t tuneMaxCorrectionPpm;
extern TaskHandle_t engineTaskHandle;

#if defined(ESPDISP_HOST_AUDIO_TEST)
namespace host {

struct AdmissionSnapshot {
  uint32_t fillFrames;
  uint32_t lastPacketAt;
  uint32_t latePackets;
  uint32_t lostFrames;
  uint32_t engineDrops;
  bool streamSeen;
};

struct EngineLoopSnapshot {
  uint32_t packetsVisited;
  uint32_t packetsAccepted;
  uint32_t engineDrops;
  uint32_t metricsObserveCalls;
  uint32_t minimumFillFrames;
  uint32_t underrunDurationMs;
};

void resetAdmission(size_t capacityFrames);
bool admitPacket(const audiotransport::Packet &packet, uint32_t nowMs);
bool discardFrames(size_t frames);
AdmissionSnapshot admissionSnapshot();
bool runEngineTaskIterations(uint32_t iterations);
EngineLoopSnapshot engineLoopSnapshot();
bool renderFadingOut(const int16_t *input, size_t inputFrames,
                     uint8_t channels, size_t outputFrames,
                     const int16_t *lastOutput, int16_t *output);

}  // namespace host
#endif

}  // namespace audioengine
