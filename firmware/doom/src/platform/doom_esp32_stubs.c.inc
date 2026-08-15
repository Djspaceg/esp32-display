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

void I_Error(char *error, ...) {
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

// --- Sound/Music module definitions ---
// doomgeneric expects DG_sound_module and DG_music_module to be defined.
// These are no-op implementations since there's no audio hardware.

#include "i_sound.h"

static boolean DG_InitSound(boolean use_sfx_prefix) { (void)use_sfx_prefix; return true; }
static void DG_ShutdownSound(void) {}
static int DG_GetSfxLumpNum(sfxinfo_t* sfx) { (void)sfx; return 0; }
static void DG_UpdateSound(void) {}
static void DG_UpdateSoundParams(int channel, int vol, int sep) {
    (void)channel; (void)vol; (void)sep;
}
static int DG_StartSound(sfxinfo_t* sfx, int channel, int vol, int sep) {
    (void)sfx; (void)channel; (void)vol; (void)sep;
    return channel;
}
static void DG_StopSound(int channel) { (void)channel; }
static boolean DG_SoundIsPlaying(int channel) { (void)channel; return false; }
static void DG_CacheSounds(sfxinfo_t* sounds, int num_sounds) {
    (void)sounds; (void)num_sounds;
}

static snddevice_t sound_esp32_devices[] = { SNDDEVICE_SB };

sound_module_t DG_sound_module = {
    sound_esp32_devices,
    1,  // num_sound_devices
    DG_InitSound,
    DG_ShutdownSound,
    DG_GetSfxLumpNum,
    DG_UpdateSound,
    DG_UpdateSoundParams,
    DG_StartSound,
    DG_StopSound,
    DG_SoundIsPlaying,
    DG_CacheSounds,
};

// Music module
static boolean DG_InitMusic(void) { return true; }
static void DG_ShutdownMusic(void) {}
static void DG_SetMusicVolume(int volume) { (void)volume; }
static void DG_PauseMusic(void) {}
static void DG_ResumeMusic(void) {}
static void* DG_RegisterSong(void* data, int len) { (void)data; (void)len; return NULL; }
static void DG_UnRegisterSong(void* handle) { (void)handle; }
static void DG_PlaySong(void* handle, boolean looping) { (void)handle; (void)looping; }
static void DG_StopSong(void) {}
static boolean DG_MusicIsPlaying(void) { return false; }

static snddevice_t music_esp32_devices[] = { SNDDEVICE_SB };

music_module_t DG_music_module = {
    music_esp32_devices,
    1,  // num_sound_devices
    DG_InitMusic,
    DG_ShutdownMusic,
    DG_SetMusicVolume,
    DG_PauseMusic,
    DG_ResumeMusic,
    DG_RegisterSong,
    DG_UnRegisterSong,
    DG_PlaySong,
    DG_StopSong,
    DG_MusicIsPlaying,
};

// --- Timer stubs ---
// DG_GetTicksMs and DG_SleepMs are in doomgeneric_esp32s3.c, but the engine
// also calls I_Sleep from i_timer.c
void I_Sleep(int ms) {
    extern void DG_SleepMs(uint32_t);
    DG_SleepMs((uint32_t)ms);
}

// --- Video ---
// Video is handled by i_video.c (from doomgeneric) which calls DG_DrawFrame.
// We do NOT stub video functions here -- i_video.c provides them.
// DG_DrawFrame and DG_SetWindowTitle are in platform/doomgeneric_esp32s3.c.

// --- Network stubs ---
void I_InitNetwork(void) {}
int I_NetCmd(void) { return 0; }

// --- exit() override ---
// On ESP32, exit() would call abort() and trigger the task watchdog.
// Instead, signal the Doom game loop to stop cleanly, then spin.
// The game loop checks doom_exit_requested and returns to doom_enter(),
// which returns to handleButton(), which calls esp_restart().
void doom_exit_override(int status) {
    (void)status;
    extern void doom_request_exit(void);
    doom_request_exit();
    while (1) { vTaskDelay(pdMS_TO_TICKS(100)); }
}

// Redirect exit() to our override via a macro in doom_config.h
// (see: #define exit(x) doom_exit_override(x))
