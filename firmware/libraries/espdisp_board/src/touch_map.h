// Mapping raw AXS5106L touch coordinates into framebuffer coordinates.
//
// The panel's orientation follows macOS at runtime and the user can flip it 180
// for upside-down mounting, so a touch point only means something once it has
// been through the same transform the pixels went through. This file is that
// transform, and it lives beside panel_init.h deliberately: if touch and pixels
// disagree about which way is up, taps land in the wrong place, and the only way
// to prevent that is for one piece of arithmetic to serve both.
//
// Hardware-free on purpose, so it is unit tested on the host like
// band_protocol.h and panel_state.h. Nothing here touches I2C - see
// board_touch.h for the reading half.
//
// The transform is deliberately three small steps rather than one matrix, so
// each can be reasoned about (and corrected) on its own:
//
//   1. raw controller coords  ->  glass coords (portrait-upright)
//   2. glass coords           ->  framebuffer coords for the orientation
//   3. the 180 mounting flip
#pragma once

#include <stdint.h>

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

/// Steps 2 and 3: glass coordinates to framebuffer coordinates.
///
/// Landscape-flipped is expressed as landscape-then-180 rather than as its own
/// case, so the four combinations cannot drift apart.
inline Point glassToFrame(Point g, bool landscape, bool flip180) {
  Point f;
  if (!landscape) {
    f = g;
  } else if (ROTATE_CLOCKWISE) {
    f.x = g.y;
    f.y = (int16_t)(PANEL_SHORT - 1 - g.x);
  } else {
    f.x = (int16_t)(PANEL_LONG - 1 - g.y);
    f.y = g.x;
  }
  if (flip180) {
    f.x = (int16_t)(frameWidth(landscape) - 1 - f.x);
    f.y = (int16_t)(frameHeight(landscape) - 1 - f.y);
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
inline Point map(int16_t rawX, int16_t rawY, bool landscape, bool flip180) {
  return clampToFrame(glassToFrame(rawToGlass(rawX, rawY), landscape, flip180),
                      landscape);
}

}  // namespace touchmap
