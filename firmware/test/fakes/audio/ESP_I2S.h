#pragma once

#include <stddef.h>
#include <stdint.h>

enum i2s_slot_mode_t {
  I2S_SLOT_MODE_MONO,
  I2S_SLOT_MODE_STEREO,
};

static constexpr int I2S_MODE_STD = 1;
static constexpr int I2S_DATA_BIT_WIDTH_16BIT = 16;

class I2SClass {
 public:
  void setPins(int8_t mclk, int8_t bclk, int8_t lrck, int8_t dout,
               int8_t din);
  bool begin(int mode, uint32_t sampleRateHz, int bits,
             i2s_slot_mode_t slots);
  size_t write(const void *data, size_t bytes);
  size_t readBytes(char *data, size_t bytes);
  void end();
};
