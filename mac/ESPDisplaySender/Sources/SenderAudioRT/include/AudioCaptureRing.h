#ifndef ESPDISPLAY_AUDIO_CAPTURE_RING_H
#define ESPDISPLAY_AUDIO_CAPTURE_RING_H

#include <stdbool.h>
#include <stdint.h>

typedef struct ESPAudioCaptureRing ESPAudioCaptureRing;

ESPAudioCaptureRing *ESPAudioCaptureRingCreate(
    uint32_t slot_count,
    uint32_t maximum_frames,
    uint32_t channels);

void ESPAudioCaptureRingDestroy(ESPAudioCaptureRing *ring);
void ESPAudioCaptureRingSetAccepting(
    ESPAudioCaptureRing *ring,
    bool accepting);
void ESPAudioCaptureRingRetainCallback(ESPAudioCaptureRing *ring);
void ESPAudioCaptureRingReleaseCallback(ESPAudioCaptureRing *ring);
void ESPAudioCaptureRingQuiesce(ESPAudioCaptureRing *ring);

bool ESPAudioCaptureRingWrite(
    ESPAudioCaptureRing *ring,
    const float *channel_zero,
    const float *channel_one,
    uint32_t frame_count);

bool ESPAudioCaptureRingRead(
    ESPAudioCaptureRing *ring,
    float *channel_zero,
    float *channel_one,
    uint32_t frame_capacity,
    uint32_t *frame_count);

uint64_t ESPAudioCaptureRingDropped(const ESPAudioCaptureRing *ring);

#endif
