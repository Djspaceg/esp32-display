// Compiles the Doom engine's IWAD lookup alone, as C, the way the board
// builds it (ESP_PLATFORM), for test_doom_iwad.cpp.
#define ESP_PLATFORM 1
#include "../doom/src/d_iwad.c.inc"
