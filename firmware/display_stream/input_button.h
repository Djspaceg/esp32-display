// BOOT button tiers: short press (backlight toggle), double press (signal
// survey), long press (180 flip), extra-long press (power), and a triple press
// that reopens the boot-mode menu where it offers more than streaming. Edges
// are captured by an ISR so rendering cannot swallow one half of a double
// press. A carrier rotary encoder, where present, steps the same selector and
// backlight controls. The WiFi selector and the boot menu share one scheme.
#pragma once

#include <stdint.h>

void initializeButtonInput();
void handleButton();

// Called as the boot menu ends: the rest of a BOOT press that went down while
// it was up is swallowed, so it cannot reach the normal press tiers. Defined
// only in images that have a boot menu.
void swallowBootPressAcrossMenuEnd(uint32_t endedAt);
