// The ESP-IDF and Arduino surface panel_init_dsi.h uses, faked for the host:
// every bring-up call succeeds and the backlight's LEDC duty is recorded.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

typedef int esp_err_t;
#define ESP_OK 0
#define ESP_ERR_INVALID_ARG 0x102
#define ESP_ERR_TIMEOUT 0x107
#define IRAM_ATTR

// Arduino
#define OUTPUT 1
#define LOW 0
#define HIGH 1
inline void pinMode(int, int) {}
inline void digitalWrite(int, int) {}
inline void delay(uint32_t) {}
inline uint32_t millis() { return 0; }

// LEDC
typedef enum { LEDC_LOW_SPEED_MODE = 0 } ledc_mode_t;
typedef enum { LEDC_TIMER_10_BIT = 10 } ledc_timer_bit_t;
typedef enum { LEDC_TIMER_0 = 0 } ledc_timer_t;
typedef enum { LEDC_CHANNEL_0 = 0 } ledc_channel_t;
typedef enum { LEDC_INTR_DISABLE = 0 } ledc_intr_type_t;
typedef enum { LEDC_AUTO_CLK = 0 } ledc_clk_cfg_t;
typedef struct {
  ledc_mode_t speed_mode;
  ledc_timer_bit_t duty_resolution;
  ledc_timer_t timer_num;
  uint32_t freq_hz;
  ledc_clk_cfg_t clk_cfg;
} ledc_timer_config_t;
typedef struct {
  int gpio_num;
  ledc_mode_t speed_mode;
  ledc_channel_t channel;
  ledc_intr_type_t intr_type;
  ledc_timer_t timer_sel;
  uint32_t duty;
  struct { unsigned output_invert : 1; } flags;
} ledc_channel_config_t;
inline uint32_t fakeLedcDuty = 0xFFFFFFFFu;
inline esp_err_t ledc_timer_config(const ledc_timer_config_t *) { return ESP_OK; }
inline esp_err_t ledc_channel_config(const ledc_channel_config_t *c) {
  fakeLedcDuty = c->duty;
  return ESP_OK;
}
inline esp_err_t ledc_set_duty(ledc_mode_t, ledc_channel_t, uint32_t duty) {
  fakeLedcDuty = duty;
  return ESP_OK;
}
inline esp_err_t ledc_update_duty(ledc_mode_t, ledc_channel_t) { return ESP_OK; }

// Heap
#define MALLOC_CAP_SPIRAM 1
#define MALLOC_CAP_8BIT 2
inline void *heap_caps_malloc(size_t bytes, uint32_t) { return malloc(bytes); }

// LDO
typedef struct fake_ldo *esp_ldo_channel_handle_t;
typedef struct { int chan_id; int voltage_mv; } esp_ldo_channel_config_t;
inline esp_err_t esp_ldo_acquire_channel(const esp_ldo_channel_config_t *,
                                         esp_ldo_channel_handle_t *out) {
  *out = reinterpret_cast<esp_ldo_channel_handle_t>(1);
  return ESP_OK;
}
inline esp_err_t esp_ldo_release_channel(esp_ldo_channel_handle_t) { return ESP_OK; }

// esp_lcd
typedef struct fake_io *esp_lcd_panel_io_handle_t;
typedef struct fake_panel *esp_lcd_panel_handle_t;
typedef struct fake_bus *esp_lcd_dsi_bus_handle_t;
typedef bool (*esp_lcd_panel_io_color_trans_done_cb_t)(esp_lcd_panel_io_handle_t,
                                                       void *, void *);
