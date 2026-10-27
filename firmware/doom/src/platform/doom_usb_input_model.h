// Hardware-free half of the USB keyboard and mouse support: which carriers can
// host a device, and what a HID boot report means to Doom.
//
// Everything here is pure logic over plain bytes so it can be host tested
// (firmware/test/test_usb_input.cpp) without TinyUSB, Arduino or a board. The
// TinyUSB glue that feeds it lives in doom_usb_input.cpp.
//
// The report layouts are the USB HID boot protocol ones, which is what the
// firmware asks every keyboard and mouse for, so the fields are fixed:
//   keyboard: modifier, reserved, keycode[6]   (8 bytes)
//   mouse:    buttons, dx, dy, wheel, pan      (3 bytes or more)
// Those are the same structs TinyUSB declares as hid_keyboard_report_t and
// hid_mouse_report_t; the numbers are repeated here rather than included so
// this header stays free of the core's headers.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include <board_config.h>

#include "doomkeys.h"

namespace doomusb {

// ---- Per-board hosting ---------------------------------------------------

/// What one carrier's USB wiring can actually do for an input device.
///
/// `hostCapable` means a host-capable USB PHY of the chip reaches a connector
/// a device can be plugged into. `suppliesVbus` means the board itself drives
/// 5 V out to that connector; where it is false the device must bring its own
/// power (a powered hub, or a cable that injects 5 V) or it will never
/// enumerate, however correct the firmware is.
struct HostPort {
  bool hostCapable;
  bool suppliesVbus;
};

/// Settled from each board's schematic; the evidence, and what is still only a
/// graphical read, are in docs/usb-host-ports.md.
///
/// P4 carriers: the chip's USB 2.0 high-speed OTG pins (package pin 49 = DM,
/// pin 50 = DP) reach a connector on all three, and none of them flash or log
/// over it -- every P4 board here talks to the computer through a CH343P UART
/// bridge on a separate connector (U6/H1 on the 4B, U5/H5 on the XC) -- so
/// hosting costs nothing.
///   - 4B: the second Type-C (H2, nets USBD_P/USBD_N, silkscreened USB-OTG).
///     Its VBUS is an input only: CC1/CC2 carry 5.1K pulldowns (R2/R3), so the
///     port permanently advertises itself as a sink, and USB1_5V reaches the
///     board only through Q3 (AO3401), which its gate circuit (U3 MMDT3906DW
///     with R30 51K and R31 10K referencing VCC_5V) holds off whenever the port
///     is the unpowered one. There is no boost, no load switch and no VBUS
///     GPIO. The board cannot power a keyboard.
///   - 4C and 3.4C (the shared XC schematic, three USB connectors: H5 for the
///     CH343P, H1 carrying the serial-JTAG pair, and J3): a dedicated USB type
///     A receptacle (J3) whose VBUS is VBUS_OUT, driven from VCC_5V by U10
///     (DIO7003HEST5 load switch) whose enable is tied high through R12 with
///     its pulldown R53 unpopulated. 5 V is therefore present whenever the
///     board itself is powered, with no firmware control -- though the current
///     available to the device is whatever the upstream Type-C supplies, since
///     VCC_5V is itself OR-ed from H5 and H1 through AO3401 pass FETs.
///
/// S3 carriers: the chip multiplexes USB-Serial-JTAG and USB-OTG onto one
/// D-/D+ pair (GPIO19/GPIO20), and on every S3 board here that pair goes to the
/// single USB-C the board is powered, flashed and logged through. Hosting would
/// therefore cost the board its only link to the computer, and none of them can
/// power the device either: each Type-C VBUS enters through a Schottky
/// (MBR230LSFT1G on the 0.85, 1.54, 1.9 and 1.85C) or straight into the
/// AXP2101's VBUS input pin (1.75C), every switching part on board is a buck or
/// a charger, and no board has a boost or an OTG power path. The Elecrow knob
/// is the same picture: its only 5 V comes in on the MX1.25 connector. The S3
/// 1.3 cannot host at all -- its connector's data pins land on a CH343P bridge
/// and GPIO19/GPIO20 are spent on reset control and the backlight. So hosting
/// stays off for all of them.
/// The carrier's own descriptor says (carrier.usb_host, generated into
/// GENERATED_USB_HOSTS); a board with no entry has no host port.
inline HostPort hostPortFor(board::Variant variant) {
  const board::GeneratedUsbHost *port = board::generatedUsbHost(variant);
  return port == nullptr ? HostPort{false, false}
                         : HostPort{port->hostCapable, port->suppliesVbus};
}

/// Whether this firmware brings the USB host stack up at all on a carrier.
inline bool inputSupported(board::Variant variant) {
  return hostPortFor(variant).hostCapable;
}

// ---- HID usage ids ------------------------------------------------------

enum : uint8_t {
  USAGE_NONE = 0x00,
  USAGE_A = 0x04,
  USAGE_D = 0x07,
  USAGE_S = 0x16,
  USAGE_W = 0x1A,
  USAGE_Z = 0x1D,
  USAGE_1 = 0x1E,
  USAGE_7 = 0x24,
  USAGE_0 = 0x27,
  USAGE_ENTER = 0x28,
  USAGE_ESCAPE = 0x29,
  USAGE_BACKSPACE = 0x2A,
  USAGE_TAB = 0x2B,
  USAGE_SPACE = 0x2C,
  USAGE_MINUS = 0x2D,
  USAGE_EQUAL = 0x2E,
  USAGE_COMMA = 0x36,
  USAGE_PERIOD = 0x37,
  USAGE_SLASH = 0x38,
  USAGE_F1 = 0x3A,
  USAGE_F10 = 0x43,
  USAGE_PAUSE = 0x48,
  USAGE_ARROW_RIGHT = 0x4F,
  USAGE_ARROW_LEFT = 0x50,
  USAGE_ARROW_DOWN = 0x51,
  USAGE_ARROW_UP = 0x52,
  USAGE_KEYPAD_SUBTRACT = 0x56,
  USAGE_KEYPAD_ADD = 0x57,
  USAGE_KEYPAD_ENTER = 0x58,
};

/// Keyboard modifier bits, in report byte 0.
enum : uint8_t {
  MOD_LEFTCTRL = 0x01,
  MOD_LEFTSHIFT = 0x02,
  MOD_LEFTALT = 0x04,
  MOD_RIGHTCTRL = 0x10,
  MOD_RIGHTSHIFT = 0x20,
  MOD_RIGHTALT = 0x40,
};

/// Mouse button bits, in report byte 0.
enum : uint8_t {
  MOUSE_LEFT = 0x01,
  MOUSE_RIGHT = 0x02,
  MOUSE_MIDDLE = 0x04,
};

// ---- Keyboard ----------------------------------------------------------

/// One key transition to hand to the engine, in the engine's own key space.
struct KeyEvent {
  unsigned char key;
  bool pressed;
};

/// Where a key press lands. Doom reads letters as text while a menu is open
/// (save-game names), so the movement letters only mean movement outside one.
enum class Context {
  Gameplay,
  Menu,
};

/// The Doom key one HID usage id stands for, or 0 when this firmware ignores it.
constexpr unsigned char doomKeyForUsage(uint8_t usage, Context context) {
  // Inside a menu every letter is itself, so a save-game name can be typed and
  // the engine's own letter prompts (the y/n of a quit confirmation) work.
  if (context == Context::Menu && usage >= USAGE_A && usage <= USAGE_Z) {
    return (unsigned char)('a' + (usage - USAGE_A));
  }

  // In play only the movement four are mapped. Passing the rest through would
  // turn stray typing into cheat codes, and Doom binds nothing else to a letter.
  if (usage == USAGE_W) return (unsigned char)KEY_UPARROW;
  if (usage == USAGE_S) return (unsigned char)KEY_DOWNARROW;
  if (usage == USAGE_A) return (unsigned char)KEY_STRAFE_L;
  if (usage == USAGE_D) return (unsigned char)KEY_STRAFE_R;

  // Weapons 1-7 are the engine's own '1'..'7' bindings; 8, 9 and 0 are not
  // weapons in Doom but reach the menu as their own characters.
  if (usage >= USAGE_1 && usage <= USAGE_7) {
    return (unsigned char)('1' + (usage - USAGE_1));
  }
  if (usage == 0x25) return '8';
  if (usage == 0x26) return '9';
  if (usage == USAGE_0) return '0';

  // Function keys F1-F10 (help, save, load, volume, detail, quit...).
  if (usage >= USAGE_F1 && usage <= USAGE_F10) {
    return (unsigned char)(KEY_F1 + (usage - USAGE_F1));
  }

  switch (usage) {
    case USAGE_ARROW_UP: return (unsigned char)KEY_UPARROW;
    case USAGE_ARROW_DOWN: return (unsigned char)KEY_DOWNARROW;
    case USAGE_ARROW_LEFT: return (unsigned char)KEY_LEFTARROW;
    case USAGE_ARROW_RIGHT: return (unsigned char)KEY_RIGHTARROW;
    case USAGE_SPACE: return (unsigned char)KEY_USE;
    case USAGE_ESCAPE: return (unsigned char)KEY_ESCAPE;
    case USAGE_ENTER: return (unsigned char)KEY_ENTER;
    case USAGE_KEYPAD_ENTER: return (unsigned char)KEY_ENTER;
    case USAGE_BACKSPACE: return (unsigned char)KEY_BACKSPACE;
    case USAGE_TAB: return (unsigned char)KEY_TAB;
    case USAGE_PAUSE: return (unsigned char)KEY_PAUSE;
    // '.' and '/' are what M_ApplyPlatformDefaults binds the weapon-cycle
    // directions to, so they reach the engine as themselves.
    case USAGE_PERIOD: return '.';
    case USAGE_SLASH: return '/';
    case USAGE_COMMA: return ',';
    case USAGE_MINUS: return (unsigned char)KEY_MINUS;
    case USAGE_KEYPAD_SUBTRACT: return (unsigned char)KEY_MINUS;
    case USAGE_EQUAL: return (unsigned char)KEY_EQUALS;
    case USAGE_KEYPAD_ADD: return (unsigned char)KEY_EQUALS;
    default: return 0;
  }
}

/// The Doom key one modifier bit stands for. Ctrl fires, Shift runs and Alt is
/// the strafe modifier -- Doom's own defaults (key_fire, key_speed,
/// key_strafe), so a player's muscle memory carries over.
constexpr unsigned char doomKeyForModifier(uint8_t bit) {
  return (bit == MOD_LEFTCTRL || bit == MOD_RIGHTCTRL)
             ? (unsigned char)KEY_FIRE
         : (bit == MOD_LEFTSHIFT || bit == MOD_RIGHTSHIFT)
             ? (unsigned char)KEY_RSHIFT
         : (bit == MOD_LEFTALT || bit == MOD_RIGHTALT)
             ? (unsigned char)KEY_RALT
             : (unsigned char)0;
}

/// Folds boot-protocol keyboard reports into key-down and key-up events.
///
/// A boot report is a set, not a transition: it names the keys held right now.
/// This keeps the previous set so each report yields only the edges. It also
/// remembers the Doom key it emitted for every held usage, so a key held while
/// the engine moves between gameplay and a menu is released as whatever it was
/// pressed as -- otherwise holding W into a menu would leave KEY_UPARROW stuck
/// down forever.
class KeyboardTracker {
 public:
  // 6 keycode slots in a boot report plus the 3 distinct modifiers.
  static constexpr size_t MAX_HELD = 9;
  // Worst case in one report: every held key releases and a full new set
  // arrives.
  static constexpr size_t MAX_EVENTS = 2 * MAX_HELD;

