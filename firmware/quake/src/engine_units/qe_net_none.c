// Compiles the vendored engine source net_none.c (engine/net_none.c.inc) as its own
// unit. Written by firmware/quake/update_engine_units.sh; do not edit.
#include "../quake_build.h"
#if defined(ESPDISP_QUAKE_RUNTIME)
#include "../platform/quake_prelude.h"
#include "../engine/net_none.c.inc"
QUAKE_DEFINE_STATICS_ALLOCATOR(net_none)
#endif
