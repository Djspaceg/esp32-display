// Host fake of the touch controller, so the real serviceTouch() in
// input_touch.cpp runs in test_doom_entry_gate. Shadows the library's
// board_touch.h because fakes/doom_entry is first on the include path.
#pragma once

#include <stdint.h>

#include <board_config.h>

namespace boardtouch {

struct Sample {
  bool pressed;
  uint16_t rawX;
  uint16_t rawY;
  uint8_t points;
};

// The test owns the reports: one is handed out per poll once its time comes.
bool poll(Sample &sample);

// A direct read of where the finger is now, whatever has been reported.
bool readNow(Sample &sample);

inline bool init(const board::Config &) { return true; }

}  // namespace boardtouch
