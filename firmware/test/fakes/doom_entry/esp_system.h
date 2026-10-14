// Host fake of the reset-reason query boot_menu.cpp uses.
#pragma once

typedef enum {
  ESP_RST_UNKNOWN,
  ESP_RST_POWERON,
  ESP_RST_EXT,
  ESP_RST_SW,
  ESP_RST_PANIC,
  ESP_RST_INT_WDT,
  ESP_RST_TASK_WDT,
  ESP_RST_WDT,
  ESP_RST_DEEPSLEEP,
  ESP_RST_BROWNOUT,
  ESP_RST_SDIO,
  ESP_RST_USB,
} esp_reset_reason_t;

esp_reset_reason_t esp_reset_reason(void);

// esp_restart() runs these first. The fake keeps them so a test can play a
// deliberate restart.
typedef int esp_err_t;
typedef void (*shutdown_handler_t)(void);
esp_err_t esp_register_shutdown_handler(shutdown_handler_t handler);
