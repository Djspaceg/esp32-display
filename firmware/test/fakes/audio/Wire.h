#pragma once

#include <stddef.h>
#include <stdint.h>

class TwoWire {
 public:
  bool begin(int8_t sda, int8_t scl, uint32_t frequency);
  void beginTransmission(uint8_t address);
  size_t write(uint8_t value);
  uint8_t endTransmission();
};

extern TwoWire Wire;
