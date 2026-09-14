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

static constexpr PanelConfig PANEL_ST7789_172X320 = {
    PanelProfile::St7789_172x320, PanelDriver::St7789, PanelBus::Spi,
    172, 320, 80000000, 0, 34, 0, 0, true, false, true,
    0, 0, 0, 0, 0, 0, 0, 0};
static constexpr PanelConfig PANEL_JD9853_172X320 = {
    PanelProfile::Jd9853_172x320, PanelDriver::Jd9853, PanelBus::Spi,
    172, 320, 80000000, 0, 34, 0, 0, true, false, true,
    0, 0, 0, 0, 0, 0, 0, 0};
static constexpr PanelConfig PANEL_CO5300_466X466 = {
    PanelProfile::Co5300_466x466, PanelDriver::Co5300, PanelBus::Qspi,
    466, 466, 40000000, 0, 6, 0, 0, false, true, true,
    0, 0, 0, 0, 0, 0, 0, 0};
static constexpr PanelConfig PANEL_ST77916_360X360 = {
    PanelProfile::St77916_360x360, PanelDriver::St77916, PanelBus::Qspi,
    360, 360, 80000000, 0, 0, 0, 0, true, true, true,
    0, 0, 0, 0, 0, 0, 0, 0};
static constexpr PanelConfig PANEL_GC9107_128X128 = {
    PanelProfile::Gc9107_128x128, PanelDriver::Gc9107, PanelBus::Spi,
    128, 128, 40000000, 0, 2, 1, 2, true, false, true,
    0, 0, 0, 0, 0, 0, 0, 0};
static constexpr PanelConfig PANEL_ST7789_240X240 = {
    PanelProfile::St7789_240x240, PanelDriver::St7789, PanelBus::Spi,
    240, 240, 40000000, 3, 0, 0, 0, true, false, true,
    0, 0, 0, 0, 0, 0, 0, 0};
static constexpr PanelConfig PANEL_ST7789V2_240X240 = {
    PanelProfile::St7789V2_240x240, PanelDriver::St7789, PanelBus::Spi,
    240, 240, 40000000, 0, 0, 0, 0, true, false, true,
    0, 0, 0, 0, 0, 0, 0, 0};
static constexpr PanelConfig PANEL_ST7703_720X720 = {
    PanelProfile::St7703_720x720, PanelDriver::St7703, PanelBus::MipiDsi,
    720, 720, 38000000, 0, 0, 0, 0, false, false, false,
    2, 480, 50, 20, 50, 20, 4, 20};

}  // namespace board
