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
  Jd9365,
  St7735,
  Ssd1315,
};

enum class PanelBus : uint8_t { Spi, Qspi, I2c, MipiDsi };
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
  St7789V2_170x320,
  Jd9365_720x720,
  Jd9365_800x800,
  St7735_96x54,
  Ssd1315_72x40,
  St7789V3_240x240,
  Gc9107Tqt_128x128,
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
  /// Whether a mirrored axis addresses the glass from the far end of the
  /// controller's memory, so the window there starts memory - glass - offset
  /// in (panelorient::windowGap). False keeps every quadrant on the panel's
  /// own near offsets, as measured on the Waveshare 1.54-inch ST7789.
  bool windowFollowsMirror = false;
  /// Whether the controller takes red and blue swapped (MADCTL BGR) on a SPI
  /// or QSPI panel: the descriptor's color_order.
  bool colorBgr = false;
  /// Whether init writes black over the whole memoryWidth x memoryHeight
  /// before the display turns on (panel_memory_clear.h).
  bool clearMemory = false;
};
}  // namespace board
