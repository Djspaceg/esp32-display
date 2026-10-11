// Included by every Quake engine unit before any engine source or header:
// the PSRAM relocations and the renames that let Quake share an image with
// Doom. The engine headers have no include guards, which is why each upstream
// .c is its own unit (engine_units/) rather than one unity build like Doom's.
#pragma once

#include "quake_renames.h"
#include "quake_statics.h"
#include "quake_platform.h"
