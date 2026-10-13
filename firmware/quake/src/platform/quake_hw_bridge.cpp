// Hardware side of Quake on the P4 and S3: the panel, touch, BOOT, the USB keyboard
// and mouse, and the serial console. What each input MEANS is decided in
// quake_input_model.h, which is host tested; this file only samples hardware
// and moves bytes.
//
// Everything here runs on the Quake task (quake_mode.cpp), the one task that
// drives the engine, so none of it needs locking.
#include "../quake_build.h"
#if defined(ESPDISP_QUAKE_RUNTIME)

#include <Arduino.h>
#include <esp_heap_caps.h>
#include <esp_timer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <freertos/task.h>
#include <Preferences.h>
#include <stdarg.h>
#include <string.h>

#include <new>

#include <board_config.h>
#include <board_touch.h>
#include <touch_gesture.h>
#include <touch_map.h>

#include "quake_input_model.h"
#include "quake_platform.h"
#include "../quake_mode.h"  // the render size's NVS keys

// Doom's USB host glue (firmware/doom/src/platform/doom_usb_input.h). Polled in
// its menu context it hands every key over as Doom key codes through Doom's
// key queue, which nothing else drains while Quake runs.
#include <platform/doom_usb_input.h>
// Doom's sound bridge (display_stream/doom_audio.cpp): the codec and a paced
// output task on core 0, which Quake's sound device (quake_snd_esp32.c) feeds.
#include <platform/doom_audio_bridge.h>
extern "C" int DG_GetKey(int* pressed, unsigned char* key);
// The keys Doom's wheel handling sends. Doom sets them when its own engine
// starts, which a Quake boot never does.
extern "C" int key_nextweapon;
extern "C" int key_prevweapon;

// Settled by display_stream before Quake is entered.
extern const board::Config* bcfg;
extern int16_t PANEL_W;
extern int16_t PANEL_H;

#if defined(CONFIG_IDF_TARGET_ESP32S3)
// display_stream/quake_bridge.cpp: the 1x frame straight into DMA staging.
extern "C" bool quake_display_present_1x(int x0, int y0, int width, int height,
                                         const uint8_t* pixels,
                                         const uint16_t* palette565,
                                         bool sample_input);
#endif

// display_stream/quake_bridge.cpp: queue a panel region and wait for its DMA.
extern "C" bool quake_display_blit_blocking(int x0, int y0, int x1, int y1,
                                            const uint16_t* pixels);

void presentTask(void*);  // below, the S3's core-0 panel task
extern "C" void quake_input_sample_while_waiting(void);  // below

