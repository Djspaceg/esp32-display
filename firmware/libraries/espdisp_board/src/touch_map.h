// Mapping raw AXS5106L touch coordinates into framebuffer coordinates.
//
// The panel's orientation follows macOS at runtime and the user can rotate it
// in quarter turns for its mounting (180 on rectangular panels, any quarter on
// square ones), so a touch point only means something once it has been through
// the same transform the pixels went through. This file is that
// transform, and it lives beside panel_init.h deliberately: if touch and pixels
// disagree about which way is up, taps land in the wrong place, and the only way
// to prevent that is for one piece of arithmetic to serve both.
//
// Hardware-free on purpose, so it is unit tested on the host like
// band_protocol.h and panel_state.h. Nothing here touches I2C - see
// board_touch.h for the reading half.
//
// The transform is deliberately two small steps rather than one matrix, so
// each can be reasoned about (and corrected) on its own:
//
//   1. raw controller coords  ->  glass coords (portrait-upright)
//   2. glass coords           ->  framebuffer coords for the quadrant, i.e.
//      the sender's landscape turn composed with the user's mounting
//      rotation (clockwise quarter turns 0-3; 2 is the old 180 flip)
//
// The quadrant composition is panelorient::quadrant - the same arithmetic
// panel_init.h drives MADCTL with, which is what keeps touch and pixels
// agreeing about which way is up.
#pragma once

#include <stdint.h>

#include "panel_orientation.h"

