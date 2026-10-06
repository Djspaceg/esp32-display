// Doom's sound-effect output, between the engine's sound module
// (doom_sound_esp32.c.inc) and the board's codec backend, which
// display_stream/doom_audio.cpp drives. A Doom boot never starts the
// streaming audio engine, so while Doom runs the codec is this bridge's alone.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Writes `frames` interleaved frames of `channels` samples. Runs on the
/// bridge's output task, never on loopTask.
typedef void (*doom_audio_render_fn)(int16_t* out, size_t frames,
                                     unsigned channels);

/// Start the board's codec and an output task that pulls every block from
/// `render`. Returns the output sample rate, or 0 when this board has no
/// usable audio; a board whose descriptor names no audio parts gets no I2C
/// read and no GPIO write. Call once, from loopTask (it uses the I2C bus).
uint32_t doom_audio_begin(doom_audio_render_fn render);

/// Serializes the mixer state the engine writes and the output task reads.
/// No-ops until doom_audio_begin() has succeeded.
void doom_audio_lock(void);
void doom_audio_unlock(void);

/// Turn the speaker amplifier off ahead of a restart. Safe to call when
/// doom_audio_begin() failed or never ran.
void doom_audio_end(void);

#ifdef __cplusplus
}
#endif
