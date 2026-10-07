// Compiles the vendored engine source d_fill.c (engine/d_fill.c.inc) as its own
// unit. Written by firmware/quake/update_engine_units.sh; do not edit.
#include "../quake_build.h"
#if defined(ESPDISP_QUAKE_RUNTIME)
#include "../platform/quake_prelude.h"
#include "../engine/d_fill.c.inc"
#endif
