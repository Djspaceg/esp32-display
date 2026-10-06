// Host test for how doom_usb_input.cpp starts TinyUSB on the P4.
//
// The USB keyboard and mouse only ever run inside a Doom session, but what the
// glue links is paid for in every boot. tusb_init() is TinyUSB's role
// dispatcher and also calls the device stack's init, and reaching it keeps
// every device class driver's endpoint buffers (NCM, audio, DFU, MSC, CDC,
// HID, MIDI, vendor: about 48 KB) in static internal RAM on the P4. That is the
// DMA-capable memory the WiFi co-processor link and the audio I2S descriptors
// need while streaming; with it gone the 4C's DMA heap read 60 bytes free at
// idle and the C6 link died on the next failed 3 KB allocation. So the host
// stack must start through its own entry, tuh_rhport_init(). (The other edge,
// the DWC2 interrupt wrapper, is cut at link time; test_espdisp.py holds that.)
#include <cstdio>
#include <cstring>

#include <Arduino.h>
#include <board_config.h>
#include <esp_private/usb_phy.h>
#include <tusb.h>

#include "platform/doom_usb_input.h"

static int checks = 0;
#define CHECK(cond)                                          \
  do {                                                       \
    checks++;                                                \
    if (!(cond)) {                                           \
      printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      return 1;                                              \
    }                                                        \
  } while (0)

// ---- Fakes the glue links against -----------------------------------------

FakeSerial Serial;
const board::Config *bcfg = nullptr;
extern "C" int key_nextweapon = 0;
extern "C" int key_prevweapon = 0;
extern "C" void push_key(unsigned char, int) {}

static int phyCreated = 0;
static usb_phy_config_t lastPhy = {};
static int dispatcherCalls = 0;  // tusb_rhport_init: reaches the device stack
static int hostInitCalls = 0;    // tuh_rhport_init: the host stack alone
static uint8_t hostRhport = 0xFF;
static tusb_rhport_init_t hostInit = {};

esp_err_t usb_new_phy(const usb_phy_config_t *config, usb_phy_handle_t *handle) {
  phyCreated++;
  lastPhy = *config;
  *handle = reinterpret_cast<usb_phy_handle_t>(&phyCreated);
  return ESP_OK;
}
esp_err_t usb_del_phy(usb_phy_handle_t) { return ESP_OK; }

bool tusb_rhport_init(uint8_t, const tusb_rhport_init_t *) {
  dispatcherCalls++;
  return true;
}
bool tuh_rhport_init(uint8_t rhport, const tusb_rhport_init_t *rh_init) {
  hostInitCalls++;
  hostRhport = rhport;
  hostInit = *rh_init;
  return true;
}
void tuh_task_ext(uint32_t, bool) {}
void tuh_hid_set_default_protocol(uint8_t) {}
uint8_t tuh_hid_interface_protocol(uint8_t, uint8_t) {
  return HID_ITF_PROTOCOL_NONE;
}
bool tuh_hid_receive_report(uint8_t, uint8_t) { return true; }

static void reset() {
  Serial.captured.clear();
  phyCreated = 0;
  lastPhy = {};
  dispatcherCalls = 0;
  hostInitCalls = 0;
  hostRhport = 0xFF;
  hostInit = {};
}

int main() {
  // A carrier with a host port: the host stack starts, on its own entry.
  reset();
  bcfg = &board::configFor(board::Variant::P4_4C);
  doom_usb_input_init();
  CHECK(phyCreated == 1);
  CHECK(lastPhy.target == USB_PHY_TARGET_UTMI);
  CHECK(lastPhy.otg_mode == USB_OTG_MODE_HOST);
  CHECK(dispatcherCalls == 0);
  CHECK(hostInitCalls == 1);
  CHECK(hostRhport == 1);
  CHECK(hostInit.role == TUSB_ROLE_HOST);
  CHECK(hostInit.speed == TUSB_SPEED_HIGH);
  CHECK(Serial.captured.find("USB input ready") != std::string::npos);

  // The 4B hosts too (it just cannot power the device): same entry.
  reset();
  bcfg = &board::configFor(board::Variant::P4_4B);
  doom_usb_input_init();
  CHECK(dispatcherCalls == 0);
  CHECK(hostInitCalls == 1);
  CHECK(Serial.captured.find("does not supply 5 V") != std::string::npos);

  // No board settled: nothing is started at all.
  reset();
  bcfg = nullptr;
  doom_usb_input_init();
  CHECK(phyCreated == 0);
  CHECK(dispatcherCalls == 0);
  CHECK(hostInitCalls == 0);

  printf("usb host init: %d checks passed\n", checks);
  return 0;
}
