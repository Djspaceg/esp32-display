#pragma once

#include <stddef.h>
#include <stdint.h>

enum i2s_slot_mode_t {
  I2S_SLOT_MODE_MONO,
  I2S_SLOT_MODE_STEREO,
};

static constexpr int I2S_MODE_STD = 1;
static constexpr int I2S_DATA_BIT_WIDTH_16BIT = 16;

// The IDF channel handle and the disable and delete calls, as
// driver/i2s_common.h declares them. The fake port has one channel pair; a handle the fake hands out stays
// allocated until end() or i2s_del_channel() frees it.
#ifndef ESP_OK
#define ESP_OK 0
#endif
typedef struct FakeI2sChannel *i2s_chan_handle_t;
int i2s_channel_disable(i2s_chan_handle_t handle);
int i2s_del_channel(i2s_chan_handle_t handle);

// Mirrors the Arduino core's I2SClass where it matters to callers: begin()
// creates the channel before configuring it, so a configuration that fails
// (an I2S DMA allocation, on a P4 short of internal DMA RAM) returns false
// with the channel still allocated; end() disables before deleting and bails
// on the first error, so a channel that was never enabled is not deleted.
class I2SClass {
 public:
  void setPins(int8_t mclk, int8_t bclk, int8_t lrck, int8_t dout,
               int8_t din);
  bool begin(int mode, uint32_t sampleRateHz, int bits,
             i2s_slot_mode_t slots);
  size_t write(const void *data, size_t bytes);
  size_t readBytes(char *data, size_t bytes);
  bool end();
  i2s_chan_handle_t txChan() { return tx_; }
  i2s_chan_handle_t rxChan() { return rx_; }

 private:
  bool begun_ = false;
  bool capture_ = false;
  i2s_chan_handle_t tx_ = nullptr;
  i2s_chan_handle_t rx_ = nullptr;
};
