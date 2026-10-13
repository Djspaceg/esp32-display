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
// is rendered at the panel's own size instead, square on a square panel, so
// the view fills the glass and its horizontal and vertical fields of view
// are equal. Quake keeps its 320-wide status bar and menus centred in it.
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
// At 1x the frame is the whole panel, even in both directions (the 1.75C's
// CO5300 takes windows only from even columns and rows): 466x466 on the
// 1.75C, 360x360 on the 1.85C. The round glass hides the corners, which the
// view's own corners can afford to lose.
//
// Or, when asked (wantWidth and wantHeight both nonzero), that size unscaled
// and centred, if the panel holds it and it is no smaller than the base frame,
// else the base frame: 372x280 or 320x240 inside the 1.75C's circle. Only that window is
// written to the panel. Sizes round down to even, and the origin to even, so a
// window that cannot sit exactly central sits a pixel up and left of centre.
constexpr FrameLayout frameLayout(int panelWidth, int panelHeight,
                                  int wantWidth = 0, int wantHeight = 0) {
  const int sx = panelWidth / RENDER_WIDTH;
  const int sy = panelHeight / RENDER_HEIGHT;
  const int s = sx < sy ? sx : sy;
  if (s <= 0) return FrameLayout{0, 0, 0, 0, 0, 0, 0};
  int rw = RENDER_WIDTH;
  int rh = RENDER_HEIGHT;
  if (s == 1) {
    const bool asked = wantWidth > 0 && wantHeight > 0;
    const bool fits = wantWidth >= RENDER_WIDTH && wantHeight >= RENDER_HEIGHT &&
                      wantWidth <= panelWidth && wantHeight <= panelHeight;
    // A request the panel cannot take (372x280 on the 1.85C's 360x360) falls
    // back to the base frame, whose status bar stays on round glass; no
    // request at all means the whole panel.
    rw = (!asked ? panelWidth : fits ? wantWidth : RENDER_WIDTH) & ~1;
    rh = (!asked ? panelHeight : fits ? wantHeight : RENDER_HEIGHT) & ~1;
  }
  // The origin is even: the 1.75C's CO5300 takes windows only from even
  // columns and rows.
  return FrameLayout{s, rw, rh, rw * s, rh * s,
                     ((panelWidth - rw * s) / 2) & ~1,
                     ((panelHeight - rh * s) / 2) & ~1};
}

// ---- Render size choices --------------------------------------------------

// What Quake's Video Options offers on a 1x panel (the S3 boards): requests
// for frameLayout, the first the default. 0x0 is the whole panel. A panel
// that scales (the P4's 2x) has nothing to choose.
struct RenderChoice {
  int width;
  int height;
  const char* label;
};
constexpr int MAX_RENDER_CHOICES = 3;

inline int renderChoices(int panelWidth, int panelHeight,
                         RenderChoice out[MAX_RENDER_CHOICES]) {
  if (frameLayout(panelWidth, panelHeight).scale != 1) return 0;
  int n = 0;
  if (panelWidth >= 372 && panelHeight >= 280) {
    out[n++] = RenderChoice{372, 280, "372x280"};
  }
  out[n++] = RenderChoice{0, 0, "full panel"};
  out[n++] = RenderChoice{RENDER_WIDTH, RENDER_HEIGHT, "320x240"};
  return n;
}

/// Which of renderChoices() a request is, or -1.
inline int renderChoiceIndex(int panelWidth, int panelHeight, int width,
                             int height) {
  RenderChoice choices[MAX_RENDER_CHOICES];
  const int n = renderChoices(panelWidth, panelHeight, choices);
  for (int i = 0; i < n; ++i) {
    if (choices[i].width == width && choices[i].height == height) return i;
  }
  return -1;
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
