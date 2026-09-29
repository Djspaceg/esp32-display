// Bench-only fault injection for the P4 hosted-WiFi watchdog check. Compiled
// in only when a gitignored fault_inject_local.h defining
// ESPDISP_FAULT_INJECT 1 sits beside the sketch AND the build is asked for it
// (tools/espdisp.py stages that header only with ESPDISP_FAULT_INJECT=1), so a
// shipped image never answers these commands (handleLine returns false).
//   DIAGC6HOLD <ms>  hold the C6 co-processor in reset (its GPIO low) for ms,
//                    then release it, so every hosted RPC in that window goes
//                    unanswered the way a silent C6 leaves it
//   DIAGRPCJAM <n> <kind>  from a side task, send n hosted RPCs back to back
//                    that this C6 leaves unanswered (kind 0 get_cp_info,
//                    1 fwversion), so hosted RPCs from every
//                    other task wait their turn behind them
//   DIAGSCAN <ms>    from a side task, run a blocking passive scan with this
//                    dwell per channel; the C6 answers no other RPC until it
//                    ends, so the loop's hosted RPCs go unanswered meanwhile
//   DIAGC6VER        print the host and co-processor ESP-Hosted versions
#pragma once

#include <Print.h>

namespace faultinject {

// Boot banner when compiled in; nothing otherwise.
void announce();
bool handleLine(const char *line, Print &out);

}  // namespace faultinject
