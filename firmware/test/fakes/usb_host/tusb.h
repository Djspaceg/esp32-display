// Host fake of the TinyUSB surface doom_usb_input.cpp touches.
//
// The split that matters is kept exactly as the core's headers have it:
// tusb_init(rhport, init) is a macro for tusb_rhport_init(), the role
// dispatcher in tusb.c that also calls the DEVICE stack's init
// (tud_rhport_init), while tuh_rhport_init() is the host stack's own entry in
// usbh.c. The fakes count which one ran, because on the P4 reaching the
// dispatcher keeps every device class driver's buffers in the image.
#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef enum {
  TUSB_SPEED_FULL = 0,
  TUSB_SPEED_LOW = 1,
  TUSB_SPEED_HIGH = 2,
  TUSB_SPEED_AUTO = 0xFF,
} tusb_speed_t;

typedef enum {
  TUSB_ROLE_INVALID = 0,
  TUSB_ROLE_DEVICE = 1,
  TUSB_ROLE_HOST = 2,
} tusb_role_t;

typedef struct {
  tusb_role_t role;
  tusb_speed_t speed;
} tusb_rhport_init_t;

#define CFG_TUH_DEVICE_MAX 7
#define CFG_TUH_HID (3 * CFG_TUH_DEVICE_MAX)

enum { HID_PROTOCOL_BOOT = 0, HID_PROTOCOL_REPORT = 1 };
enum {
  HID_ITF_PROTOCOL_NONE = 0,
  HID_ITF_PROTOCOL_KEYBOARD = 1,
  HID_ITF_PROTOCOL_MOUSE = 2,
};

bool tusb_rhport_init(uint8_t rhport, const tusb_rhport_init_t *rh_init);
#define tusb_init(rhport, rh_init) tusb_rhport_init(rhport, rh_init)

bool tuh_rhport_init(uint8_t rhport, const tusb_rhport_init_t *rh_init);
void tuh_task_ext(uint32_t timeout_ms, bool in_isr);

void tuh_hid_set_default_protocol(uint8_t protocol);
uint8_t tuh_hid_interface_protocol(uint8_t dev_addr, uint8_t idx);
bool tuh_hid_receive_report(uint8_t dev_addr, uint8_t idx);
