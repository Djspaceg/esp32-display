// The symbols the ESPDoomEasterEgg library links against, isolated here
// so the exact-target gating is one file rather than scattered through the
// sketch. See firmware/doom/README.md.

#include <Arduino.h>
#include <esp_heap_caps.h>

#include "esp_lcd_panel_ops.h"

#include "app_state.h"
#include "dma_gate.h"
#include "doom_failure_screen.h"
#include "panel_transfer.h"

#if defined(ESPDISP_DOOM_RUNTIME)
#include <doom_mode.h>
#include <platform/doom_log.h>
#endif

// Doom-enabled family images link these symbols, while callers gate entry on
// board::supportsDoom so unsupported carriers never initialize Doom hardware.
#if defined(ESPDISP_DOOM_RUNTIME)
esp_lcd_panel_handle_t doom_get_panel_handle(void) { return panel; }
#endif
#if defined(ESPDISP_DOOM_RUNTIME)
// The touch driver state is translation-unit-local inside Doom's hardware
// bridge, so service it through that bridge rather than including board_touch.h
// here and accidentally polling a separate disabled copy.
extern "C" void doom_touch_sample(void);

// Doom renders into one reusable full-panel buffer. esp_lcd queues the source
// pointer rather than copying it, so every blit must block until the completion
// ISR says DMA is done before Doom rewrites or frees that buffer. A timeout
// fails closed; the caller immediately restarts instead of continuing with an
// unknown transfer lifetime. Service touch while waiting because full-panel
// transfers can occupy most of a frame and controller reports may not be queued.
extern "C" bool doom_display_blit_blocking(const uint16_t *pixels,
                                             int width, int height) {
  if (panel == nullptr || pixels == nullptr || width <= 0 || height <= 0) {
    return false;
  }
  uint32_t startedAt = millis();
  while (dmaInFlight != 0 && millis() - startedAt < 1000) {
    doom_touch_sample();
    delay(1);
  }
  doom_touch_sample();
  if (dmaInFlight != 0) return false;

  if (queuePanelBitmap(panel, *bcfg, 0, 0, width, height, pixels) != ESP_OK) {
    return false;
  }

  startedAt = millis();
  while (dmaInFlight != 0 && millis() - startedAt < 1000) {
    doom_touch_sample();
    delay(1);
  }
  doom_touch_sample();
  return dmaInFlight == 0;
}

// How long a Doom boot that cannot start keeps its reason on the panel.
static const uint32_t DOOM_FAILURE_SHOW_MS = 4000;

static bool waitForDoomDmaIdle(uint32_t maxMs) {
  const uint32_t startedAt = millis();
  while (dmaInFlight != 0 && millis() - startedAt < maxMs) delay(1);
  return dmaInFlight == 0;
}

// Draws the failure card; returns whether it reached the glass. Prints
// nothing, so the FATAL line stays the last serial line before the restart.
static bool showDoomFailure(const char *reason) {
  if (panel == nullptr || bcfg == nullptr || bcfg->panel == nullptr ||
      PANEL_W <= 0 || PANEL_H <= 0 || !waitForDoomDmaIdle(1000)) {
    return false;
  }
  const size_t bytes = (size_t)PANEL_W * (size_t)PANEL_H * 2;
  uint8_t *card = (uint8_t *)heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM);
  if (card == nullptr) return false;
  doomfail::compose(card, PANEL_W, PANEL_H, bcfg->panel->roundDisplay, reason);
  if (queuePanelBitmap(panel, *bcfg, 0, 0, PANEL_W, PANEL_H, card) != ESP_OK) {
    heap_caps_free(card);
    return false;
  }
  // DMA still owns the card until completion; leak it on a timeout, the
  // restart reclaims it.
  if (!waitForDoomDmaIdle(1000)) return false;
  heap_caps_free(card);
  return true;
}

// Print-only (no printf), so the line still goes out when the heap is
// exhausted: Print::printf allocates for anything past 64 bytes.
static void printDoomFatal(const char *reason) {
  Serial.print("[doom] FATAL: ");
  Serial.print(reason);
  Serial.println("; restarting normal firmware");
  Serial.flush();
}

// Every Doom failure that the firmware can see ends here (platform/
// doom_log.h): the reason goes to Serial first, so it survives a panel that
// hangs, then to the glass for a few seconds, then the restart. It is printed
// again after the panel attempt because a failed panel queue logs its own
// line, and the last line before the restart must name the reason.
extern "C" void doom_fail_restart(const char *reason, bool showOnPanel) {
  printDoomFatal(reason);
  if (showOnPanel) {
    if (showDoomFailure(reason)) delay(DOOM_FAILURE_SHOW_MS);
    printDoomFatal(reason);
  }
  delay(20);
  ESP.restart();
  while (true) delay(1000);
}
#endif