  void reset() { held_count_ = 0; }

  /// Fold one report. Returns how many events were written to `out`, which must
  /// have room for MAX_EVENTS -- a smaller buffer is refused outright rather
  /// than truncated, because dropping an event while still updating the held
  /// set is how a key gets stranded down. A report shorter than 8 bytes is
  /// ignored too: a boot-protocol keyboard always sends 8, and a short one
  /// would otherwise be read past its end.
  size_t apply(const uint8_t* report, size_t length, Context context,
               KeyEvent* out, size_t capacity) {
    if (report == nullptr || length < 8 || out == nullptr) return 0;
    if (capacity < MAX_EVENTS) return 0;

    Held next[MAX_HELD];
    size_t next_count = 0;

    const uint8_t modifiers = report[0];
    static const uint8_t kModifierBits[] = {MOD_LEFTCTRL | MOD_RIGHTCTRL,
                                            MOD_LEFTSHIFT | MOD_RIGHTSHIFT,
                                            MOD_LEFTALT | MOD_RIGHTALT};
    static const uint8_t kModifierRepresentative[] = {
        MOD_LEFTCTRL, MOD_LEFTSHIFT, MOD_LEFTALT};
    for (size_t i = 0; i < 3; ++i) {
      if ((modifiers & kModifierBits[i]) == 0) continue;
      const unsigned char key =
          doomKeyForModifier(kModifierRepresentative[i]);
      if (key == 0) continue;
      // Left and right of the same modifier are one logical key, identified by
      // the pair's mask so the two never double-count.
      const uint16_t id = (uint16_t)(0x100u | kModifierBits[i]);
      addHeld(next, next_count, id, keyFor(id, key));
    }

    for (size_t i = 0; i < 6; ++i) {
      const uint8_t usage = report[2 + i];
      // 0x01..0x03 are the rollover and POST-fail error codes, not keys.
      if (usage <= 0x03) continue;
      const unsigned char key = doomKeyForUsage(usage, context);
      if (key == 0) continue;
      addHeld(next, next_count, usage, keyFor(usage, key));
    }

    size_t emitted = 0;
    // Releases first: a report that swaps one key for another must release
    // before it presses, or a shared Doom key would end up released.
    for (size_t i = 0; i < held_count_; ++i) {
      if (contains(next, next_count, held_[i].id)) continue;
      push(out, capacity, emitted, KeyEvent{held_[i].key, false});
    }
    for (size_t i = 0; i < next_count; ++i) {
      if (contains(held_, held_count_, next[i].id)) continue;
      push(out, capacity, emitted, KeyEvent{next[i].key, true});
    }

    held_count_ = next_count;
    for (size_t i = 0; i < next_count; ++i) held_[i] = next[i];
    return emitted;
  }

