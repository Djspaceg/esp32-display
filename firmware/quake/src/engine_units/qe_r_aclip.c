// Compiles the vendored engine source r_aclip.c (engine/r_aclip.c.inc) as its own
// unit. Written by firmware/quake/update_engine_units.sh; do not edit.
#include "../quake_build.h"
#if defined(ESPDISP_QUAKE_RUNTIME)
#include "../platform/quake_prelude.h"
#include "../engine/r_aclip.c.inc"
#endif
