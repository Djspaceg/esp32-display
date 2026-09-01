/*
 * SPDX-FileCopyrightText: 2023 Espressif Systems (Shanghai) CO LTD
 * SPDX-License-Identifier: Apache-2.0
 *
 * Adapted from Waveshare's ESP32-S3-Touch-LCD-1.85C example. Inactive
 * historical command tables were removed; the maintained V2 table remains.
 */
#include <stdlib.h>
#include <sys/cdefs.h>

#include "driver/gpio.h"
#include "esp_check.h"
#include "esp_lcd_panel_commands.h"
#include "esp_lcd_panel_interface.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_st77916.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define LCD_OPCODE_WRITE_CMD 0x02ULL
#define LCD_OPCODE_WRITE_COLOR 0x32ULL
#define ST77916_CMD_SET 0xF0
#define ST77916_PARAM_SET 0x00

static const char *TAG = "st77916";

typedef struct {
    esp_lcd_panel_t base;
    esp_lcd_panel_io_handle_t io;
    int reset_gpio_num;
    int x_gap;
    int y_gap;
    uint8_t fb_bits_per_pixel;
    uint8_t madctl_val;
    uint8_t colmod_val;
    const st77916_lcd_init_cmd_t *init_cmds;
    uint16_t init_cmds_size;
    struct {
        unsigned int use_qspi_interface : 1;
        unsigned int reset_level : 1;
    } flags;
} st77916_panel_t;

