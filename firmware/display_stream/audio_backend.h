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
  // start() without capture, for a caller that never reads: the ES7210 is
  // left powered down, the I2S channel is transmit-only, and readFrames()
  // returns nothing. Doom's sound effects use it.
  bool startPlaybackOnly(const board::Config &boardConfig,
                         const board::AudioConfig &audioConfig,
                         const audiobackend::Format &format);

  bool running() const { return running_; }
  const audiobackend::Format &format() const { return format_; }
  // Readback for the speaker test's report: an ES8311 register, and the
  // amplifier enable pin's pad level (-1 when not running).
  bool readCodecRegister(uint8_t reg, uint8_t &value);
  int ampEnableLevel() const;
  // The speaker test's control window: the codec keeps playing with the
  // amplifier off. No-op when not running.
  void setAmpEnabled(bool enabled);

 private:
  bool writeRegister(uint8_t address, uint8_t reg, uint8_t value);
  bool initializeEs8311();
  bool initializeEs7210();
  void powerDownEs7210();
  bool startWith(const board::Config &boardConfig,
                 const board::AudioConfig &audioConfig,
                 const audiobackend::Format &format, bool capture);
  bool setCodecMuted(bool muted);
  void disableAmp();

  board::AudioConfig config_ = {};
  audiobackend::Format format_ = {};
  bool configured_ = false;
  bool running_ = false;
  bool capture_ = false;
};

CodecSerialAudioBackend &sharedCodecBackend();

// Read-only probe of the descriptor's codec and capture-ADC chip IDs on the
// board I2C bus. It writes no codec register and touches no audio GPIO, so it
// is safe on a board revision that does not carry the parts.
audiobackend::CodecProbe probeCodecs(const board::Config &boardConfig,
                                     const board::AudioConfig &audioConfig);

// The runtime audio status for this board: the descriptor classification,
// then, for a supported descriptor, one cached probe. A positively identified
// board has its amplifier driven off before this returns, and nothing else
// may start audio until it has.
audiobackend::DescriptorStatus boardAudioStatus(
    const board::Config &boardConfig);

#if defined(ESPDISP_HOST_AUDIO_TEST)
void resetBoardAudioStatusForTest();
#endif

}  // namespace audio
