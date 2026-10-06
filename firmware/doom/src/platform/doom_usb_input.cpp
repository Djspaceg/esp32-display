// TinyUSB host glue for the USB keyboard and mouse.
//
// The installed Arduino core (3.3.11) already ships the whole stack: TinyUSB's
// host core and its HID class driver are compiled into libarduino_tinyusb.a for
// both the S3 and the P4 (CFG_TUH_ENABLED follows CFG_TUD_ENABLED, which the
// prebuilt sdkconfig turns on), and the core even defines the tuh_hid_* callback
// set as weak symbols for a sketch to override, which is what this file does.
// No new dependency is added.
//
// All of this runs only inside a Doom session. Doom is entered through a
// one-shot reboot, so during normal streaming the USB host stack is never
// installed: a keyboard plugged in while the panel is streaming does nothing at
// all, and a board with no keyboard behaves exactly as it did before.
//
// Everything that decides what a report MEANS lives in doom_usb_input_model.h
// and is host tested. This file only moves bytes and talks to hardware.
#if defined(ESPDISP_DOOM_RUNTIME)

#include "doom_usb_input.h"

#include <Arduino.h>  // also brings in sdkconfig.h (CONFIG_IDF_TARGET_*)

#include <string.h>

#include <board_config.h>

#include "doom_usb_input_model.h"

// Only the P4 carriers have a USB connector a device can be plugged into while
// the board keeps its link to the computer, so only the P4 image carries the
// host stack: referencing it at all would pull TinyUSB's host core and HID
// class driver into every S3 image to sit unreachable behind hostPortFor().
// hostPortFor() remains the real gate; an S3 carrier that grew a second USB
// connector would need this condition widened as well as its table entry.
#if CONFIG_IDF_TARGET_ESP32P4

// The Arduino build does not define CFG_TUSB_MCU for sketch and library
// translation units, so tusb_config.h would quietly default it to the S2 and
// the speed macros below would come out wrong. Pin it to this chip first, using
// the same value tusb_option.h assigns (OPT_MCU_ESP32P4 907); that constant is
// not yet visible at this point, which is why the number is written out.
#ifndef CFG_TUSB_MCU
#define CFG_TUSB_MCU 907
#endif

#include <esp_private/usb_phy.h>
#include <tusb.h>

// Taking the port as host requires that nothing else already owns it. With the
// FQBN this firmware builds (USBMode=default, CDCOnBoot=default) the core never
// calls USB.begin(), so the port is free; enabling CDC, MSC or DFU on boot would
// have the core bring the same PHY up in device mode first and this feature
// would silently vanish, taking the Serial diagnostics below out the port being
// re-roled. Fail the build rather than ship that.
#if defined(ARDUINO_USB_MODE) && ARDUINO_USB_MODE == 0 &&            \
    ((defined(ARDUINO_USB_CDC_ON_BOOT) && ARDUINO_USB_CDC_ON_BOOT) || \
     (defined(ARDUINO_USB_MSC_ON_BOOT) && ARDUINO_USB_MSC_ON_BOOT) || \
     (defined(ARDUINO_USB_DFU_ON_BOOT) && ARDUINO_USB_DFU_ON_BOOT))
#error \
    "Doom USB input needs the USB OTG port free; this build starts TinyUSB in device mode on it (CDCOnBoot/MSC/DFU on boot)."
#endif

#define DOOM_USB_HOST_AVAILABLE 1
#else
#define DOOM_USB_HOST_AVAILABLE 0
#endif

// Settled by display_stream before Doom is entered; the same global the rest of
// the Doom bridge reads.
extern const board::Config* bcfg;

// From the doomgeneric platform layer (compiled as C in the unity build).
extern "C" void push_key(unsigned char key, int pressed);

// The engine's weapon-cycle bindings, set by M_ApplyPlatformDefaults().
extern "C" int key_nextweapon;
extern "C" int key_prevweapon;

