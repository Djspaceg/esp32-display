// Hardware-free half of Quake's input and frame placement: what a touch, a
// BOOT press or a USB key means to the engine, and how large the frame is and
// where it sits on the panel.
//
// C++ with no Arduino, IDF or engine headers beyond the two key tables, so the
// host suite (firmware/test/test_quake_input.cpp) runs it directly. The
// hardware sampling lives in quake_hw_bridge.cpp.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "../engine/quakekeys.h"
#include "doomkeys.h"

namespace quakeinput {

// ---- Frame placement -----------------------------------------------------

// The engine's base frame, and the one every panel that takes it at 2x or more
// renders (the P4 carriers).
constexpr int RENDER_WIDTH = 320;
constexpr int RENDER_HEIGHT = 240;
// On a panel that takes the base frame only at 1x (the S3 boards) the frame
// is rendered larger instead, 4k x 3k, up to this k: 368x276, which a frame
// on the S3 renders at about the base frame's rate once the panel write runs
// beside the next frame (quake_hw_bridge.cpp).
constexpr int MAX_ONE_X_K = 92;

struct FrameLayout {
  int scale;         // whole-pixel scale, 0 when the panel cannot hold one copy
  int renderWidth;   // the engine's frame
  int renderHeight;
  int width;         // scaled frame
  int height;
  int x;             // its top-left corner on the panel
  int y;
};

// The largest whole-pixel scale of the base frame that fits, centred. Whole
// pixels keep the software renderer's output sharp and make the scaler a plain
// copy; 2x fills 640x480 of the 720x720 4B and 4C and of the 800x800 3.4C
// (whose round glass still shows all of it: the 3.4C's 800-pixel circle has
// room for 640x480).
//
// At 1x the frame grows to the largest 4:3 that the panel shows whole: on
// round glass that is the rectangle inside the circle (diagonal 5k at most the
// diameter), so the 1.75C's 466 pixels give 368x276. Never below the base
// frame, whose 320x200 menus Quake draws in the middle of whatever it gets:
// the 1.85C's 360-pixel circle is too small for 4:3 at 320, so it keeps
// 320x240 and loses the corners.
constexpr FrameLayout frameLayout(int panelWidth, int panelHeight,
                                  bool round = false) {
  const int sx = panelWidth / RENDER_WIDTH;
  const int sy = panelHeight / RENDER_HEIGHT;
  const int s = sx < sy ? sx : sy;
  if (s <= 0) return FrameLayout{0, 0, 0, 0, 0, 0, 0};
  int rw = RENDER_WIDTH;
  int rh = RENDER_HEIGHT;
  if (s == 1) {
    const int side = panelWidth < panelHeight ? panelWidth : panelHeight;
    const int kw = round ? side / 5 : panelWidth / 4;
    const int kh = round ? side / 5 : panelHeight / 3;
    int k = (kw < kh ? kw : kh) & ~1;
    if (k > MAX_ONE_X_K) k = MAX_ONE_X_K;
    if (k > RENDER_WIDTH / 4) {
      rw = 4 * k;
      rh = 3 * k;
    }
  }
  // The origin is even: the 1.75C's CO5300 takes windows only from even
  // columns and rows.
  return FrameLayout{s, rw, rh, rw * s, rh * s,
                     ((panelWidth - rw * s) / 2) & ~1,
                     ((panelHeight - rh * s) / 2) & ~1};
}

// ---- Key events ------------------------------------------------------------

struct KeyEvent {
  int key;
  bool down;
};

// ---- USB keyboard and mouse ----------------------------------------------
//
// The USB host glue is Doom's (firmware/doom/src/platform/doom_usb_input.*):
// it decodes boot-protocol reports into Doom key codes. Polled in its menu
// context, every letter arrives as itself, so only Doom's special codes need
// translating here. Ctrl and the left button both arrive as Doom's fire key,
// and Space and the right button both as its use key, which Quake's defaults
// make attack and jump.

constexpr int quakeKeyForDoomKey(int key) {
  switch (key) {
    case KEY_UPARROW: return K_UPARROW;
    case KEY_DOWNARROW: return K_DOWNARROW;
    case KEY_LEFTARROW: return K_LEFTARROW;
    case KEY_RIGHTARROW: return K_RIGHTARROW;
    case KEY_FIRE: return K_CTRL;
    case KEY_USE: return K_SPACE;
    case KEY_RSHIFT: return K_SHIFT;
    case KEY_RALT: return K_ALT;
    case KEY_ESCAPE: return K_ESCAPE;
    case KEY_ENTER: return K_ENTER;
    case KEY_TAB: return K_TAB;
    case KEY_BACKSPACE: return K_BACKSPACE;
    case KEY_PAUSE: return K_PAUSE;
    case KEY_F11: return K_F11;
    case KEY_F12: return K_F12;
    default: break;
  }
  if (key >= KEY_F1 && key <= KEY_F10) return K_F1 + (key - KEY_F1);
  // Letters, digits and the punctuation Doom passes through ('-', '=', ',',
  // '.', '/') are the same ASCII codes in both engines.
  if (key >= ' ' && key < 127) return key;
  return 0;
}

// Doom's mouse sense is "positive y walks forward"; Quake's is screen
// coordinates, where moving the mouse away from you is negative y.
constexpr int quakeMouseY(int doomDy) { return -doomDy; }

// The keys the wheel sends, bound to next and previous weapon at start
// (QUAKE_STARTUP_COMMANDS in quake_mode.cpp).
constexpr int WHEEL_NEXT_KEY = ']';
constexpr int WHEEL_PREV_KEY = '[';

// ---- BOOT ------------------------------------------------------------------
//
// The same tiers as Doom's: a short press, a longer one, and a 3 s hold that
// leaves the game. A short press is Escape (open or back out of a menu); the
// longer one is Enter, so a menu can be driven with BOOT alone.

constexpr uint32_t BOOT_DEBOUNCE_MS = 30;
constexpr uint32_t BOOT_LONG_MS = 600;
constexpr uint32_t BOOT_EXIT_MS = 3000;

enum class BootAction : uint8_t { None, Escape, Enter, Exit };

class BootButton {
 public:
  // Called every poll with the pin's state. Returns what just happened.
  BootAction update(bool down, uint32_t now) {
    if (down && !down_) {
      down_ = true;
      exited_ = false;
      downAt_ = now;
      return BootAction::None;
    }
    if (down && down_) {
      if (!exited_ && now - downAt_ >= BOOT_EXIT_MS) {
        exited_ = true;
        return BootAction::Exit;
      }
      return BootAction::None;
    }
    if (!down && down_) {
      down_ = false;
      const uint32_t held = now - downAt_;
      if (exited_) return BootAction::None;
      if (held >= BOOT_EXIT_MS) return BootAction::Exit;
      if (held >= BOOT_LONG_MS) return BootAction::Enter;
      if (held >= BOOT_DEBOUNCE_MS) return BootAction::Escape;
    }
    return BootAction::None;
  }

