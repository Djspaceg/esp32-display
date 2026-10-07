// Moves the engine's large zero-initialised arrays out of internal RAM.
//
// The P4 image links Quake into the same binary as the streaming firmware, and
// Arduino's precompiled IDF cannot put .bss in PSRAM: every engine global lands
// in the internal RAM that streaming, the C6 WiFi link and the I2S descriptors
// share. Upstream that is about 670 KB of .bss: some 230 KB of it is
// vid_null.c's frame and depth buffers, which quake_sys_esp32.c allocates
// instead, and about 430 KB is what this file moves. A streaming 4C has well
// under 40 KB of DMA-capable RAM to spare.
//
// Each rename below turns one upstream global into a dereferenced pointer:
//
//     #define cl_entities (*quake_cl_entities)
//
// so the upstream definition `entity_t cl_entities[MAX_EDICTS];` now reads
// `entity_t (*quake_cl_entities)[MAX_EDICTS];`, a 4-byte pointer to the same
// array type, and every `extern` declaration changes the same way. Indexing,
// `&x[i]`, `sizeof(x)` and `memset(x, 0, sizeof(x))` all keep their meaning, so
// the vendored sources are not edited. Each engine unit that defines one of
// them also defines its allocator (engine_units/), and quake_statics_allocate()
// calls them all at the start of a Quake boot, before the engine runs.
//
// Zero-initialised file-scope globals of 20 bytes or more are moved, except
// the few update_statics.py lists as EXCLUDED; the smaller ones stay, where a
// pointer would save little and cost an extra load on every use. A name moved
// must be used only as that global: a local, parameter or member of the same
// name would be renamed too. firmware/test/test_quake_statics.sh rejects any
// relocated name declared inside a function or struct; host_cmd.c's one
// local `cl` (compiled only with IDGODS) is renamed for that reason.
//
// INTERNAL entries are the renderer's and the QuakeC stacks: they come from
// internal RAM when the Quake boot has it (it does: WiFi and streaming are
// off), else PSRAM.
#pragma once

#include <stdbool.h>

// The lists and renames, generated from the compiled engine by
// firmware/quake/update_statics.py: per defining unit, X(name, placement),
// QUAKE_STATICS_UNITS naming every unit with a list, and one
// `#define name (*quake_name)` per entry.
#include "quake_statics_lists.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
  QUAKE_STATIC_PSRAM,
  QUAKE_STATIC_INTERNAL,
} quake_static_placement_t;

// Zeroed storage for one relocated array (quake_sys_esp32.c). NULL on failure.
void* quake_statics_calloc(unsigned bytes, quake_static_placement_t placement);

// Fills every relocated pointer. False if any allocation failed.
bool quake_statics_allocate(void);

#define QUAKE_STATICS_ALLOCATE_ONE(name, where)                     \
  if (quake_##name == 0) {                                           \
    quake_##name = quake_statics_calloc(sizeof(*quake_##name),       \
                                        QUAKE_STATIC_##where);       \
  }                                                                  \
  ok = ok && quake_##name != 0;

// Placed at the end of an engine unit, after its source, where every type and
// file-static it names is in scope.
#define QUAKE_DEFINE_STATICS_ALLOCATOR(unit)          \
  bool quake_statics_allocate_##unit(void) {          \
    bool ok = true;                                   \
    QUAKE_STATICS_##unit(QUAKE_STATICS_ALLOCATE_ONE)  \
    return ok;                                        \
  }

#define QUAKE_DECLARE_STATICS_ALLOCATOR(unit) \
  bool quake_statics_allocate_##unit(void);
QUAKE_STATICS_UNITS(QUAKE_DECLARE_STATICS_ALLOCATOR)

#ifdef __cplusplus
}
#endif
