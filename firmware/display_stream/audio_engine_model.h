#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "audio_protocol.h"

namespace audioengine {

static const uint32_t DEFAULT_STREAM_IDLE_TIMEOUT_MS = 2000;

inline bool streamIdleExpired(uint32_t nowMs, uint32_t lastPacketMs,
                              uint32_t timeoutMs) {
  return timeoutMs > 0 && nowMs - lastPacketMs >= timeoutMs;
}

inline bool crossfadeBlocks(const int16_t *from, int16_t *to,
                            size_t frames, uint8_t channels) {
  if (from == nullptr || to == nullptr || frames == 0 ||
      channels == 0 || channels > 2) {
    return false;
  }
  if (frames == 1) return true;
  for (size_t frame = 0; frame < frames; ++frame) {
    const int32_t incomingWeight = (int32_t)frame;
    const int32_t previousWeight =
        (int32_t)(frames - 1) - incomingWeight;
    for (uint8_t channel = 0; channel < channels; ++channel) {
      const size_t index = frame * channels + channel;
      to[index] = (int16_t)(
          ((int32_t)from[index] * previousWeight +
           (int32_t)to[index] * incomingWeight) /
          (int32_t)(frames - 1));
    }
  }
  return true;
}

inline bool applyEdgeFade(int16_t *samples, size_t frames,
                          uint8_t channels, size_t fadeFrames,
                          bool fadeIn) {
  if (samples == nullptr || frames == 0 || channels == 0 ||
      channels > 2 || fadeFrames == 0) {
    return false;
  }
  if (fadeFrames > frames) fadeFrames = frames;
  const size_t edgeStart = fadeIn ? 0 : frames - fadeFrames;
  const int32_t denominator =
      fadeFrames > 1 ? (int32_t)(fadeFrames - 1) : 1;
  for (size_t edgeFrame = 0; edgeFrame < fadeFrames; ++edgeFrame) {
    const int32_t gain =
        fadeIn ? (int32_t)edgeFrame
               : (int32_t)(fadeFrames - edgeFrame - 1);
    for (uint8_t channel = 0; channel < channels; ++channel) {
      const size_t index = (edgeStart + edgeFrame) * channels + channel;
      samples[index] =
          (int16_t)(((int32_t)samples[index] * gain) / denominator);
    }
  }
  return true;
}

class JitterBuffer {
 public:
  bool reset(int16_t *storage, size_t capacityFrames, uint8_t channels) {
    if (storage == nullptr || capacityFrames < 2 || channels == 0 ||
        channels > 2) {
      return false;
    }
    storage_ = storage;
    capacityFrames_ = capacityFrames;
    channels_ = channels;
    headFrame_ = 0;
    fillFrames_ = 0;
    return true;
  }

  void clear() {
    headFrame_ = 0;
    fillFrames_ = 0;
  }

  bool push(const int16_t *samples, size_t frames) {
    if (storage_ == nullptr || samples == nullptr ||
        frames > freeFrames()) {
      return false;
    }
    for (size_t frame = 0; frame < frames; ++frame) {
      const size_t destination =
          (headFrame_ + fillFrames_ + frame) % capacityFrames_;
      memcpy(storage_ + destination * channels_,
             samples + frame * channels_, channels_ * sizeof(int16_t));
    }
    fillFrames_ += frames;
    return true;
  }

  bool pushSilence(size_t frames) {
    if (storage_ == nullptr || frames > freeFrames()) return false;
    for (size_t frame = 0; frame < frames; ++frame) {
      const size_t destination =
          (headFrame_ + fillFrames_ + frame) % capacityFrames_;
      memset(storage_ + destination * channels_, 0,
             channels_ * sizeof(int16_t));
    }
    fillFrames_ += frames;
    return true;
  }

  bool discard(size_t frames) {
    if (frames > fillFrames_) return false;
    headFrame_ = (headFrame_ + frames) % capacityFrames_;
    fillFrames_ -= frames;
    return true;
  }

  int16_t peek(size_t frame, uint8_t channel) const {
    if (storage_ == nullptr || frame >= fillFrames_ || channel >= channels_) {
      return 0;
    }
    return storage_[((headFrame_ + frame) % capacityFrames_) * channels_ +
                    channel];
  }

  size_t fillFrames() const { return fillFrames_; }
  size_t freeFrames() const { return capacityFrames_ - fillFrames_; }
  uint8_t channels() const { return channels_; }

 private:
  int16_t *storage_ = nullptr;
  size_t capacityFrames_ = 0;
  size_t headFrame_ = 0;
  size_t fillFrames_ = 0;
  uint8_t channels_ = 0;
};

enum class StreamDecision : uint8_t {
  Start,
  Accept,
  AcceptGap,
  Late,
  VersionMismatch,
  Discontinuity,
};

struct StreamResult {
  StreamDecision decision;
  uint32_t gapFrames;
};

class StreamTracker {
 public:
  explicit StreamTracker(uint32_t maxGapFrames)
      : maxGapFrames_(maxGapFrames) {}

