// Input stubs for ESP32.
// doomgeneric handles input via DG_GetKey(); SDL event polling is not used.
#include "doomtype.h"
#include "d_event.h"

int vanilla_keyboard_mapping = 1;

void I_GetEvent(void) {
    // No-op: doomgeneric's i_video.c calls DG_GetKey() instead
}

void I_InitInput(void) {
    // No-op: IMU and touch are initialized in DG_Init()
}
