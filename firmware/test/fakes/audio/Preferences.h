#pragma once

#include <stdint.h>

class Preferences {
 public:
  bool begin(const char *, bool) { return true; }
  uint8_t getUChar(const char *, uint8_t fallback) { return fallback; }
  void end() {}
};