  /// Release everything still held, for an unplugged keyboard. Without this a
  /// player who yanks the cable mid-stride keeps walking forever.
  size_t releaseAll(KeyEvent* out, size_t capacity) {
    if (out == nullptr || capacity < MAX_EVENTS) return 0;
    size_t emitted = 0;
    for (size_t i = 0; i < held_count_; ++i) {
      push(out, capacity, emitted, KeyEvent{held_[i].key, false});
    }
    held_count_ = 0;
    return emitted;
  }

  /// Press everything still held again, in the Doom keys it was pressed as.
  ///
  /// The touch and tilt path releases the movement keys whenever the engine
  /// leaves gameplay (dg_release_gameplay_keys), and those are the same engine
  /// keys a keyboard holds. A keyboard sends no report while its key set is
  /// unchanged, so without re-pressing them a key held across that boundary
  /// would be silently dead until the player let go and pressed it again.
  /// Re-pressing a key the engine already thinks is down is harmless: gameplay
  /// reads held state, not edges.
  size_t reassertHeld(KeyEvent* out, size_t capacity) {
    if (out == nullptr || capacity < MAX_EVENTS) return 0;
    size_t emitted = 0;
    for (size_t i = 0; i < held_count_; ++i) {
      push(out, capacity, emitted, KeyEvent{held_[i].key, true});
    }
    return emitted;
  }

