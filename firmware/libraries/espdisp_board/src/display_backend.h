// Bus-neutral display facade used by firmware and bring-up diagnostics.
#pragma once

#include <esp_lcd_panel_ops.h>
#include "board_config.h"
#include "panel_init.h"
#if defined(CONFIG_IDF_TARGET_ESP32P4)
#include "panel_init_dsi.h"
#endif

namespace boarddisplay {

inline bool init(const board::Config &cfg, spi_host_device_t spiHost,
                 size_t maxTransfer,
                 esp_lcd_panel_io_color_trans_done_cb_t doneCb,
                 void *userCtx, esp_lcd_panel_io_handle_t *outIo,
                 esp_lcd_panel_handle_t *outPanel) {
  if (cfg.platform == nullptr || cfg.panel == nullptr ||
      !board::platformSupportsPanel(*cfg.platform, *cfg.panel)) {
    return false;
  }
#if defined(CONFIG_IDF_TARGET_ESP32P4)
  if (cfg.panel->bus == board::PanelBus::MipiDsi) {
    return boardpaneldsi::init(cfg, maxTransfer, doneCb, userCtx, outIo,
                               outPanel);
  }
#endif
  return boardpanel::init(cfg, spiHost, maxTransfer, doneCb, userCtx, outIo,
                          outPanel);
}

inline esp_err_t drawBitmap(esp_lcd_panel_handle_t panel,
                            const board::Config &cfg, int x0, int y0,
                            int x1, int y1, const void *pixels) {
#if defined(CONFIG_IDF_TARGET_ESP32P4)
  if (cfg.isDsi()) {
    return boardpaneldsi::drawBitmap(panel, x0, y0, x1, y1, pixels);
  }
#endif
  return esp_lcd_panel_draw_bitmap(panel, x0, y0, x1, y1, pixels);
}

inline void applyOrientation(esp_lcd_panel_handle_t panel,
                             const board::Config &cfg, bool landscape,
                             uint8_t rotation,
                             bool installationMirrorX = false) {
#if defined(CONFIG_IDF_TARGET_ESP32P4)
  if (cfg.isDsi()) {
    boardpaneldsi::applyOrientation(cfg, landscape, rotation);
    return;
  }
#endif
  boardpanel::applyOrientation(panel, cfg, landscape, rotation,
                               installationMirrorX);
}

inline bool setBrightness(esp_lcd_panel_handle_t panel,
                          const board::Config &cfg, uint8_t level) {
#if defined(CONFIG_IDF_TARGET_ESP32P4)
  if (cfg.isDsi()) return boardpaneldsi::setBrightness(level);
#endif
  return boardpanel::setPanelBrightness(panel, cfg, level);
}

inline esp_err_t setDisplayEnabled(esp_lcd_panel_handle_t panel,
                                   const board::Config &, bool enabled) {
  if (panel == nullptr) return ESP_ERR_INVALID_ARG;
  return esp_lcd_panel_disp_on_off(panel, enabled);
}

}  // namespace boarddisplay
