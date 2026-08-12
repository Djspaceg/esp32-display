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

}  // namespace panelorient
