#pragma once

#include <stddef.h>
#include <stdint.h>

#include <board_config.h>

#include "audio_backend_model.h"

namespace audio {

class AudioBackend {
 public:
  virtual ~AudioBackend() = default;
  virtual bool start(const board::Config &boardConfig,
                     const board::AudioConfig &audioConfig,
                     const audiobackend::Format &format) = 0;
  virtual size_t writeFrames(const int16_t *samples, size_t frameCount) = 0;
  virtual size_t readFrames(int16_t *samples, size_t frameCount) = 0;
  virtual bool setGain(uint8_t percent) = 0;
  virtual void stop() = 0;
};

class CodecSerialAudioBackend final : public AudioBackend {
 public:
  bool start(const board::Config &boardConfig,
             const board::AudioConfig &audioConfig,
             const audiobackend::Format &format) override;
  size_t writeFrames(const int16_t *samples, size_t frameCount) override;
  size_t readFrames(int16_t *samples, size_t frameCount) override;
  bool setGain(uint8_t percent) override;
  void stop() override;

  bool running() const { return running_; }
  const audiobackend::Format &format() const { return format_; }

 private:
  bool writeRegister(uint8_t address, uint8_t reg, uint8_t value);
  bool initializeEs8311();
  bool initializeEs7210();
  bool setCodecMuted(bool muted);
  void disableAmp();

  board::AudioConfig config_ = {};
  audiobackend::Format format_ = {};
  bool configured_ = false;
  bool running_ = false;
};

}  // namespace audio