  size_t heldCount() const { return held_count_; }

 private:
  struct Held {
    uint16_t id;        // HID usage, or 0x100|mask for a modifier pair
    unsigned char key;  // the Doom key emitted when it went down
  };

  static void addHeld(Held* list, size_t& count, uint16_t id,
                      unsigned char key) {
    if (count >= MAX_HELD) return;
    for (size_t i = 0; i < count; ++i) {
      if (list[i].id == id) return;
    }
    list[count].id = id;
    list[count].key = key;
    ++count;
  }

  /// The Doom key to carry for `id`: whatever it was pressed as if it is
  /// already held, otherwise what the current context maps it to. Without this
  /// a key held while the engine opens a menu would be released as the menu
  /// letter and left stuck down as the movement key.
  unsigned char keyFor(uint16_t id, unsigned char fresh) const {
    for (size_t i = 0; i < held_count_; ++i) {
      if (held_[i].id == id) return held_[i].key;
    }
    return fresh;
  }

  static bool contains(const Held* list, size_t count, uint16_t id) {
    for (size_t i = 0; i < count; ++i) {
      if (list[i].id == id) return true;
    }
    return false;
  }

  static void push(KeyEvent* out, size_t capacity, size_t& emitted,
                   KeyEvent event) {
    if (emitted >= capacity) return;
    out[emitted++] = event;
  }

