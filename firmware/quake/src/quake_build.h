// Whether this image carries the Quake runtime.
//
// Quake runs on the P4 carriers only: it needs their 32 MB of PSRAM and the
// quake_pak partition, and it borrows Doom's USB keyboard and mouse glue, so it
// rides on the Doom runtime. Both conditions are compile flags (the P4 family
// selector and the Doom runtime), which is what lets Arduino's library
// discovery see the same answer as the compile. A rescue image drops the Doom
// runtime and so drops Quake with it.
#pragma once

#if defined(ESPDISP_DOOM_RUNTIME) && defined(ESPDISP_BOARD_P4_4B) && \
    !defined(ESPDISP_QUAKE_RUNTIME)
#define ESPDISP_QUAKE_RUNTIME 1
#endif
