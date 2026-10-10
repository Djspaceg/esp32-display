#pragma once

#include <math.h>
#include <stddef.h>
#include <stdint.h>

namespace audiometer {

// The level of one frequency in interleaved PCM16, per channel, by the
// Goertzel recurrence over whole blocks. The speaker test reads the board's
// own microphones with it: the test tone's level against the same window of
// silence played first is objective evidence that the speaker made a sound,
// with no one listening.
class ToneMeter {
 public:
  static constexpr uint8_t MAX_CHANNELS = 2;
  // What a channel with no complete block, or pure silence, reports.
  static constexpr float FLOOR_DBFS = -120.0f;

  void reset(uint32_t sampleRateHz, uint8_t channels, uint32_t frequencyHz,
             size_t blockFrames) {
    channels_ = channels > MAX_CHANNELS ? MAX_CHANNELS : channels;
    blockFrames_ = blockFrames;
    coefficient_ =
        sampleRateHz == 0
            ? 0.0f
            : 2.0f * cosf(2.0f * (float)M_PI * (float)frequencyHz /
                          (float)sampleRateHz);
    framesInBlock_ = 0;
    blocks_ = 0;
    for (uint8_t channel = 0; channel < MAX_CHANNELS; ++channel) {
      s1_[channel] = 0.0f;
      s2_[channel] = 0.0f;
      powerSum_[channel] = 0.0;
    }
  }

  // `samples` interleaves the channels given to reset(), `channels` of them
  // per frame; channels past MAX_CHANNELS are skipped.
  void add(const int16_t *samples, size_t frames, uint8_t channels) {
    if (samples == nullptr || blockFrames_ == 0 || channels < channels_) {
      return;
    }
    for (size_t frame = 0; frame < frames; ++frame) {
      for (uint8_t channel = 0; channel < channels_; ++channel) {
        const float x =
            (float)samples[frame * channels + channel] / 32768.0f;
        const float s = x + coefficient_ * s1_[channel] - s2_[channel];
        s2_[channel] = s1_[channel];
        s1_[channel] = s;
      }
      if (++framesInBlock_ < blockFrames_) continue;
      for (uint8_t channel = 0; channel < channels_; ++channel) {
        const float power = s1_[channel] * s1_[channel] +
                            s2_[channel] * s2_[channel] -
                            coefficient_ * s1_[channel] * s2_[channel];
        // A full-scale sine of N frames gives power (N/2)^2.
        const float amplitude =
            2.0f * sqrtf(power > 0.0f ? power : 0.0f) /
            (float)blockFrames_;
        powerSum_[channel] += (double)amplitude * amplitude;
        s1_[channel] = 0.0f;
        s2_[channel] = 0.0f;
      }
      framesInBlock_ = 0;
      blocks_++;
    }
  }

  uint32_t blocks() const { return blocks_; }

  // The mean amplitude of the frequency over the complete blocks, in dB
  // relative to a full-scale sine.
  float levelDbfs(uint8_t channel) const {
    if (channel >= channels_ || blocks_ == 0) return FLOOR_DBFS;
    const double meanPower = powerSum_[channel] / (double)blocks_;
    if (meanPower <= 0.0) return FLOOR_DBFS;
    const float level = 10.0f * (float)log10(meanPower);
    return level < FLOOR_DBFS ? FLOOR_DBFS : level;
  }

 private:
  uint8_t channels_ = 0;
  size_t blockFrames_ = 0;
  float coefficient_ = 0.0f;
  size_t framesInBlock_ = 0;
  uint32_t blocks_ = 0;
  float s1_[MAX_CHANNELS] = {};
  float s2_[MAX_CHANNELS] = {};
  double powerSum_[MAX_CHANNELS] = {};
};

}  // namespace audiometer
