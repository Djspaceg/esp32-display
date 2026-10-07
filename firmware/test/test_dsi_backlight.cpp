// The P4 boards' backlight, through the real DSI backend (panel_init_dsi.h)
// against fakes/dsi_backlight: every lit level must reach a duty the glass
// shows, and a level the glass already showed keeps its duty. On a 4B the
// panel is dark below about 47% duty, so the status card's dimmed level (10 of
// 255, about 4%) read as black, and a touch that lit the card for ten seconds
// looked like the panel timing out.
#include <stdio.h>

#include <panel_init_dsi.h>

static int failures = 0;
#define CHECK(cond)                                                   \
  do {                                                                \
    if (!(cond)) {                                                    \
      printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);          \
      ++failures;                                                     \
    }                                                                 \
  } while (0)

esp_err_t esp_lcd_new_panel_jd9365(esp_lcd_panel_io_handle_t,
                                   const esp_lcd_panel_dev_config_t *,
                                   esp_lcd_panel_handle_t *out) {
  *out = reinterpret_cast<esp_lcd_panel_handle_t>(1);
  return ESP_OK;
}
esp_err_t esp_lcd_new_panel_st7703(esp_lcd_panel_io_handle_t,
                                   const esp_lcd_panel_dev_config_t *,
                                   esp_lcd_panel_handle_t *out) {
  *out = reinterpret_cast<esp_lcd_panel_handle_t>(1);
  return ESP_OK;
}

static bool noCompletion(esp_lcd_panel_io_handle_t, void *, void *) {
  return false;
}

static uint32_t dutyFor(uint8_t level) {
  CHECK(boardpaneldsi::setBrightness(level));
  return fakeLedcDuty;
}

int main() {
  // Lowest duty out of 1023 at which the 4B's glass showed a picture
  // (2026-10-07: dark below 47%, visible from 47%).
  const uint32_t visibleDuty = (470u * 1023u + 999u) / 1000u;
  const board::Variant p4[] = {board::Variant::P4_4B, board::Variant::P4_4C,
                               board::Variant::P4_34C};
  for (board::Variant variant : p4) {
    const board::Config &cfg = board::configFor(variant);
    esp_lcd_panel_handle_t panel = nullptr;
    CHECK(boardpaneldsi::init(cfg, 0, noCompletion, nullptr, nullptr, &panel));
    CHECK(panel != nullptr);
    printf("%s: status card (level 10) duty %u/1023, low preset (24) %u\n",
           cfg.name, (unsigned)dutyFor(10), (unsigned)dutyFor(24));
    CHECK(dutyFor(0) == 0);
    CHECK(dutyFor(255) == 1023);
    // What the lowest lit level gets is the board's floor, read back through
    // the backend rather than from the config, so this runs on any version.
    const uint32_t floorDuty = dutyFor(1);
    uint32_t previous = 0;
    for (int level = 1; level <= 255; ++level) {
      const uint32_t duty = dutyFor((uint8_t)level);
      CHECK(duty >= visibleDuty);
      CHECK(duty >= previous);  // brighter levels never get darker
      // A level already above the board's floor keeps its old duty.
      const uint32_t linear = (uint32_t)level * 1023u / 255u;
      if (linear >= floorDuty) CHECK(duty == linear);
      previous = duty;
    }
  }

  if (failures != 0) {
    printf("test_dsi_backlight: %d failure(s)\n", failures);
    return 1;
  }
  printf("test_dsi_backlight: all checks passed\n");
  return 0;
}
