#pragma once

#include <array>
#include <stddef.h>
#include <stdint.h>

#include <board_config.h>

namespace audiobackend {

struct Format {
  uint32_t sampleRateHz;
  uint8_t channels;
  uint8_t bitsPerSample;
};

enum class DescriptorStatus : uint8_t {
  NoAudio,
  UnsupportedTopology,
  RevisionNotApproved,
  Ready,
};

inline DescriptorStatus classify(const board::AudioConfig &config) {
  if (config.amp == board::AudioAmp::None &&
      config.codec == board::AudioCodec::None &&
      config.mic == board::AudioMic::None) {
    return DescriptorStatus::NoAudio;
  }
  if (config.amp != board::AudioAmp::Ns4150b ||
      config.codec != board::AudioCodec::Es8311 ||
      config.mic != board::AudioMic::Es7210 ||
      config.speakerBus != board::AudioSpeakerBus::I2s ||
      config.micBus != board::AudioMicBus::I2s ||
      config.pinPlaybackMclk == board::NO_PIN ||
      config.pinPlaybackBclk == board::NO_PIN ||
      config.pinPlaybackLrck == board::NO_PIN ||
      config.pinDout == board::NO_PIN ||
      config.pinCaptureMclk != config.pinPlaybackMclk ||
      config.pinCaptureBclk != config.pinPlaybackBclk ||
      config.pinCaptureLrck != config.pinPlaybackLrck ||
      config.pinDin == board::NO_PIN ||
      config.pinAmpEnable == board::NO_PIN ||
      config.codecI2cAddress == 0 || config.micI2cAddress == 0 ||
      config.playbackRateHz == 0 || config.captureRateHz == 0 ||
      config.playbackRateHz != config.captureRateHz ||
      config.playbackChannels == 0 || config.playbackChannels > 2 ||
      config.captureChannels == 0 || config.captureChannels > 2) {
    return DescriptorStatus::UnsupportedTopology;
  }
  // The 1.85C descriptor records V2 wiring, but runtime detection cannot yet
  // distinguish V2 from incompatible V1 hardware. Only the uniquely identified
  // 1.75C may drive audio until revision metadata or variants are approved.
  if (config.variant != board::Variant::AmoledCo5300) {
    return DescriptorStatus::RevisionNotApproved;
  }
  return DescriptorStatus::Ready;
}

inline bool matchesBoard(const board::Config &boardConfig,
                         const board::AudioConfig &audioConfig) {
  return boardConfig.variant == audioConfig.variant;
}

inline Format descriptorFormat(const board::AudioConfig &config) {
  return {config.playbackRateHz, config.playbackChannels, 16};
}

struct Es7210Clock {
  uint8_t mainClock;
  uint8_t osr;
  uint8_t lrckHigh;
  uint8_t lrckLow;
};

inline bool es7210Clock(uint32_t sampleRateHz, Es7210Clock &out) {
  // Values are the vendor driver's coefficients for an ESP-generated
  // 256*sample-rate MCLK. Keeping the rate as a lookup parameter means a
  // descriptor change to one of these demonstrated rates needs no driver
  // rewrite.
  switch (sampleRateHz) {
    case 16000:
      out = {0xC1, 0x20, 0x01, 0x00};
      return true;
    case 24000:
      out = {0x81, 0x20, 0x02, 0x00};
      return true;
    case 44100:
    case 48000:
      out = {0xC1, 0x20, 0x01, 0x00};
      return true;
    case 64000:
      out = {0x81, 0x20, 0x01, 0x00};
      return true;
    default:
      return false;
  }
}

inline bool supportsCodecClock(uint32_t sampleRateHz) {
  Es7210Clock ignored = {};
  return es7210Clock(sampleRateHz, ignored);
}

enum class PowerStep : uint8_t {
  DisableAmp,
  StartClocks,
  PrimeSilence,
  InitializeCodecsMuted,
  SetGain,
  UnmuteCodec,
  EnableAmp,
};

inline constexpr std::array<PowerStep, 7> SAFE_POWER_UP = {
    PowerStep::DisableAmp,
    PowerStep::StartClocks,
    PowerStep::PrimeSilence,
    PowerStep::InitializeCodecsMuted,
    PowerStep::SetGain,
    PowerStep::UnmuteCodec,
    PowerStep::EnableAmp,
};

class ToneGenerator {
 public:
  ToneGenerator() = default;
  ToneGenerator(uint32_t sampleRateHz, uint8_t channels,
                uint32_t frequencyHz) {
    reset(sampleRateHz, channels, frequencyHz);
  }

  void reset(uint32_t sampleRateHz, uint8_t channels, uint32_t frequencyHz) {
    channels_ = channels;
    phase_ = 0;
    phaseStep_ =
        sampleRateHz == 0 ? 0 : (uint32_t)(((uint64_t)frequencyHz << 32) /
                                           sampleRateHz);
  }

  size_t fill(int16_t *output, size_t frames) {
    if (output == nullptr || channels_ == 0 || phaseStep_ == 0) return 0;
    for (size_t frame = 0; frame < frames; ++frame) {
      const uint16_t ramp = (uint16_t)(phase_ >> 16);
      const int32_t triangle =
          ramp < 32768 ? (int32_t)ramp * 2 - 32767
                       : (int32_t)(65535 - ramp) * 2 - 32767;
      const int16_t sample = (int16_t)(triangle / 5);
      for (uint8_t channel = 0; channel < channels_; ++channel) {
        output[frame * channels_ + channel] = sample;
      }
      phase_ += phaseStep_;
    }
    return frames;
  }

 private:
  uint8_t channels_ = 0;
  uint32_t phase_ = 0;
  uint32_t phaseStep_ = 0;
};

}  // namespace audiobackend
