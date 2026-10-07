// Compiles the vendored engine source d_sprite.c (engine/d_sprite.c.inc) as its own
// unit. Written by firmware/quake/update_engine_units.sh; do not edit.
#include "../quake_build.h"
#if defined(ESPDISP_QUAKE_RUNTIME)
#include "../platform/quake_prelude.h"
#include "../engine/d_sprite.c.inc"
#endif