static const st77916_lcd_init_cmd_t init_v2[] = {
    {0xF0, (uint8_t[]){0x28}, 1, 0},
    {0xF2, (uint8_t[]){0x28}, 1, 0},
    {0x73, (uint8_t[]){0xF0}, 1, 0},
    {0x7C, (uint8_t[]){0xD1}, 1, 0},
    {0x83, (uint8_t[]){0xE0}, 1, 0},
    {0x84, (uint8_t[]){0x61}, 1, 0},
    {0xF2, (uint8_t[]){0x82}, 1, 0},
    {0xF0, (uint8_t[]){0x00}, 1, 0},
    {0xF0, (uint8_t[]){0x01}, 1, 0},
    {0xF1, (uint8_t[]){0x01}, 1, 0},
    {0xB0, (uint8_t[]){0x56}, 1, 0},
    {0xB1, (uint8_t[]){0x4D}, 1, 0},
    {0xB2, (uint8_t[]){0x24}, 1, 0},
    {0xB4, (uint8_t[]){0x87}, 1, 0},
    {0xB5, (uint8_t[]){0x44}, 1, 0},
    {0xB6, (uint8_t[]){0x8B}, 1, 0},
    {0xB7, (uint8_t[]){0x40}, 1, 0},
    {0xB8, (uint8_t[]){0x86}, 1, 0},
    {0xBA, (uint8_t[]){0x00}, 1, 0},
    {0xBB, (uint8_t[]){0x08}, 1, 0},
    {0xBC, (uint8_t[]){0x08}, 1, 0},
    {0xBD, (uint8_t[]){0x00}, 1, 0},
    {0xC0, (uint8_t[]){0x80}, 1, 0},
    {0xC1, (uint8_t[]){0x10}, 1, 0},
    {0xC2, (uint8_t[]){0x37}, 1, 0},
    {0xC3, (uint8_t[]){0x80}, 1, 0},
    {0xC4, (uint8_t[]){0x10}, 1, 0},
    {0xC5, (uint8_t[]){0x37}, 1, 0},
    {0xC6, (uint8_t[]){0xA9}, 1, 0},
    {0xC7, (uint8_t[]){0x41}, 1, 0},
    {0xC8, (uint8_t[]){0x01}, 1, 0},
    {0xC9, (uint8_t[]){0xA9}, 1, 0},
    {0xCA, (uint8_t[]){0x41}, 1, 0},
    {0xCB, (uint8_t[]){0x01}, 1, 0},
    {0xD0, (uint8_t[]){0x91}, 1, 0},
    {0xD1, (uint8_t[]){0x68}, 1, 0},
    {0xD2, (uint8_t[]){0x68}, 1, 0},
    {0xF5, (uint8_t[]){0x00, 0xA5}, 2, 0},
    {0xDD, (uint8_t[]){0x4F}, 1, 0},
    {0xDE, (uint8_t[]){0x4F}, 1, 0},
    {0xF1, (uint8_t[]){0x10}, 1, 0},
    {0xF0, (uint8_t[]){0x00}, 1, 0},
    {0xF0, (uint8_t[]){0x02}, 1, 0},
    {0xE0, (uint8_t[]){0xF0, 0x0A, 0x10, 0x09, 0x09, 0x36, 0x35,
                        0x33, 0x4A, 0x29, 0x15, 0x15, 0x2E, 0x34}, 14, 0},
    {0xE1, (uint8_t[]){0xF0, 0x0A, 0x0F, 0x08, 0x08, 0x05, 0x34,
                        0x33, 0x4A, 0x39, 0x15, 0x15, 0x2D, 0x33}, 14, 0},
    {0xF0, (uint8_t[]){0x10}, 1, 0},
    {0xF3, (uint8_t[]){0x10}, 1, 0},
    {0xE0, (uint8_t[]){0x07}, 1, 0},
    {0xE1, (uint8_t[]){0x00}, 1, 0},
    {0xE2, (uint8_t[]){0x00}, 1, 0},
    {0xE3, (uint8_t[]){0x00}, 1, 0},
    {0xE4, (uint8_t[]){0xE0}, 1, 0},
    {0xE5, (uint8_t[]){0x06}, 1, 0},
    {0xE6, (uint8_t[]){0x21}, 1, 0},
    {0xE7, (uint8_t[]){0x01}, 1, 0},
    {0xE8, (uint8_t[]){0x05}, 1, 0},
    {0xE9, (uint8_t[]){0x02}, 1, 0},
    {0xEA, (uint8_t[]){0xDA}, 1, 0},
    {0xEB, (uint8_t[]){0x00}, 1, 0},
    {0xEC, (uint8_t[]){0x00}, 1, 0},
    {0xED, (uint8_t[]){0x0F}, 1, 0},
    {0xEE, (uint8_t[]){0x00}, 1, 0},
    {0xEF, (uint8_t[]){0x00}, 1, 0},
    {0xF8, (uint8_t[]){0x00}, 1, 0},
    {0xF9, (uint8_t[]){0x00}, 1, 0},
    {0xFA, (uint8_t[]){0x00}, 1, 0},
    {0xFB, (uint8_t[]){0x00}, 1, 0},
    {0xFC, (uint8_t[]){0x00}, 1, 0},
    {0xFD, (uint8_t[]){0x00}, 1, 0},
    {0xFE, (uint8_t[]){0x00}, 1, 0},
    {0xFF, (uint8_t[]){0x00}, 1, 0},
    {0x60, (uint8_t[]){0x40}, 1, 0},
    {0x61, (uint8_t[]){0x04}, 1, 0},
    {0x62, (uint8_t[]){0x00}, 1, 0},
    {0x63, (uint8_t[]){0x42}, 1, 0},
    {0x64, (uint8_t[]){0xD9}, 1, 0},
    {0x65, (uint8_t[]){0x00}, 1, 0},
    {0x66, (uint8_t[]){0x00}, 1, 0},
    {0x67, (uint8_t[]){0x00}, 1, 0},
    {0x68, (uint8_t[]){0x00}, 1, 0},
    {0x69, (uint8_t[]){0x00}, 1, 0},
    {0x6A, (uint8_t[]){0x00}, 1, 0},
    {0x6B, (uint8_t[]){0x00}, 1, 0},
    {0x70, (uint8_t[]){0x40}, 1, 0},
    {0x71, (uint8_t[]){0x03}, 1, 0},
    {0x72, (uint8_t[]){0x00}, 1, 0},
    {0x73, (uint8_t[]){0x42}, 1, 0},
    {0x74, (uint8_t[]){0xD8}, 1, 0},
    {0x75, (uint8_t[]){0x00}, 1, 0},
    {0x76, (uint8_t[]){0x00}, 1, 0},
    {0x77, (uint8_t[]){0x00}, 1, 0},
    {0x78, (uint8_t[]){0x00}, 1, 0},
    {0x79, (uint8_t[]){0x00}, 1, 0},
    {0x7A, (uint8_t[]){0x00}, 1, 0},
    {0x7B, (uint8_t[]){0x00}, 1, 0},
    {0x80, (uint8_t[]){0x48}, 1, 0},
    {0x81, (uint8_t[]){0x00}, 1, 0},
    {0x82, (uint8_t[]){0x06}, 1, 0},
    {0x83, (uint8_t[]){0x02}, 1, 0},
    {0x84, (uint8_t[]){0xD6}, 1, 0},
    {0x85, (uint8_t[]){0x04}, 1, 0},
    {0x86, (uint8_t[]){0x00}, 1, 0},
    {0x87, (uint8_t[]){0x00}, 1, 0},
    {0x88, (uint8_t[]){0x48}, 1, 0},
    {0x89, (uint8_t[]){0x00}, 1, 0},
    {0x8A, (uint8_t[]){0x08}, 1, 0},
    {0x8B, (uint8_t[]){0x02}, 1, 0},
    {0x8C, (uint8_t[]){0xD8}, 1, 0},
    {0x8D, (uint8_t[]){0x04}, 1, 0},
    {0x8E, (uint8_t[]){0x00}, 1, 0},
    {0x8F, (uint8_t[]){0x00}, 1, 0},
    {0x90, (uint8_t[]){0x48}, 1, 0},
    {0x91, (uint8_t[]){0x00}, 1, 0},
    {0x92, (uint8_t[]){0x0A}, 1, 0},
    {0x93, (uint8_t[]){0x02}, 1, 0},
    {0x94, (uint8_t[]){0xDA}, 1, 0},
    {0x95, (uint8_t[]){0x04}, 1, 0},
    {0x96, (uint8_t[]){0x00}, 1, 0},
    {0x97, (uint8_t[]){0x00}, 1, 0},
    {0x98, (uint8_t[]){0x48}, 1, 0},
    {0x99, (uint8_t[]){0x00}, 1, 0},
    {0x9A, (uint8_t[]){0x0C}, 1, 0},
    {0x9B, (uint8_t[]){0x02}, 1, 0},
    {0x9C, (uint8_t[]){0xDC}, 1, 0},
    {0x9D, (uint8_t[]){0x04}, 1, 0},
    {0x9E, (uint8_t[]){0x00}, 1, 0},
    {0x9F, (uint8_t[]){0x00}, 1, 0},
    {0xA0, (uint8_t[]){0x48}, 1, 0},
    {0xA1, (uint8_t[]){0x00}, 1, 0},
    {0xA2, (uint8_t[]){0x05}, 1, 0},
    {0xA3, (uint8_t[]){0x02}, 1, 0},
    {0xA4, (uint8_t[]){0xD5}, 1, 0},
    {0xA5, (uint8_t[]){0x04}, 1, 0},
    {0xA6, (uint8_t[]){0x00}, 1, 0},
    {0xA7, (uint8_t[]){0x00}, 1, 0},
    {0xA8, (uint8_t[]){0x48}, 1, 0},
    {0xA9, (uint8_t[]){0x00}, 1, 0},
    {0xAA, (uint8_t[]){0x07}, 1, 0},
    {0xAB, (uint8_t[]){0x02}, 1, 0},
    {0xAC, (uint8_t[]){0xD7}, 1, 0},
    {0xAD, (uint8_t[]){0x04}, 1, 0},
    {0xAE, (uint8_t[]){0x00}, 1, 0},
    {0xAF, (uint8_t[]){0x00}, 1, 0},
    {0xB0, (uint8_t[]){0x48}, 1, 0},
    {0xB1, (uint8_t[]){0x00}, 1, 0},
    {0xB2, (uint8_t[]){0x09}, 1, 0},
    {0xB3, (uint8_t[]){0x02}, 1, 0},
    {0xB4, (uint8_t[]){0xD9}, 1, 0},
    {0xB5, (uint8_t[]){0x04}, 1, 0},
    {0xB6, (uint8_t[]){0x00}, 1, 0},
    {0xB7, (uint8_t[]){0x00}, 1, 0},
    {0xB8, (uint8_t[]){0x48}, 1, 0},
    {0xB9, (uint8_t[]){0x00}, 1, 0},
    {0xBA, (uint8_t[]){0x0B}, 1, 0},
    {0xBB, (uint8_t[]){0x02}, 1, 0},
    {0xBC, (uint8_t[]){0xDB}, 1, 0},
    {0xBD, (uint8_t[]){0x04}, 1, 0},
    {0xBE, (uint8_t[]){0x00}, 1, 0},
    {0xBF, (uint8_t[]){0x00}, 1, 0},
    {0xC0, (uint8_t[]){0x10}, 1, 0},
    {0xC1, (uint8_t[]){0x47}, 1, 0},
    {0xC2, (uint8_t[]){0x56}, 1, 0},
    {0xC3, (uint8_t[]){0x65}, 1, 0},
    {0xC4, (uint8_t[]){0x74}, 1, 0},
    {0xC5, (uint8_t[]){0x88}, 1, 0},
    {0xC6, (uint8_t[]){0x99}, 1, 0},
    {0xC7, (uint8_t[]){0x01}, 1, 0},
    {0xC8, (uint8_t[]){0xBB}, 1, 0},
    {0xC9, (uint8_t[]){0xAA}, 1, 0},
    {0xD0, (uint8_t[]){0x10}, 1, 0},
    {0xD1, (uint8_t[]){0x47}, 1, 0},
    {0xD2, (uint8_t[]){0x56}, 1, 0},
    {0xD3, (uint8_t[]){0x65}, 1, 0},
    {0xD4, (uint8_t[]){0x74}, 1, 0},
    {0xD5, (uint8_t[]){0x88}, 1, 0},
    {0xD6, (uint8_t[]){0x99}, 1, 0},
    {0xD7, (uint8_t[]){0x01}, 1, 0},
    {0xD8, (uint8_t[]){0xBB}, 1, 0},
    {0xD9, (uint8_t[]){0xAA}, 1, 0},
    {0xF3, (uint8_t[]){0x01}, 1, 0},
    {0xF0, (uint8_t[]){0x00}, 1, 0},
    {0x21, NULL, 0, 0},
    {0x11, NULL, 0, 120},
    {0x29, NULL, 0, 0},
};

