// Device side of the "mem" diagnostic line (mem_report.h).
#pragma once

#include "mem_report.h"

namespace memdiag {

// Registers the heap allocation-failure callback. Call once, early in
// setup(), before the WiFi (and on P4 the ESP-Hosted) link starts, so its
// allocations are counted.
void begin();

// Reads the heap figures and counters for one line. Loop task only.
memreport::Sample sample();

}  // namespace memdiag