namespace {

// Larger state lives in PSRAM, allocated by quake_input_setup(): anything
// static here is internal RAM the streaming firmware pays for on every boot.
struct QuakeIo {
  quakeinput::KeyQueue keys;
  char consoleLine[128];
  size_t consoleLength;
};
QuakeIo* s_io = nullptr;

// ---- Frame -----------------------------------------------------------------

quakeinput::FrameLayout s_layout = {};
// One band of the scaled frame: QUAKE_BAND_ROWS engine rows, scaled. The frame
// goes to the panel a band at a time, so a 466x466 frame needs 30 KB here
// rather than a 434 KB copy of the whole panel.
constexpr int QUAKE_BAND_ROWS = 32;
uint16_t* s_frame = nullptr;

// Frame-rate line: every FPS_WINDOW_US, frames drawn and where the time went.
constexpr int64_t FPS_WINDOW_US = 5000000;
int64_t s_window_started = 0;
uint32_t s_window_frames = 0;
int64_t s_window_present_us = 0;
int64_t s_window_wait_us = 0;

// On the S3's 1x panel the frame goes to the panel from a task on core 0
// (which a Quake boot leaves to the sound output) while the engine draws the
// next into its other page. Measured at 466x466 (serial_s3_diagE.log): the
// write is 30.6 ms of a 115-140 ms frame, on top of the render. The P4 keeps
// its one page and blocking write.
#if defined(CONFIG_IDF_TARGET_ESP32S3)
constexpr bool OVERLAP_1X = true;
#else
constexpr bool OVERLAP_1X = false;
#endif
constexpr uint32_t PRESENT_TASK_STACK = 4096;
constexpr UBaseType_t PRESENT_TASK_PRIORITY = 5;  // below the sound output's 10
constexpr BaseType_t PRESENT_TASK_CORE = 0;
bool s_overlap = false;  // set once the panel task is running
TaskHandle_t s_present_task = nullptr;
SemaphoreHandle_t s_present_go = nullptr;
SemaphoreHandle_t s_present_done = nullptr;
const uint8_t* s_present_pixels = nullptr;
// The palette as it was when the frame was handed over: the engine may change
// its own (a flash of damage) while the frame is still going out.
uint16_t* s_present_palette = nullptr;
volatile int64_t s_present_last_us = 0;
// r_dspeeds' stage times summed over the window (quake_profile_frame), when
// the cvar is on: render, world, brush models, edge scan and spans, alias
// models, view model, particles; and the cache-surface builds inside the scan.
float s_profile_ms[7] = {};
uint32_t s_profile_frames = 0;
double s_profile_surface_s = 0;

// ---- Input -----------------------------------------------------------------

quakeinput::TouchControls s_touch;
quakeinput::BootButton s_boot;
touchgesture::Tracker s_tracker;
touchmap::Calibration s_calibration = touchmap::GT911_ON_ST7703_4B;
bool s_touch_ready = false;
quakeinput::TouchSnapshot s_snapshot = {};
uint32_t s_last_tap_ms = 0;
int s_mouse_x = 0;
int s_mouse_y = 0;
bool s_usb_started = false;

constexpr uint32_t DOUBLE_TAP_MS = 400;

void push(const quakeinput::KeyEvent* events, size_t count) {
  for (size_t i = 0; i < count; ++i) s_io->keys.push(events[i].key, events[i].down);
}

quakeinput::Swipe swipeFor(touchgesture::Gesture gesture) {
  switch (gesture) {
    case touchgesture::Gesture::SwipeLeft: return quakeinput::Swipe::Left;
    case touchgesture::Gesture::SwipeRight: return quakeinput::Swipe::Right;
    case touchgesture::Gesture::SwipeUp: return quakeinput::Swipe::Up;
    case touchgesture::Gesture::SwipeDown: return quakeinput::Swipe::Down;
    default: return quakeinput::Swipe::None;
  }
}

// Folds at most one controller report into the pending snapshot; the edges
// (press start, tap, swipe) stay set until serviceTouch() consumes them.
void sampleTouch() {
  if (!s_touch_ready) return;
  boardtouch::Sample sample = {};
  if (!boardtouch::poll(sample)) return;
  const uint32_t now = millis();
  // Quake runs at the panel's native orientation, like Doom.
  const touchmap::Point p = touchmap::map((int16_t)sample.rawX,
                                          (int16_t)sample.rawY, false, 0,
                                          s_calibration);
  const touchgesture::Event ev =
      s_tracker.onReport(sample.pressed, p.x, p.y, now);
  if (sample.pressed) {
    if (ev.pressStarted) {
      s_snapshot.pressStarted = true;
      s_snapshot.startX = ev.startX;
      s_snapshot.startY = ev.startY;
    }
    s_snapshot.x = p.x;
    s_snapshot.y = p.y;
    s_snapshot.pressed = true;
    s_snapshot.secondPressed = sample.points >= 2;
  } else {
    s_snapshot.pressed = false;
    s_snapshot.secondPressed = false;
  }
  if (ev.gesture == touchgesture::Gesture::Tap) {
    if (s_last_tap_ms != 0 && now - s_last_tap_ms < DOUBLE_TAP_MS) {
      s_snapshot.doubleTap = true;
      s_last_tap_ms = 0;
    } else {
      s_snapshot.tap = true;
      s_last_tap_ms = now;
    }
  } else if (ev.gesture != touchgesture::Gesture::None) {
    s_snapshot.swipe = swipeFor(ev.gesture);
  }
}

void serviceTouch(bool inMenu) {
  sampleTouch();
  quakeinput::KeyEvent events[quakeinput::TouchControls::MAX_EVENTS];
  push(events, s_touch.apply(s_snapshot, inMenu, PANEL_W, events, &s_mouse_x,
                             &s_mouse_y));
  s_snapshot.pressStarted = false;
  s_snapshot.tap = false;
  s_snapshot.doubleTap = false;
  s_snapshot.swipe = quakeinput::Swipe::None;
}

void serviceBoot() {
  const int pin = bcfg != nullptr ? bcfg->pinBootButton : board::NO_PIN;
  if (pin < 0) return;
  switch (s_boot.update(digitalRead(pin) == LOW, millis())) {
    case quakeinput::BootAction::Escape:
      s_io->keys.push(K_ESCAPE, true);
      s_io->keys.push(K_ESCAPE, false);
      break;
    case quakeinput::BootAction::Enter:
      s_io->keys.push(K_ENTER, true);
      s_io->keys.push(K_ENTER, false);
      break;
    case quakeinput::BootAction::Exit:
      quake_log("BOOT held 3 s -- leaving Quake");
      quake_quit();
    case quakeinput::BootAction::None:
      break;
  }
}

void serviceUsb() {
  if (!s_usb_started) return;
  // Menu context: letters arrive as themselves, and Quake's own bindings
  // decide what they do.
  doom_usb_input_poll(1);
  int pressed = 0;
  unsigned char key = 0;
  while (DG_GetKey(&pressed, &key)) {
    const int quakeKey = quakeinput::quakeKeyForDoomKey(key);
    if (quakeKey != 0) s_io->keys.push(quakeKey, pressed != 0);
  }
  int dx = 0, dy = 0;
  if (doom_usb_input_take_mouse(&dx, &dy)) {
    s_mouse_x += dx;
    s_mouse_y += quakeinput::quakeMouseY(dy);
  }
}

}  // namespace