  Held held_[MAX_HELD] = {};
  size_t held_count_ = 0;
};

// ---- Mouse -------------------------------------------------------------

/// How far one poll of mouse movement may turn the player. Doom multiplies the
/// horizontal delta by 8 for angleturn, so an unbounded report (or a burst of
/// them accumulated between polls) spins the view. The cap is the touch
/// joystick's maximum turn rate (TOUCH_TURN_MAX_MOUSE_DELTA in
/// doomgeneric_esp32.c.inc), so mouse and finger agree on the fastest turn.
constexpr int MOUSE_MAX_TURN_DELTA = 160;

/// The same for walking. Doom adds the vertical delta straight to `forward`,
/// which it then clamps to MAXPLMOVE (0x32 = 50, g_game.c.inc), so anything
/// past 50 in a tic is simply full speed. Capping at 50 rather than 160 keeps
/// the axis proportional over its whole useful range instead of saturating on
/// any ordinary flick of the wrist.
constexpr int MOUSE_MAX_WALK_DELTA = 50;

/// How many unspent wheel notches are kept. Doom's weapon cycle is one step per
/// tic however many notches arrived (G_Responder sets next_weapon, and
/// G_BuildTiccmd consumes it once), so notches are delivered one per poll; an
/// unbounded queue would turn one vigorous scroll into seconds of cycling.
constexpr int MOUSE_MAX_WHEEL_QUEUE = 4;

/// Folds mouse reports into the engine's one-tic mouse delta and the key
/// events its buttons stand for.
///
/// Buttons become key events rather than Doom's own mouse-button bitmask: the
/// engine's key path already holds, releases and reaches menus correctly, and
/// the existing touch code drives Fire and Use the same way.
class MouseTracker {
 public:
  static constexpr size_t MAX_EVENTS = 4;

  void reset() {
    dx_ = 0;
    dy_ = 0;
    wheel_ = 0;
    buttons_ = 0;
  }

  /// Fold one report: accumulate movement, and return the button edges.
  /// `capacity` must be at least MAX_EVENTS.
  size_t apply(const uint8_t* report, size_t length, KeyEvent* out,
               size_t capacity) {
    if (report == nullptr || length < 3 || out == nullptr) return 0;
    if (capacity < MAX_EVENTS) return 0;

    dx_ = clamp(dx_ + (int)(int8_t)report[1], MOUSE_MAX_TURN_DELTA);
    dy_ = clamp(dy_ + (int)(int8_t)report[2], MOUSE_MAX_WALK_DELTA);
    if (length >= 4) {
      wheel_ = clamp(wheel_ + (int)(int8_t)report[3], MOUSE_MAX_WHEEL_QUEUE);
    }

    const uint8_t buttons = report[0];
    size_t emitted = 0;
    emitButton(buttons, MOUSE_LEFT, (unsigned char)KEY_FIRE, out, capacity,
               emitted);
    emitButton(buttons, MOUSE_RIGHT, (unsigned char)KEY_USE, out, capacity,
               emitted);
    buttons_ = buttons;
    return emitted;
  }

  /// Release any held button, for an unplugged mouse.
  size_t releaseAll(KeyEvent* out, size_t capacity) {
    if (out == nullptr || capacity < MAX_EVENTS) return 0;
    size_t emitted = 0;
    emitButton(0, MOUSE_LEFT, (unsigned char)KEY_FIRE, out, capacity, emitted);
    emitButton(0, MOUSE_RIGHT, (unsigned char)KEY_USE, out, capacity, emitted);
    buttons_ = 0;
    dx_ = 0;
    dy_ = 0;
    wheel_ = 0;
    return emitted;
  }

  /// Take the accumulated movement in the engine's sense: positive x turns
  /// right, and positive y moves forward. A HID mouse reports y growing
  /// downwards (pulled towards the player), which is backwards for Doom's
  /// `forward += mousey`, so the vertical axis is inverted here. Doom has no
  /// free look, so vertical movement walks rather than tilting the view.
  void takeMovement(int* dx, int* dy) {
    *dx = dx_;
    *dy = -dy_;
    dx_ = 0;
    dy_ = 0;
  }