static esp_err_t tx_param(st77916_panel_t *ctx, int command,
                          const void *data, size_t size) {
    if (ctx->flags.use_qspi_interface) {
        command = (command & 0xff) << 8;
        command |= LCD_OPCODE_WRITE_CMD << 24;
    }
    return esp_lcd_panel_io_tx_param(ctx->io, command, data, size);
}

static esp_err_t tx_color(st77916_panel_t *ctx, int command,
                          const void *data, size_t size) {
    if (ctx->flags.use_qspi_interface) {
        command = (command & 0xff) << 8;
        command |= LCD_OPCODE_WRITE_COLOR << 24;
    }
    return esp_lcd_panel_io_tx_color(ctx->io, command, data, size);
}

static esp_err_t panel_del(esp_lcd_panel_t *panel) {
    st77916_panel_t *ctx = __containerof(panel, st77916_panel_t, base);
    if (ctx->reset_gpio_num >= 0) gpio_reset_pin(ctx->reset_gpio_num);
    free(ctx);
    return ESP_OK;
}

static esp_err_t panel_reset(esp_lcd_panel_t *panel) {
    st77916_panel_t *ctx = __containerof(panel, st77916_panel_t, base);
    if (ctx->reset_gpio_num >= 0) {
        gpio_set_level(ctx->reset_gpio_num, ctx->flags.reset_level);
        vTaskDelay(pdMS_TO_TICKS(10));
        gpio_set_level(ctx->reset_gpio_num, !ctx->flags.reset_level);
    } else {
        ESP_RETURN_ON_ERROR(tx_param(ctx, LCD_CMD_SWRESET, NULL, 0), TAG,
                            "send reset failed");
    }
    vTaskDelay(pdMS_TO_TICKS(120));
    return ESP_OK;
}

