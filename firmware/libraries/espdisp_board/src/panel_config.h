// Display-controller and panel timing profiles, independent of MCU/carrier.
// Carrier wiring lives in board_config.h; chip memory and networking decisions
// live in platform_config.h.
#pragma once

#include <stdint.h>

namespace board {

enum class PanelDriver : uint8_t {
  St7789,
  Jd9853,
  Co5300,
  St77916,
  Gc9107,
  St7703,
};

enum class PanelBus : uint8_t { Spi, Qspi, MipiDsi };
enum class PanelProfile : uint8_t {
  St7789_172x320,
  Jd9853_172x320,
  Co5300_466x466,
  St77916_360x360,
  Gc9107_128x128,
  Gc9107_240x240,
  St7789_240x240,
  St7703_720x720,
  St7789V2_240x240,
};

struct PanelConfig {
  PanelProfile profile;
  PanelDriver driver;
  PanelBus bus;
  uint16_t width;
  uint16_t height;
  uint16_t memoryWidth;
  uint16_t memoryHeight;
  uint32_t pixelClockHz;
  uint8_t spiMode;
  uint8_t colOffset;
  uint8_t rowOffset;
  uint8_t orientationOffset;
  bool invertColor;
  bool roundDisplay;
  bool supportsCommandRotation;
  uint8_t dsiDataLanes;
  uint16_t dsiLaneMbps;
  uint16_t hsyncBackPorch;
  uint16_t hsyncPulseWidth;
  uint16_t hsyncFrontPorch;
  uint16_t vsyncBackPorch;
  uint16_t vsyncPulseWidth;
  uint16_t vsyncFrontPorch;
};
}  // namespace board
