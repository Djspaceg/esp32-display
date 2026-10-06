// Host fake of the ESP-IDF USB PHY driver: records the request, always succeeds.
#pragma once

#include <stdint.h>

typedef int esp_err_t;
#ifndef ESP_OK
#define ESP_OK 0
#endif

typedef enum { USB_PHY_CTRL_OTG = 0, USB_PHY_CTRL_SERIAL_JTAG } usb_phy_controller_t;
typedef enum { USB_PHY_TARGET_INT = 0, USB_PHY_TARGET_EXT, USB_PHY_TARGET_UTMI } usb_phy_target_t;
typedef enum { USB_OTG_MODE_HOST = 0, USB_OTG_MODE_DEVICE } usb_otg_mode_t;
typedef enum { USB_PHY_SPEED_UNDEFINED = 0, USB_PHY_SPEED_LOW, USB_PHY_SPEED_FULL, USB_PHY_SPEED_HIGH } usb_phy_speed_t;

typedef struct {
  usb_phy_controller_t controller;
  usb_phy_target_t target;
  usb_otg_mode_t otg_mode;
  usb_phy_speed_t otg_speed;
  const void *ext_io_conf;
  const void *otg_io_conf;
} usb_phy_config_t;

typedef struct fake_usb_phy *usb_phy_handle_t;

esp_err_t usb_new_phy(const usb_phy_config_t *config, usb_phy_handle_t *handle);
esp_err_t usb_del_phy(usb_phy_handle_t handle);