  /// Press any held button again. Same reason as KeyboardTracker::reassertHeld:
  /// the touch path releases Fire and Use when the engine leaves gameplay, and
  /// a mouse sends no report while its buttons do not change.
  size_t reassertHeld(KeyEvent* out, size_t capacity) {
    if (out == nullptr || capacity < MAX_EVENTS) return 0;
    size_t emitted = 0;
    if ((buttons_ & MOUSE_LEFT) != 0) {
      out[emitted++] = KeyEvent{(unsigned char)KEY_FIRE, true};
    }
    if ((buttons_ & MOUSE_RIGHT) != 0) {
      out[emitted++] = KeyEvent{(unsigned char)KEY_USE, true};
    }
    return emitted;
  }

  /// Take one wheel notch: +1 for the next weapon, -1 for the previous, 0 when
  /// the wheel has not moved. One at a time because the engine can only act on
  /// one weapon change per tic (see MOUSE_MAX_WHEEL_QUEUE).
  int takeWheelNotch() {
    if (wheel_ == 0) return 0;
    const int notch = wheel_ > 0 ? 1 : -1;
    wheel_ -= notch;
    return notch;
  }

 private:
  static int clamp(int value, int limit) {
    if (value > limit) return limit;
    if (value < -limit) return -limit;
    return value;
  }

  void emitButton(uint8_t buttons, uint8_t bit, unsigned char key,
                  KeyEvent* out, size_t capacity, size_t& emitted) {
    const bool was = (buttons_ & bit) != 0;
    const bool now = (buttons & bit) != 0;
    if (was == now || emitted >= capacity) return;
    out[emitted++] = KeyEvent{key, now};
  }

  int dx_ = 0;
  int dy_ = 0;
  int wheel_ = 0;
  uint8_t buttons_ = 0;
};

// ---- The queue between the host callbacks and the engine ----------------

/// Which device a queued report came from.
enum class Device : uint8_t { None, Keyboard, Mouse };

/// Reports waiting to be folded into engine events.
///
/// It exists because the engine polls input at most DOOM_TARGET_FPS times a
/// second while the host stack is serviced every millisecond or so, and a tap
/// of a key is two reports a few milliseconds apart. Without a queue the press
/// and its release could both land inside one engine poll and cancel out.
///
/// Full means the OLDEST report is dropped, not the newest. A boot report is an
/// absolute set of what is held, not a transition, so the newest is the
/// authoritative one; the oldest is at worst a transient that was never acted
/// on. Dropping the newest would throw away a key-up that the keyboard will
/// never send again, and leave that key down for the rest of the session.
class ReportQueue {
 public:
  static constexpr size_t CAPACITY = 32;
  static constexpr size_t MAX_REPORT = 8;

  struct Entry {
    Device device;
    uint8_t length;
    uint8_t data[MAX_REPORT];
  };

  void clear() {
    head_ = 0;
    tail_ = 0;
  }

  bool empty() const { return head_ == tail_; }

  size_t size() const {
    return (head_ + CAPACITY + 1 - tail_) % (CAPACITY + 1);
  }

  void push(Device device, const uint8_t* data, size_t length) {
    if (device == Device::None || data == nullptr || length == 0) return;
    if (size() == CAPACITY) dropOldest();
    Entry& slot = slots_[head_];
    slot.device = device;
    slot.length = (uint8_t)(length > MAX_REPORT ? MAX_REPORT : length);
    for (size_t i = 0; i < MAX_REPORT; ++i) {
      slot.data[i] = i < slot.length ? data[i] : 0;
    }
    head_ = advance(head_);
  }

  bool pop(Entry& out) {
    if (empty()) return false;
    out = slots_[tail_];
    tail_ = advance(tail_);
    return true;
  }

  /// Forget everything queued from one device, for an unplug.
  ///
  /// Required: the reports a keyboard sent just before the cable came out are
  /// still queued when its unmount releases what it held, and folding them
  /// afterwards would press those keys again with no device left to ever
  /// release them.
  void dropDevice(Device device) {
    const size_t kept_from = tail_;
    size_t write = tail_;
    for (size_t read = kept_from; read != head_; read = advance(read)) {
      if (slots_[read].device == device) continue;
      if (write != read) slots_[write] = slots_[read];
      write = advance(write);
    }
    head_ = write;
  }

 private:
  // One spare slot so a full queue is distinguishable from an empty one.
  static size_t advance(size_t index) { return (index + 1) % (CAPACITY + 1); }

  void dropOldest() { tail_ = advance(tail_); }

  Entry slots_[CAPACITY + 1] = {};
  size_t head_ = 0;
  size_t tail_ = 0;
};

}  // namespace doomusb
