// The engine's sound device: what upstream's snd_win.c or snd_linux.c provide
// on a desktop, on the board's codec through Doom's sound bridge
// (doom/src/platform/doom_audio_bridge.h).
//
// Quake mixes into a ring it believes is a DMA buffer, ahead of the position
// SNDDMA_GetDMAPos() reports. Here that ring is in PSRAM and the "DMA" is the
// bridge's output task: each block it asks for is copied out of the ring at
// the read position, which then moves on. What it copies out is zeroed, so a
// stall (a level loading) plays silence rather than the last ring again.
//
// The ring is always 16-bit stereo; a mono codec gets the two sides averaged.
// The mixer runs on the Quake task, the output task on core 0; they touch
// different parts of the ring, and the read position is one aligned word.
//
// Compiled as C beside the engine, after the same prelude as every engine unit,
// so `shm` and `sn` are the relocated globals they really are.
//
// GPL-2.0, like the engine it drives.
#include "../quake_build.h"
#if defined(ESPDISP_QUAKE_RUNTIME)

#include "quake_prelude.h"

#include "../engine/quakedef.h"

#include <string.h>

#include <esp_heap_caps.h>

#include "quake_platform.h"

// Stereo frames in the ring: a power of two, as the mixer requires, and more
// than _snd_mixahead (quake_mode.cpp) asks it to stay ahead by.
#define QUAKE_SOUND_RING_FRAMES 4096u
#define QUAKE_SOUND_RING_SAMPLES (QUAKE_SOUND_RING_FRAMES * 2u)

static uint32_t s_rate = 0;
static int16_t* s_ring = NULL;
// The next sample (not frame) the output task reads, 0 to RING_SAMPLES - 1.
static volatile uint32_t s_read = 0;

void quake_audio_set_rate(uint32_t rate) { s_rate = rate; }

void quake_audio_render(int16_t* out, size_t frames, unsigned channels) {
  int16_t* ring = s_ring;
  if (ring == NULL || (channels != 1 && channels != 2)) {
    memset(out, 0, frames * channels * sizeof(int16_t));
    return;
  }
  uint32_t pos = s_read;
  for (size_t i = 0; i < frames; ++i) {
    const int16_t left = ring[pos];
    const int16_t right = ring[pos + 1];
    ring[pos] = 0;
    ring[pos + 1] = 0;
    pos = (pos + 2u) & (QUAKE_SOUND_RING_SAMPLES - 1u);
    if (channels == 2) {
      out[2 * i] = left;
      out[2 * i + 1] = right;
    } else {
      out[i] = (int16_t)(((int32_t)left + (int32_t)right) / 2);
    }
  }
  s_read = pos;
}

qboolean SNDDMA_Init(void) {
  if (s_rate == 0) {
    Con_Printf("sound: this board has no usable audio\n");
    return false;
  }
  int16_t* ring = (int16_t*)heap_caps_calloc(
      QUAKE_SOUND_RING_SAMPLES, sizeof(int16_t),
      MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (ring == NULL) {
    Con_Printf("sound: no PSRAM for the mixing ring\n");
    return false;
  }
  memset((void*)&sn, 0, sizeof(sn));
  shm = &sn;
  shm->splitbuffer = 0;
  shm->channels = 2;
  shm->samplebits = 16;
  shm->speed = (int)s_rate;
  shm->samples = QUAKE_SOUND_RING_SAMPLES;
  shm->samplepos = 0;
  shm->submission_chunk = 1;
  shm->buffer = (unsigned char*)ring;
  s_read = 0;
  s_ring = ring;  // last: from here on the output task reads it
  quake_log("sound: %u Hz, %u-frame ring", (unsigned)s_rate,
            (unsigned)QUAKE_SOUND_RING_FRAMES);
  return true;
}

int SNDDMA_GetDMAPos(void) {
  shm->samplepos = (int)s_read;
  return shm->samplepos;
}

void SNDDMA_Submit(void) {}

void SNDDMA_Shutdown(void) { s_ring = NULL; }

#endif  // ESPDISP_QUAKE_RUNTIME
