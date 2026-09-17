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
/// WHAT THE PANEL ACTUALLY DID, one quadrant at a time on white-cube-154. Each
/// row is an observation on the glass, not a derivation:
///
///   q  swapped  mirrorY  row gap tried  result
///   0  no       no       0              TRUNCATED
///   1  yes      no       0              correct
///   2  no       yes      80             correct
///   3  yes      yes      80             correct
///
/// q0 and q1 were both given 0 and only q1 was correct, so the gap alone does not
/// decide it and the axis swap matters. Among the UNSWAPPED quadrants, 80 was
/// correct and 0 was truncated - so unswapped wants the far end whether or not the
/// rows are mirrored. Among the SWAPPED quadrants both values tried were correct,
/// which is consistent with the swap moving this offset onto the column axis where
/// memory equals glass and it cannot matter; that is NOT established, only
/// unfalsified, so the swapped quadrants keep the exact values already seen
/// working rather than being tidied into a prettier rule.
///
/// This is why the earlier attempts kept failing: both tied the offset to the axis
/// swap alone, or to the row mirror alone, and each fitted three quadrants and
/// missed the fourth. There is no single-bit rule here.
inline WindowGap windowGap(uint16_t width, uint16_t height,
                           uint16_t memoryWidth, uint16_t memoryHeight,
                           uint16_t colOffset, uint16_t rowOffset, uint8_t q,
                           bool installationMirrorX = false) {
  // The row window sits at the far end of memory unless the axes are swapped and
  // the rows are not mirrored. Read off the panel one quadrant at a time rather
  // than derived, because the swapped quadrants turned out not to behave like the
  // unswapped ones - see the table above the function.
  const bool rowAtFarEnd =
      !swapXY(q) || mirrorY(q, installationMirrorX);
  return {
      axisWindowGap(colOffset, width, memoryWidth,
                    mirrorX(q, installationMirrorX)),
      axisWindowGap(rowOffset, height, memoryHeight, rowAtFarEnd),
  };
}

}  // namespace panelorient
