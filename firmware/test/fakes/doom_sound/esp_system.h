// C-compatible stand-in for the one esp_system.h call the Doom stubs make.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif
void esp_restart(void) __attribute__((noreturn));
#ifdef __cplusplus
}
#endif
