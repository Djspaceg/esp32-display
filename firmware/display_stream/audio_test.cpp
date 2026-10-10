#include "audio_test.h"

#include <Arduino.h>

#include "audio_backend.h"
#include "audio_engine.h"

namespace {

#if defined(ESPDISP_AUDIO_RUNTIME)
constexpr uint32_t TONE_FREQUENCY_HZ = 440;
constexpr uint32_t SERVICE_INTERVAL_MS = 10;
constexpr size_t MAX_SERVICE_FRAMES = 640;
constexpr uint8_t MAX_CHANNELS = 2;
// The engine task parks within one service block (10 ms) unless an I2S write
// is stuck; past this the tone gives up rather than share the backend.
constexpr uint32_t ENGINE_PARK_WAIT_MS = 200;

audiobackend::ToneGenerator toneGenerator;
uint32_t framesRemaining = 0;
// The codec backend is shared with the network audio engine. Only a backend
// this test started is the test's to service or stop: the loop task used to
// stop any running backend with no tone pending, which tore I2S down under a
// live sender stream and left the engine spinning until the loop watchdog
// rebooted the board.
bool toneOwnsBackend = false;
int16_t samples[MAX_SERVICE_FRAMES * MAX_CHANNELS] = {};
#endif

}  // namespace

const char *startAudioToneTest(const board::Config &config,
                               uint32_t durationMs) {
  const board::AudioConfig *audioConfig =
      board::generatedAudioConfig(config.variant);
  if (audioConfig == nullptr) return "no generated audio descriptor";
  switch (audio::boardAudioStatus(config)) {
    case audiobackend::DescriptorStatus::NoAudio:
      return "board descriptor has no audio";
    case audiobackend::DescriptorStatus::UnsupportedTopology:
      return "audio descriptor topology is unsupported";
    case audiobackend::DescriptorStatus::HardwareNotIdentified:
      // Kept verbatim for CFG clients: the codec and ADC did not both answer
      // with their chip IDs, which on the 1.85C means the V1 revision.
      return "audio disabled: board revision is not safely distinguishable";
    case audiobackend::DescriptorStatus::Ready:
      break;
  }

#if defined(ESPDISP_AUDIO_RUNTIME)
  // A connected sender streams the whole time, silence included, so the tone
  // takes precedence: the engine drops the stream and lets go of the codec
  // for the tone's length, and the stream plays again after it.
  const bool pausesStream = audioengine::streamActive();
  // A tone already playing holds the engine; re-arming the hold here could
  // only time out into releasing it under that tone's running backend.
  if (!toneOwnsBackend) {
    audioengine::setLocalTestActive(true);
    for (TickType_t waited = 0; !audioengine::localTestHeld() &&
                                waited < pdMS_TO_TICKS(ENGINE_PARK_WAIT_MS);
         ++waited) {
      vTaskDelay(1);
    }
    if (!audioengine::localTestHeld()) {
      audioengine::setLocalTestActive(false);
      return "network audio did not pause; amp unchanged";
    }
  }
  audio::CodecSerialAudioBackend &backend = audio::sharedCodecBackend();
  const audiobackend::Format format =
      audiobackend::descriptorFormat(*audioConfig);
  if (!backend.start(config, *audioConfig, format)) {
    // Ownership goes with the hold, so a tone owning the backend always means
    // the engine is held: a re-sent tone relies on that to skip the wait.
    toneOwnsBackend = false;
    framesRemaining = 0;
    audioengine::setLocalTestActive(false);
    return "codec/I2S initialization failed; amp remains disabled";
  }
  toneOwnsBackend = true;
  if (pausesStream) {
    Serial.println("audio: network stream paused for the tone");
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
#if defined(ESPDISP_AUDIO_RUNTIME)
  framesRemaining = 0;
  if (!toneOwnsBackend) return;
  audio::CodecSerialAudioBackend &backend = audio::sharedCodecBackend();
  const bool wasRunning = backend.running();
  backend.stop();
  toneOwnsBackend = false;
  audioengine::setLocalTestActive(false);
  if (report && wasRunning) {
    Serial.println("audio: tone stopped; amp disabled, codec muted");
  }
#else
  (void)report;
#endif
}

void serviceAudioToneTest() {
#if defined(ESPDISP_AUDIO_RUNTIME)
  audio::CodecSerialAudioBackend &backend = audio::sharedCodecBackend();
  if (!toneOwnsBackend) return;
  if (!backend.running()) {
    // Stopped underneath the test (the engine's dead-I2S path): release the
    // engine's local-test hold so a sender's stream can play again.
    toneOwnsBackend = false;
    framesRemaining = 0;
    audioengine::setLocalTestActive(false);
    return;
  }
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
#if defined(ESPDISP_AUDIO_RUNTIME)
  return toneOwnsBackend && framesRemaining > 0 &&
         audio::sharedCodecBackend().running();
#else
  return false;
#endif
}
