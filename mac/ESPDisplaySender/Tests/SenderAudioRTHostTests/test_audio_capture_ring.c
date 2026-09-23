#include "AudioCaptureRing.h"

#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void expect_channel(
    const float *actual, const float *expected, uint32_t frames) {
  assert(memcmp(actual, expected, (size_t)frames * sizeof(float)) == 0);
}

static void test_create_and_disabled_boundaries(void) {
  assert(ESPAudioCaptureRingCreate(1, 4, 1) == NULL);
  assert(ESPAudioCaptureRingCreate(2, 0, 1) == NULL);
  assert(ESPAudioCaptureRingCreate(2, 4, 0) == NULL);
  assert(ESPAudioCaptureRingCreate(2, 4, 3) == NULL);

  ESPAudioCaptureRing *ring = ESPAudioCaptureRingCreate(2, 4, 1);
  assert(ring != NULL);
  float input[] = {1, 2, 3, 4};
  float output[4] = {0};
  uint32_t frames = 99;

  assert(!ESPAudioCaptureRingWrite(ring, input, NULL, 4));
  assert(!ESPAudioCaptureRingRead(ring, output, NULL, 4, &frames));
  assert(frames == 99);
  assert(ESPAudioCaptureRingDropped(ring) == 0);

  ESPAudioCaptureRingSetAccepting(ring, true);
  assert(!ESPAudioCaptureRingWrite(ring, NULL, NULL, 4));
  assert(!ESPAudioCaptureRingWrite(ring, input, NULL, 0));
  assert(!ESPAudioCaptureRingRead(ring, NULL, NULL, 4, &frames));
  assert(!ESPAudioCaptureRingRead(ring, output, NULL, 4, NULL));
  assert(ESPAudioCaptureRingDropped(ring) == 0);

  assert(!ESPAudioCaptureRingWrite(ring, input, NULL, 5));
  assert(ESPAudioCaptureRingDropped(ring) == 1);
  ESPAudioCaptureRingDestroy(ring);
}

static void test_wrap_full_empty_and_variable_frames(void) {
  ESPAudioCaptureRing *ring = ESPAudioCaptureRingCreate(3, 4, 2);
  assert(ring != NULL);
  ESPAudioCaptureRingSetAccepting(ring, true);

  float a0[] = {10, 11, 12, 13};
  float a1[] = {-10, -11, -12, -13};
  float b0[] = {20, 21};
  float b1[] = {-20, -21};
  float c0[] = {30};
  float c1[] = {-30};
  float d0[] = {40, 41, 42};
  float d1[] = {-40, -41, -42};
  float out0[4] = {0};
  float out1[4] = {0};
  uint32_t frames = 77;

  assert(ESPAudioCaptureRingWrite(ring, a0, a1, 4));
  assert(ESPAudioCaptureRingWrite(ring, b0, b1, 2));
  assert(ESPAudioCaptureRingWrite(ring, c0, c1, 1));
  assert(!ESPAudioCaptureRingWrite(ring, d0, d1, 3));
  assert(ESPAudioCaptureRingDropped(ring) == 1);

  assert(!ESPAudioCaptureRingRead(ring, out0, out1, 3, &frames));
  assert(frames == 77);
  assert(ESPAudioCaptureRingRead(ring, out0, out1, 4, &frames));
  assert(frames == 4);
  expect_channel(out0, a0, frames);
  expect_channel(out1, a1, frames);

  assert(ESPAudioCaptureRingWrite(ring, d0, d1, 3));
  assert(ESPAudioCaptureRingRead(ring, out0, out1, 4, &frames));
  assert(frames == 2);
  expect_channel(out0, b0, frames);
  expect_channel(out1, b1, frames);
  assert(ESPAudioCaptureRingRead(ring, out0, out1, 4, &frames));
  assert(frames == 1);
  expect_channel(out0, c0, frames);
  expect_channel(out1, c1, frames);
  assert(ESPAudioCaptureRingRead(ring, out0, out1, 4, &frames));
  assert(frames == 3);
  expect_channel(out0, d0, frames);
  expect_channel(out1, d1, frames);
  assert(!ESPAudioCaptureRingRead(ring, out0, out1, 4, &frames));
  assert(ESPAudioCaptureRingDropped(ring) == 1);

  assert(!ESPAudioCaptureRingWrite(ring, a0, NULL, 4));
  assert(ESPAudioCaptureRingDropped(ring) == 1);
  ESPAudioCaptureRingDestroy(ring);
}

enum {
  STRESS_SLOTS = 64,
  STRESS_MAX_FRAMES = 31,
  STRESS_PACKETS = 1000000
};

struct stress_context {
  ESPAudioCaptureRing *ring;
  atomic_bool producer_done;
  atomic_bool failed;
  atomic_uint_fast64_t full_retries;
};

static void fill_packet(
    uint32_t sequence,
    float *channel_zero,
    float *channel_one,
    uint32_t frames) {
  for (uint32_t frame = 0; frame < frames; ++frame) {
    channel_zero[frame] = (float)sequence;
    channel_one[frame] = -(float)sequence;
  }
}

static void *stress_producer(void *opaque) {
  struct stress_context *context = opaque;
  float channel_zero[STRESS_MAX_FRAMES];
  float channel_one[STRESS_MAX_FRAMES];
  for (uint32_t sequence = 1; sequence <= STRESS_PACKETS; ++sequence) {
    const uint32_t frames = sequence % STRESS_MAX_FRAMES + 1;
    fill_packet(sequence, channel_zero, channel_one, frames);
    while (!ESPAudioCaptureRingWrite(
        context->ring, channel_zero, channel_one, frames)) {
      atomic_fetch_add_explicit(
          &context->full_retries, 1, memory_order_relaxed);
      sched_yield();
    }
  }
  atomic_store_explicit(&context->producer_done, true, memory_order_release);
  return NULL;
}

