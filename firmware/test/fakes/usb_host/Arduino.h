// Host fake of the Arduino surface doom_usb_input.cpp touches: Serial output is
// captured, and the chip is the P4, so the file compiles its host-stack path.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include <string>

#ifndef CONFIG_IDF_TARGET_ESP32P4
#define CONFIG_IDF_TARGET_ESP32P4 1
#endif

class FakeSerial {
 public:
  std::string captured;
  void println(const char *value) {
    captured += value;
    captured += "\n";
  }
};
extern FakeSerial Serial;
