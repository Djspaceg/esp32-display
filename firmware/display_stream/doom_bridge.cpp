// The two symbols the ESPDoomEasterEgg library links against, isolated here
// so the exact-target gating is one file rather than scattered through the
// sketch. See firmware/doom/README.md.

#include <Arduino.h>

#include "esp_lcd_panel_ops.h"

#include "app_state.h"
#include "dma_gate.h"


// Expose the panel handle to the Doom Easter Egg display bridge. The build
// define exists only on the 466x466 CO5300 target; the same-chip s3-185 image
// neither links nor advertises this hardware-specific mode.
#if defined(ESPDISP_DOOM_S3_175)
esp_lcd_panel_handle_t doom_get_panel_handle(void) { return panel; }
#endif
#if defined(ESPDISP_DOOM_S3_175)
// Doom renders into one reusable full-panel buffer. esp_lcd queues the source
// pointer rather than copying it, so every blit must block until the completion
// ISR says DMA is done before Doom rewrites or frees that buffer. A timeout
// fails closed; the caller immediately restarts instead of continuing with an
// unknown transfer lifetime.
extern "C" bool doom_display_blit_blocking(const uint16_t *pixels,
                                             int width, int height) {
  if (panel == nullptr || pixels == nullptr || width <= 0 || height <= 0) {
    return false;
  }
  uint32_t startedAt = millis();
  while (dmaInFlight != 0 && millis() - startedAt < 1000) {
    delay(1);
  }
  if (dmaInFlight != 0) return false;

  dmaMarkQueued();
  if (esp_lcd_panel_draw_bitmap(panel, 0, 0, width, height, pixels) != ESP_OK) {
    dmaUnmarkFailed();
    return false;
  }

  startedAt = millis();
  while (dmaInFlight != 0 && millis() - startedAt < 1000) {
    delay(1);
  }
  return dmaInFlight == 0;
}
#endif
