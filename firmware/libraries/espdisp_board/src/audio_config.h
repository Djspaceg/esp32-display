#pragma once

#include <stdint.h>

namespace board {

enum class Variant : uint8_t;

enum class AudioAmp : uint8_t { None, Unknown, Ns4150b, Ns8002 };
enum class AudioCodec : uint8_t { None, Unknown, Es8311, Pcm5101a };
enum class AudioMic : uint8_t { None, Unknown, Es7210, Ics43434, Pdm };
enum class AudioSpeakerBus : uint8_t { None, Unknown, I2s };
enum class AudioMicBus : uint8_t { None, Unknown, I2s, Pdm };

struct AudioConfig {
  Variant variant;
  AudioAmp amp;
  AudioCodec codec;
  AudioMic mic;
  AudioSpeakerBus speakerBus;
  AudioMicBus micBus;
  int8_t pinPlaybackMclk;
  int8_t pinPlaybackBclk;
  int8_t pinPlaybackLrck;
  int8_t pinDout;
  int8_t pinCaptureMclk;
  int8_t pinCaptureBclk;
  int8_t pinCaptureLrck;
  int8_t pinDin;
  int8_t pinPdmClock;
  int8_t pinAmpEnable;
  uint8_t codecI2cAddress;
  uint8_t micI2cAddress;
  uint32_t playbackRateHz;
  uint8_t playbackChannels;
  uint32_t captureRateHz;
  uint8_t captureChannels;
};

}  // namespace board