namespace touchmap {

/// Panel geometry, in its native portrait sense. The framebuffer is
/// SHORT x LONG in portrait and LONG x SHORT in landscape.
static const int16_t PANEL_SHORT = 172;
static const int16_t PANEL_LONG = 320;

struct Point {
  int16_t x;
  int16_t y;
};

inline int16_t frameWidth(bool landscape) {
  return landscape ? PANEL_LONG : PANEL_SHORT;
}
inline int16_t frameHeight(bool landscape) {
  return landscape ? PANEL_SHORT : PANEL_LONG;
}

/// Whether the controller's X axis runs opposite to the display's X axis in
/// portrait.
///
/// Set from evidence rather than derivation: Waveshare's own Arduino AXS5106L
/// driver applies `x = width - 1 - x` in its rotation-0 case, while their
/// esp_lcd display config for rotation 0 uses mirror_x = false. Same vendor,
/// same board, both their own code - so the raw touch X is mirrored relative to
/// the panel's X.
///
/// STATUS: confirmed on an ESP32-C6-Touch-LCD-1.47. Touching the white corner in
/// portrait reported raw (150,10) and (154,13), which map to framebuffer (21,10)
/// and (17,13) - inside the white square. Touching blue reported raw (19,312),
/// mapping to (152,312), inside the blue square. Both require the X mirror; with
/// it removed the two corners would swap.
static const bool RAW_X_MIRRORED = true;

/// Which way the image rotates when the panel goes landscape.
///
/// Our landscape MADCTL is MV|MX, but deriving the resulting touch axis mapping
/// from MADCTL bits is exactly the kind of reasoning that produces a transform
/// which is wrong by one reflection and looks right until you touch a corner.
///
/// STATUS: confirmed on hardware across all four orientations. In landscape,
/// touching white reported raw (23,7) -> (7,23) and blue reported raw (143,311)
/// -> (311,143); in landscape-flipped, white reported raw (144,313) -> (6,27) and
/// blue raw (33,13) -> (306,138). Each lands inside the square of the colour that
/// was touched, in a frame whose axes are swapped relative to portrait. The
/// counter-clockwise alternative would put every one of those in the opposite
/// corner along Y.
static const bool ROTATE_CLOCKWISE = true;

/// Step 1: raw controller coordinates to glass coordinates.
///
/// Glass coordinates are "where your finger is on the physical panel, viewed in
/// portrait-upright", independent of what the firmware is currently displaying.
inline Point rawToGlass(int16_t rawX, int16_t rawY) {
  Point g;
  g.x = RAW_X_MIRRORED ? (int16_t)(PANEL_SHORT - 1 - rawX) : rawX;
  g.y = rawY;
  return g;
}

/// Whether this orientation's framebuffer has swapped axes (landscape-shaped),
/// i.e. the quadrant is odd. With rotation limited to {0, 2} - every
/// rectangular panel, since only square glass accepts quarter turns - this is
/// exactly the landscape flag, which is why callers that key buffer shape on
/// `landscape` alone stay correct.
inline bool swapsAxes(bool landscape, uint8_t rotation) {
  return panelorient::swapXY(panelorient::quadrant(rotation, landscape));
}

/// Step 2: glass coordinates to framebuffer coordinates, through the same
/// quadrant the pixels went through (rotation is the user's mounting turn,
/// clockwise quarter turns 0-3; 2 is the old 180 flip).
///
/// The four quadrant cases are one clockwise quarter turn apart, composed as
/// panelorient::quadrant so a rotation of 2 is landscape-then-180 by
/// construction rather than by a separate flip step that could drift. The 180
/// involution the old flip step guaranteed still holds as arithmetic: the
/// point at quadrant q+2 is the point at quadrant q reflected through the
/// frame's centre, asserted by the host suite across the whole coordinate
/// space and from every rotation, not only from upright.
inline Point glassToFrame(Point g, bool landscape, uint8_t rotation) {
  uint8_t q = panelorient::quadrant(rotation, landscape);
  if (!ROTATE_CLOCKWISE) {
    // A panel whose landscape MADCTL turns the image the other way would need
    // touch to turn with it. Negating the quadrant keeps the hardware
    // evidence above meaningful rather than folding it away silently.
    q = (uint8_t)((4 - q) & 3);
  }
  Point f;
  switch (q) {
    case 1:  // one clockwise quarter turn (the old landscape case)
      f.x = g.y;
      f.y = (int16_t)(PANEL_SHORT - 1 - g.x);
      break;
    case 2:  // 180 (the old portrait-flipped case)
      f.x = (int16_t)(PANEL_SHORT - 1 - g.x);
      f.y = (int16_t)(PANEL_LONG - 1 - g.y);
      break;
    case 3:  // three clockwise = one counter-clockwise (landscape-flipped)
      f.x = (int16_t)(PANEL_LONG - 1 - g.y);
      f.y = g.x;
      break;
    default:  // q == 0: portrait upright
      f = g;
      break;
  }
  return f;
}

/// Hold a point inside the framebuffer.
///
/// Touch controllers report a little outside the active area near the bezel, and
/// an out-of-range point would index past the framebuffer. Clamping rather than
/// rejecting is deliberate: a tap 1px off the edge is still a tap on the edge,
/// and silently dropping it feels like the panel ignored you.
inline Point clampToFrame(Point p, bool landscape) {
  const int16_t w = frameWidth(landscape);
  const int16_t h = frameHeight(landscape);
  if (p.x < 0) p.x = 0;
  if (p.y < 0) p.y = 0;
  if (p.x > w - 1) p.x = (int16_t)(w - 1);
  if (p.y > h - 1) p.y = (int16_t)(h - 1);
  return p;
}

/// Raw controller coordinates straight to a clamped framebuffer point.
///
/// The clamp is bounded by the quadrant's frame shape, not the landscape flag
/// alone: an odd total quadrant (only reachable with rotation 1/3, i.e. on
/// square glass where the two shapes coincide anyway) swaps which axis is
/// long. On every rectangular panel the two agree - see swapsAxes.
inline Point map(int16_t rawX, int16_t rawY, bool landscape, uint8_t rotation) {
  return clampToFrame(glassToFrame(rawToGlass(rawX, rawY), landscape, rotation),
                      swapsAxes(landscape, rotation));
}

}  // namespace touchmap
