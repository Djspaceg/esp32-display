// Doom Easter Egg mode controller
//
// Mode lifecycle management.
// GPL-2.0 for the doomgeneric integration; this glue file is MIT.
#include "doom_mode.h"

#include <Arduino.h>
#include <stdio.h>
#include <string.h>
#include <esp_log.h>
#include <esp_partition.h>
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include "platform/doom_audio_bridge.h"
#include "platform/doom_log.h"
#include "platform/doom_splash.h"
#include "save_store.h"

// From the doomgeneric platform and the C engine unity build.
extern "C" void push_key(unsigned char key, int pressed);

// doomkeys.h contains only key-code macros, so no C declarations cross into
// this C++ translation unit.
#include "doomkeys.h"

// From doom_hw_bridge.cpp
extern "C" void doom_display_init(void);
extern "C" void doom_display_blit(const uint16_t* buf, int w, int h);
extern "C" int doom_display_width(void);
extern "C" int doom_display_height(void);
extern "C" bool doom_motion_available(void);
extern "C" int doom_boot_pin(void);

// doomgeneric entry points (C linkage)
extern "C" {
    void doomgeneric_Create(int argc, char** argv);
    void doomgeneric_Tick(void);
    void doom_serial_command(char* line);
    void doom_save_config(void);
    bool doom_prepare_static_buffers(void);
    bool doom_wad_available(void);
}

static const char* TAG = "doom_mode";

// Entry is the boot-mode menu's (display_stream/boot_menu.cpp), which sets
// the one-shot request this boot consumed.
static volatile bool doom_active = false;
static volatile bool doom_exit_requested = false;

bool doom_is_active(void) {
    return doom_active;
}

void doom_request_exit(void) {
    if (doom_active) {
        ESP_LOGI(TAG, "Doom exit requested (BOOT long-press)");
        doom_exit_requested = true;
    }
}

// Check if exit was requested (called from the game loop)
static bool should_exit(void) {
    return doom_exit_requested;
}

