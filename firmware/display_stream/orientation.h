// Panel orientation: the sender-driven landscape flag, the user's persisted
// mounting rotation, the gravity-derived automatic correction, and the MADCTL
// application that composes them. Touch mapping reads appliedPanelRotation so
// a finger is never transformed ahead of a pending orientation change.
#pragma once

#include <stdint.h>

extern bool panelLandscape;       // current panel MADCTL state
extern uint8_t panelRotation;     // user mounting rotation, quarter turns 0-3
extern bool panelMirrorX;         // installation-level left/right reflection
extern uint8_t automaticRotation; // gravity-derived correction, RAM-only
extern uint8_t appliedPanelRotation;  // what MADCTL actually holds
extern bool madctlDirty;          // panel config needs reapplying

uint8_t effectivePanelRotation();
void applyPanelConfig(bool landscape);

// QMI8658 auto-rotation: four-way on square panels, flip-only otherwise.
extern bool motionAvailable;
void serviceAutoRotation();
void reportMotionDiagnostics();
