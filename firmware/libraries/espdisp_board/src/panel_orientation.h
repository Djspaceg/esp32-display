// The quarter-turn arithmetic behind MADCTL orientation and touch mapping.
//
// Extracted from panel_init.h so it can be host-tested: panel_init.h needs the
// esp_lcd headers and cannot compile off-target, but the part of it that was
// ever worth testing is this pure arithmetic. touch_map.h composes the same
// quadrant, which is the point of sharing it - if touch and pixels disagree
// about which way is up, taps land in the wrong place, and one piece of
// arithmetic serving both is the only structural way to prevent that.
//
// THE INSIGHT THIS ENCODES: the historical applyOrientation table was already
// the quarter-turn table. Its four states -
//
//   portrait             MADCTL 0        q=0
//   landscape            MV|MX           q=1
//   portrait flipped     MX|MY           q=2
//   landscape flipped    MV|MY           q=3
//
// - are exactly q = (landscape ? 1 : 0) + (flip180 ? 2 : 0) clockwise quarter
// turns. Generalising flip180 (0 or 2 turns) to rotation (0-3 turns) therefore
// adds no new MADCTL states at all; it only makes q=1 and q=3 reachable from
// portrait. The host suite asserts this reproduces the old four states
// byte-for-byte.
#pragma once

#include <stdint.h>

namespace panelorient {

/// Total clockwise quarter turns the panel content is addressed through:
/// the user's mounting rotation composed with the sender's landscape turn.
inline uint8_t quadrant(uint8_t rotation, bool landscape) {
  return (uint8_t)((rotation + (landscape ? 1u : 0u)) & 3u);
}

/// MADCTL MV: odd quadrants exchange the axes.
inline bool swapXY(uint8_t q) { return (q & 1) != 0; }

/// MADCTL MX. With swapXY these three reproduce the table above:
/// q=0 none, q=1 MV|MX, q=2 MX|MY, q=3 MV|MY.
inline bool mirrorX(uint8_t q) { return q == 1 || q == 2; }

/// MADCTL MY.
inline bool mirrorY(uint8_t q) { return q == 2 || q == 3; }

/// Compose an installation-level framebuffer-X reflection with MADCTL. After
/// an odd quadrant swaps axes, visible left/right is carried by MY instead.
inline bool mirrorX(uint8_t q, bool installationMirrorX) {
  return mirrorX(q) != (installationMirrorX && !swapXY(q));
}

inline bool mirrorY(uint8_t q, bool installationMirrorX) {
  return mirrorY(q) != (installationMirrorX && swapXY(q));
}

struct WindowGap {
  uint16_t x;
  uint16_t y;
};

/// One axis of the window offset. Unmirrored, the visible span starts at the
/// panel's own near offset. Mirrored, address 0 is the far end of memory, so the
/// same span starts memoryExtent - visibleExtent - nearOffset in. Degenerate or
/// unknown extents (a panel whose memory equals its glass, or one whose extents
/// were never measured and read zero) fall back to the near offset unchanged.
inline uint16_t axisWindowGap(uint16_t nearOffset, uint16_t visibleExtent,
                              uint16_t memoryExtent, bool mirrored) {
  if (!mirrored || memoryExtent == 0 || visibleExtent > memoryExtent ||
      nearOffset > memoryExtent - visibleExtent) {
    return nearOffset;
  }
  return (uint16_t)(memoryExtent - visibleExtent - nearOffset);
}

/// Where the visible window sits inside the controller's own memory.
///
/// This panel family shows a FIXED window of a larger memory: the 1.54-inch
/// ST7789 is 240x240 of glass over 240x320 of RAM, and the driver is told no
/// resolution at all - esp_lcd_panel_dev_config_t carries none - so the only
/// things that place the image are the window the draw call passes (always the
/// full panel) and this gap.
///
/// THE GLASS IS TOP-ALIGNED IN MEMORY, so the offset is the panel's OWN near
/// offset and nothing is derived from the memory extents. On the 1.54-inch panel
/// both of its offsets are zero and its descriptor lists all four per-rotation
/// offsets as zero, so the gap is (0,0) in every quadrant.
///
/// HOW THAT WAS ESTABLISHED, from the failure signature rather than by fitting:
/// with a row gap of 80 the driver addresses rows 80..319, but the visible window
/// is rows 0..239. So 80 rows of the image fall off the bottom into memory the
/// glass never shows, 160 rows land in the lower part of the glass, and the top 80
/// rows are never written at all - which showed up as an image TRUNCATED at the
/// top with a stale, non-updating strip above it. Truncation means content lost,
/// not content moved: a shift would have kept all 240 rows.
///
/// The memory extents stay in the descriptor for validation and are deliberately
/// NOT an input here. Every rule that derived an offset from them put a nonzero
/// value into some quadrant, and that quadrant was always the broken one.
///
/// A WARNING FOR ANYONE RE-DERIVING THIS. Several rules were fitted here before
/// the board could report anything, and all were wrong, because the picture also
/// depended on the sender's capture source: this panel's app record had the WHOLE
/// 3456x2234 display as its source instead of a 240x240 region, so a non-square
/// capture was being fitted onto square glass and the result changed with
/// rotation. Any bench result from before that was corrected is untrustworthy.
///
/// The board now logs what it programmed (see applyOrientation), and driving
/// CFGROT 0..3 over one open serial port reports the quadrant per rotation. Note
/// q = rotation + 1, because the sender streams with the landscape flag set;
/// reading the reported rotation as the quadrant is what made the earlier attempts
/// each fit three cable positions and miss the fourth.
inline WindowGap windowGap(uint16_t width, uint16_t height,
                           uint16_t memoryWidth, uint16_t memoryHeight,
                           uint16_t colOffset, uint16_t rowOffset, uint8_t q,
                           bool installationMirrorX = false) {
  // The visible window is top-aligned, so hand the driver the panel's own near
  // offsets and derive nothing from the memory extents. colOffset rides the x axis
  // and rowOffset the y axis, swapping with the axes exactly as the landscape path
  // always did.
  (void)width;
  (void)height;
  (void)memoryWidth;
  (void)memoryHeight;
  (void)installationMirrorX;
  const bool swap = swapXY(q);
  return {
      swap ? rowOffset : colOffset,
      swap ? colOffset : rowOffset,
  };
}

}  // namespace panelorient
