// How much of a panel controller's own memory to clear before the display
// turns on, kept apart from panel_init.h so the host suite can reach it.
//
// A controller's memory comes up holding noise, and only the window the
// firmware draws is ever rewritten. If that window and the glass ever
// disagree, the glass shows the noise, frozen: that was the XIAO's 0.42-inch
// ST7735 (96x54 of glass in 128x160 of memory) until its far-end window rule
// was measured. Clearing the whole memory once at init turns any such
// mismatch into black instead.
//
// Only the ST7735 is cleared. Its memory extents are measured; every other
// panel's init stays exactly as it was proven on its own board.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "panel_config.h"

namespace panelorient {

struct MemoryExtent {
  uint16_t width;
  uint16_t height;
};

/// The controller memory to clear at init, or 0x0 for none.
inline MemoryExtent memoryToClear(const board::PanelConfig &panel) {
  if (panel.driver != board::PanelDriver::St7735 ||
      panel.bus != board::PanelBus::Spi || panel.memoryWidth == 0 ||
      panel.memoryHeight == 0) {
    return {0, 0};
  }
  return {panel.memoryWidth, panel.memoryHeight};
}

/// Whole RGB565 memory rows per clearing transfer that fit maxTransferBytes,
/// at most the memory's height; 0 when not even one row fits.
inline uint16_t clearBandRows(MemoryExtent extent, size_t maxTransferBytes) {
  const size_t rowBytes = (size_t)extent.width * 2;
  if (rowBytes == 0 || extent.height == 0) return 0;
  const size_t rows = maxTransferBytes / rowBytes;
  if (rows == 0) return 0;
  return (uint16_t)(rows < extent.height ? rows : extent.height);
}

}  // namespace panelorient