 private:
  bool down_ = false;
  bool exited_ = false;
  uint32_t downAt_ = 0;
};

// ---- Touch -----------------------------------------------------------------
//
// One snapshot per poll, in panel coordinates, as the shared gesture tracker
// classifies it (see doom_touch_bridge.h for the same contract on Doom's side).
enum class Swipe : uint8_t { None, Left, Right, Up, Down };

struct TouchSnapshot {
  bool pressed;
  bool secondPressed;
  int x, y;              // current point
  int startX, startY;    // where this press began
  bool pressStarted;     // a new press began since the last poll
  bool tap;              // a single tap completed
  bool doubleTap;        // a double tap completed (the second tap)
  Swipe swipe;           // a swipe completed
};

// Movement keys the touch path binds at start (QUAKE_STARTUP_COMMANDS).
constexpr int TOUCH_FORWARD_KEY = 'w';
constexpr int TOUCH_BACK_KEY = 's';
constexpr int TOUCH_LEFT_KEY = 'a';
constexpr int TOUCH_RIGHT_KEY = 'd';

// Drag distance, in panel pixels, before the left-half stick moves.
constexpr int STICK_DEADZONE_PX = 24;
// Panel pixels of right-half drag per mouse count. The engine's sensitivity
// cvar scales it further.
constexpr int LOOK_PX_PER_COUNT = 2;

// Like Doom's P4 layout: in play the left half is a movement stick and the
// right half aims (drag), fires (tap), jumps (double tap) and changes weapon
// (vertical swipe); a second finger runs. In a menu or the console every swipe
// is an arrow key and a tap is Enter.
class TouchControls {
 public:
  static constexpr size_t MAX_EVENTS = 12;

