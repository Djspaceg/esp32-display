// Doom sound effects on the board's codec.
//
// The engine's s_sound.c picks a channel, volume and separation for each
// sound and calls this module through i_sound.c. The module keeps one voice
// per engine channel and mixes them on demand for the audio bridge's output
// task (doom_audio_bridge.h), which feeds the codec at its own rate.
//
// Sound lumps are DMX format 3: u16 format (3), u16 sample rate, u32 length,
// then `length` unsigned 8-bit mono samples, of which DMX plays neither the
// first nor the last 16, and lumps of 48 or fewer it does not play at all
// (Chocolate Doom's i_sdlsound.c rule). The WAD stays memory-mapped for the whole Doom boot,
// so a voice points straight into its lump; nothing is copied or cached.
//
// Each voice is resampled from its lump's rate (11025 Hz in the shareware
// WAD) with linear interpolation. Separation is ignored: every audio board
// drives one speaker from the ES8311's left I2S slot (SDP_IN 0x0C), so a
// stereo pan would silence sounds to the player's right. The mono mix goes
// to every output channel.
//
// GPL-2.0 (part of the doomgeneric build)
#include <esp_heap_caps.h>

#include "doom_audio_bridge.h"
#include "i_timer.h"
#include "w_wad.h"
#include "z_zone.h"

// More than the engine's snd_channels (8), which no config file can raise on
// the board, since Doom here has no writable filesystem.
#define DOOM_SFX_VOICES 16
#define DOOM_SFX_HEADER_BYTES 8
#define DOOM_SFX_PAD_BYTES 16
#define DOOM_SFX_MIN_LENGTH 49
// Vanilla's quit wait, I_WaitVBL(105) at 70 Hz.
#define DOOM_SFX_QUIT_WAIT_MS 1500

typedef struct {
    const uint8_t* samples;
    uint32_t length;
    uint32_t index;
    uint32_t fraction;  // Q16 position between samples[index] and the next
    uint32_t step;      // Q16 source samples per output frame
    int32_t gain;       // the engine's volume, 0..127
    boolean active;
} doom_sfx_voice_t;

// Allocated only once the board's audio has started, so a board without
// audio carries none of it. Written by the engine on loopTask and read by the
// output task, always under doom_audio_lock().
static doom_sfx_voice_t* sfx_voices = NULL;
static uint32_t sfx_output_rate = 0;
static boolean sfx_use_prefix = true;

static void DG_RenderSound(int16_t* out, size_t frames, unsigned channels) {
    doom_audio_lock();
    for (size_t frame = 0; frame < frames; ++frame) {
        int32_t mix = 0;
        for (int v = 0; sfx_voices != NULL && v < DOOM_SFX_VOICES; ++v) {
            doom_sfx_voice_t* voice = &sfx_voices[v];
            if (!voice->active) continue;
            const int32_t a = (int32_t)voice->samples[voice->index] - 128;
            const int32_t b = voice->index + 1 < voice->length
                                  ? (int32_t)voice->samples[voice->index + 1] - 128
                                  : a;
            const int32_t sample =
                a * 256 + ((b - a) * (int32_t)voice->fraction) / 256;
            mix += (sample * voice->gain) / 127;
            voice->fraction += voice->step;
            voice->index += voice->fraction >> 16;
            voice->fraction &= 0xFFFF;
            if (voice->index >= voice->length) voice->active = false;
        }
        if (mix > 32767) mix = 32767;
        if (mix < -32768) mix = -32768;
        for (unsigned channel = 0; channel < channels; ++channel) {
            out[frame * channels + channel] = (int16_t)mix;
        }
    }
    doom_audio_unlock();
}

static boolean DG_ValidChannel(int channel) {
    return sfx_voices != NULL && channel >= 0 && channel < DOOM_SFX_VOICES;
}

