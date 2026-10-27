// BOOT button tiers: short press (WiFi status screen), double press (WiFi
// selector), long press (180 flip), extra-long press (power), and a triple
// press that reopens the boot-mode menu where it offers more than streaming. Edges
// are captured by an ISR so rendering cannot swallow one half of a double
// press. A carrier rotary encoder, where present, steps the same selector and
// otherwise the sender's volume, and its push switch's short press is the
// sender's mute. The WiFi selector and the boot menu share one scheme.
#pragma once

#include <stdint.h>

void initializeButtonInput();
void handleButton();

// A carrier's second key (Config::pinKey), reported as the PWR key's press
// and long press. serviceKeyButton() polls it; call it every 10 ms or so.
void initializeKeyInput();
void serviceKeyButton();

// Runs one input map function (a deviceproto::InputFunction value) for
// `input` (its ETCH gesture value): the board's own, the sender's, or nothing.
void runInputFunction(uint8_t input, uint8_t function);

// Whether a BOOT edge is still settling (inside the debounce window). The
// boot menu's countdown does not run out under one: a press made in its last
// moments stops it once it settles.
bool bootPressSettling();

// Called as the boot menu ends: the rest of a BOOT press that went down while
// it was up is swallowed, so it cannot reach the normal press tiers. Defined
// only in images that have a boot menu.
void swallowBootPressAcrossMenuEnd(uint32_t endedAt);
