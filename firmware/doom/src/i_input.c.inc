// Input bridge for ESP32.
// Convert queued DoomGeneric keys and proportional touch mouse movement into
// Doom engine events.
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

    int mouse_dx;
    int mouse_dy;
    if (DG_GetMouse(&mouse_dx, &mouse_dy)) {
        event_t event = {0};
        event.type = ev_mouse;
        event.data1 = 0;  // no synthetic mouse buttons
        event.data2 = mouse_dx;
        event.data3 = mouse_dy;
        D_PostEvent(&event);
    }
}

void I_InitInput(void) {
    // No-op: IMU and touch are initialized in DG_Init()
}