static void *stress_consumer(void *opaque) {
  struct stress_context *context = opaque;
  float channel_zero[STRESS_MAX_FRAMES];
  float channel_one[STRESS_MAX_FRAMES];
  uint32_t expected = 1;
  while (expected <= STRESS_PACKETS) {
    uint32_t frames = 0;
    if (!ESPAudioCaptureRingRead(
        context->ring,
        channel_zero,
        channel_one,
        STRESS_MAX_FRAMES,
        &frames)) {
      if (atomic_load_explicit(
          &context->producer_done, memory_order_acquire)) {
        sched_yield();
      }
      continue;
    }
    const uint32_t expected_frames = expected % STRESS_MAX_FRAMES + 1;
    if (frames != expected_frames) {
      atomic_store_explicit(&context->failed, true, memory_order_relaxed);
      return NULL;
    }
    for (uint32_t frame = 0; frame < frames; ++frame) {
      if (channel_zero[frame] != (float)expected ||
          channel_one[frame] != -(float)expected) {
        atomic_store_explicit(&context->failed, true, memory_order_relaxed);
        return NULL;
      }
    }
    ++expected;
  }
  return NULL;
}

static void test_concurrent_spsc_publication(void) {
  ESPAudioCaptureRing *ring =
      ESPAudioCaptureRingCreate(STRESS_SLOTS, STRESS_MAX_FRAMES, 2);
  assert(ring != NULL);
  ESPAudioCaptureRingSetAccepting(ring, true);
  struct stress_context context = {
      .ring = ring,
      .producer_done = ATOMIC_VAR_INIT(false),
      .failed = ATOMIC_VAR_INIT(false),
      .full_retries = ATOMIC_VAR_INIT(0),
  };
  pthread_t producer;
  pthread_t consumer;
  assert(pthread_create(&producer, NULL, stress_producer, &context) == 0);
  assert(pthread_create(&consumer, NULL, stress_consumer, &context) == 0);
  assert(pthread_join(producer, NULL) == 0);
  assert(pthread_join(consumer, NULL) == 0);
  assert(!atomic_load_explicit(&context.failed, memory_order_relaxed));
  assert(
      ESPAudioCaptureRingDropped(ring) ==
      atomic_load_explicit(&context.full_retries, memory_order_relaxed));

  float output_zero[STRESS_MAX_FRAMES];
  float output_one[STRESS_MAX_FRAMES];
  uint32_t frames = 0;
  assert(!ESPAudioCaptureRingRead(
      ring, output_zero, output_one, STRESS_MAX_FRAMES, &frames));
  ESPAudioCaptureRingDestroy(ring);
}

struct quiesce_context {
  ESPAudioCaptureRing *ring;
  atomic_bool stop;
  atomic_bool quiesced;
  atomic_bool succeeded_after_quiesce;
  atomic_uint_fast64_t successes;
  atomic_uint_fast64_t attempts_after_quiesce;
};

static void *quiesce_producer(void *opaque) {
  struct quiesce_context *context = opaque;
  float input[] = {1, 2, 3, 4};
  while (!atomic_load_explicit(&context->stop, memory_order_acquire)) {
    const bool after_quiesce =
        atomic_load_explicit(&context->quiesced, memory_order_acquire);
    const bool wrote =
        ESPAudioCaptureRingWrite(context->ring, input, NULL, 4);
    if (after_quiesce) {
      atomic_fetch_add_explicit(
          &context->attempts_after_quiesce, 1, memory_order_relaxed);
      if (wrote) {
        atomic_store_explicit(
            &context->succeeded_after_quiesce, true, memory_order_relaxed);
      }
    } else if (wrote) {
      atomic_fetch_add_explicit(
          &context->successes, 1, memory_order_relaxed);
    }
    if (!wrote) {
      sched_yield();
    }
  }
  return NULL;
}

static void test_quiesce_stops_acceptance(void) {
  ESPAudioCaptureRing *ring = ESPAudioCaptureRingCreate(64, 4, 1);
  assert(ring != NULL);
  ESPAudioCaptureRingSetAccepting(ring, true);
  struct quiesce_context context = {
      .ring = ring,
      .stop = ATOMIC_VAR_INIT(false),
      .quiesced = ATOMIC_VAR_INIT(false),
      .succeeded_after_quiesce = ATOMIC_VAR_INIT(false),
      .successes = ATOMIC_VAR_INIT(0),
      .attempts_after_quiesce = ATOMIC_VAR_INIT(0),
  };
  pthread_t producer;
  assert(pthread_create(&producer, NULL, quiesce_producer, &context) == 0);
  while (atomic_load_explicit(
      &context.successes, memory_order_acquire) < 32) {
    sched_yield();
  }
  ESPAudioCaptureRingQuiesce(ring);
  atomic_store_explicit(&context.quiesced, true, memory_order_release);
  while (atomic_load_explicit(
      &context.attempts_after_quiesce, memory_order_acquire) < 1000) {
    sched_yield();
  }
  atomic_store_explicit(&context.stop, true, memory_order_release);
  assert(pthread_join(producer, NULL) == 0);
  assert(!atomic_load_explicit(
      &context.succeeded_after_quiesce, memory_order_relaxed));
  ESPAudioCaptureRingDestroy(ring);
}

int main(void) {
  test_create_and_disabled_boundaries();
  test_wrap_full_empty_and_variable_frames();
  test_concurrent_spsc_publication();
  test_quiesce_stops_acceptance();
  puts("AudioCaptureRing host tests: PASS");
  return 0;
}