  StreamResult accept(uint8_t version, uint16_t generation,
                      uint16_t sequence, uint32_t sampleCounter,
                      uint16_t frameCount) {
    if (version != audioproto::VERSION) {
      return {StreamDecision::VersionMismatch, 0};
    }
    if (!active_ || generation != generation_) {
      active_ = true;
      generation_ = generation;
      expectedSequence_ = (uint16_t)(sequence + 1);
      expectedSample_ = sampleCounter + frameCount;
      return {StreamDecision::Start, 0};
    }
    const int32_t sampleDelta = (int32_t)(sampleCounter - expectedSample_);
    if (sampleDelta < 0) return {StreamDecision::Late, 0};
    if ((uint32_t)sampleDelta > maxGapFrames_) {
      return {StreamDecision::Discontinuity, 0};
    }
    if (sampleDelta == 0 && sequence != expectedSequence_) {
      return {StreamDecision::Discontinuity, 0};
    }
    expectedSequence_ = (uint16_t)(sequence + 1);
    expectedSample_ = sampleCounter + frameCount;
    return {sampleDelta == 0 ? StreamDecision::Accept
                             : StreamDecision::AcceptGap,
            (uint32_t)sampleDelta};
  }

  void reset() { active_ = false; }

 private:
  uint32_t maxGapFrames_;
  bool active_ = false;
  uint16_t generation_ = 0;
  uint16_t expectedSequence_ = 0;
  uint32_t expectedSample_ = 0;
};

struct DriftConfig {
  uint32_t targetFrames;
  uint32_t lowFrames;
  uint32_t highFrames;
  int32_t maxPpm;
};

enum class HardCorrection : uint8_t { None, DropCrossfadedBlock };

struct DriftDecision {
  int32_t ppm;
  int32_t trendFrames;
  HardCorrection hardCorrection;
};

class FillTrendController {
 public:
  explicit FillTrendController(DriftConfig config) : config_(config) {}
  void setConfig(DriftConfig config) { config_ = config; }

  DriftDecision update(uint32_t fillFrames) {
    const int32_t trend =
        initialized_ ? (int32_t)fillFrames - (int32_t)previousFill_ : 0;
    previousFill_ = fillFrames;
    initialized_ = true;

    const int32_t error =
        (int32_t)fillFrames - (int32_t)config_.targetFrames;
    const uint32_t span =
        error < 0 ? config_.targetFrames - config_.lowFrames
                  : config_.highFrames - config_.targetFrames;
    int32_t ppm = span == 0
        ? 0
        : (int32_t)(((int64_t)error * config_.maxPpm) /
                    ((int64_t)span * 2));
    if (trend < 0) ppm -= config_.maxPpm / 4;
    if (trend > 0) ppm += config_.maxPpm / 4;
    if (ppm > config_.maxPpm) ppm = config_.maxPpm;
    if (ppm < -config_.maxPpm) ppm = -config_.maxPpm;
    return {
        ppm,
        trend,
        fillFrames > config_.highFrames
            ? HardCorrection::DropCrossfadedBlock
            : HardCorrection::None,
    };
  }

 private:
  DriftConfig config_;
  bool initialized_ = false;
  uint32_t previousFill_ = 0;
};

class ResampleCursor {
 public:
  void reset() { residualPpm_ = 0; }

  void setCorrectionPpm(int32_t ppm) {
    if (ppm < -999999) ppm = -999999;
    correctionPpm_ = ppm;
  }

  size_t advance(size_t outputFrames) {
    const uint64_t scaled =
        residualPpm_ +
        (uint64_t)outputFrames * (uint64_t)(1000000 + correctionPpm_);
    const size_t consumed = (size_t)(scaled / 1000000U);
    residualPpm_ = scaled % 1000000U;
    return consumed;
  }

  uint64_t stepQ32() const {
    return (((uint64_t)(1000000 + correctionPpm_) << 32) + 500000U) /
           1000000U;
  }
  uint32_t fractionQ32() const {
    return (uint32_t)((residualPpm_ << 32) / 1000000U);
  }

 private:
  int32_t correctionPpm_ = 0;
  uint64_t residualPpm_ = 0;
};

enum class UnderrunState : uint8_t {
  Buffering,
  Playing,
  FadingOut,
  SilentRefill,
  FadingIn,
};

class UnderrunController {
 public:
  UnderrunState update(uint32_t fillFrames, int32_t trendFrames,
                       uint32_t lowFrames, uint32_t targetFrames,
                       uint32_t blockFrames) {
    switch (state_) {
      case UnderrunState::Buffering:
        if (fillFrames >= targetFrames) state_ = UnderrunState::Playing;
        break;
      case UnderrunState::Playing:
        if (fillFrames < blockFrames * 2 ||
            (fillFrames < lowFrames && trendFrames < 0)) {
          state_ = UnderrunState::FadingOut;
          underruns_++;
        }
        break;
      case UnderrunState::FadingOut:
        state_ = UnderrunState::SilentRefill;
        break;
      case UnderrunState::SilentRefill:
        if (fillFrames >= targetFrames) state_ = UnderrunState::FadingIn;
        break;
      case UnderrunState::FadingIn:
        state_ = UnderrunState::Playing;
        break;
    }
    return state_;
  }

  void reset() {
    state_ = UnderrunState::Buffering;
    underruns_ = 0;
  }

  UnderrunState state() const { return state_; }
  uint32_t underruns() const { return underruns_; }

 private:
  UnderrunState state_ = UnderrunState::Buffering;
  uint32_t underruns_ = 0;
};

}  // namespace audioengine
