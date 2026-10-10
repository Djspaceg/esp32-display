// Whether this image carries the Quake runtime.
//
// The P4 and S3 images carry it; which boards then run it is quake_mode.h's
// quakeSupportsBoard() and, on the S3, whether the chip holds the pak
// (quake_pak_vfs.c). It borrows Doom's USB keyboard and mouse glue, so it
// rides on the Doom runtime. Every condition is a compile flag (the Doom
// runtime, the P4 family selector, the core's S3 board define), which is what
// lets Arduino's library discovery see the same answer as the compile. A
// rescue image drops the Doom runtime and so drops Quake with it.
#pragma once

#if defined(ESPDISP_DOOM_RUNTIME) && \
    (defined(ESPDISP_BOARD_P4_4B) || defined(ARDUINO_ESP32S3_DEV)) && \
    !defined(ESPDISP_QUAKE_RUNTIME)
#define ESPDISP_QUAKE_RUNTIME 1
#endif
