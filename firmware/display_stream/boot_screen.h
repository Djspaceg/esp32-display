// The boot screen: the image, a progress bar and a status line, drawn the moment
// the panel is up and kept until the boot menu, a game, the stream or another
// screen of this firmware takes the panel. Layout, stage text and pixels are in
// boot_screen_model.h; this module only pushes rows to the panel.
//
// Draws through a small strip buffer of its own, so it works before the frame
// buffers exist.
#pragma once

#include <stdint.h>

#include "boot_screen_model.h"

namespace bootscreen {

using Stage = bootscreenmodel::Stage;

// Draws the whole screen at this stage. Returns whether every row reached the
// panel.
bool show(Stage stage);

// Moves to a stage, repainting only the rows that changed (the whole screen if
// it is not up or the panel's shape changed since).
void advance(Stage stage);

// The bar during the WiFi join, from elapsed time against the wait's deadline.
// Repaints only when the filled width moves.
void joining(uint32_t elapsedMs, uint32_t timeoutMs);

// Setup stopped: a red bar and this text (at most MAX_STATUS_CHARS to fit).
void fail(const char *text);

// Redraws the whole screen in the panel's current shape, at the current stage:
// after the boot menu covered it, or after a rotation.
void redraw();

// Another screen took the panel; showing() is false from now on.
void release();

// Whether the boot screen is what the panel is showing: drawn, not released,
// and no streamed frame drawn since.
bool showing();

// Composes rows [y0, y1) of the boot screen into dst, width pixels wide, for a
// screen drawn over part of it (the info bar). False, leaving dst alone, when
// the boot screen is not showing or width is not its width.
bool composeRows(uint8_t *dst, int width, int y0, int y1);

}  // namespace bootscreen
