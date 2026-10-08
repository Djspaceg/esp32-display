// The C6 coprocessor's ESP-Hosted firmware at runtime: the boot report, the
// CFGSHOW fields, and CFGC6UPDATE. The decisions live in coprocessor_update.h.
//
// On a board with no hosted coprocessor every call is a no-op: status() is
// Unknown and startUpdate() refuses.
#pragma once

#include <stddef.h>

#include "coprocessor_update.h"

namespace coprocessorsvc {

/// Reads the host's and the coprocessor's ESP-Hosted versions and prints one
/// boot line. No RPC: the core asked the coprocessor once, when it brought
/// ESP-Hosted up for WiFi.begin(), and this reads that answer. Call it from
/// setup() after WiFi.begin().
void probe();

coprocessor::Status status();

/// "2.12.13", or "none" when the coprocessor did not report one.
void coprocessorVersionText(char *out, size_t len);

/// Starts installing the pinned image for this host on the update task
/// (coprocessor_ota.h) and returns nullptr, or returns why it will not
/// (version unknown, not older, no pinned image for this host, not on WiFi,
/// already running). The task prints C6UPDATE lines and restarts the board
/// once the coprocessor has the image; on any failure before finalizing it
/// leaves the coprocessor's current image in place. A C6UPDATE OK line may
/// not appear: ESP-Hosted can restart the host as soon as the C6 resets.
const char *startUpdate();

}  // namespace coprocessorsvc
