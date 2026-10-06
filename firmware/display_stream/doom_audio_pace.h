#pragma once

// Hardware-free pacing for Doom's sound-effect output task (doom_audio.cpp).
//
// Arduino's I2SClass always gives the transmit channel 6 DMA buffers of 240
// frames, 90 ms at 16 kHz, with no setter. A task that writes as fast as the
// blocking write allows keeps that ring full, so every sound is heard about
// 90 ms after the game starts it. The pacer instead sleeps the task until only
// `leadUs` of audio is still queued, then lets it render the next block.
//
// The queue cannot be read, so the pacer estimates it from the frames written
// and the time elapsed. A write blocks only when the ring is full: ESP-IDF's
// free-buffer queue holds one buffer fewer than the ring, so when a
// whole-buffer write returns from blocking, those five buffers plus the one
// it just filled are queued, `fullFrames`. That holds only while writes stay
// aligned to the buffers, which is why the codec's playback-only start primes
// exactly one.
//
// Every `probeIntervalUs` it stops pacing until a write blocks, which
// re-measures the queue before the I2S clock and the timer can drift apart by
// more than a few frames. Between probes a block re-anchors only if the
// estimate already says the ring is nearly full, so a write that was merely
// preempted cannot pass for a full ring. The estimate plays BIAS_PPM fast, so
// drift between probes grows the queue rather than draining it. A write that
// finds the estimate already run dry (the task was held off) starts a probe
// too, since only a blocked write can tell how much really is queued.
#include <stdint.h>

namespace doomaudio {

class OutputPacer {
 public:
  // A write that waited this long was waiting for a free DMA buffer.
  static constexpr int64_t BLOCKED_US = 2000;
  static constexpr int64_t BIAS_PPM = 100;

  OutputPacer(uint32_t sampleRateHz, uint32_t fullFrames, uint32_t leadUs,
              uint32_t probeIntervalUs)
      : rateHz_(sampleRateHz),
        fullUs_(framesToUs(fullFrames, sampleRateHz)),
        leadUs_(leadUs),
        probeIntervalUs_(probeIntervalUs) {}

  // How long to sleep before rendering the next block. Zero until the first
  // blocked write has anchored the estimate, and while a probe is due.
  uint32_t sleepUs(int64_t nowUs) const {
    if (probing(nowUs)) return 0;
    const int64_t queued = queuedUs(nowUs);
    return queued > leadUs_ ? (uint32_t)(queued - leadUs_) : 0;
  }

  // Record a write of `frames` frames that began at beforeUs and returned at
  // afterUs.
  void wrote(uint32_t frames, int64_t beforeUs, int64_t afterUs) {
    if (anchored_ && queuedUs(beforeUs) < 0) dry_ = true;
    const bool expectFull =
        probing(beforeUs) ||
        queuedUs(beforeUs) >= fullUs_ - 2 * framesToUs(frames, rateHz_);
    framesWritten_ += frames;
    if (frames > 0 && afterUs - beforeUs >= BLOCKED_US && expectFull) {
      // queuedUs(afterUs) == fullUs_ from here on.
      const int64_t writtenUs = framesToUs(framesWritten_, rateHz_);
      originUs_ = afterUs - ((writtenUs - fullUs_) * 1000000) /
                                (1000000 + BIAS_PPM);
      anchored_ = true;
      anchoredAtUs_ = afterUs;
      dry_ = false;
    }
  }

  // Estimated audio still queued ahead of the codec; negative means the
  // estimate thinks the ring ran dry.
  int64_t queuedUs(int64_t nowUs) const {
    const int64_t playedUs =
        ((nowUs - originUs_) * (1000000 + BIAS_PPM)) / 1000000;
    return framesToUs(framesWritten_, rateHz_) - playedUs;
  }

  bool anchored() const { return anchored_; }

  // Unanchored, run dry, or due to re-measure: write until the ring blocks.
  bool probing(int64_t nowUs) const {
    return !anchored_ || dry_ || nowUs - anchoredAtUs_ >= probeIntervalUs_;
  }

 private:
  static int64_t framesToUs(uint64_t frames, uint32_t rateHz) {
    return rateHz == 0 ? 0 : (int64_t)((frames * 1000000) / rateHz);
  }

  uint32_t rateHz_;
  int64_t fullUs_;
  int64_t leadUs_;
  int64_t probeIntervalUs_;
  uint64_t framesWritten_ = 0;
  int64_t originUs_ = 0;
  int64_t anchoredAtUs_ = 0;
  bool anchored_ = false;
  bool dry_ = false;
};

}  // namespace doomaudio
