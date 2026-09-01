// Input bridge for ESP32.
// Convert queued doomgeneric platform keys into Doom engine events.
#include "doomtype.h"
#include "d_event.h"
#include "doomgeneric.h"

int vanilla_keyboard_mapping = 1;

void I_GetEvent(void) {
    int pressed;
    unsigned char key;

    DG_PollInput();
    while (DG_GetKey(&pressed, &key)) {
        event_t event = {0};
        event.type = pressed ? ev_keydown : ev_keyup;
        event.data1 = key;
        event.data2 = key;
        D_PostEvent(&event);
    }
}

void I_InitInput(void) {
    // No-op: IMU and touch are initialized in DG_Init()
}