namespace {

bool s_started = false;

#if DOOM_USB_HOST_AVAILABLE

// The P4 has two USB controllers and TinyUSB maps root hub port 0 to the
// full-speed one and port 1 to the USB 2.0 high-speed OTG. It is the high-speed
// one whose DP/DM pins (package pins 50/51, nets USBD_P/USBD_N) reach the
// connector on all three P4 carriers, so port 1 is the host port.
constexpr uint8_t kHostRhPort = 1;
constexpr tusb_speed_t kHostSpeed = TUSB_SPEED_HIGH;
constexpr usb_phy_speed_t kPhySpeed = USB_PHY_SPEED_HIGH;

usb_phy_handle_t s_phy = nullptr;

// What each mounted HID interface is. TinyUSB indexes HID interfaces globally
// across every device, with CFG_TUH_HID (3 * CFG_TUH_DEVICE_MAX, so 21 here)
// slots in all, which is exactly the range tuh_hid_* hands back as `idx`.
doomusb::Device s_interface[CFG_TUH_HID] = {};

// Reports arrive on whichever task calls tuh_task_ext() -- TinyUSB's host core
// spawns none of its own -- and every call site here is on loopTask, the same
// task that polls the engine, so the queue needs no locking. Its own logic,
// including what a full queue and an unplug do to it, is host tested.
doomusb::ReportQueue s_queue;

doomusb::KeyboardTracker s_keyboard;
doomusb::MouseTracker s_mouse;

void emit(const doomusb::KeyEvent* events, size_t count) {
  for (size_t i = 0; i < count; ++i) {
    push_key(events[i].key, events[i].pressed ? 1 : 0);
  }
}

#endif  // DOOM_USB_HOST_AVAILABLE

}  // namespace

#if DOOM_USB_HOST_AVAILABLE
// The P4 link wraps dcd_int_handler onto this no-op (PLATFORM_LINK_FLAGS in
// tools/espdisp.py). TinyUSB's DWC2 interrupt wrapper, which the host stack
// installs, also calls the DEVICE controller's handler for a device-role port,
// and that one edge keeps usbd.c and every device class driver reachable, with
// about 48 KB of their endpoint buffers in static internal RAM on every boot.
// That is the DMA-capable RAM the C6 WiFi link and the audio I2S descriptors
// need while streaming: with it gone the 4C's DMA heap sat at 60 bytes free
// and the C6 link died on the next failed allocation. The wrapped call can
// never run: the host stack installs that interrupt with the host role, so the
// wrapper only ever takes its host branch (and dcd_dwc2.c's own copy of it is
// not redirected, since --wrap only rewrites references between objects). With
// the wrap the linker drops the device side: its archive members still load,
// but nothing reaches their sections.
extern "C" void __wrap_dcd_int_handler(uint8_t rhport) { (void)rhport; }

// The DFU runtime device driver still links (the archive member is pulled by
// name even though the linker then drops it), and its one callback is what
// pulls the core's USB.cpp in, whose global ESPUSB constructor starts an
// "arduino_usb_events" task at every boot. Defined here, the core's copy is
// never extracted. Nothing calls it: the device stack never runs. Weak, so a
// future build that pulls USB.cpp in for its own sake gets the core's strong
// copy instead of a multiple-definition error.
extern "C" __attribute__((weak)) void tud_dfu_runtime_reboot_to_dfu_cb(void) {}
#endif

// ---- Lifecycle -----------------------------------------------------------

