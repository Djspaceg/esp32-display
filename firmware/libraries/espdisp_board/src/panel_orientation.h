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
/// THE VISIBLE WINDOW IS BOTTOM-ALIGNED IN MEMORY, IN EVERY QUADRANT. The glass
/// occupies row addresses 80..319 of the 320 available, whatever the rotation and
/// whatever the mirror bits, so the row offset is unconditional.
///
/// Observed on white-cube-154 with the board's own placement log, one cable
/// position at a time. Note the quadrant is NOT the rotation: the sender streams
/// with the landscape flag set, so q = rotation + 1, and reading the reported
/// rotation as the quadrant is what made three earlier attempts fit three
/// positions and miss the fourth.
///
///   cable  rotation  q  row gap given  result
///   12     0         1  0              TRUNCATED
///   3      1         2  80             correct
///   6      2         3  80             correct
///   9      3         0  80             correct
///
/// Every quadrant that received 80 was correct and the only one that received 0
/// was truncated. So there is no MADCTL bit in this at all - not the axis swap,
/// not the row mirror, not the 180 flip. Each of those was tried, each produced a
/// zero in some quadrant, and that quadrant was always the broken one.
///
/// The column axis is separate and does still follow its mirror bit: here memory
/// equals glass so it never moves, and on the 172x320 C6 panel the 34-column
/// offset is symmetric within 240 and comes out the same either way.
inline WindowGap windowGap(uint16_t width, uint16_t height,
                           uint16_t memoryWidth, uint16_t memoryHeight,
                           uint16_t colOffset, uint16_t rowOffset, uint8_t q,
                           bool installationMirrorX = false) {
  // The row window is at the far end of memory in EVERY quadrant. Not derived
  // from the MADCTL bits - see the table above - and deliberately not conditional
  // on any of them, because every rule that made it conditional produced a zero
  // in some quadrant and that quadrant was always the truncated one.
  return {
      axisWindowGap(colOffset, width, memoryWidth,
                    mirrorX(q, installationMirrorX)),
      axisWindowGap(rowOffset, height, memoryHeight, true),
  };
}

}  // namespace panelorient
