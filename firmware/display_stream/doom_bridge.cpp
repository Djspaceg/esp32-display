// The two symbols the ESPDoomEasterEgg library links against, isolated here
// so the exact-target gating is one file rather than scattered through the
// sketch. See firmware/doom/README.md.

#include <Arduino.h>

#include "esp_lcd_panel_ops.h"

#include "app_state.h"
#include "dma_gate.h"
#include "panel_transfer.h"


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
#endif
