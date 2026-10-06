// Host test for Doom's sound-output pacing (display_stream/doom_audio_pace.h).
//
// Simulates the output task against ESP-IDF 5.5's transmit path as I2SClass
// sets it up: 6 DMA buffers of 240 frames played in a ring, and a free-buffer
// queue one shorter, so a writer can hold only buffers the DMA has finished,
// each of which plays again five buffers later. i2s_channel_write also drops a
// partly filled buffer for a fresh one whenever at most one queue space is
// left, which plays the dropped buffer's unwritten tail as silence: a hole. The codec clock runs a little fast,
// exact or a little slow against the timer, for ten minutes each. The pacer
// must keep the queue, which is the delay between the game starting a sound
// and the speaker playing it, near its lead instead of the ring's 80 ms, and
// must never let the ring run dry, even across a preempted write.
#include <cstdio>
#include <initializer_list>

#include "../display_stream/doom_audio_pace.h"

static int checks = 0;
#define CHECK(cond)                                          \
  do {                                                       \
    checks++;                                                \
    if (!(cond)) {                                           \
      printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      return 1;                                              \
    }                                                        \
  } while (0)

static constexpr uint32_t RATE = 16000;
static constexpr uint32_t BUFFER = 240;
static constexpr uint32_t BUFFERS = 6;
// Queued right after a blocked whole-buffer write: the five buffers the
// free queue held back, plus the one the write just filled.
static constexpr uint32_t FULL_FRAMES = (BUFFERS - 1) * BUFFER + BUFFER;
static constexpr uint32_t BLOCK = 240;  // whole DMA buffers
static constexpr uint32_t LEAD_US = 16000;
static constexpr uint32_t PROBE_US = 30000000;

struct Result {
  unsigned underruns;
  unsigned holes;  // anywhere, before or after the first anchor
  double firstAnchorErrorMs;  // estimate minus real; above 0 underfeeds
  unsigned samples;
  unsigned over40ms;
  double meanQueuedMs;
  double minQueuedMs;
};

// The task loop of doom_audio.cpp: sleep whole milliseconds as vTaskDelay
// does, render (instant), write a block, which blocks while every buffer the
// writer could take is still queued. `stallAtUs` preempts one write for
// `stallUs` (2.5 ms: inside a write, with the ring not full; longer: the task
// itself held off before rendering).
// The start is i2s_channel_enable's: an empty free queue, the DMA playing
// buffer 0, a prime of `primeFrames` that waits for the first buffer to come
// free, then `startGapUs` of codec setup before the task's first write.
static Result simulate(double codecPpm, double seconds,
                       int64_t stallAtUs = -1, int64_t stallUs = 2500,
                       uint32_t block = BLOCK, uint32_t primeFrames = BUFFER,
                       int64_t startGapUs = 30000) {
  doomaudio::OutputPacer pacer(RATE, FULL_FRAMES, LEAD_US, PROBE_US);
  const double playPerUs = RATE * (1.0 + codecPpm * 1e-6) / 1e6;
  double played = 0;    // DMA position, in frames since the channel started
  // Absolute ring position of the writer's buffer, and frames written into
  // it. Nothing is held at enable: the first write waits for buffer 0 to
  // finish and refills it for its next lap, position 6.
  int64_t slot = BUFFERS - 1;
  uint32_t filled = BUFFER;
  int64_t now = 0;
  bool stalled = false;
  Result result = {0, 0, 0.0, 0, 0, 0.0, 1e9};
  bool anchoredBefore = false;
  double queuedSum = 0;
  auto underrunCheck = [&] {
    if (played >= (double)slot * BUFFER) {
      // The writer's buffer started playing before it was full.
      if (pacer.anchored()) result.underruns++;
      slot = (int64_t)(played / BUFFER) + 1;
      filled = 0;
    }
  };
  auto advance = [&](int64_t us) {
    played += playPerUs * (double)us;
    now += us;
    underrunCheck();
  };
  // Buffers the DMA has finished and the writer has not taken.
  auto queuedFree = [&] {
    const int64_t free = (int64_t)(played / BUFFER) + (BUFFERS - 1) - slot;
    return free < 0 ? 0 : free;
  };
  auto write = [&](uint32_t frames) {
    while (frames > 0) {
      if (filled > 0 && filled < BUFFER && queuedFree() >= BUFFERS - 2) {
        result.holes++;
        slot++;
        filled = 0;
        continue;
      }
      if (filled == BUFFER) {
        // The next buffer is free once the DMA finishes its previous lap.
        const double freeAt = (double)(slot + 1 - (BUFFERS - 1)) * BUFFER;
        if (played < freeAt) {
          advance((int64_t)((freeAt - played) / playPerUs) + 1);
        }
        if (filled == BUFFER) {
          slot++;
          filled = 0;
        }
      }
      const uint32_t chunk = frames < BUFFER - filled ? frames : BUFFER - filled;
      filled += chunk;
      frames -= chunk;
    }
  };
  write(primeFrames);  // the backend's primed silence
  advance(startGapUs);
  while (now < (int64_t)(seconds * 1e6)) {
    const uint32_t sleep = pacer.sleepUs(now);
    if (sleep >= 1000) advance((int64_t)(sleep / 1000) * 1000);
    if (!stalled && stallAtUs >= 0 && now >= stallAtUs && stallUs > 2500) {
      stalled = true;
      advance(stallUs);
    }
    advance(30);  // render
    const int64_t before = now;
    write(block);
    advance(20);
    if (!stalled && stallAtUs >= 0 && now >= stallAtUs) {
      stalled = true;
      advance(stallUs);
    }
    pacer.wrote(block, before, now);
    if (pacer.anchored() && !anchoredBefore) {
      anchoredBefore = true;
      const double realMs =
          ((double)slot * BUFFER + filled - played) * 1000.0 / RATE;
      result.firstAnchorErrorMs = pacer.queuedUs(now) / 1000.0 - realMs;
    }
    if (pacer.anchored()) {
      const double queuedMs =
          ((double)slot * BUFFER + filled - played) * 1000.0 / RATE;
      result.samples++;
      queuedSum += queuedMs;
      if (queuedMs > 40.0) result.over40ms++;
      if (queuedMs < result.minQueuedMs) result.minQueuedMs = queuedMs;
    }
  }
  result.meanQueuedMs = result.samples == 0 ? 0 : queuedSum / result.samples;
  return result;
}

