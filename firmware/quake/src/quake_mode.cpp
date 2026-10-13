// Quake mode controller: the Quake boot from the one-shot request to the
// engine loop. GPL-2.0 for the engine integration; this glue file is MIT.
#include "quake_build.h"
#if defined(ESPDISP_QUAKE_RUNTIME)

#include "quake_mode.h"

#include <Arduino.h>
#include <Preferences.h>
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/idf_additions.h>
#include <freertos/task.h>

#include "platform/quake_pak_vfs.h"
#include "platform/quake_input_model.h"
#include "platform/quake_platform.h"

// Settled by display_stream before Quake is entered.
extern int16_t PANEL_W;
extern int16_t PANEL_H;

extern "C" const char* quake_display_setup(int want_width, int want_height);

int quake_render_width = QUAKE_RENDER_WIDTH;
int quake_render_height = QUAKE_RENDER_HEIGHT;
extern "C" bool quake_input_setup(void);
extern "C" void quake_audio_setup(void);

namespace {

// Bindings the touch path and the USB wheel rely on (quake_input_model.h),
// run after quake.rc has loaded default.cfg. Free look on, so dragging the
// right half or moving a mouse aims rather than walks.
const char QUAKE_STARTUP_COMMANDS[] =
    "bind w +forward\n"
    "bind s +back\n"
    "bind a +moveleft\n"
    "bind d +moveright\n"
    "bind ] \"impulse 10\"\n"
    "bind [ \"impulse 12\"\n"
    // Mix 200 ms ahead: an S3 frame can take 120 ms, and anything less than
    // a frame ahead leaves gaps of silence.
    "_snd_mixahead 0.2\n"
    "+mlook\n";

void logStage(const char* stage) {
  quake_log("stage %s: %s stack min free %u bytes, internal free %u, "
            "psram free %u largest %u",
            stage, pcTaskGetName(nullptr),
            (unsigned)uxTaskGetStackHighWaterMark(nullptr),
            (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
            (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM),
            (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM));
}

void quakeTask(void*) {
  logStage("task");
  // -basedir is the read-only partition file system; -mem is set by the heap
  // size passed below.
  static char arg0[] = "quake";
  static char* argv[] = {arg0, nullptr};
  const char* failure = quake_engine_start(1, argv, QUAKE_HUNK_BYTES,
                                           QUAKE_HUNK_SLACK_BYTES);
  if (failure != nullptr) quake_fail_restart(failure, true);
  quake_engine_command(QUAKE_STARTUP_COMMANDS);
  logStage("engine");

  bool first = true;
  while (true) {
    quake_input_service();
    quake_engine_frame();
    if (first && quake_engine_frames_rendered() > 0) {
      first = false;
      logStage("first frame");
    }
    // Lets the idle task run: one tick a pass. Quake itself skips host frames
    // sooner than 1/72 s, so most passes at speed draw nothing anyway.
    vTaskDelay(1);
  }
}

}  // namespace

void quake_enter(void) {
  logStage("enter");
  const char* problem = quake_pak_mount();
  if (problem != nullptr) {
    char reason[128];  // quake_fail_restart never returns
    snprintf(reason, sizeof(reason), "Quake data unusable: %s", problem);
    quake_fail_restart(reason, true);
  }
  quake_log("pak0.pak: %u bytes on the quake_pak partition",
            (unsigned)quake_pak_bytes());

  {
    // A size chosen in Video Options, if it is one this panel offers.
    Preferences prefs;
    if (prefs.begin("espdisp", true)) {
      if (prefs.isKey(QUAKE_RENDER_WIDTH_KEY) &&
          prefs.isKey(QUAKE_RENDER_HEIGHT_KEY)) {
        const int w = prefs.getShort(QUAKE_RENDER_WIDTH_KEY, 0);
        const int h = prefs.getShort(QUAKE_RENDER_HEIGHT_KEY, 0);
        if (quakeinput::renderChoiceIndex(PANEL_W, PANEL_H, w, h) >= 0) {
          quake_render_width = w;
          quake_render_height = h;
        }
      }
      prefs.end();
    }
  }
  const char* displayProblem =
      quake_display_setup(quake_render_width, quake_render_height);
  if (displayProblem != nullptr) {
    // The panel may be what failed, so the reason goes to Serial only.
    quake_fail_restart(displayProblem, false);
  }
  if (!quake_input_setup()) {
    quake_fail_restart("no PSRAM for Quake's input state", true);
  }
  quake_audio_setup();
  quake_log("Controls: left half drag moves, right half drag aims, tap fires,");
  quake_log("  double tap jumps, swipe up/down changes weapon, 2nd finger runs;");
  quake_log("  BOOT short = Escape, 0.6-3 s = Enter, 3 s hold = exit;");
  quake_log("  USB keyboard and mouse as in Quake (WASD added);");
  quake_log("  serial lines go to the Quake console (try: timedemo demo1).");

  // The engine runs on its own task so its stack can live in PSRAM; this
  // task (loopTask) only waits. Same core as loopTask, which now sleeps.
  TaskHandle_t task = nullptr;
  if (xTaskCreatePinnedToCoreWithCaps(
          quakeTask, "quake", QUAKE_TASK_STACK_BYTES, nullptr, 1, &task,
          xPortGetCoreID(), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT) != pdPASS) {
    quake_fail_restart("no PSRAM for the Quake task stack", true);
  }
  // The Quake task ends every session itself, by restarting.
  while (true) vTaskDelay(portMAX_DELAY);
}

#endif  // ESPDISP_QUAKE_RUNTIME
