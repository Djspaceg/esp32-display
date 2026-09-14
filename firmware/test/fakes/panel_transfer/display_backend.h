#pragma once

#include <board_config.h>
#include <esp_err.h>
#include <esp_lcd_panel_ops.h>

extern esp_err_t fakeDrawResult;

namespace boarddisplay {
inline esp_err_t drawBitmap(esp_lcd_panel_handle_t, const board::Config &, int,
                            int, int, int, const void *) {
  return fakeDrawResult;
}
}
