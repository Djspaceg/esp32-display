// BOOT button tiers: short press (backlight toggle), double press (signal
// survey), long press (180 flip), extra-long press (power), and a triple press
// that reopens the boot-mode menu where it offers more than streaming. Edges
// are captured by an ISR so rendering cannot swallow one half of a double
// press. A carrier rotary encoder, where present, steps the same selector and
// backlight controls. The WiFi selector and the boot menu share one scheme.
#pragma once

void initializeButtonInput();
void handleButton();
