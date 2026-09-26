// Detent decoding for a half-cycle rotary encoder, kept hardware-free so the
// host suite can drive it with recorded pin sequences.
//
// The CrowPanel knob's EC3501-C15H30 datasheet gives 30 detents for 15 pulses
// (one pulse per two detents), with every detent resting at a stable A level
// and B unspecified - B may sit on its edge and chatter there. So each change of
// A is exactly one detent crossed, and B, which is a quarter cycle away from any
// A edge, gives the direction. B changes alone are ignored. Contact bounce on A
// reverses the direction on every bounce, so it cancels itself; a sample where
// both lines changed at once carries no direction and is dropped.
//
// Direction follows ELECROW's own decoder: A changing to differ from B is
// clockwise, reported as +1.
#pragma once

#include <stdint.h>

namespace rotaryencoder {

/// Pin state as a two-bit value: bit 1 is line A, bit 0 is line B.
inline uint8_t pinState(bool a, bool b) {
  return (uint8_t)((a ? 2 : 0) | (b ? 1 : 0));
}

struct Decoder {
  uint8_t state = 3;  // both lines idle high through their pull-ups

  /// Feed the current pin state; returns +1 (clockwise) or -1 on a detent,
  /// otherwise 0.
  int8_t update(uint8_t current) {
    current &= 3;
    const uint8_t changed = (uint8_t)(state ^ current);
    state = current;
    if (changed != 2) return 0;  // no change, B only, or both at once
    const bool a = (current & 2) != 0;
    const bool b = (current & 1) != 0;
    return a != b ? 1 : -1;
  }
};

}  // namespace rotaryencoder
