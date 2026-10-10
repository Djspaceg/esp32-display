#include "audio_test.h"

#include <Arduino.h>
#include <stdio.h>
#include <string.h>

#include "audio_backend.h"
#include "audio_engine.h"
#include "audio_tone_meter.h"

namespace {

#if defined(ESPDISP_AUDIO_RUNTIME)
constexpr uint32_t TONE_FREQUENCY_HZ = 440;
constexpr uint32_t SERVICE_INTERVAL_MS = 10;
constexpr size_t MAX_SERVICE_FRAMES = 640;
constexpr uint8_t MAX_CHANNELS = 2;
// The engine task parks within one service block (10 ms) unless an I2S write
// is stuck; past this the tone gives up rather than share the backend.
constexpr uint32_t ENGINE_PARK_WAIT_MS = 200;
// The tone follows this much silence, so the microphones' level at the tone's
// frequency can be compared with the same amplifier and codec state. Each
// window's start is skipped: the I2S DMA queues about 90 ms each way, so the
// first reads of a window still hold the one before.
constexpr uint32_t LEAD_SILENCE_MS = 500;
constexpr uint32_t WINDOW_SETTLE_MS = 200;
// Then the tone plays on this long with the amplifier off. Sound from the
// speaker stops with the amplifier; 440 Hz coupled into the microphones
// electrically from the codec side does not, so the two rises tell them
// apart where one rise alone cannot.
constexpr uint32_t AMP_OFF_CONTROL_MS = 500;
// 25 ms blocks put 440 Hz on a whole bin (11 cycles).
constexpr uint32_t METER_BLOCK_MS = 25;
constexpr uint8_t ES8311_REPORTED_REGISTERS[] = {0x12, 0x13, 0x31, 0x32};

audiobackend::ToneGenerator toneGenerator;
uint32_t leadFramesRemaining = 0;
uint32_t framesRemaining = 0;
uint32_t ampOffFramesRemaining = 0;
bool ampOffStarted = false;
uint32_t windowFrames = 0;
uint32_t settleFrames = 0;
uint8_t captureChannels = 0;
audiometer::ToneMeter silenceMeter;
audiometer::ToneMeter toneMeter;
audiometer::ToneMeter ampOffMeter;
AudioToneLoopback loopback = {};
int16_t captured[MAX_SERVICE_FRAMES * MAX_CHANNELS] = {};
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
    leadFramesRemaining = 0;
    framesRemaining = 0;
    ampOffFramesRemaining = 0;
    audioengine::setLocalTestActive(false);
    return "codec/I2S initialization failed; amp remains disabled";
  }
  toneOwnsBackend = true;
  if (pausesStream) {
    Serial.println("audio: network stream paused for the tone");
  }
  toneGenerator.reset(format.sampleRateHz, format.channels, TONE_FREQUENCY_HZ);
  leadFramesRemaining =
      (uint32_t)(((uint64_t)format.sampleRateHz * LEAD_SILENCE_MS) / 1000U);
  framesRemaining =
      (uint32_t)(((uint64_t)format.sampleRateHz * durationMs) / 1000U);
  ampOffFramesRemaining = 0;
  ampOffStarted = false;
  windowFrames = 0;
  settleFrames =
      (uint32_t)(((uint64_t)format.sampleRateHz * WINDOW_SETTLE_MS) / 1000U);
  // The I2S receive side runs in the playback slot mode and at its clock, so
  // the microphones are only read as such when the descriptor says the same.
  captureChannels =
      audioConfig->captureChannels <= MAX_CHANNELS &&
              audioConfig->captureChannels == format.channels &&
              audioConfig->captureRateHz == format.sampleRateHz
          ? audioConfig->captureChannels
          : 0;
  const size_t blockFrames =
      (format.sampleRateHz * METER_BLOCK_MS) / 1000U;
  silenceMeter.reset(format.sampleRateHz, captureChannels, TONE_FREQUENCY_HZ,
                     blockFrames);
  toneMeter.reset(format.sampleRateHz, captureChannels, TONE_FREQUENCY_HZ,
                  blockFrames);
  ampOffMeter.reset(format.sampleRateHz, captureChannels, TONE_FREQUENCY_HZ,
                    blockFrames);
  loopback = {};
  Serial.printf(
      "audio: tone started rate=%lu channels=%u bits=%u duration=%lums "
      "after %lums silence mclk=%d bclk=%d lrck=%d dout=%d amp=%d\n",
      (unsigned long)format.sampleRateHz, (unsigned)format.channels,
      (unsigned)format.bitsPerSample, (unsigned long)durationMs,
      (unsigned long)LEAD_SILENCE_MS,
      audioConfig->pinPlaybackMclk, audioConfig->pinPlaybackBclk,
      audioConfig->pinPlaybackLrck, audioConfig->pinDout,
      audioConfig->pinAmpEnable);
  return nullptr;
#else
  (void)durationMs;
  return "audio backend unavailable on this target";
#endif
}

