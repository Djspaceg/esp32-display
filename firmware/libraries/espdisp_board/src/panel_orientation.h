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
/// The offset follows the MIRROR BIT OF ITS OWN AXIS and nothing else. When the
/// row axis is mirrored, row address 0 addresses the far end of memory, so the
/// visible 240 rows become addresses 80..319 and the window must start 80 rows
/// in. When it is not mirrored they are 0..239 and the offset is zero. The
/// column axis here has memory equal to glass, so its offset stays put either
/// way.
///
/// DO NOT MAKE THIS DEPEND ON THE AXIS SWAP. Two earlier rules did, each derived
/// by elimination rather than from the memory window, and each fitted three
/// rotations and failed the fourth: one swapped the extents and offsets along
/// with the axes (an 80 appeared on the column in the odd quarter turns), and one
/// applied the offset only for the 180 flip. Field evidence on white-cube-154:
/// with no offset anywhere the image was truncated in the two ADJACENT cable
/// positions that mirror rows, which is quadrants 2 and 3 - exactly the pair this
/// rule offsets and neither earlier rule did.
inline WindowGap windowGap(uint16_t width, uint16_t height,
                           uint16_t memoryWidth, uint16_t memoryHeight,
                           uint16_t colOffset, uint16_t rowOffset, uint8_t q,
                           bool installationMirrorX = false) {
  return {
      axisWindowGap(colOffset, width, memoryWidth,
                    mirrorX(q, installationMirrorX)),
      axisWindowGap(rowOffset, height, memoryHeight,
                    mirrorY(q, installationMirrorX)),
  };
}

}  // namespace panelorient
