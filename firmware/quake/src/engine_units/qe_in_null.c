// Compiles the vendored engine source in_null.c (engine/in_null.c.inc) as its own
// unit. Written by firmware/quake/update_engine_units.sh; do not edit.
#include "../quake_build.h"
#if defined(ESPDISP_QUAKE_RUNTIME)
#include "../platform/quake_prelude.h"
#include "../engine/in_null.c.inc"
QUAKE_DEFINE_STATICS_ALLOCATOR(in_null)
#endif