typedef enum { LCD_RGB_ELEMENT_ORDER_RGB = 0 } lcd_rgb_element_order_t;
typedef enum { LCD_COLOR_PIXEL_FORMAT_RGB565 = 0 } lcd_color_rgb_pixel_format_t;
typedef enum { MIPI_DSI_PHY_CLK_SRC_DEFAULT = 0 } mipi_dsi_phy_clock_source_t;
typedef enum { MIPI_DSI_DPI_CLK_SRC_DEFAULT = 0 } mipi_dsi_dpi_clock_source_t;
typedef struct {
  int reset_gpio_num;
  lcd_rgb_element_order_t rgb_ele_order;
  uint32_t bits_per_pixel;
  void *vendor_config;
} esp_lcd_panel_dev_config_t;
typedef struct {
  int bus_id;
  uint8_t num_data_lanes;
  mipi_dsi_phy_clock_source_t phy_clk_src;
  uint32_t lane_bit_rate_mbps;
} esp_lcd_dsi_bus_config_t;
typedef struct {
  uint8_t virtual_channel;
  int lcd_cmd_bits;
  int lcd_param_bits;
} esp_lcd_dbi_io_config_t;
typedef struct {
  uint8_t virtual_channel;
  mipi_dsi_dpi_clock_source_t dpi_clk_src;
  float dpi_clock_freq_mhz;
  lcd_color_rgb_pixel_format_t pixel_format;
  uint8_t num_fbs;
  struct {
    uint32_t h_size, v_size, hsync_back_porch, hsync_pulse_width,
        hsync_front_porch, vsync_back_porch, vsync_pulse_width,
        vsync_front_porch;
  } video_timing;
  struct { unsigned use_dma2d : 1; } flags;
} esp_lcd_dpi_panel_config_t;
typedef struct { int unused; } esp_lcd_dpi_panel_event_data_t;
typedef bool (*esp_lcd_dpi_panel_color_trans_done_cb_t)(
    esp_lcd_panel_handle_t, esp_lcd_dpi_panel_event_data_t *, void *);
typedef struct {
  esp_lcd_dpi_panel_color_trans_done_cb_t on_color_trans_done;
} esp_lcd_dpi_panel_event_callbacks_t;
inline esp_err_t esp_lcd_new_dsi_bus(const esp_lcd_dsi_bus_config_t *,
                                     esp_lcd_dsi_bus_handle_t *out) {
  *out = reinterpret_cast<esp_lcd_dsi_bus_handle_t>(1);
  return ESP_OK;
}
inline esp_err_t esp_lcd_del_dsi_bus(esp_lcd_dsi_bus_handle_t) { return ESP_OK; }
inline esp_err_t esp_lcd_new_panel_io_dbi(esp_lcd_dsi_bus_handle_t,
                                          const esp_lcd_dbi_io_config_t *,
                                          esp_lcd_panel_io_handle_t *out) {
  *out = reinterpret_cast<esp_lcd_panel_io_handle_t>(1);
  return ESP_OK;
}
inline esp_err_t esp_lcd_panel_io_rx_param(esp_lcd_panel_io_handle_t, int,
                                           void *, size_t) {
  return ESP_OK;
}
inline esp_err_t esp_lcd_panel_io_del(esp_lcd_panel_io_handle_t) { return ESP_OK; }
inline esp_err_t esp_lcd_dpi_panel_register_event_callbacks(
    esp_lcd_panel_handle_t, const esp_lcd_dpi_panel_event_callbacks_t *,
    void *) {
  return ESP_OK;
}
inline esp_err_t esp_lcd_panel_init(esp_lcd_panel_handle_t) { return ESP_OK; }
inline esp_err_t esp_lcd_panel_draw_bitmap(esp_lcd_panel_handle_t, int, int,
                                           int, int, const void *) {
  return ESP_OK;
}

// FreeRTOS
typedef int portMUX_TYPE;
#define portMUX_INITIALIZER_UNLOCKED 0
#define portENTER_CRITICAL(mux) ((void)(mux))
#define portEXIT_CRITICAL(mux) ((void)(mux))
#define portENTER_CRITICAL_ISR(mux) ((void)(mux))
#define portEXIT_CRITICAL_ISR(mux) ((void)(mux))
typedef struct fake_sem *SemaphoreHandle_t;
typedef struct fake_task *TaskHandle_t;
#define pdTRUE 1
#define pdPASS 1
#define pdMS_TO_TICKS(ms) (ms)
inline SemaphoreHandle_t xSemaphoreCreateBinary() { return nullptr; }
inline int xSemaphoreGive(SemaphoreHandle_t) { return pdTRUE; }
inline int xSemaphoreTake(SemaphoreHandle_t, uint32_t) { return pdTRUE; }
inline int uxTaskPriorityGet(TaskHandle_t) { return 1; }
inline int xTaskCreate(void (*)(void *), const char *, uint32_t, void *, int,
                       TaskHandle_t *) {
  return 0;
}
inline void vTaskDelete(TaskHandle_t) {}
inline void vTaskSuspend(TaskHandle_t) {}