static esp_err_t panel_init(esp_lcd_panel_t *panel) {
    st77916_panel_t *ctx = __containerof(panel, st77916_panel_t, base);
    ESP_RETURN_ON_ERROR(tx_param(ctx, LCD_CMD_MADCTL, &ctx->madctl_val, 1), TAG,
                        "send MADCTL failed");
    ESP_RETURN_ON_ERROR(tx_param(ctx, LCD_CMD_COLMOD, &ctx->colmod_val, 1), TAG,
                        "send COLMOD failed");
    const st77916_lcd_init_cmd_t *commands = ctx->init_cmds;
    uint16_t count = ctx->init_cmds_size;
    if (commands == NULL || count == 0) {
        commands = init_v2;
        count = sizeof(init_v2) / sizeof(init_v2[0]);
    }
    bool userCommandSet = true;
    for (uint16_t i = 0; i < count; i++) {
        if (userCommandSet && commands[i].data_bytes > 0) {
            if (commands[i].cmd == LCD_CMD_MADCTL) {
                ctx->madctl_val = ((const uint8_t *)commands[i].data)[0];
            } else if (commands[i].cmd == LCD_CMD_COLMOD) {
                ctx->colmod_val = ((const uint8_t *)commands[i].data)[0];
            }
        }
        ESP_RETURN_ON_ERROR(tx_param(ctx, commands[i].cmd, commands[i].data,
                                     commands[i].data_bytes), TAG,
                            "send init command failed");
        vTaskDelay(pdMS_TO_TICKS(commands[i].delay_ms));
        if (commands[i].cmd == ST77916_CMD_SET && commands[i].data_bytes > 0) {
            userCommandSet = ((const uint8_t *)commands[i].data)[0] ==
                             ST77916_PARAM_SET;
        }
    }
    return ESP_OK;
}

