// The symbols the Quake runtime links against from the sketch: the panel and
// the failure path. Its counterpart for Doom is doom_bridge.cpp; see
// firmware/quake/README.md.

// Only images with the Doom runtime get the firmware/ library folder, and
// Quake rides on that runtime (quake_build.h), so the C6 and C3 never look.
#if defined(ESPDISP_DOOM_RUNTIME)
#include <quake_build.h>
#endif

#if defined(ESPDISP_QUAKE_RUNTIME)

#include <Arduino.h>
#include <esp_heap_caps.h>

#include "app_state.h"
#include "dma_gate.h"
#include "doom_failure_screen.h"
#include "panel_transfer.h"

#include <platform/quake_platform.h>

extern "C" void quake_input_sample_while_waiting(void);

static bool waitForQuakeDma(uint32_t maxMs, bool sampleInput) {
  const uint32_t startedAt = millis();
  while (dmaInFlight != 0 && millis() - startedAt < maxMs) {
    if (sampleInput) quake_input_sample_while_waiting();
    delay(1);
  }
  return dmaInFlight == 0;
}

// esp_lcd queues the source pointer rather than copying it, so the caller's
// buffer is DMA's until completion: this returns only once it is done, or
// false on a timeout, after which the caller restarts. Touch and USB are
// serviced while waiting, so input that lands mid-transfer is kept.
extern "C" bool quake_display_blit_blocking(int x0, int y0, int x1, int y1,
                                            const uint16_t *pixels) {
  if (panel == nullptr || bcfg == nullptr || pixels == nullptr || x1 <= x0 ||
      y1 <= y0) {
    return false;
  }
  if (!waitForQuakeDma(1000, true)) return false;
  if (queuePanelBitmap(panel, *bcfg, x0, y0, x1, y1, pixels) != ESP_OK) {
    return false;
  }
  return waitForQuakeDma(1000, true);
}

// How long a Quake boot that cannot start keeps its reason on the panel.
static const uint32_t QUAKE_FAILURE_SHOW_MS = 4000;
static const char QUAKE_FAILURE_HEADLINE[] = "Quake could not start";

static bool showQuakeFailure(const char *reason) {
  if (panel == nullptr || bcfg == nullptr || bcfg->panel == nullptr ||
      PANEL_W <= 0 || PANEL_H <= 0 || !waitForQuakeDma(1000, false)) {
    return false;
  }
  const size_t bytes = (size_t)PANEL_W * (size_t)PANEL_H * 2;
  uint8_t *card = (uint8_t *)heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM);
  if (card == nullptr) return false;
  doomfail::compose(card, PANEL_W, PANEL_H, bcfg->panel->roundDisplay, reason,
                    QUAKE_FAILURE_HEADLINE);
  if (queuePanelBitmap(panel, *bcfg, 0, 0, PANEL_W, PANEL_H, card) != ESP_OK) {
    heap_caps_free(card);
    return false;
  }
  // DMA owns the card until completion; leak it on a timeout, the restart
  // reclaims it.
  if (!waitForQuakeDma(1000, false)) return false;
  heap_caps_free(card);
  return true;
}

// Print-only, so the line still goes out when the heap is exhausted.
static void printQuakeFatal(const char *reason) {
  Serial.print("[quake] FATAL: ");
  Serial.print(reason);
  Serial.println("; restarting normal firmware");
  Serial.flush();
}

// Every Quake failure the firmware can see ends here: the reason on Serial
// first, so it survives a panel that hangs, then on the glass, then again on
// Serial so it is the last line before the restart.
extern "C" void quake_fail_restart(const char *reason, bool showOnPanel) {
  printQuakeFatal(reason);
  if (showOnPanel) {
    if (showQuakeFailure(reason)) delay(QUAKE_FAILURE_SHOW_MS);
    printQuakeFatal(reason);
  }
  delay(20);
  ESP.restart();
  while (true) delay(1000);
}
#endif