static boolean DG_InitSound(boolean use_sfx_prefix) {
    sfx_use_prefix = use_sfx_prefix;
    if (sfx_output_rate != 0) return true;
    // The output task may render as soon as the bridge starts it, so the
    // (all idle) voices exist first.
    sfx_voices = (doom_sfx_voice_t*)heap_caps_calloc(
        DOOM_SFX_VOICES, sizeof(*sfx_voices),
        MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    if (sfx_voices == NULL) return false;
    const uint32_t rate = doom_audio_begin(DG_RenderSound);
    if (rate == 0) {
        // No usable audio: decline, and i_sound.c leaves sound off.
        heap_caps_free(sfx_voices);
        sfx_voices = NULL;
        return false;
    }
    sfx_output_rate = rate;
    return true;
}

static boolean DG_AnyVoiceActive(void) {
    boolean active = false;
    doom_audio_lock();
    for (int v = 0; v < DOOM_SFX_VOICES; ++v) active |= sfx_voices[v].active;
    doom_audio_unlock();
    return active;
}

// Runs from I_Quit right after M_QuitResponse starts the quit sound. Its
// I_WaitVBL(105) is a no-op in this port, so the sound gets vanilla's wait
// here instead, before the amplifier goes off for the restart.
static void DG_ShutdownSound(void) {
    if (sfx_voices == NULL) return;
    for (int waited = 0;
         waited < DOOM_SFX_QUIT_WAIT_MS && DG_AnyVoiceActive(); waited += 10) {
        I_Sleep(10);
    }
    doom_audio_end();
    doom_audio_lock();
    for (int v = 0; v < DOOM_SFX_VOICES; ++v) sfx_voices[v].active = false;
    doom_audio_unlock();
}

static int DG_GetSfxLumpNum(sfxinfo_t* sfx) {
    char name[16];
    if (sfx->link != NULL) sfx = sfx->link;
    snprintf(name, sizeof(name), sfx_use_prefix ? "ds%s" : "%s", sfx->name);
    return W_CheckNumForName(name);
}

static void DG_UpdateSound(void) {}

static void DG_UpdateSoundParams(int channel, int vol, int sep) {
    (void)sep;
    if (!DG_ValidChannel(channel)) return;
    doom_audio_lock();
    sfx_voices[channel].gain = vol;
    doom_audio_unlock();
}

static void DG_StopSound(int channel) {
    if (!DG_ValidChannel(channel)) return;
    doom_audio_lock();
    sfx_voices[channel].active = false;
    doom_audio_unlock();
}

static int DG_StartSound(sfxinfo_t* sfx, int channel, int vol, int sep) {
    (void)sep;
    if (!DG_ValidChannel(channel)) return -1;
    DG_StopSound(channel);
    if (sfx->lumpnum < 0) return -1;

    const uint8_t* lump = (const uint8_t*)W_CacheLumpNum(sfx->lumpnum, PU_STATIC);
    const int lump_bytes = W_LumpLength(sfx->lumpnum);
    if (lump == NULL || lump_bytes < DOOM_SFX_HEADER_BYTES ||
        lump[0] != 3 || lump[1] != 0) {
        return -1;
    }
    const uint32_t rate = (uint32_t)lump[2] | ((uint32_t)lump[3] << 8);
    const uint32_t length = (uint32_t)lump[4] | ((uint32_t)lump[5] << 8) |
                            ((uint32_t)lump[6] << 16) | ((uint32_t)lump[7] << 24);
    if (rate == 0 || length > (uint32_t)lump_bytes - DOOM_SFX_HEADER_BYTES ||
        length < DOOM_SFX_MIN_LENGTH) {
        return -1;
    }

    doom_sfx_voice_t voice = {
        lump + DOOM_SFX_HEADER_BYTES + DOOM_SFX_PAD_BYTES,
        length - 2 * DOOM_SFX_PAD_BYTES,
        0,
        0,
        (rate << 16) / sfx_output_rate,
        vol,
        true,
    };
    doom_audio_lock();
    sfx_voices[channel] = voice;
    doom_audio_unlock();
    return channel;
}

static boolean DG_SoundIsPlaying(int channel) {
    if (!DG_ValidChannel(channel)) return false;
    doom_audio_lock();
    const boolean playing = sfx_voices[channel].active;
    doom_audio_unlock();
    return playing;
}

// Nothing to cache: every lump is already mapped.
static void DG_CacheSounds(sfxinfo_t* sounds, int num_sounds) {
    (void)sounds; (void)num_sounds;
}

static snddevice_t sound_esp32_devices[] = { SNDDEVICE_SB };

sound_module_t DG_sound_module = {
    sound_esp32_devices,
    1,  // num_sound_devices
    DG_InitSound,
    DG_ShutdownSound,
    DG_GetSfxLumpNum,
    DG_UpdateSound,
    DG_UpdateSoundParams,
    DG_StartSound,
    DG_StopSound,
    DG_SoundIsPlaying,
    DG_CacheSounds,
};