  // Fills `out` with this poll's key events and adds right-half drag to
  // *mouseX/*mouseY. Returns the number of events.
  size_t apply(const TouchSnapshot& t, bool inMenu, int panelWidth,
               KeyEvent* out, int* mouseX, int* mouseY) {
    size_t n = 0;
    if (inMenu) {
      // Leaving play mid-drag must not leave the player walking.
      n = releaseHeld(out, n);
      lookActive_ = false;
      const int key = t.swipe == Swipe::Up      ? K_UPARROW
                      : t.swipe == Swipe::Down  ? K_DOWNARROW
                      : t.swipe == Swipe::Left  ? K_LEFTARROW
                      : t.swipe == Swipe::Right ? K_RIGHTARROW
                      : (t.tap || t.doubleTap)  ? K_ENTER
                                                : 0;
      if (key != 0) {
        out[n++] = KeyEvent{key, true};
        out[n++] = KeyEvent{key, false};
      }
      return n;
    }

    const bool moveZone = t.startX < panelWidth / 2;
    if (t.pressStarted) {
      lastX_ = t.x;
      lastY_ = t.y;
      lookActive_ = !moveZone;
    }

    // Stick: held keys follow the drag from where the press began.
    bool fwd = false, back = false, left = false, right = false;
    if (t.pressed && moveZone) {
      const int dx = t.x - t.startX;
      const int dy = t.y - t.startY;
      fwd = dy < -STICK_DEADZONE_PX;
      back = dy > STICK_DEADZONE_PX;
      left = dx < -STICK_DEADZONE_PX;
      right = dx > STICK_DEADZONE_PX;
    }
    n = setHeld(forward_, fwd, TOUCH_FORWARD_KEY, out, n);
    n = setHeld(back_, back, TOUCH_BACK_KEY, out, n);
    n = setHeld(left_, left, TOUCH_LEFT_KEY, out, n);
    n = setHeld(right_, right, TOUCH_RIGHT_KEY, out, n);
    n = setHeld(run_, t.pressed && t.secondPressed, K_SHIFT, out, n);

    // Look: relative drag on the right half, whole counts only so slow drags
    // are not lost to rounding.
    if (t.pressed && lookActive_) {
      const int cx = (t.x - lastX_) / LOOK_PX_PER_COUNT;
      const int cy = (t.y - lastY_) / LOOK_PX_PER_COUNT;
      *mouseX += cx;
      *mouseY += cy;
      lastX_ += cx * LOOK_PX_PER_COUNT;
      lastY_ += cy * LOOK_PX_PER_COUNT;
    }
    if (!t.pressed) lookActive_ = false;

    if (!moveZone) {
      const int key = t.doubleTap               ? K_SPACE
                      : t.tap                   ? K_MOUSE1
                      : t.swipe == Swipe::Up    ? WHEEL_NEXT_KEY
                      : t.swipe == Swipe::Down  ? WHEEL_PREV_KEY
                                                : 0;
      if (key != 0) {
        // Down and up in one poll still counts: Quake's buttons latch the
        // press ("impulse down") until the next move is sent.
        out[n++] = KeyEvent{key, true};
        out[n++] = KeyEvent{key, false};
      }
    }
    return n;
  }

  // Releases every held key, for an unknown state (a lost touch controller).
  size_t releaseAll(KeyEvent* out) {
    lookActive_ = false;
    return releaseHeld(out, 0);
  }

 private:
  static size_t setHeld(bool& held, bool want, int key, KeyEvent* out,
                        size_t n) {
    if (held != want) {
      held = want;
      out[n++] = KeyEvent{key, want};
    }
    return n;
  }

  size_t releaseHeld(KeyEvent* out, size_t n) {
    n = setHeld(forward_, false, TOUCH_FORWARD_KEY, out, n);
    n = setHeld(back_, false, TOUCH_BACK_KEY, out, n);
    n = setHeld(left_, false, TOUCH_LEFT_KEY, out, n);
    n = setHeld(right_, false, TOUCH_RIGHT_KEY, out, n);
    n = setHeld(run_, false, K_SHIFT, out, n);
    return n;
  }

  bool forward_ = false, back_ = false, left_ = false, right_ = false;
  bool run_ = false;
  bool lookActive_ = false;
  int lastX_ = 0, lastY_ = 0;
};

// ---- Key queue ---------------------------------------------------------------

// What QG_GetKey drains. Single producer and consumer on the Quake task.
class KeyQueue {
 public:
  static constexpr size_t CAPACITY = 64;

  // False when full; the event is dropped.
  bool push(int key, bool down) {
    const size_t next = (head_ + 1) % CAPACITY;
    if (next == tail_ || key <= 0) return false;
    events_[head_] = KeyEvent{key, down};
    head_ = next;
    return true;
  }

  bool pop(KeyEvent& out) {
    if (tail_ == head_) return false;
    out = events_[tail_];
    tail_ = (tail_ + 1) % CAPACITY;
    return true;
  }

 private:
  KeyEvent events_[CAPACITY] = {};
  size_t head_ = 0;
  size_t tail_ = 0;
};

}  // namespace quakeinput