extern "C" void doom_usb_input_init(void) {
  s_started = false;
  const board::Variant variant =
      bcfg != nullptr ? bcfg->variant : board::Variant::Unknown;
  const doomusb::HostPort port = doomusb::hostPortFor(variant);

#if !DOOM_USB_HOST_AVAILABLE
  (void)port;
  Serial.println("[doom] USB input: this chip has no USB host controller");
  return;
#else
  if (!port.hostCapable) {
    Serial.println(
        "[doom] USB input: this board has no host-capable USB port; "
        "touch and BOOT only");
    return;
  }

  // USB_PHY_TARGET_UTMI, emphatically not USB_PHY_TARGET_INT. The two are the
  // P4's two PHYs: UTMI belongs to the high-speed OTG controller on root hub
  // port 1, INT is the full-speed FSLS one on port 0. usb_new_phy() promotes a
  // request for INT to UTMI only in DEVICE mode (verified in the disassembly of
  // usb_phy.c.obj in the core's libusb.a: the promotion is gated on
  // otg_mode == USB_OTG_MODE_DEVICE), so in host mode INT stays INT. That would
  // be wrong twice over: the PHY would not be the one rhport 1 drives, so
  // nothing could ever enumerate, and bringing up the OTG internal PHY also
  // claims its fixed pads, GPIO26 (DM) and GPIO27 (DP) -- which on all three P4
  // carriers are the backlight and the panel reset.
  usb_phy_config_t phy_config = {};
  phy_config.controller = USB_PHY_CTRL_OTG;
  phy_config.target = USB_PHY_TARGET_UTMI;
  phy_config.otg_mode = USB_OTG_MODE_HOST;
  phy_config.otg_speed = kPhySpeed;
  phy_config.ext_io_conf = nullptr;
  phy_config.otg_io_conf = nullptr;
  if (usb_new_phy(&phy_config, &s_phy) != ESP_OK) {
    s_phy = nullptr;
    Serial.println("[doom] USB input: PHY unavailable; touch and BOOT only");
    return;
  }

  // Ask every keyboard and mouse for the boot protocol. Its report layout is
  // fixed by the USB HID specification, which is what lets the decoding be
  // plain byte arithmetic instead of a report-descriptor parser.
  tuh_hid_set_default_protocol(HID_PROTOCOL_BOOT);

  // The host stack's own entry, never tusb_init(): that is TinyUSB's role
  // dispatcher, which also calls the device stack's init, and that reference
  // alone keeps the device class drivers' buffers in the image (see
  // __wrap_dcd_int_handler above for the other edge and what they cost).
  // test_usb_host_init.cpp holds this.
  tusb_rhport_init_t rh_init = {};
  rh_init.role = TUSB_ROLE_HOST;
  rh_init.speed = kHostSpeed;
  if (!tuh_rhport_init(kHostRhPort, &rh_init)) {
    usb_del_phy(s_phy);
    s_phy = nullptr;
    Serial.println(
        "[doom] USB input: host stack would not start; touch and BOOT only");
    return;
  }

  memset(s_interface, 0, sizeof(s_interface));
  s_keyboard.reset();
  s_mouse.reset();
  s_queue.clear();
  s_started = true;

  Serial.println("[doom] USB input ready: keyboard and mouse on the USB host port");
  if (!port.suppliesVbus) {
    // Said plainly, because on such a board a correct firmware and a working
    // keyboard still produce nothing: the port never powers the device.
    Serial.println(
        "[doom] USB input: this board does not supply 5 V on that port; "
        "use a powered hub or a self-powered keyboard");
  }
#endif
}

extern "C" void doom_usb_input_service(void) {
#if DOOM_USB_HOST_AVAILABLE
  if (!s_started) return;
  // Non-blocking: process whatever is already queued and return.
  tuh_task_ext(0, false);
#endif
}

extern "C" void doom_usb_input_poll(int menu_context) {
#if !DOOM_USB_HOST_AVAILABLE
  (void)menu_context;
#else
  if (!s_started) return;
  tuh_task_ext(0, false);

  const doomusb::Context context = menu_context != 0
                                       ? doomusb::Context::Menu
                                       : doomusb::Context::Gameplay;

  doomusb::KeyEvent events[doomusb::KeyboardTracker::MAX_EVENTS];
  doomusb::ReportQueue::Entry report;
  while (s_queue.pop(report)) {
    if (report.device == doomusb::Device::Keyboard) {
      emit(events,
           s_keyboard.apply(report.data, report.length, context, events,
                            doomusb::KeyboardTracker::MAX_EVENTS));
    } else if (report.device == doomusb::Device::Mouse) {
      emit(events, s_mouse.apply(report.data, report.length, events,
                                 doomusb::MouseTracker::MAX_EVENTS));
    }
  }

  // A wheel notch is a complete press and release in this one poll: the engine
  // latches a weapon change from the key-down event itself (G_Responder sets
  // next_weapon), so unlike the movement keys it needs no hold.
  const int notch = s_mouse.takeWheelNotch();
  if (notch != 0) {
    const unsigned char key =
        (unsigned char)(notch > 0 ? key_nextweapon : key_prevweapon);
    if (key != 0) {
      push_key(key, 1);
      push_key(key, 0);
    }
  }
#endif
}

