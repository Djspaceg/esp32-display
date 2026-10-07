// Compiles the vendored engine source cl_parse.c (engine/cl_parse.c.inc) as its own
// unit. Written by firmware/quake/update_engine_units.sh; do not edit.
#include "../quake_build.h"
#if defined(ESPDISP_QUAKE_RUNTIME)
#include "../platform/quake_prelude.h"
#include "../engine/cl_parse.c.inc"
QUAKE_DEFINE_STATICS_ALLOCATOR(cl_parse)
#endif
