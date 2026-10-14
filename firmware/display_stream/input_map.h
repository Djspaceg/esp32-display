// The input map: which function each of this board's inputs runs in normal
// streaming mode (deviceproto::InputMap, EMAP/EINP). Owns the active map, its
// NVS copy, the map an EMAP left for loop() to apply, and the EINP report.
#pragma once

#include <stddef.h>
#include <stdint.h>

// Reads the stored map, or this board's defaults when none was saved. Call
// once in setup() after the board profile is resolved, before any input is
// serviced.
void loadInputMap();

// The function (a deviceproto::InputFunction value) the map in force gives
// `input` (its ETCH gesture value). The stored map is in force with no sender,
// or for the sender that sent it; any other sender gets this board's defaults.
uint8_t inputFunctionFor(uint8_t input);

// Whether BOOT's single (on the knob carrier, the knob's click), double and
// triple presses are still today's, so the immediate single press and the
// undo a double makes still apply.
bool bootShortPressesAsDefault();

// The highest of BOOT's short tiers (1-3) with a function, for counting.
uint8_t highestBoundBootTier();

// Network task: takes an EMAP for loop() to apply. Returns false for a
// packet that is not a valid map, which is then ignored.
bool offerInputMap(const uint8_t *data, size_t len);

// loop(): applies a map the network task took, saving it if it changed.
// Returns false only when a changed map could not be saved.
bool applyPendingInputMap();

// EINP to the sender: sent after each EINF. `powerKey`: this board's PWR key
// can be read (an AXP2101 that answered at boot).
void sendInputReport(bool powerKey);

// One line for CFGSHOW and the boot log: the active map, inputs 1..16.
void formatInputMap(char *out, size_t capacity);
