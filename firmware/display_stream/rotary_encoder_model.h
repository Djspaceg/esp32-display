// Quadrature decoding for a detented rotary encoder, kept hardware-free so the
// host suite can drive it with recorded pin sequences.
//
// Both encoder lines idle high through pull-ups, so a detent rests at A=1 B=1.
// Each valid Gray-code transition moves the accumulator one quarter step, and a
// click is reported only when the encoder is back at rest having moved at least
// half a cycle. Contact bounce that returns to the starting state therefore
// cancels itself, and an invalid two-bit jump (both lines changed between
// samples) is ignored rather than guessed at.
#pragma once

#include <stdint.h>

// Called from a GPIO interrupt, so it must not become an out-of-line call into
// flash-resident code.
#define ROTARY_ENCODER_INLINE inline __attribute__((always_inline))

namespace rotaryencoder {

/// Pin state as a two-bit value: bit 1 is line A, bit 0 is line B.
ROTARY_ENCODER_INLINE uint8_t pinState(bool a, bool b) {
  return (uint8_t)((a ? 2 : 0) | (b ? 1 : 0));
}

static const uint8_t REST_STATE = 3;

/// Quarter-step direction between two pin states: +1, -1, or 0 for no change
/// or an invalid two-line jump. Pure arithmetic rather than a lookup table so
/// the GPIO interrupt that calls it never reads flash-resident constants.
/// Gray-to-binary turns the quadrature cycle 0-1-3-2 into positions 0-1-2-3.
ROTARY_ENCODER_INLINE int8_t quarterStep(uint8_t previous, uint8_t current) {
  const uint8_t from = (uint8_t)((previous ^ (previous >> 1)) & 3);
  const uint8_t to = (uint8_t)((current ^ (current >> 1)) & 3);
  const uint8_t delta = (uint8_t)((to - from) & 3);
  return delta == 1 ? 1 : (delta == 3 ? -1 : 0);
}

struct Decoder {
  uint8_t state = REST_STATE;
  int8_t accumulated = 0;

  /// Feed the current pin state; returns +1 or -1 on a completed detent,
  /// otherwise 0.
  ROTARY_ENCODER_INLINE int8_t update(uint8_t current) {
    current &= 3;
    accumulated = (int8_t)(accumulated + quarterStep(state, current));
    state = current;
    if (current != REST_STATE) return 0;
    const int8_t moved = accumulated;
    accumulated = 0;
    if (moved >= 2) return 1;
    if (moved <= -2) return -1;
    return 0;
  }
};

}  // namespace rotaryencoder
