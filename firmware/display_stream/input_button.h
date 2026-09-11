// BOOT button tiers: short press (backlight toggle), double press (signal
// survey), long press (180 flip), extra-long press (power), and the Doom
// triple-tap on supported targets. Edges are captured by an ISR so rendering
// cannot swallow one half of a double press.
#pragma once

void initializeButtonInput();
void handleButton();
