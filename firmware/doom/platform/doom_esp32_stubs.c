// ESP32 platform stubs for doomgeneric
//
// The upstream doomgeneric source assumes POSIX (unistd.h, sys/stat.h, etc).
// This file provides the minimal stubs needed to compile on ESP-IDF/Arduino.
//
// GPL-2.0 (part of the doomgeneric build)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <sys/stat.h>

// --- File I/O stubs ---
// doomgeneric's config and save systems call fopen/mkdir/etc.
// On ESP32 we have no filesystem beyond the WAD partition, so these are no-ops.

#if !defined(HAVE_MKDIR)
int M_MakeDirectory(const char* path) {
    (void)path;
    return 0;  // pretend success
}
#endif

// --- i_system.c overrides ---
// These are called by the engine for error handling and exit.

#include <esp_log.h>

void I_Error(const char* error, ...) {
    static char buf[256];
    va_list args;
    va_start(args, error);
    vsnprintf(buf, sizeof(buf), error, args);
    va_end(args);
    ESP_LOGE("DOOM", "I_Error: %s", buf);
    // Don't call exit() on embedded -- signal the game loop to stop
    extern void doom_request_exit(void);
    doom_request_exit();
    // Spin until the main loop picks it up
    while (1) { vTaskDelay(pdMS_TO_TICKS(100)); }
}

// --- Sound stubs ---
// No sound hardware on this board. All sound functions are no-ops.

#include "doomtype.h"

// Forward declarations from the engine's sound interface
typedef struct sfxinfo_struct sfxinfo_t;
typedef struct music_module_s music_module_t;

// i_sound.c expects these to be defined somewhere
static int I_SDL_InitSound(int use_sfx_prefix) { (void)use_sfx_prefix; return 1; }
static void I_SDL_ShutdownSound(void) {}
static int I_SDL_GetSfxLumpNum(sfxinfo_t* sfx) { (void)sfx; return 0; }
static void I_SDL_UpdateSound(void) {}
static void I_SDL_UpdateSoundParams(int channel, int vol, int sep) {
    (void)channel; (void)vol; (void)sep;
}
static int I_SDL_StartSound(sfxinfo_t* sfx, int channel, int vol, int sep, int pitch) {
    (void)sfx; (void)channel; (void)vol; (void)sep; (void)pitch;
    return channel;
}
static void I_SDL_StopSound(int channel) { (void)channel; }
static int I_SDL_SoundIsPlaying(int channel) { (void)channel; return 0; }
static void I_SDL_PrecacheSounds(sfxinfo_t* sounds, int num_sounds) {
    (void)sounds; (void)num_sounds;
}

// Music stubs
static int I_SDL_InitMusic(void) { return 1; }
static void I_SDL_ShutdownMusic(void) {}
static void I_SDL_SetMusicVolume(int volume) { (void)volume; }
static void I_SDL_PauseMusic(void) {}
static void I_SDL_ResumeMusic(void) {}
static void I_SDL_PlaySong(void* handle, int looping) { (void)handle; (void)looping; }
static void I_SDL_StopSong(void) {}
static int I_SDL_MusicIsPlaying(void) { return 0; }
static int I_SDL_RegisterSong(void* data, int len) { (void)data; (void)len; return 0; }
static void I_SDL_UnRegisterSong(void* handle) { (void)handle; }

// --- Timer stubs ---
// DG_GetTicksMs and DG_SleepMs are in doomgeneric_esp32s3.c, but the engine
// also calls I_Sleep from i_timer.c
void I_Sleep(int ms) {
    extern void DG_SleepMs(uint32_t);
    DG_SleepMs((uint32_t)ms);
}

// --- Video stubs ---
// DG_DrawFrame handles all display. These are called by the engine's video
// layer but we don't need them to do anything.
void I_InitGraphics(void) {}
void I_ShutdownGraphics(void) {}
void I_StartFrame(void) {}
void I_StartTic(void) {}
void I_UpdateNoBlit(void) {}
void I_FinishUpdate(void) {}
void I_ReadScreen(unsigned char* scr) { (void)scr; }
void I_SetPalette(unsigned char* palette) { (void)palette; }
int I_GetPaletteIndex(int r, int g, int b) {
    (void)r; (void)g; (void)b;
    return 0;
}
void I_SetWindowTitle(const char* title) { (void)title; }

// --- Network stubs ---
void I_InitNetwork(void) {}
int I_NetCmd(void) { return 0; }
