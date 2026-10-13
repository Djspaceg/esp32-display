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
#include <esp_system.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

// Config/save path stubs live in m_misc.c.inc. Keeping their one definition in
// the upstream module avoids duplicate symbols in the ESP32 unity build.

// --- i_system.c overrides ---
// These are called by the engine for error handling and exit.

#include "doom_log.h"

void I_Error(char *error, ...) {
    static char buf[256];
    static const char prefix[] = "I_Error: ";
    memcpy(buf, prefix, sizeof(prefix));
    va_list args;
    va_start(args, error);
    vsnprintf(buf + sizeof(prefix) - 1, sizeof(buf) - (sizeof(prefix) - 1),
              error, args);
    va_end(args);
    // Fatal engine errors cannot unwind Doom's global state safely. The
    // one-shot boot flag was consumed before entry, so restart always returns
    // to the normal display firmware instead of looping back into Doom.
    doom_fail_restart(buf, true);
}

// --- Sound/Music module definitions ---
// doomgeneric expects DG_sound_module and DG_music_module to be defined.
// Sound effects play on the board's codec when it has one; music is not
// implemented, so the module i_sound.c selects is a no-op.

#include "i_sound.h"
#include "doom_sound_esp32.c.inc"

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

// --- Timer ---
// i_timer.c.inc owns I_Sleep and delegates timing to the DG_* platform calls.

// --- Video ---
// Video is handled by i_video.c (from doomgeneric) which calls DG_DrawFrame.
// We do NOT stub video functions here -- i_video.c provides them.
// DG_DrawFrame and DG_SetWindowTitle are in platform/doomgeneric_esp32.c.inc.

// --- Network stubs ---
void I_InitNetwork(void) {}
int I_NetCmd(void) { return 0; }

// --- exit() override ---
// The engine's exit paths share the same restart boundary as fatal errors.
void doom_exit_override(int status) {
    if (status != 0) {
        static char reason[32];
        snprintf(reason, sizeof(reason), "engine exit(%d)", status);
        doom_fail_restart(reason, true);
    }
    doom_log("Engine quit; restarting normal firmware");  // flushes
    doom_audio_end();
    esp_restart();
    while (1) { vTaskDelay(pdMS_TO_TICKS(100)); }
}

// Redirect exit() to our override via a macro in doom_config.h
// (see: #define exit(x) doom_exit_override(x))
