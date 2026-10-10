// Compiles the vendored engine source snd_dma.c (engine/snd_dma.c.inc) as its own
// unit. Written by firmware/quake/update_engine_units.sh; do not edit.
#include "../quake_build.h"
#if defined(ESPDISP_QUAKE_RUNTIME)
#include "../platform/quake_prelude.h"
#include "../engine/snd_dma.c.inc"
QUAKE_DEFINE_STATICS_ALLOCATOR(snd_dma)
#endif
