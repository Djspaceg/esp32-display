#include "audio_test.h"

#include <Arduino.h>

#include "audio_backend.h"

namespace {

#if defined(CONFIG_IDF_TARGET_ESP32S3)
constexpr uint32_t TONE_FREQUENCY_HZ = 440;
constexpr uint32_t SERVICE_INTERVAL_MS = 10;
constexpr size_t MAX_SERVICE_FRAMES = 640;
constexpr uint8_t MAX_CHANNELS = 2;

audio::CodecSerialAudioBackend backend;
audiobackend::ToneGenerator toneGenerator;
uint32_t framesRemaining = 0;
int16_t samples[MAX_SERVICE_FRAMES * MAX_CHANNELS] = {};
#endif

}  // namespace

const char *startAudioToneTest(const board::Config &config,
                               uint32_t durationMs) {
  const board::AudioConfig *audioConfig =
      board::generatedAudioConfig(config.variant);
  if (audioConfig == nullptr) return "no generated audio descriptor";
  switch (audiobackend::classify(*audioConfig)) {
    case audiobackend::DescriptorStatus::NoAudio:
      return "board descriptor has no audio";
    case audiobackend::DescriptorStatus::UnsupportedTopology:
      return "audio descriptor topology is unsupported";
    case audiobackend::DescriptorStatus::RevisionNotApproved:
      return "audio disabled: board revision is not safely distinguishable";
    case audiobackend::DescriptorStatus::Ready:
      break;
  }

#if defined(CONFIG_IDF_TARGET_ESP32S3)
  const audiobackend::Format format =
      audiobackend::descriptorFormat(*audioConfig);
  if (!backend.start(config, *audioConfig, format)) {
    return "codec/I2S initialization failed; amp remains disabled";
  }
  toneGenerator.reset(format.sampleRateHz, format.channels, TONE_FREQUENCY_HZ);
  framesRemaining =
      (uint32_t)(((uint64_t)format.sampleRateHz * durationMs) / 1000U);
  Serial.printf(
      "audio: tone started rate=%lu channels=%u bits=%u duration=%lums "
      "mclk=%d bclk=%d lrck=%d dout=%d amp=%d\n",
      (unsigned long)format.sampleRateHz, (unsigned)format.channels,
      (unsigned)format.bitsPerSample, (unsigned long)durationMs,
      audioConfig->pinPlaybackMclk, audioConfig->pinPlaybackBclk,
      audioConfig->pinPlaybackLrck, audioConfig->pinDout,
      audioConfig->pinAmpEnable);
  return nullptr;
#else
  (void)durationMs;
  return "audio backend unavailable on this target";
#endif
}

void stopAudioToneTest(bool report) {
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  const bool wasRunning = backend.running();
  framesRemaining = 0;
  backend.stop();
  if (report && wasRunning) {
    Serial.println("audio: tone stopped; amp disabled, codec muted");
  }
#else
  (void)report;
#endif
}

void serviceAudioToneTest() {
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  if (!backend.running()) return;
  if (framesRemaining == 0) {
    stopAudioToneTest(false);
    Serial.println("audio: tone complete; amp disabled, codec muted");
    return;
  }
  const audiobackend::Format &format = backend.format();
  const size_t intervalFrames =
      (format.sampleRateHz * SERVICE_INTERVAL_MS) / 1000U;
  const size_t frames =
      min((size_t)framesRemaining, min(intervalFrames, MAX_SERVICE_FRAMES));
  if (toneGenerator.fill(samples, frames) != frames ||
      backend.writeFrames(samples, frames) != frames) {
    stopAudioToneTest(false);
    Serial.println("audio: ERROR tone write failed; amp disabled");
    return;
  }
  framesRemaining -= (uint32_t)frames;
#endif
}

bool audioToneTestRunning() {
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  return backend.running();
#else
  return false;
#endif
}