void doom_enter(void) {
    doom_log_stage("enter");
    if (!doom_prepare_static_buffers()) {
        doom_fail_restart("Doom renderer PSRAM allocation failed", true);
    }
    if (!doom_wad_available()) {
        static char reason[96];
        snprintf(reason, sizeof(reason), "Doom WAD unusable: %s",
                 doom_wad_failure());
        doom_fail_restart(reason, true);
    }
    doom_log_stage("wad");
    {
        // Settings and saves (default.cfg, the save slots); without the
        // store Doom runs as before, keeping nothing.
        const char* problem = save_store_open();
        if (problem != nullptr) doom_log("saves off: %s", problem);
    }

    doom_log("=== DOOM EASTER EGG ACTIVATED ===");
    ESP_LOGI(TAG, "Panel rotation locked for Doom");
    ESP_LOGI(TAG, "Controls:");
    if (doom_motion_available()) {
        ESP_LOGI(TAG, "  Tilt device    = Move (forward/back/strafe)");
        ESP_LOGI(TAG, "  Touch drag     = Turn/aim");
    } else {
        ESP_LOGI(TAG, "  Left touch     = Move (forward/back/strafe)");
        ESP_LOGI(TAG, "  Right touch    = Turn/aim + combat");
    }
    ESP_LOGI(TAG, "  Tap            = Shoot");
    ESP_LOGI(TAG, "  Double-tap     = Use/Open");
    ESP_LOGI(TAG, "  Swipe up       = Next weapon");
    ESP_LOGI(TAG, "  Swipe down     = Use/Open");
    ESP_LOGI(TAG, "  2nd finger     = Run");
    ESP_LOGI(TAG, "  Menu tap/swipe = Select/navigate");
    ESP_LOGI(TAG, "  BOOT short     = Escape (open/close menu)");
    ESP_LOGI(TAG, "  BOOT 0.6-<3s   = Previous menu");
    ESP_LOGI(TAG, "  BOOT 3s hold   = Exit Doom");
    ESP_LOGI(TAG, "  USB keyboard   = WASD/arrows move, Ctrl fire, Space use,");
    ESP_LOGI(TAG, "                   Shift run, Alt strafe, 1-7 weapons,");
    ESP_LOGI(TAG, "                   Esc/Enter/Backspace menu, Tab map");
    ESP_LOGI(TAG, "  USB mouse      = move to turn and walk, buttons fire/use,");
    ESP_LOGI(TAG, "                   wheel changes weapon");

    doom_active = true;
    doom_exit_requested = false;

    // Show splash screen while engine initializes
    {
        doom_display_init();

        const int panel_width = doom_display_width();
        const int panel_height = doom_display_height();
        uint16_t* splash = (uint16_t*)heap_caps_calloc(
            (size_t)panel_width * (size_t)panel_height, sizeof(uint16_t),
            MALLOC_CAP_SPIRAM);
        if (splash) {
            doom_splash::render(splash, panel_width, panel_height);
            doom_display_blit(splash, panel_width, panel_height);
            heap_caps_free(splash);
        }
        doom_log_stage("splash");
    }

    // Initialize doomgeneric
    // -mb 4 = 4MB memory zone (from PSRAM via malloc). PSRAM budget:
    //   4MB zone + 256KB render buf + 434KB scaled buf = ~4.7MB of 8MB
    // Remaining ~3.3MB is free for texture cache etc.
    // A stored WAD is not mapped, so its lumps live in the zone too; where the
    // PSRAM has room (a P4's 32 MB) the zone doubles for them. The name is how
    // the engine tells Doom from Doom II (d_iwad.c.inc), so it is the file's.
    char zone_mb[] = "4";
    if (!doom_wad_is_mapped() &&
        heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM) >= 12u << 20) {
        zone_mb[0] = '8';
    }
    static char iwad[GAME_STORE_NAME_BYTES + 1];
    strncpy(iwad, doom_selected_wad_name(), GAME_STORE_NAME_BYTES);
    iwad[GAME_STORE_NAME_BYTES] = '\0';
    char* argv[] = {"doom", "-mb", zone_mb, "-iwad", iwad, NULL};
    int argc = 5;
    doom_log("Doom WAD %s, %s MB zone", iwad, zone_mb);

    doomgeneric_Create(argc, argv);

    // Game loop -- runs until exit requested
    bool first_tick = true;
    uint32_t config_saved_at = millis();
    while (!should_exit()) {
        doomgeneric_Tick();
        if (first_tick) {
            first_tick = false;
            doom_log_stage("first tick");
        }

        // A changed setting reaches flash within 10 s, as Doom itself only
        // writes default.cfg when it quits; an unchanged one is not written.
        if (millis() - config_saved_at >= 10000) {
            config_saved_at = millis();
            doom_save_config();
        }

        // Serial lines are commands (platform/doom_serial_commands.c.inc).
        {
            static char line[96];
            static size_t used = 0;
            while (Serial.available() > 0) {
                const int c = Serial.read();
                if (c == '\n' || c == '\r') {
                    if (used > 0) {
                        line[used] = '\0';
                        used = 0;
                        doom_serial_command(line);
                    }
                } else if (used + 1 < sizeof(line)) {
                    line[used++] = (char)c;
                }
            }
        }

        // Poll BOOT during Doom. Every short release is a normal Escape press:
        // the first opens the root menu and the next closes it. Touch tap owns
        // menu selection, while the longer Back and Exit tiers remain separate.
        {
            static bool btn_was_down = false;
            static uint32_t btn_down_at = 0;
            static bool btn_long_fired = false;

            const int boot_pin = doom_boot_pin();
            bool btn_down =
                boot_pin >= 0 && digitalRead(boot_pin) == LOW;
            uint32_t now = millis();

            if (btn_down && !btn_was_down) {
                btn_was_down = true;
                btn_long_fired = false;
                btn_down_at = now;
            } else if (btn_down && btn_was_down && !btn_long_fired &&
                       (now - btn_down_at) >= 3000) {
                btn_long_fired = true;
                doom_log("BOOT long-press (3s) -- exiting Doom");
                doom_request_exit();
            } else if (!btn_down && btn_was_down) {
                btn_was_down = false;
                uint32_t held_ms = now - btn_down_at;
                if (!btn_long_fired && held_ms >= 3000) {
                    doom_log("BOOT released at 3s -- exiting Doom");
                    doom_request_exit();
                } else if (!btn_long_fired && held_ms >= 30 && held_ms < 600) {
                    push_key(KEY_ESCAPE, 1);
                    push_key(KEY_ESCAPE, 0);
                } else if (!btn_long_fired && held_ms >= 600) {
                    push_key(KEY_BACKSPACE, 1);
                    push_key(KEY_BACKSPACE, 0);
                }
            }
        }

        // Yield to allow other tasks (watchdog, WiFi stack)
        vTaskDelay(1);
    }

    // A restart is the ownership boundary for the engine zone, scaled buffer,
    // WAD mapping, and every upstream global. The caller restarts immediately;
    // partial in-process teardown would add use-after-free paths without ever
    // returning to normal operation. The amplifier goes off first so the
    // restart does not pop the speaker.
    doom_save_config();
    doom_audio_end();
    doom_log("Doom stopped. Restarting to normal firmware...");
}
