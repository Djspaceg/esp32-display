#pragma once

#include <array>
#include <stddef.h>
#include <stdint.h>

#include <board_config.h>

// The codec backend, engine, transport, and tone test run on the dual-core
// targets whose boards carry audio. C3 and C6 boards have none.
#if defined(CONFIG_IDF_TARGET_ESP32S3) || defined(CONFIG_IDF_TARGET_ESP32P4)
#define ESPDISP_AUDIO_RUNTIME 1
#endif

namespace audiobackend {

struct Format {
  uint32_t sampleRateHz;
  uint8_t channels;
  uint8_t bitsPerSample;
};

enum class DescriptorStatus : uint8_t {
  NoAudio,
  UnsupportedTopology,
  HardwareNotIdentified,
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
  return DescriptorStatus::Ready;
}

// Chip-ID registers read to identify the parts positively. An ACK alone could
// come from any device strapped to the same address.
inline constexpr uint8_t ES8311_CHIP_ID1_REG = 0xFD;
inline constexpr uint8_t ES8311_CHIP_ID2_REG = 0xFE;
inline constexpr uint8_t ES8311_CHIP_ID1 = 0x83;
inline constexpr uint8_t ES8311_CHIP_ID2 = 0x11;
inline constexpr uint8_t ES7210_CHIP_ID1_REG = 0x3D;
inline constexpr uint8_t ES7210_CHIP_ID0_REG = 0x3E;
inline constexpr uint8_t ES7210_CHIP_ID1 = 0x72;
inline constexpr uint8_t ES7210_CHIP_ID0 = 0x10;

// What a read-only probe of the descriptor's two I2C addresses returned.
struct CodecProbe {
  bool codecRead;
  uint8_t codecId1;
  uint8_t codecId2;
  bool micRead;
  uint8_t micId1;
  uint8_t micId0;
};

// Both parts must answer with their own chip IDs. This is what separates the
// 1.85C V2 (ES8311 + ES7210 on the touch bus) from V1, whose PCM5101A and
// ICS-43434 have no I2C interface, and it keeps every other codec board from
// powering audio when the expected parts are not actually there.
inline bool codecsIdentified(const CodecProbe &probe) {
  return probe.codecRead && probe.codecId1 == ES8311_CHIP_ID1 &&
         probe.codecId2 == ES8311_CHIP_ID2 && probe.micRead &&
         probe.micId1 == ES7210_CHIP_ID1 && probe.micId0 == ES7210_CHIP_ID0;
}

// A supported descriptor becomes Ready only once the parts it names have been
// positively identified on this board.
inline DescriptorStatus runtimeStatus(const board::AudioConfig &config,
                                      bool hardwareIdentified) {
  const DescriptorStatus status = classify(config);
  if (status != DescriptorStatus::Ready) return status;
  return hardwareIdentified ? DescriptorStatus::Ready
                            : DescriptorStatus::HardwareNotIdentified;
}

struct ControlBus {
  int8_t sda;
  int8_t scl;
};

// The codec control bus: the descriptor's own pair when declared (the 0.85
// has no touch bus), otherwise the board's touch I2C bus the codecs share.
inline ControlBus controlBus(const board::Config &boardConfig,
                             const board::AudioConfig &audioConfig) {
  if (audioConfig.pinControlSda != board::NO_PIN &&
      audioConfig.pinControlScl != board::NO_PIN) {
    return {audioConfig.pinControlSda, audioConfig.pinControlScl};
  }
  return {boardConfig.pinTouchSda, boardConfig.pinTouchScl};
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
  // Values are vendor-driver coefficients that match the Arduino I2S layer's
  // 256*sample-rate MCLK. Rates without a matching 256-Fs tuple are rejected.
  switch (sampleRateHz) {
    case 16000:
      out = {0xC1, 0x20, 0x01, 0x00};
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
