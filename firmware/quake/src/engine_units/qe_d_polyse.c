// Compiles the vendored engine source d_polyse.c (engine/d_polyse.c.inc) as its own
// unit. Written by firmware/quake/update_engine_units.sh; do not edit.
#include "../quake_build.h"
#if defined(ESPDISP_QUAKE_RUNTIME)
#include "../platform/quake_prelude.h"
#include "../engine/d_polyse.c.inc"
QUAKE_DEFINE_STATICS_ALLOCATOR(d_polyse)
#endif