int main() {
  // Unanchored, the pacer never holds the task back: the ring fills, and
  // the first blocked write anchors the estimate at a full ring.
  {
    doomaudio::OutputPacer pacer(RATE, FULL_FRAMES, LEAD_US, PROBE_US);
    CHECK(!pacer.anchored());
    CHECK(pacer.sleepUs(0) == 0);
    pacer.wrote(BLOCK, 0, 100);  // did not block
    CHECK(!pacer.anchored());
    for (int i = 0; i < 11; ++i) pacer.wrote(BLOCK, 100, 100);
    pacer.wrote(BLOCK, 100, 8100);  // blocked for a free buffer
    CHECK(pacer.anchored());
    const int64_t fullUs = (int64_t)FULL_FRAMES * 1000000 / RATE;
    CHECK(pacer.queuedUs(8100) >= fullUs - 1 &&
          pacer.queuedUs(8100) <= fullUs + 1);
    // Sleep until only the lead is left.
    const uint32_t sleep = pacer.sleepUs(8100);
    CHECK(sleep >= fullUs - LEAD_US - 20 && sleep <= fullUs - LEAD_US + 20);
    // A failed write records nothing.
    pacer.wrote(0, 9000, 30000);
    CHECK(pacer.sleepUs(8100) == sleep);
    // When a probe is due the task writes until the ring is full again.
    CHECK(pacer.sleepUs(8100 + PROBE_US) == 0);
  }

  // Half-buffer blocks leave a partly filled buffer between writes, which
  // the driver drops as the queue runs short: holes in the sound.
  {
    const Result result = simulate(0.0, 120.0, -1, 2500, 128);
    printf("128-frame blocks: %u holes\n", result.holes);
    CHECK(result.holes > 0);
  }

  // Streaming's 80-frame prime would leave whole-buffer writes 80 frames out
  // of line: the first anchor 10 ms high and a hole to realign. The
  // playback-only prime is a whole buffer, whatever the setup time.
  {
    const Result result = simulate(0.0, 60.0, -1, 2500, BLOCK, 80);
    printf("80-frame prime: first anchor %+.1f ms, %u holes\n",
           result.firstAnchorErrorMs, result.holes);
    CHECK(result.firstAnchorErrorMs > 5.0);
    CHECK(result.holes > 0);
  }
  for (int64_t gapUs : {0, 15000, 25000, 40000, 60000}) {
    const Result result = simulate(0.0, 60.0, -1, 2500, BLOCK, BUFFER, gapUs);
    printf("240-frame prime, %lld ms setup: first anchor %+.2f ms, %u holes\n",
           (long long)(gapUs / 1000), result.firstAnchorErrorMs, result.holes);
    CHECK(result.firstAnchorErrorMs <= 0.1);
    CHECK(result.holes == 0);
  }

  for (double ppm : {-100.0, 0.0, 100.0}) {
    const Result result = simulate(ppm, 600.0);
    printf("codec %+.0f ppm: queued mean %.1f ms, min %.1f ms, %u of %u "
           "samples over 40 ms, %u underruns, %u holes\n",
           ppm, result.meanQueuedMs, result.minQueuedMs, result.over40ms,
           result.samples, result.underruns, result.holes);
    CHECK(result.underruns == 0);
    CHECK(result.holes == 0);
    CHECK(result.samples > 10000);
    // The lead holds as a floor once writes are aligned to whole buffers.
    CHECK(result.minQueuedMs >= 16.0);
    // Near the lead plus a block, not the ring's 80 ms.
    CHECK(result.meanQueuedMs < 36.0);
    // Only the probes, under 100 ms in every 30 s, run deeper.
    CHECK(result.over40ms * 200 < result.samples);
  }

  // A write preempted for 2.5 ms while the ring is not full is not taken
  // for a full ring: no dropout, and the queue keeps its floor.
  {
    const Result result = simulate(0.0, 60.0, 31000000);
    printf("preempted write: queued min %.1f ms, %u underruns, %u holes\n",
           result.minQueuedMs, result.underruns, result.holes);
    CHECK(result.underruns == 0);
    CHECK(result.holes == 0);
    CHECK(result.minQueuedMs >= 16.0);
  }

  // A long stall of the task runs the ring dry once; the pacer re-measures
  // at once instead of carrying a wrong estimate until the next probe.
  for (int64_t stallUs : {60000, 90000, 150000, 300000}) {
    const Result result = simulate(0.0, 60.0, 31000000, stallUs);
    printf("%lld ms stall: %u samples over 40 ms\n",
           (long long)(stallUs / 1000), result.over40ms);
    CHECK(result.over40ms < 60);
  }

  printf("test_doom_audio_pace: %d checks passed\n", checks);
  return 0;
}
