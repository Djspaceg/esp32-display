// Compile-time configuration for doomgeneric on ESP32-S3
//
// This header is force-included via the build system (-include doom_config.h)
// to override doomgeneric's defaults without modifying upstream source files.
#pragma once

// Mark this as an ESP platform build for all #ifdef guards
#ifndef ESP_PLATFORM
#define ESP_PLATFORM 1
#endif

// Render resolution (Doom's native is 320x200)
#define DOOMGENERIC_RESX 320
#define DOOMGENERIC_RESY 200

// Use 32-bit XRGB8888 pixel format (we convert to RGB565 in DG_DrawFrame)
// Do NOT define CMAP256 -- we want 32-bit for clean color conversion
#undef CMAP256

// Disable features that need POSIX or desktop infrastructure
#define NO_STDIO_REDIRECT 1

// Memory: use PSRAM for all large allocations
// The engine's Z_Malloc zone is configured via -mb command line arg (8MB)

// Disable savegames (no writable filesystem)
// The engine handles missing save gracefully -- it just won't offer Load Game

// Disable network multiplayer
#define NET_CLIENT_H  // prevent net_client.h from defining anything

// Disable sound (no audio hardware; stubs in doom_esp32_stubs.c)
// Note: FEATURE_SOUND is NOT defined, which disables the sound system.
// If we later add I2S audio, define it and implement the sound module.

// Override exit() to signal game loop exit instead of calling abort()
extern void doom_exit_override(int status);
#define exit(x) doom_exit_override(x)
