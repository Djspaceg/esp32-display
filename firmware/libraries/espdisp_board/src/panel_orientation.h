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
/// The gap is expressed in the CONTROLLER's column/row space, not in the rotated
/// screen space, so it is NOT swapped when MADCTL swaps the axes: the rotation
/// setting changes how the controller scans its memory, not where that memory
/// begins. An earlier version swapped the extents and offsets alongside the axes,
/// which measured a 240-wide window against the 320-tall extent in the odd
/// quarter turns and put 80 pixels of offset on the wrong axis.
///
/// FIELD-VERIFIED on the square 1.54-inch panel (white-cube-154, S3): with the
/// cable in the two positions whose rotation swaps the axes, the old rule drew
/// the image as an off-centre rectangle, while the two non-swapping positions
/// were a correct 240x240. The sender was ruled out at the same time from the
/// board's own counters - frames advancing with partial=0, badlen=0, drawerr=0
/// while the picture was wrong, so a correctly sized frame was being misplaced.
inline WindowGap windowGap(uint16_t width, uint16_t height,
                           uint16_t memoryWidth, uint16_t memoryHeight,
                           uint16_t colOffset, uint16_t rowOffset, uint8_t q,
                           bool installationMirrorX = false) {
  // The row window sits at the far end of memory only for the 180 flip: rows
  // mirrored AND axes not swapped. Under a swap it starts at the near end.
  const bool rowAtFarEnd =
      mirrorY(q, installationMirrorX) && !swapXY(q);
  return {
      axisWindowGap(colOffset, width, memoryWidth,
                    mirrorX(q, installationMirrorX)),
      axisWindowGap(rowOffset, height, memoryHeight, rowAtFarEnd),
  };
}

}  // namespace panelorient
