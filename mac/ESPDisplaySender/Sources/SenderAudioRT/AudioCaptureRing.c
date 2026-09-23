#include "AudioCaptureRing.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sched.h>

struct ESPAudioCaptureRing {
  uint32_t slot_count;
  uint32_t maximum_frames;
  uint32_t channels;
  _Atomic uint32_t write_index;
  _Atomic uint32_t read_index;
  _Atomic bool accepting;
  _Atomic uint32_t active_writers;
  _Atomic uint32_t callback_leases;
  _Atomic uint64_t dropped;
  uint32_t *frame_counts;
  float *samples;
};

ESPAudioCaptureRing *ESPAudioCaptureRingCreate(
    uint32_t slot_count,
    uint32_t maximum_frames,
    uint32_t channels) {
  if (slot_count < 2 || maximum_frames == 0 ||
      (channels != 1 && channels != 2)) {
    return NULL;
  }
  ESPAudioCaptureRing *ring = calloc(1, sizeof(*ring));
  if (ring == NULL) {
    return NULL;
  }
  ring->frame_counts = calloc(slot_count, sizeof(*ring->frame_counts));
  ring->samples = calloc(
      (size_t)slot_count * channels * maximum_frames,
      sizeof(*ring->samples));
  if (ring->frame_counts == NULL || ring->samples == NULL) {
    ESPAudioCaptureRingDestroy(ring);
    return NULL;
  }
  ring->slot_count = slot_count;
  ring->maximum_frames = maximum_frames;
  ring->channels = channels;
  atomic_init(&ring->write_index, 0);
  atomic_init(&ring->read_index, 0);
  atomic_init(&ring->accepting, false);
  atomic_init(&ring->active_writers, 0);
  atomic_init(&ring->callback_leases, 0);
  atomic_init(&ring->dropped, 0);
  return ring;
}

void ESPAudioCaptureRingDestroy(ESPAudioCaptureRing *ring) {
  if (ring == NULL) {
    return;
  }
  free(ring->samples);
  free(ring->frame_counts);
  free(ring);
}

void ESPAudioCaptureRingSetAccepting(
    ESPAudioCaptureRing *ring,
    bool accepting) {
  if (ring != NULL) {
    atomic_store_explicit(&ring->accepting, accepting, memory_order_release);
  }
}

void ESPAudioCaptureRingRetainCallback(ESPAudioCaptureRing *ring) {
  if (ring != NULL) {
    atomic_fetch_add_explicit(
        &ring->callback_leases, 1, memory_order_relaxed);
  }
}

void ESPAudioCaptureRingReleaseCallback(ESPAudioCaptureRing *ring) {
  if (ring != NULL) {
    atomic_fetch_sub_explicit(
        &ring->callback_leases, 1, memory_order_release);
  }
}

void ESPAudioCaptureRingQuiesce(ESPAudioCaptureRing *ring) {
  if (ring == NULL) {
    return;
  }
  atomic_store_explicit(&ring->accepting, false, memory_order_release);
  while (
      atomic_load_explicit(
          &ring->active_writers, memory_order_acquire) != 0 ||
      atomic_load_explicit(
          &ring->callback_leases, memory_order_acquire) != 0) {
    sched_yield();
  }
}

bool ESPAudioCaptureRingWrite(
    ESPAudioCaptureRing *ring,
    const float *channel_zero,
    const float *channel_one,
    uint32_t frame_count) {
  if (ring == NULL || channel_zero == NULL || frame_count == 0) {
    return false;
  }
  atomic_fetch_add_explicit(
      &ring->active_writers, 1, memory_order_acquire);
  if (frame_count > ring->maximum_frames) {
    atomic_fetch_add_explicit(&ring->dropped, 1, memory_order_relaxed);
    atomic_fetch_sub_explicit(
        &ring->active_writers, 1, memory_order_release);
    return false;
  }
  if (ring->channels == 2 && channel_one == NULL) {
    atomic_fetch_sub_explicit(
        &ring->active_writers, 1, memory_order_release);
    return false;
  }
  if (!atomic_load_explicit(&ring->accepting, memory_order_acquire)) {
    atomic_fetch_sub_explicit(
        &ring->active_writers, 1, memory_order_release);
    return false;
  }
  const uint32_t write_index =
      atomic_load_explicit(&ring->write_index, memory_order_relaxed);
  const uint32_t read_index =
      atomic_load_explicit(&ring->read_index, memory_order_acquire);
  if (write_index - read_index >= ring->slot_count) {
    atomic_fetch_add_explicit(&ring->dropped, 1, memory_order_relaxed);
    atomic_fetch_sub_explicit(
        &ring->active_writers, 1, memory_order_release);
    return false;
  }

  const uint32_t slot = write_index % ring->slot_count;
  const size_t channel_stride = ring->maximum_frames;
  const size_t slot_offset =
      (size_t)slot * ring->channels * channel_stride;
  memcpy(
      ring->samples + slot_offset,
      channel_zero,
      (size_t)frame_count * sizeof(float));
  if (ring->channels == 2) {
    memcpy(
        ring->samples + slot_offset + channel_stride,
        channel_one,
        (size_t)frame_count * sizeof(float));
  }
  ring->frame_counts[slot] = frame_count;
  atomic_store_explicit(
      &ring->write_index, write_index + 1, memory_order_release);
  atomic_fetch_sub_explicit(
      &ring->active_writers, 1, memory_order_release);
  return true;
}

bool ESPAudioCaptureRingRead(
    ESPAudioCaptureRing *ring,
    float *channel_zero,
    float *channel_one,
    uint32_t frame_capacity,
    uint32_t *frame_count) {
  if (ring == NULL || channel_zero == NULL || frame_count == NULL ||
      (ring->channels == 2 && channel_one == NULL)) {
    return false;
  }
  const uint32_t read_index =
      atomic_load_explicit(&ring->read_index, memory_order_relaxed);
  const uint32_t write_index =
      atomic_load_explicit(&ring->write_index, memory_order_acquire);
  if (read_index == write_index) {
    return false;
  }

  const uint32_t slot = read_index % ring->slot_count;
  const uint32_t frames = ring->frame_counts[slot];
  if (frames > frame_capacity) {
    return false;
  }
  const size_t channel_stride = ring->maximum_frames;
  const size_t slot_offset =
      (size_t)slot * ring->channels * channel_stride;
  memcpy(
      channel_zero,
      ring->samples + slot_offset,
      (size_t)frames * sizeof(float));
  if (ring->channels == 2) {
    memcpy(
        channel_one,
        ring->samples + slot_offset + channel_stride,
        (size_t)frames * sizeof(float));
  }
  *frame_count = frames;
  atomic_store_explicit(
      &ring->read_index, read_index + 1, memory_order_release);
  return true;
}

uint64_t ESPAudioCaptureRingDropped(const ESPAudioCaptureRing *ring) {
  if (ring == NULL) {
    return 0;
  }
  return atomic_load_explicit(&ring->dropped, memory_order_relaxed);
}
