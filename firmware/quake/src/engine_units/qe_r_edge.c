// Compiles the vendored engine source r_edge.c (engine/r_edge.c.inc) as its own
// unit. Written by firmware/quake/update_engine_units.sh; do not edit.
#include "../quake_build.h"
#if defined(ESPDISP_QUAKE_RUNTIME)
#include "../platform/quake_prelude.h"
#include "../engine/r_edge.c.inc"
QUAKE_DEFINE_STATICS_ALLOCATOR(r_edge)
#endif