extern "C" void doom_usb_input_reassert(void) {
#if DOOM_USB_HOST_AVAILABLE
  if (!s_started) return;
  doomusb::KeyEvent events[doomusb::KeyboardTracker::MAX_EVENTS];
  emit(events, s_keyboard.reassertHeld(
                   events, doomusb::KeyboardTracker::MAX_EVENTS));
  emit(events,
       s_mouse.reassertHeld(events, doomusb::KeyboardTracker::MAX_EVENTS));
#endif
}

extern "C" bool doom_usb_input_take_mouse(int* dx, int* dy) {
  if (dx == nullptr || dy == nullptr) return false;
  *dx = 0;
  *dy = 0;
#if DOOM_USB_HOST_AVAILABLE
  if (!s_started) return false;
  s_mouse.takeMovement(dx, dy);
  return *dx != 0 || *dy != 0;
#else
  return false;
#endif
}

// ---- TinyUSB HID host callbacks -----------------------------------------
//
// The Arduino core defines these as weak no-ops, so these definitions replace
// them for the whole image. They are harmless in a build that never installs
// the host stack: nothing calls them.

#if DOOM_USB_HOST_AVAILABLE

extern "C" void tuh_hid_mount_cb(uint8_t dev_addr, uint8_t idx,
                                 uint8_t const* report_desc,
                                 uint16_t desc_len) {
  (void)report_desc;
  (void)desc_len;
  if (idx >= CFG_TUH_HID) return;

  const uint8_t protocol = tuh_hid_interface_protocol(dev_addr, idx);
  if (protocol == HID_ITF_PROTOCOL_KEYBOARD) {
    s_interface[idx] = doomusb::Device::Keyboard;
    Serial.println("[doom] USB keyboard connected");
  } else if (protocol == HID_ITF_PROTOCOL_MOUSE) {
    s_interface[idx] = doomusb::Device::Mouse;
    Serial.println("[doom] USB mouse connected");
  } else {
    // A device with no boot interface (a gamepad, a keyboard's media keys)
    // would need its report descriptor parsed to be understood. Say so rather
    // than feeding the engine bytes whose meaning is a guess.
    s_interface[idx] = doomusb::Device::None;
    Serial.println("[doom] USB device ignored: not a boot keyboard or mouse");
    return;
  }

  if (!tuh_hid_receive_report(dev_addr, idx)) {
    Serial.println("[doom] USB input: could not start reading reports");
  }
}

extern "C" void tuh_hid_umount_cb(uint8_t dev_addr, uint8_t idx) {
  (void)dev_addr;
  if (idx >= CFG_TUH_HID) return;
  const doomusb::Device device = s_interface[idx];
  s_interface[idx] = doomusb::Device::None;
  if (device == doomusb::Device::None) return;

  // Drop what it had already sent before releasing what it held: folding those
  // queued reports afterwards would press keys again that nothing can release.
  s_queue.dropDevice(device);

  // Release what the unplugged device was holding, or the player keeps walking
  // (or firing) with nothing pressed.
  doomusb::KeyEvent events[doomusb::KeyboardTracker::MAX_EVENTS];
  if (device == doomusb::Device::Keyboard) {
    emit(events, s_keyboard.releaseAll(
                     events, doomusb::KeyboardTracker::MAX_EVENTS));
    Serial.println("[doom] USB keyboard disconnected");
  } else {
    emit(events,
         s_mouse.releaseAll(events, doomusb::KeyboardTracker::MAX_EVENTS));
    Serial.println("[doom] USB mouse disconnected");
  }
}

extern "C" void tuh_hid_report_received_cb(uint8_t dev_addr, uint8_t idx,
                                           uint8_t const* report,
                                           uint16_t len) {
  if (idx < CFG_TUH_HID && report != nullptr) {
    s_queue.push(s_interface[idx], report, len);
  }
  // Re-arm regardless, or this interface goes silent after one report.
  tuh_hid_receive_report(dev_addr, idx);
}

#endif  // DOOM_USB_HOST_AVAILABLE

#endif  // ESPDISP_DOOM_RUNTIME
