// Panel orientation: the sender-driven landscape flag, the user's persisted
// mounting rotation, the gravity-derived automatic correction, and the MADCTL
// application that composes them. Touch mapping reads addressedPanelRotation
// (derived from appliedPanelRotation) so a finger is never transformed ahead
// of a pending orientation change.
#pragma once

#include <stdint.h>

extern bool panelLandscape;       // current panel MADCTL state
extern uint8_t panelRotation;     // user mounting rotation, quarter turns 0-3
extern bool panelMirrorX;         // installation-level left/right reflection
extern bool automaticRotationEnabled;  // persisted gravity correction setting
extern uint8_t automaticRotation; // gravity-derived correction, RAM-only
extern uint8_t appliedPanelRotation;  // what MADCTL actually holds
extern bool madctlDirty;          // panel config needs reapplying

uint8_t desiredPanelRotation();
// appliedPanelRotation as it reaches the MADCTL quadrant: all of it on square
// glass, only its half-turn part on rectangular glass, where the quarter turn
// rides the frame shape (panelorient::addressedRotation). Touch maps through
// this so a finger follows the pixels.
uint8_t addressedPanelRotation();
// The frame shape the firmware's own screens use when no sender frame decides
// it: landscape on rectangular glass mounted at rotation 1 or 3.
bool localFrameLandscape();
bool panelIsRectangular();
void setAutomaticRotationEnabled(bool enabled);
void applyPanelConfig(bool landscape);

// QMI8658 auto-rotation: four-way on square panels, flip-only otherwise. On
// rectangular glass mounted at rotation 1 or 3 the flip is read across the
// panel's other axis, since gravity then lies along its short side.
extern bool motionAvailable;
void serviceAutoRotation();
void reportMotionDiagnostics();
