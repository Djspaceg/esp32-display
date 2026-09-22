#include "audio_engine.h"

#include <string.h>

#include "audio_backend.h"
#include "audio_engine_model.h"
#include "audio_transport.h"

#if defined(CONFIG_IDF_TARGET_ESP32S3)
#include <esp_heap_caps.h>
#endif

namespace audioengine {

uint32_t tuneLowWatermarkMs = 80;
uint32_t tuneTargetWatermarkMs = 120;
uint32_t tuneHighWatermarkMs = 180;
int32_t tuneMaxCorrectionPpm = 400;
TaskHandle_t engineTaskHandle = nullptr;

#if defined(CONFIG_IDF_TARGET_ESP32S3)
namespace {

constexpr UBaseType_t ENGINE_TASK_PRIORITY = 12;
constexpr uint32_t ENGINE_TASK_STACK = 9216;
constexpr uint32_t MAX_JITTER_MS = 250;
constexpr uint32_t HARD_CORRECTION_MS = 10;
constexpr uint32_t FADE_MS = 5;
constexpr uint32_t STATUS_INTERVAL_MS = 250;
constexpr uint8_t MAX_CHANNELS = 2;

const board::Config *activeBoard = nullptr;
const board::AudioConfig *activeAudio = nullptr;
int16_t *jitterStorage = nullptr;
size_t jitterCapacityFrames = 0;
volatile bool engineAvailable = false;
volatile bool suppressVideo = false;
volatile bool streamSeen = false;
volatile bool localTestActive = false;

uint32_t framesForMs(uint32_t sampleRateHz, uint32_t milliseconds) {
  return (uint32_t)(((uint64_t)sampleRateHz * milliseconds) / 1000U);
}

bool render(JitterBuffer &jitter, ResampleCursor &cursor,
            int16_t *output, size_t outputFrames,
            uint8_t outputChannels) {
  const uint64_t step = cursor.stepQ32();
  uint64_t position = cursor.fractionQ32();
  const size_t lastIndex =
      (size_t)((position + step * (outputFrames - 1)) >> 32);
  if (jitter.fillFrames() <= lastIndex + 1) return false;

  for (size_t frame = 0; frame < outputFrames; ++frame) {
    const size_t sourceFrame = (size_t)(position >> 32);
    const uint32_t fraction = (uint32_t)position;
    int32_t converted[2] = {};
    for (uint8_t channel = 0; channel < jitter.channels(); ++channel) {
      const int32_t a = jitter.peek(sourceFrame, channel);
      const int32_t b = jitter.peek(sourceFrame + 1, channel);
      converted[channel] =
          a + (int32_t)(((int64_t)(b - a) * fraction) >> 32);
    }
    if (jitter.channels() == 1) {
      for (uint8_t channel = 0; channel < outputChannels; ++channel) {
        output[frame * outputChannels + channel] = (int16_t)converted[0];
      }
    } else if (outputChannels == 1) {
      output[frame] = (int16_t)((converted[0] + converted[1]) / 2);
    } else {
      output[frame * outputChannels] = (int16_t)converted[0];
      output[frame * outputChannels + 1] = (int16_t)converted[1];
    }
    position += step;
  }
  const size_t consumed = cursor.advance(outputFrames);
  return consumed <= jitter.fillFrames() && jitter.discard(consumed);
}

bool acceptPacket(const audiotransport::Packet &packet,
                  uint32_t sampleRateHz, JitterBuffer &jitter,
                  StreamTracker &tracker, ResampleCursor &cursor,
                  UnderrunController &underrun, uint8_t &inputChannels,
                  uint16_t &streamGeneration, volatile bool &seen,
                  volatile bool &videoSuppressed, uint32_t &lastPacketAt,
                  uint32_t &latePackets, uint32_t &lostFrames,
                  uint32_t &engineDrops, uint32_t nowMs) {
  if (packet.header.sampleRateHz != sampleRateHz ||
      packet.header.channels == 0 ||
      packet.header.channels > MAX_CHANNELS) {
    engineDrops++;
    return false;
  }
  StreamTracker candidateTracker = tracker;
  const StreamResult sequence = candidateTracker.accept(
      audioproto::VERSION, packet.header.streamGeneration,
      packet.header.sequence, packet.header.sampleCounter,
      packet.header.frameCount);
  if (sequence.decision == StreamDecision::VersionMismatch ||
      sequence.decision == StreamDecision::Discontinuity) {
    engineDrops++;
    return false;
  }
  if (sequence.decision == StreamDecision::Late) {
    latePackets++;
    engineDrops++;
    return false;
  }
  if (sequence.decision == StreamDecision::Start) {
    JitterBuffer candidateJitter;
    if (!candidateJitter.reset(
            jitterStorage, jitterCapacityFrames, packet.header.channels) ||
        !candidateJitter.push(packet.samples, packet.header.frameCount)) {
      engineDrops++;
      return false;
    }
    jitter = candidateJitter;
    tracker = candidateTracker;
    inputChannels = packet.header.channels;
    streamGeneration = packet.header.streamGeneration;
    cursor.reset();
    underrun.reset();
    seen = true;
    videoSuppressed = true;
  } else if (packet.header.channels != inputChannels) {
    engineDrops++;
    return false;
  } else {
    const size_t requiredFrames =
        (size_t)sequence.gapFrames + packet.header.frameCount;
    if (requiredFrames > jitter.freeFrames()) {
      engineDrops++;
      return false;
    }
    JitterBuffer candidateJitter = jitter;
    if ((sequence.gapFrames > 0 &&
         !candidateJitter.pushSilence(sequence.gapFrames)) ||
        !candidateJitter.push(packet.samples, packet.header.frameCount)) {
      engineDrops++;
      return false;
    }
    jitter = candidateJitter;
    tracker = candidateTracker;
    lostFrames += sequence.gapFrames;
  }
  lastPacketAt = nowMs;
  return true;
}

void fadeFromLastOutput(int16_t *output, size_t serviceFrames,
                        uint8_t outputChannels, size_t fadeFrames,
                        const int16_t *lastOutput) {
  memset(output, 0,
         serviceFrames * outputChannels * sizeof(int16_t));
  if (fadeFrames > serviceFrames) fadeFrames = serviceFrames;
  if (fadeFrames == 0) return;
  const int32_t denominator =
      fadeFrames > 1 ? (int32_t)(fadeFrames - 1) : 1;
  for (size_t frame = 0; frame < fadeFrames; ++frame) {
    const int32_t gain = (int32_t)(fadeFrames - frame - 1);
    for (uint8_t channel = 0; channel < outputChannels; ++channel) {
      output[frame * outputChannels + channel] =
          (int16_t)(((int32_t)lastOutput[channel] * gain) / denominator);
    }
  }
}

bool prepareOutputBlock(JitterBuffer &jitter, ResampleCursor &cursor,
                        int16_t *output, size_t serviceFrames,
                        uint8_t outputChannels, UnderrunState state,
                        bool correctionApplied,
                        const int16_t *correctionSource,
                        const int16_t *lastOutput, uint32_t fadeFrames) {
  const bool shouldRender =
      state == UnderrunState::Playing ||
      state == UnderrunState::FadingOut ||
      state == UnderrunState::FadingIn;
  bool rendered = false;
  if (shouldRender) {
    rendered = render(jitter, cursor, output, serviceFrames,
                      outputChannels);
  }
  if (!rendered) {
    fadeFromLastOutput(output, serviceFrames, outputChannels,
                       fadeFrames, lastOutput);
  } else if (correctionApplied) {
    crossfadeBlocks(correctionSource, output, serviceFrames,
                    outputChannels);
  } else if (state == UnderrunState::FadingOut) {
    applyEdgeFade(output, serviceFrames, outputChannels,
                  fadeFrames, false);
  } else if (state == UnderrunState::FadingIn) {
    applyEdgeFade(output, serviceFrames, outputChannels,
                  fadeFrames, true);
  }
  return rendered;
}

void engineTask(void *) {
  const uint32_t sampleRateHz = activeAudio->playbackRateHz;
  const uint8_t outputChannels = activeAudio->playbackChannels;
  const uint8_t captureChannels = activeAudio->captureChannels;
  const size_t maxPacketFrames =
      audioproto::MAX_PAYLOAD_BYTES /
      (sizeof(int16_t) * max(outputChannels, captureChannels));
  const size_t serviceFrames =
      min((size_t)framesForMs(sampleRateHz, 10), maxPacketFrames);
  static int16_t output[audioproto::MAX_PAYLOAD_BYTES / sizeof(int16_t)];
  static int16_t capture[audioproto::MAX_PAYLOAD_BYTES / sizeof(int16_t)];
  static int16_t correctionSource[
      audioproto::MAX_PAYLOAD_BYTES / sizeof(int16_t)];

  JitterBuffer jitter;
  StreamTracker tracker(framesForMs(sampleRateHz, 100));
  ResampleCursor cursor;
  UnderrunController underrun;
  PlaybackMetrics playbackMetrics;
  FillTrendController fillController({
      framesForMs(sampleRateHz, tuneTargetWatermarkMs),
      framesForMs(sampleRateHz, tuneLowWatermarkMs),
      framesForMs(sampleRateHz, tuneHighWatermarkMs),
      tuneMaxCorrectionPpm,
  });
  audio::CodecSerialAudioBackend &backend = audio::sharedCodecBackend();
  uint8_t inputChannels = 0;
  uint16_t streamGeneration = 0;
  uint32_t captureCounter = 0;
  uint32_t latePackets = 0;
  uint32_t lostFrames = 0;
  uint32_t hardCorrections = 0;
  uint32_t captureOverruns = 0;
  uint32_t engineDrops = 0;
  uint32_t lastStatusAt = 0;
  uint32_t lastPacketAt = 0;
  int16_t lastOutput[MAX_CHANNELS] = {};

  while (true) {
    if (localTestActive) {
      audiotransport::Packet discarded = {};
      while (audiotransport::receive(discarded, 0)) {
        engineDrops++;
      }
      tracker.reset();
      jitter.clear();
      playbackMetrics.reset();
      streamSeen = false;
      suppressVideo = false;
      vTaskDelay(1);
      continue;
    }
    audiotransport::Packet packet = {};
    bool received = audiotransport::receive(
        packet, backend.running() ? 0 : pdMS_TO_TICKS(2));
    while (received) {
      const bool startsStream =
          !streamSeen ||
          packet.header.streamGeneration != streamGeneration;
      const uint32_t receivedAt = millis();
      if (acceptPacket(packet, sampleRateHz, jitter, tracker, cursor,
                       underrun, inputChannels, streamGeneration,
                       streamSeen, suppressVideo, lastPacketAt, latePackets,
                       lostFrames, engineDrops, receivedAt) &&
          startsStream && backend.running()) {
        playbackMetrics.start((uint32_t)jitter.fillFrames(), receivedAt);
      }
      received = audiotransport::receive(packet, 0);
    }

    if (streamSeen &&
        streamIdleExpired(millis(), lastPacketAt,
                          DEFAULT_STREAM_IDLE_TIMEOUT_MS)) {
      // An active backend has already drained, faded, and emitted silence.
      // Release it instead of treating a departed sender as a permanent
      // low-watermark event that suppresses video forever.
      backend.stop();
      tracker.reset();
      jitter.clear();
      cursor.reset();
      underrun.reset();
      playbackMetrics.reset();
      streamSeen = false;
      suppressVideo = false;
      continue;
    }

    const uint32_t lowFrames =
        framesForMs(sampleRateHz, tuneLowWatermarkMs);
    const uint32_t targetFrames =
        framesForMs(sampleRateHz, tuneTargetWatermarkMs);
    const uint32_t highFrames =
        framesForMs(sampleRateHz, tuneHighWatermarkMs);
    if (!backend.running()) {
      if (streamSeen && jitter.fillFrames() >= targetFrames) {
        const audiobackend::Format backendFormat =
            audiobackend::descriptorFormat(*activeAudio);
        if (!backend.start(*activeBoard, *activeAudio, backendFormat)) {
          Serial.println("audio: ERROR backend start failed; stream muted");
          streamSeen = false;
          suppressVideo = false;
          tracker.reset();
          jitter.clear();
          playbackMetrics.reset();
        } else {
          playbackMetrics.start(
              (uint32_t)jitter.fillFrames(), millis());
        }
      }
      vTaskDelay(1);
      continue;
    }

    fillController.setConfig(
        {targetFrames, lowFrames, highFrames, tuneMaxCorrectionPpm});
    const DriftDecision drift =
        fillController.update((uint32_t)jitter.fillFrames());
    cursor.setCorrectionPpm(drift.ppm);
    bool correctionApplied = false;
    if (drift.hardCorrection == HardCorrection::DropCrossfadedBlock) {
      const size_t correctionLimit =
          (size_t)framesForMs(sampleRateHz, HARD_CORRECTION_MS);
      const size_t excess = jitter.fillFrames() > targetFrames
          ? (size_t)(jitter.fillFrames() - targetFrames)
          : (size_t)0;
      const size_t correction =
          correctionLimit < excess ? correctionLimit : excess;
      JitterBuffer uncorrectedJitter = jitter;
      ResampleCursor uncorrectedCursor = cursor;
      if (correction > 0 &&
          render(uncorrectedJitter, uncorrectedCursor, correctionSource,
                 serviceFrames, outputChannels) &&
          jitter.discard(correction)) {
        hardCorrections++;
        correctionApplied = true;
      }
    }

    const UnderrunState state = underrun.update(
        (uint32_t)jitter.fillFrames(), drift.trendFrames, lowFrames,
        targetFrames, (uint32_t)serviceFrames);
    prepareOutputBlock(
        jitter, cursor, output, serviceFrames, outputChannels, state,
        correctionApplied, correctionSource, lastOutput,
        framesForMs(sampleRateHz, FADE_MS));
    suppressVideo = state != UnderrunState::Playing ||
                    jitter.fillFrames() < lowFrames;
    size_t written = backend.writeFrames(output, serviceFrames);
    if (written != serviceFrames) {
      fadeFromLastOutput(
          output, serviceFrames, outputChannels,
          framesForMs(sampleRateHz, FADE_MS), lastOutput);
      written = backend.writeFrames(output, serviceFrames);
      suppressVideo = true;
    }
    if (written == serviceFrames) {
      for (uint8_t channel = 0; channel < outputChannels; ++channel) {
        lastOutput[channel] =
            output[(serviceFrames - 1) * outputChannels + channel];
      }
    }

    const size_t captured = backend.readFrames(capture, serviceFrames);
    if (captured == serviceFrames) {
      audiotransport::sendCapture(
          capture, (uint16_t)captured, captureChannels,
          activeAudio->captureRateHz, streamGeneration, captureCounter);
      captureCounter += (uint32_t)captured;
    } else {
      captureOverruns++;
    }

    const uint32_t now = millis();
    playbackMetrics.observe(
        (uint32_t)jitter.fillFrames(), state, now);
    if (now - lastStatusAt >= STATUS_INTERVAL_MS) {
      lastStatusAt = now;
      const audiotransport::Stats &transportStats =
          audiotransport::stats();
      audiotransport::sendStatus(
          streamGeneration, sampleRateHz,
          {
              (uint32_t)jitter.fillFrames(),
              targetFrames,
              playbackMetrics.minimumFillFrames(),
              underrun.underruns(),
              playbackMetrics.underrunDurationMs(now),
              latePackets,
              lostFrames,
              hardCorrections,
              transportStats.ingressDrops,
              transportStats.queueDrops,
              engineDrops,
              captureOverruns,
          });
    }
  }
}

}  // namespace

#if defined(ESPDISP_HOST_AUDIO_TEST)
namespace host {
namespace {

int16_t admissionStorage[64] = {};
JitterBuffer admissionJitter;
StreamTracker admissionTracker(128);
ResampleCursor admissionCursor;
UnderrunController admissionUnderrun;
uint8_t admissionChannels = 0;
uint16_t admissionGeneration = 0;
bool admissionSeen = false;
volatile bool admissionSuppressed = false;
uint32_t admissionLastPacketAt = 0;
uint32_t admissionLatePackets = 0;
uint32_t admissionLostFrames = 0;
uint32_t admissionEngineDrops = 0;

}  // namespace

void resetAdmission(size_t capacityFrames) {
  if (capacityFrames > 32) capacityFrames = 32;
  jitterStorage = admissionStorage;
  jitterCapacityFrames = capacityFrames;
  admissionJitter = JitterBuffer();
  admissionTracker = StreamTracker(128);
  admissionCursor = ResampleCursor();
  admissionUnderrun = UnderrunController();
  admissionChannels = 0;
  admissionGeneration = 0;
  admissionSeen = false;
  admissionSuppressed = false;
  admissionLastPacketAt = 0;
  admissionLatePackets = 0;
  admissionLostFrames = 0;
  admissionEngineDrops = 0;
}

bool admitPacket(const audiotransport::Packet &packet, uint32_t nowMs) {
  return acceptPacket(
      packet, 16000, admissionJitter, admissionTracker, admissionCursor,
      admissionUnderrun, admissionChannels, admissionGeneration,
      admissionSeen, admissionSuppressed, admissionLastPacketAt,
      admissionLatePackets, admissionLostFrames, admissionEngineDrops,
      nowMs);
}

bool discardFrames(size_t frames) {
  return admissionJitter.discard(frames);
}

AdmissionSnapshot admissionSnapshot() {
  return {
      (uint32_t)admissionJitter.fillFrames(),
      admissionLastPacketAt,
      admissionLatePackets,
      admissionLostFrames,
      admissionEngineDrops,
      admissionSeen,
  };
}

bool renderFadingOut(const int16_t *input, size_t inputFrames,
                     uint8_t channels, size_t outputFrames,
                     const int16_t *lastOutput, int16_t *output) {
  int16_t storage[64] = {};
  if (input == nullptr || lastOutput == nullptr || output == nullptr ||
      inputFrames * channels > 64 || outputFrames == 0 ||
      outputFrames * channels > 64) {
    return false;
  }
  JitterBuffer jitter;
  if (!jitter.reset(storage, inputFrames, channels) ||
      !jitter.push(input, inputFrames)) {
    return false;
  }
  ResampleCursor cursor;
  int16_t mutableLastOutput[2] = {
      lastOutput[0],
      (int16_t)(channels > 1 ? lastOutput[1] : 0),
  };
  return prepareOutputBlock(
      jitter, cursor, output, outputFrames, channels,
      UnderrunState::FadingOut, false, nullptr, mutableLastOutput,
      outputFrames / 2);
}

}  // namespace host
#endif

bool start(const board::Config &config) {
  activeAudio = board::generatedAudioConfig(config.variant);
  if (activeAudio == nullptr ||
      audiobackend::classify(*activeAudio) !=
          audiobackend::DescriptorStatus::Ready) {
    return false;
  }
  const size_t capacityFrames =
      framesForMs(activeAudio->playbackRateHz, MAX_JITTER_MS) + 2;
  const size_t samples = capacityFrames * MAX_CHANNELS;
  jitterStorage = static_cast<int16_t *>(heap_caps_malloc(
      samples * sizeof(int16_t), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
  if (jitterStorage == nullptr) return false;
  jitterCapacityFrames = capacityFrames;
  activeBoard = &config;
  if (xTaskCreatePinnedToCore(
          engineTask, "audioeng", ENGINE_TASK_STACK, nullptr,
          ENGINE_TASK_PRIORITY, &engineTaskHandle, 1) != pdPASS) {
    heap_caps_free(jitterStorage);
    jitterStorage = nullptr;
    return false;
  }
  engineAvailable = true;
  return true;
}

void stop() {
  engineAvailable = false;
  streamSeen = false;
  suppressVideo = false;
  localTestActive = false;
  if (engineTaskHandle != nullptr) {
    vTaskDelete(engineTaskHandle);
    engineTaskHandle = nullptr;
  }
  audio::sharedCodecBackend().stop();
  if (jitterStorage != nullptr) {
    heap_caps_free(jitterStorage);
    jitterStorage = nullptr;
  }
  jitterCapacityFrames = 0;
  activeAudio = nullptr;
  activeBoard = nullptr;
}

bool available() { return engineAvailable; }
bool shouldSuppressVideo() { return streamSeen && suppressVideo; }
bool streamActive() { return streamSeen; }
void setLocalTestActive(bool active) { localTestActive = active; }

#else

bool start(const board::Config &) { return false; }
void stop() {}
bool available() { return false; }
bool shouldSuppressVideo() { return false; }
bool streamActive() { return false; }
void setLocalTestActive(bool) {}

#endif

}  // namespace audioengine