// ---- Setup, from quake_mode.cpp ------------------------------------------

// NULL when the panel is ready for frames, else why not.
// The size asked for this boot, for Video Options.
int s_want_width = 0;
int s_want_height = 0;

extern "C" const char* quake_display_setup(int want_width, int want_height) {
  s_want_width = want_width;
  s_want_height = want_height;
  s_layout =
      quakeinput::frameLayout(PANEL_W, PANEL_H, want_width, want_height);
  if (s_layout.scale == 0) return "panel too small for a 320x240 frame";
  // The band buffer, for scaled frames only: the S3's 1x frame converts
  // straight into DMA staging.
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  const bool needBand = s_layout.scale != 1;
#else
  const bool needBand = true;
#endif
  if (needBand) {
    s_frame = (uint16_t*)heap_caps_malloc(
        (size_t)s_layout.width * QUAKE_BAND_ROWS * s_layout.scale *
            sizeof(uint16_t),
        MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (s_frame == nullptr) return "no PSRAM for the Quake frame";
  }
  // Black the whole panel once; each frame then writes only its own region.
  const size_t panelBytes = (size_t)PANEL_W * PANEL_H * sizeof(uint16_t);
  uint16_t* black =
      (uint16_t*)heap_caps_calloc(1, panelBytes, MALLOC_CAP_SPIRAM);
  if (black == nullptr) return "no PSRAM to clear the panel";
  const bool ok =
      quake_display_blit_blocking(0, 0, PANEL_W, PANEL_H, black);
  if (!ok) return "panel DMA did not complete";  // still DMA's: leak it
  heap_caps_free(black);
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  if (OVERLAP_1X && s_layout.scale == 1) {
    s_present_palette = (uint16_t*)heap_caps_malloc(
        256 * sizeof(uint16_t), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    s_present_go = xSemaphoreCreateBinary();
    s_present_done = xSemaphoreCreateBinary();
    // xTaskCreate puts the stack in internal RAM.
    if (s_present_palette == nullptr || s_present_go == nullptr ||
        s_present_done == nullptr ||
        xTaskCreatePinnedToCore(presentTask, "quake_present",
                                PRESENT_TASK_STACK, nullptr,
                                PRESENT_TASK_PRIORITY, &s_present_task,
                                PRESENT_TASK_CORE) != pdPASS) {
      return "no internal RAM for the panel task";
    }
    xSemaphoreGive(s_present_done);  // nothing in flight yet
    s_overlap = true;
  }
#endif
  quake_log("frame %dx%d rendered, %dx%d at %dx scale, at (%d,%d) on the "
            "%dx%d panel",
            s_layout.renderWidth, s_layout.renderHeight, s_layout.width,
            s_layout.height, s_layout.scale, s_layout.x, s_layout.y, PANEL_W,
            PANEL_H);
  return nullptr;
}

extern "C" int quake_display_pages(void) {
  return OVERLAP_1X && s_layout.scale == 1 ? 2 : 1;
}

// For the failure card (display_stream/quake_bridge.cpp): waits up to a
// second for the panel task's frame and keeps it from starting another, so
// the card's writes are the panel's only ones. A no-op on the panel task.
extern "C" void quake_display_quiesce(void) {
  if (!s_overlap || xTaskGetCurrentTaskHandle() == s_present_task) return;
  (void)xSemaphoreTake(s_present_done, pdMS_TO_TICKS(1000));
}

extern "C" int quake_display_render_choices(const char** labels, int max,
                                            int* current) {
  quakeinput::RenderChoice choices[quakeinput::MAX_RENDER_CHOICES];
  const int n = quakeinput::renderChoices(PANEL_W, PANEL_H, choices);
  for (int i = 0; i < n && i < max; ++i) labels[i] = choices[i].label;
  *current =
      quakeinput::renderChoiceIndex(PANEL_W, PANEL_H, s_want_width, s_want_height);
  return n < max ? n : max;
}

extern "C" void quake_display_choose_render(int index) {
  quakeinput::RenderChoice choices[quakeinput::MAX_RENDER_CHOICES];
  const int n = quakeinput::renderChoices(PANEL_W, PANEL_H, choices);
  if (index < 0 || index >= n) return;
  // The same NVS namespace and one-shot flag the boot menu uses
  // (display_stream/boot_menu.cpp), so the restart comes straight back to
  // Quake at the new size.
  Preferences prefs;
  if (!prefs.begin("espdisp", false)) return;
  const bool saved =
      prefs.putShort(QUAKE_RENDER_WIDTH_KEY, (int16_t)choices[index].width) &&
      prefs.putShort(QUAKE_RENDER_HEIGHT_KEY, (int16_t)choices[index].height) &&
      prefs.putBool("quakeonce", true);
  prefs.end();
  if (!saved) {
    quake_log("render size %s could not be saved", choices[index].label);
    return;
  }
  quake_log("render size %s chosen; restarting Quake", choices[index].label);
  doom_audio_end();
  delay(20);
  ESP.restart();
}

extern "C" void quake_display_render_size(int* width, int* height) {
  *width = s_layout.renderWidth;
  *height = s_layout.renderHeight;
}

// Before the Quake task starts, on loopTask, as doom_audio_begin() asks: it
// brings up the codec over I2C, which touch shares.
extern "C" void quake_audio_setup(void) {
  const uint32_t rate = doom_audio_begin(quake_audio_render);
  quake_audio_set_rate(rate);
  if (rate == 0) quake_log("sound unavailable; playing silent");
}

extern "C" bool quake_input_setup(void) {
  void* io = heap_caps_calloc(1, sizeof(QuakeIo), MALLOC_CAP_SPIRAM);
  if (io == nullptr) return false;
  s_io = new (io) QuakeIo();
  s_calibration = bcfg->variant == board::Variant::P4_4C
                      ? touchmap::GT911_ON_JD9365_4C
                  : bcfg->variant == board::Variant::P4_34C
                      ? touchmap::GT911_ON_JD9365_34C
                  : bcfg->variant == board::Variant::AmoledCo5300
                      ? touchmap::CST9217_ON_CO5300
                  : bcfg->variant == board::Variant::LcdSt77916
                      ? touchmap::CST816_ON_ST77916
                      : touchmap::GT911_ON_ST7703_4B;
  s_touch_ready = boardtouch::init(*bcfg);
  s_tracker.reset();
  quake_log(s_touch_ready ? "touch ready" : "touch unavailable; BOOT and USB only");
  key_nextweapon = quakeinput::WHEEL_NEXT_KEY;
  key_prevweapon = quakeinput::WHEEL_PREV_KEY;
  doom_usb_input_init();
  s_usb_started = true;
  return true;
}

// ---- quake_platform.h ------------------------------------------------------

extern "C" void quake_log(const char* format, ...) {
  char line[256];
  va_list args;
  va_start(args, format);
  vsnprintf(line, sizeof(line), format, args);
  va_end(args);
  Serial.print("[quake] ");
  Serial.println(line);
  Serial.flush();
}

extern "C" void quake_console_write(const char* text) { Serial.print(text); }

extern "C" const char* quake_console_read_line(void) {
  if (s_io == nullptr) return nullptr;
  while (Serial.available() > 0) {
    const int c = Serial.read();
    if (c < 0) break;
    if (c == '\r' || c == '\n') {
      if (s_io->consoleLength == 0) continue;
      // With its newline: Cbuf_AddText appends what it is given as is, so a
      // line without one would run into the next command queued.
      s_io->consoleLine[s_io->consoleLength++] = '\n';
      s_io->consoleLine[s_io->consoleLength] = '\0';
      s_io->consoleLength = 0;
      return s_io->consoleLine;
    }
    // Only printable text: a byte of line noise ahead of a command (seen on
    // the 4B's bridge right after a reset) would otherwise make it unknown.
    if (c < 0x20 || c > 0x7E) continue;
    // Room for this byte, the newline and the terminator.
    if (s_io->consoleLength + 2 < sizeof(s_io->consoleLine)) {
      s_io->consoleLine[s_io->consoleLength++] = (char)c;
    }
  }
  return nullptr;
}

extern "C" void quake_display_present(const uint8_t* pixels,
                                      const uint16_t* palette565) {
  const int64_t started = esp_timer_get_time();
  const int scale = s_layout.scale;
  const int width = s_layout.width;
  const int renderWidth = s_layout.renderWidth;
  // Whole-pixel scale: each source pixel becomes a scale x scale block. 2x,
  // the case every P4 panel takes, writes pixel pairs as one 32-bit store.
  //
  // The S3's 1x frame goes to its core-0 panel task (two pages) or straight
  // into DMA staging; scaled frames (the P4's 2x) go in bands on this task.
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  if (s_overlap) {
    // The previous frame must be on the panel: its page is the one the
    // engine draws into next.
    // A panel that never completes ends the session (quake_platform.h).
    const int64_t waitStarted = esp_timer_get_time();
    while (xSemaphoreTake(s_present_done, pdMS_TO_TICKS(1)) != pdTRUE) {
      quake_input_sample_while_waiting();
      if (esp_timer_get_time() - waitStarted > 2000000) {
        quake_fail_restart("panel task did not finish a frame", false);
      }
    }
    s_window_wait_us += esp_timer_get_time() - started;
    s_window_present_us += s_present_last_us;
    memcpy(s_present_palette, palette565, 256 * sizeof(uint16_t));
    s_present_pixels = pixels;
    xSemaphoreGive(s_present_go);
  } else if (scale == 1) {
    if (!quake_display_present_1x(s_layout.x, s_layout.y, renderWidth,
                                  s_layout.renderHeight, pixels, palette565,
                                  true)) {
      quake_fail_restart("panel DMA did not complete", false);
    }
  } else
#endif
  for (int band = 0; band < s_layout.renderHeight; band += QUAKE_BAND_ROWS) {
    const int rows = s_layout.renderHeight - band < QUAKE_BAND_ROWS
                         ? s_layout.renderHeight - band
                         : QUAKE_BAND_ROWS;
    for (int r = 0; r < rows; ++r) {
      const uint8_t* src = pixels + (size_t)(band + r) * renderWidth;
      uint16_t* row = s_frame + (size_t)r * scale * width;
      if (scale == 2) {
        uint32_t* out = (uint32_t*)row;
        for (int sx = 0; sx < renderWidth; ++sx) {
          const uint32_t c = palette565[src[sx]];
          out[sx] = c | (c << 16);
        }
      } else if (scale == 1) {
        for (int sx = 0; sx < renderWidth; ++sx) row[sx] = palette565[src[sx]];
      } else {
        for (int sx = 0; sx < renderWidth; ++sx) {
          const uint16_t c = palette565[src[sx]];
          for (int k = 0; k < scale; ++k) row[sx * scale + k] = c;
        }
      }
      for (int k = 1; k < scale; ++k) {
        memcpy(row + (size_t)k * width, row, (size_t)width * sizeof(uint16_t));
      }
    }
    const int y0 = s_layout.y + band * scale;
    if (!quake_display_blit_blocking(s_layout.x, y0, s_layout.x + width,
                                     y0 + rows * scale, s_frame)) {
      // The panel is what failed, so the reason goes to Serial only.
      quake_fail_restart("panel DMA did not complete", false);
    }
  }

  const int64_t now = esp_timer_get_time();
  if (!s_overlap) s_window_present_us += now - started;
  ++s_window_frames;
  if (s_window_started == 0) s_window_started = now;
  const int64_t elapsed = now - s_window_started;
  if (elapsed >= FPS_WINDOW_US) {
    const float seconds = (float)elapsed / 1e6f;
    // With the write overlapped, "present" is the panel task's time per
    // frame and "wait" what the engine spent waiting for it.
    quake_log("fps %.1f (%lu frames in %.1f s), present %.1f ms/frame, "
              "wait %.1f ms/frame, psram free %u largest %u, internal free %u",
              (float)s_window_frames / seconds, (unsigned long)s_window_frames,
              seconds,
              (float)s_window_present_us / 1000.0f / (float)s_window_frames,
              (float)s_window_wait_us / 1000.0f / (float)s_window_frames,
              (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM),
              (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM),
              (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
    if (s_profile_frames == 0) s_profile_surface_s = 0;  // r_dspeeds is off
    if (s_profile_frames > 0) {
      const float n = (float)s_profile_frames;
      quake_log("profile ms/frame: render %.1f = world %.1f + bmodels %.1f + "
                "scan %.1f (of which surface cache %.1f) + alias %.1f + "
                "viewmodel %.1f + particles %.1f; present %.1f",
                s_profile_ms[0] / n, s_profile_ms[1] / n, s_profile_ms[2] / n,
                s_profile_ms[3] / n, (float)(s_profile_surface_s * 1000.0) / n,
                s_profile_ms[4] / n, s_profile_ms[5] / n, s_profile_ms[6] / n,
                (float)s_window_present_us / 1000.0f / (float)s_window_frames);
      for (float& v : s_profile_ms) v = 0;
      s_profile_frames = 0;
      s_profile_surface_s = 0;
    }
    s_window_started = now;
    s_window_frames = 0;
    s_window_present_us = 0;
    s_window_wait_us = 0;
  }
}

void presentTask(void*) {
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  while (true) {
    xSemaphoreTake(s_present_go, portMAX_DELAY);
    const int64_t started = esp_timer_get_time();
    if (!quake_display_present_1x(s_layout.x, s_layout.y,
                                  s_layout.renderWidth, s_layout.renderHeight,
                                  s_present_pixels, s_present_palette, false)) {
      quake_fail_restart("panel DMA did not complete", false);
    }
    s_present_last_us = esp_timer_get_time() - started;
    xSemaphoreGive(s_present_done);
  }
#endif
}

extern "C" void quake_profile_frame(float render, float world, float bmodels,
                                    float scan, float entities,
                                    float viewmodel, float particles) {
  const float v[7] = {render, world, bmodels, scan, entities, viewmodel,
                      particles};
  for (int i = 0; i < 7; ++i) s_profile_ms[i] += v[i];
  ++s_profile_frames;
}

extern "C" void quake_profile_surface_cache(double seconds) {
  s_profile_surface_s += seconds;
}

extern "C" void quake_input_service(void) {
  serviceBoot();
  serviceTouch(quake_engine_in_menu());
  serviceUsb();
}

// Called while a blit waits on DMA, so a touch or key landing then is kept.
extern "C" void quake_input_sample_while_waiting(void) {
  sampleTouch();
  if (s_usb_started) doom_usb_input_service();
}

extern "C" int quake_input_get_key(int* down, int* key) {
  quakeinput::KeyEvent event;
  if (s_io == nullptr || !s_io->keys.pop(event)) return 0;
  *down = event.down ? 1 : 0;
  *key = event.key;
  return 1;
}

extern "C" void quake_input_get_mouse(int* x, int* y) {
  *x = s_mouse_x;
  *y = s_mouse_y;
  s_mouse_x = 0;
  s_mouse_y = 0;
}

extern "C" void quake_quit(void) {
  quake_log("Quake stopped. Restarting to normal firmware...");
  doom_audio_end();
  delay(20);
  ESP.restart();
  while (true) delay(1000);
}

#endif  // ESPDISP_QUAKE_RUNTIME