#if defined(ESPDISP_AUDIO_RUNTIME)
namespace {

// Printed while the amplifier is still enabled, so it shows the state the
// tone played in.
void reportReadback(audio::CodecSerialAudioBackend &backend) {
  char registers[64] = {};
  size_t used = 0;
  for (uint8_t reg : ES8311_REPORTED_REGISTERS) {
    uint8_t value = 0;
    const bool read = backend.readCodecRegister(reg, value);
    const int written = read
        ? snprintf(registers + used, sizeof(registers) - used,
                   " 0x%02x=0x%02x", reg, value)
        : snprintf(registers + used, sizeof(registers) - used,
                   " 0x%02x=??", reg);
    if (written > 0) used += (size_t)written;
    if (used >= sizeof(registers)) break;
  }
  Serial.printf("audio: readback amp enable=%d es8311%s\n",
                backend.ampEnableLevel(), registers);
}

// What the microphones heard at 440 Hz, not a verdict on its own: a speaker
// heard through the air rises with the amplifier on and falls back with it
// off, while electrical coupling rises either way.
void reportLoopback() {
  if (captureChannels == 0) {
    Serial.println(
        "audio: mic loopback not measured (capture format differs from "
        "playback)");
    return;
  }
  if (silenceMeter.blocks() == 0 || toneMeter.blocks() == 0 ||
      ampOffMeter.blocks() == 0) {
    Serial.printf(
        "audio: mic loopback not measured (tone too short; needs >= %lu "
        "ms)\n",
        (unsigned long)(WINDOW_SETTLE_MS + METER_BLOCK_MS));
    return;
  }
  loopback.measured = true;
  loopback.channels = captureChannels;
  for (uint8_t channel = 0; channel < captureChannels; ++channel) {
    loopback.silenceDbfs[channel] = silenceMeter.levelDbfs(channel);
    loopback.toneDbfs[channel] = toneMeter.levelDbfs(channel);
    loopback.ampOffDbfs[channel] = ampOffMeter.levelDbfs(channel);
    Serial.printf(
        "audio: mic%u at %lu Hz: silence %.1f, tone %.1f, tone with amp off "
        "%.1f dBFS; rise %+.1f dB amp on, %+.1f dB amp off "
        "(%lu/%lu/%lu blocks)\n",
        (unsigned)(channel + 1), (unsigned long)TONE_FREQUENCY_HZ,
        loopback.silenceDbfs[channel], loopback.toneDbfs[channel],
        loopback.ampOffDbfs[channel],
        loopback.toneDbfs[channel] - loopback.silenceDbfs[channel],
        loopback.ampOffDbfs[channel] - loopback.silenceDbfs[channel],
        (unsigned long)silenceMeter.blocks(),
        (unsigned long)toneMeter.blocks(),
        (unsigned long)ampOffMeter.blocks());
  }
}

}  // namespace
#endif

void stopAudioToneTest(bool report) {
#if defined(ESPDISP_AUDIO_RUNTIME)
  leadFramesRemaining = 0;
  framesRemaining = 0;
  ampOffFramesRemaining = 0;
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
    leadFramesRemaining = 0;
    framesRemaining = 0;
    ampOffFramesRemaining = 0;
    audioengine::setLocalTestActive(false);
    return;
  }
  if (leadFramesRemaining == 0 && framesRemaining == 0 &&
      ampOffFramesRemaining == 0) {
    // With no control window run, the amplifier is still on for the readback.
    if (!ampOffStarted) reportReadback(backend);
    reportLoopback();
    stopAudioToneTest(false);
    Serial.println("audio: tone complete; amp disabled, codec muted");
    return;
  }
  const bool lead = leadFramesRemaining > 0;
  const bool ampOff = !lead && framesRemaining == 0;
  const audiobackend::Format &format = backend.format();
  const size_t intervalFrames =
      (format.sampleRateHz * SERVICE_INTERVAL_MS) / 1000U;
  const size_t frames =
      min((size_t)(lead ? leadFramesRemaining
                        : ampOff ? ampOffFramesRemaining
                                 : framesRemaining),
          min(intervalFrames, MAX_SERVICE_FRAMES));
  if (lead) {
    memset(samples, 0, frames * format.channels * sizeof(int16_t));
  } else if (toneGenerator.fill(samples, frames) != frames) {
    stopAudioToneTest(false);
    Serial.println("audio: ERROR tone write failed; amp disabled");
    return;
  }
  if (backend.writeFrames(samples, frames) != frames) {
    stopAudioToneTest(false);
    Serial.println("audio: ERROR tone write failed; amp disabled");
    return;
  }
  // One read per write keeps the microphones in step with the speaker; the
  // backend's capture runs at the playback rate.
  if (captureChannels > 0) {
    const size_t heard = backend.readFrames(captured, frames);
    if (windowFrames >= settleFrames) {
      (lead     ? silenceMeter
       : ampOff ? ampOffMeter
                : toneMeter)
          .add(captured, heard, captureChannels);
    }
  }
  windowFrames += (uint32_t)frames;
  if (lead) {
    leadFramesRemaining -= (uint32_t)frames;
    if (leadFramesRemaining == 0) windowFrames = 0;
  } else if (ampOff) {
    ampOffFramesRemaining -= (uint32_t)frames;
  } else {
    framesRemaining -= (uint32_t)frames;
    // Straight into the control window, so the test never reads as idle
    // between the two.
    if (framesRemaining == 0 && captureChannels > 0) {
      reportReadback(backend);
      backend.setAmpEnabled(false);
      ampOffStarted = true;
      ampOffFramesRemaining = (uint32_t)(
          ((uint64_t)format.sampleRateHz * AMP_OFF_CONTROL_MS) / 1000U);
      windowFrames = 0;
    }
  }
#endif
}

bool audioToneTestRunning() {
#if defined(ESPDISP_AUDIO_RUNTIME)
  return toneOwnsBackend &&
         (leadFramesRemaining > 0 || framesRemaining > 0 ||
          ampOffFramesRemaining > 0) &&
         audio::sharedCodecBackend().running();
#else
  return false;
#endif
}

AudioToneLoopback lastAudioToneLoopback() {
#if defined(ESPDISP_AUDIO_RUNTIME)
  return loopback;
#else
  return {};
#endif
}