static esp_err_t panel_draw(esp_lcd_panel_t *panel, int xs, int ys, int xe,
                            int ye, const void *pixels) {
    st77916_panel_t *ctx = __containerof(panel, st77916_panel_t, base);
    xs += ctx->x_gap;
    xe += ctx->x_gap;
    ys += ctx->y_gap;
    ye += ctx->y_gap;
    uint8_t column[] = {(uint8_t)(xs >> 8), (uint8_t)xs,
                        (uint8_t)((xe - 1) >> 8), (uint8_t)(xe - 1)};
    uint8_t row[] = {(uint8_t)(ys >> 8), (uint8_t)ys,
                     (uint8_t)((ye - 1) >> 8), (uint8_t)(ye - 1)};
    ESP_RETURN_ON_ERROR(tx_param(ctx, LCD_CMD_CASET, column, sizeof(column)),
                        TAG, "set columns failed");
    ESP_RETURN_ON_ERROR(tx_param(ctx, LCD_CMD_RASET, row, sizeof(row)), TAG,
                        "set rows failed");
    const size_t bytes = (size_t)(xe - xs) * (ye - ys) *
                         ctx->fb_bits_per_pixel / 8;
    return tx_color(ctx, LCD_CMD_RAMWR, pixels, bytes);
}

static esp_err_t panel_invert(esp_lcd_panel_t *panel, bool invert) {
    st77916_panel_t *ctx = __containerof(panel, st77916_panel_t, base);
    return tx_param(ctx, invert ? LCD_CMD_INVON : LCD_CMD_INVOFF, NULL, 0);
}

