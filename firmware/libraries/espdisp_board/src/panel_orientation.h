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

/// The centring offsets to hand the driver, which are the panel's OWN offsets
/// with nothing derived from them: colOffset sits on the x axis for even
/// quadrants and moves to the y axis for odd ones, exactly as it always did for
/// landscape. This mapping matches the rotation/gap matrix in Waveshare's own
/// ESP-IDF example for the JD9853 board, and held on the ST7789 too.
///
/// DO NOT REINTRODUCE MEMORY-EXTENT ARITHMETIC HERE. A previous version computed
/// a "far edge" gap from memoryWidth/memoryHeight whenever a rotation mirrored an
/// address axis. On the square 1.54-inch panel - 240x240 visible inside 240x320
/// of controller RAM, with both of its own offsets zero and its descriptor's
/// per-rotation offsets table all zeros - that fabricated an 80-pixel gap out of
/// the 320, and the panel drew the image shifted with the right third of the glass
/// blank. Two successive attempts to pick the right rule by elimination each
/// failed on some other rotation, because the panel wants no gap at all in any
/// rotation and any nonzero value is wrong. The extents remain in the descriptor
/// for validation; they are deliberately not an input to this.
///
/// Field evidence: with the original pass-through the panel rendered correctly in
/// all four cable positions; with the derived gap it rendered a shifted rectangle
/// in the two positions whose rotation swaps the axes. The sender was ruled out
/// from the board's own counters - frames advancing with partial=0, badlen=0 and
/// drawerr=0 while the picture was wrong.
inline WindowGap windowGap(uint16_t width, uint16_t height,
                           uint16_t memoryWidth, uint16_t memoryHeight,
                           uint16_t colOffset, uint16_t rowOffset, uint8_t q,
                           bool installationMirrorX = false) {
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
