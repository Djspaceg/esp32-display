// Compiles the vendored engine source net_main.c (engine/net_main.c.inc) as its own
// unit. Written by firmware/quake/update_engine_units.sh; do not edit.
#include "../quake_build.h"
#if defined(ESPDISP_QUAKE_RUNTIME)
#include "../platform/quake_prelude.h"
#include "../engine/net_main.c.inc"
QUAKE_DEFINE_STATICS_ALLOCATOR(net_main)
#endif