static esp_err_t panel_mirror(esp_lcd_panel_t *panel, bool x, bool y) {
    st77916_panel_t *ctx = __containerof(panel, st77916_panel_t, base);
    ctx->madctl_val = x ? (uint8_t)(ctx->madctl_val | BIT(6))
                         : (uint8_t)(ctx->madctl_val & ~BIT(6));
    ctx->madctl_val = y ? (uint8_t)(ctx->madctl_val | BIT(7))
                         : (uint8_t)(ctx->madctl_val & ~BIT(7));
    return tx_param(ctx, LCD_CMD_MADCTL, &ctx->madctl_val, 1);
}

static esp_err_t panel_swap(esp_lcd_panel_t *panel, bool swap) {
    st77916_panel_t *ctx = __containerof(panel, st77916_panel_t, base);
    ctx->madctl_val = swap ? (uint8_t)(ctx->madctl_val | LCD_CMD_MV_BIT)
                            : (uint8_t)(ctx->madctl_val & ~LCD_CMD_MV_BIT);
    return tx_param(ctx, LCD_CMD_MADCTL, &ctx->madctl_val, 1);
}

static esp_err_t panel_gap(esp_lcd_panel_t *panel, int x, int y) {
    st77916_panel_t *ctx = __containerof(panel, st77916_panel_t, base);
    ctx->x_gap = x;
    ctx->y_gap = y;
    return ESP_OK;
}

static esp_err_t panel_power(esp_lcd_panel_t *panel, bool on) {
    st77916_panel_t *ctx = __containerof(panel, st77916_panel_t, base);
    return tx_param(ctx, on ? LCD_CMD_DISPON : LCD_CMD_DISPOFF, NULL, 0);
}

esp_err_t esp_lcd_new_panel_st77916(
    const esp_lcd_panel_io_handle_t io,
    const esp_lcd_panel_dev_config_t *config,
    esp_lcd_panel_handle_t *out) {
    ESP_RETURN_ON_FALSE(io && config && out, ESP_ERR_INVALID_ARG, TAG,
                        "invalid argument");
    st77916_panel_t *ctx = calloc(1, sizeof(st77916_panel_t));
    ESP_RETURN_ON_FALSE(ctx, ESP_ERR_NO_MEM, TAG, "no memory for panel");

    ctx->io = io;
    ctx->reset_gpio_num = config->reset_gpio_num;
    ctx->flags.reset_level = config->flags.reset_active_high;
    ctx->madctl_val = config->rgb_ele_order == LCD_RGB_ELEMENT_ORDER_BGR
                          ? LCD_CMD_BGR_BIT
                          : 0;
    if (config->bits_per_pixel == 16) {
        ctx->colmod_val = 0x55;
        ctx->fb_bits_per_pixel = 16;
    } else if (config->bits_per_pixel == 18) {
        ctx->colmod_val = 0x66;
        ctx->fb_bits_per_pixel = 24;
    } else {
        free(ctx);
        return ESP_ERR_NOT_SUPPORTED;
    }
    const st77916_vendor_config_t *vendor = config->vendor_config;
    if (vendor) {
        ctx->init_cmds = vendor->init_cmds;
        ctx->init_cmds_size = vendor->init_cmds_size;
        ctx->flags.use_qspi_interface = vendor->flags.use_qspi_interface;
    }
    if (ctx->reset_gpio_num >= 0) {
        gpio_config_t gpio = {
            .pin_bit_mask = 1ULL << ctx->reset_gpio_num,
            .mode = GPIO_MODE_OUTPUT,
        };
        esp_err_t error = gpio_config(&gpio);
        if (error != ESP_OK) {
            free(ctx);
            return error;
        }
    }

    ctx->base.del = panel_del;
    ctx->base.reset = panel_reset;
    ctx->base.init = panel_init;
    ctx->base.draw_bitmap = panel_draw;
    ctx->base.invert_color = panel_invert;
    ctx->base.mirror = panel_mirror;
    ctx->base.swap_xy = panel_swap;
    ctx->base.set_gap = panel_gap;
    ctx->base.disp_on_off = panel_power;
    *out = &ctx->base;
    return ESP_OK;
}
