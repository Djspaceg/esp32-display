// Touch servicing: polls the controller, wakes a dimmed panel (consuming
// that press), shows the quick info bar on a plain tap, and forwards
// completed gestures to the sender.
#pragma once

#include <stdint.h>

void serviceTouch();

// The knob carrier's encoder detents and push-switch click, which the sender
// maps to its own volume and mute. Sent on the touch gesture sequence, so the
// sender's duplicate filter covers both.
enum class KnobGesture : uint8_t { Clockwise, Counterclockwise, Press };
void sendKnobGesture(KnobGesture gesture);

// Reads any finger already on the glass just before the boot menu opens, so it
// is ignored until lifted instead of being taken for a press on the menu.
// Defined only in images that have a boot menu.
void primeTouchForBootMenu();

// Whether a finger is down on the glass in a press the gesture tracker is
// following. For the boot menu's knob rule. Defined with the boot menu.
bool touchPressHeld();
