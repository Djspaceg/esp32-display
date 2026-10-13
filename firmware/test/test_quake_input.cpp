// Host tests for Quake's input and frame placement model
// (firmware/quake/src/platform/quake_input_model.h).
#include <cstdio>
#include <vector>

#include "../quake/src/platform/quake_input_model.h"

static int failures = 0;
#define CHECK(cond)                                                   \
  do {                                                                \
    if (!(cond)) {                                                    \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__,     \
                   __LINE__, #cond);                                  \
      ++failures;                                                     \
    }                                                                 \
  } while (0)

using namespace quakeinput;

namespace {

struct Poll {
  std::vector<KeyEvent> events;
  int mouseX = 0;
  int mouseY = 0;
};

Poll apply(TouchControls& controls, const TouchSnapshot& t, bool inMenu,
           int panelWidth = 720) {
  KeyEvent out[TouchControls::MAX_EVENTS];
  Poll poll;
  const size_t n =
      controls.apply(t, inMenu, panelWidth, out, &poll.mouseX, &poll.mouseY);
  CHECK(n <= TouchControls::MAX_EVENTS);
  poll.events.assign(out, out + n);
  return poll;
}

bool has(const Poll& poll, int key, bool down) {
  for (const KeyEvent& e : poll.events) {
    if (e.key == key && e.down == down) return true;
  }
  return false;
}

TouchSnapshot press(int x, int y) {
  TouchSnapshot t = {};
  t.pressed = true;
  t.pressStarted = true;
  t.x = t.startX = x;
  t.y = t.startY = y;
  return t;
}

}  // namespace

int main() {
  // --- frame placement --------------------------------------------------------
  {
    const FrameLayout l = frameLayout(720, 720);  // 4B and 4C
    CHECK(l.scale == 2 && l.width == 640 && l.height == 480);
    CHECK(l.renderWidth == 320 && l.renderHeight == 240);
    CHECK(l.x == 40 && l.y == 120);
    const FrameLayout r = frameLayout(800, 800);  // 3.4C, round
    CHECK(r.scale == 2 && r.x == 80 && r.y == 160);
    CHECK(r.renderWidth == 320 && r.renderHeight == 240);
    // The 3.4C's glass is round: all four corners of the frame are inside
    // its 400-pixel radius.
    const int dx = r.width / 2, dy = r.height / 2;
    CHECK(dx * dx + dy * dy <= 400 * 400);
    // The 1.75C: the whole 466x466 panel at 1x, from (0,0).
    const FrameLayout a = frameLayout(466, 466);
    CHECK(a.scale == 1 && a.renderWidth == 466 && a.renderHeight == 466);
    CHECK(a.width == 466 && a.height == 466 && a.x == 0 && a.y == 0);
    // The 1.85C: its whole 360x360 panel.
    const FrameLayout q = frameLayout(360, 360);
    CHECK(q.scale == 1 && q.renderWidth == 360 && q.renderHeight == 360);
    CHECK(q.x == 0 && q.y == 0);
    // Odd sizes round down to even.
    const FrameLayout o = frameLayout(481, 323);
    CHECK(o.renderWidth == 480 && o.renderHeight == 322 && o.x == 0 && o.y == 0);
    // Asked-for 4:3 windows on the 1.75C, unscaled and centred. 372x280 is
    // the human's choice (its 465.6 px diagonal just fits the 466 px circle);
    // the even origin puts it at (46,92), a pixel up and left of centre.
    const FrameLayout b = frameLayout(466, 466, 372, 280);
    CHECK(b.scale == 1 && b.renderWidth == 372 && b.renderHeight == 280);
    CHECK(b.width == 372 && b.height == 280 && b.x == 46 && b.y == 92);
    const FrameLayout c = frameLayout(466, 466, 320, 240);
    CHECK(c.renderWidth == 320 && c.renderHeight == 240 && c.x == 72 && c.y == 112);
    // 0x0: the whole panel; an oversized or undersized request: the base frame.
    CHECK(frameLayout(466, 466, 0, 0).renderWidth == 466);
    CHECK(frameLayout(466, 466, 500, 280).renderWidth == 320);
    CHECK(frameLayout(466, 466, 300, 200).renderWidth == 320);
    // The 1.85C cannot take the 372x280 default: the base frame, not its
    // whole 360x360 panel, so the status bar stays on the round glass.
    const FrameLayout d = frameLayout(360, 360, 372, 280);
    CHECK(d.renderWidth == 320 && d.renderHeight == 240 && d.x == 20 && d.y == 60);
    // A request does not change a panel that scales (the P4's 2x).
    CHECK(frameLayout(720, 720, 372, 280).renderWidth == 320);
    // The render sizes offered in Quake's Video Options: on the 1.75C the
    // 372x280 default, the whole panel and 320x240; a request is each one's
    // frameLayout size.
    RenderChoice choices[MAX_RENDER_CHOICES];
    CHECK(renderChoices(466, 466, choices) == 3);
    CHECK(choices[0].width == 372 && choices[0].height == 280);
    CHECK(choices[1].width == 0 && choices[1].height == 0);
    CHECK(choices[2].width == 320 && choices[2].height == 240);
    CHECK(frameLayout(466, 466, choices[1].width, choices[1].height).renderWidth == 466);
    // The 1.85C's 360x360 cannot take 372x280: the whole panel and 320x240.
    CHECK(renderChoices(360, 360, choices) == 2);
    CHECK(choices[0].width == 0 && choices[1].width == 320);
    // A scaled panel (the P4) offers nothing: its size is fixed.
    CHECK(renderChoices(720, 720, choices) == 0);
    // Which choice a saved size is; anything else is -1.
    CHECK(renderChoiceIndex(466, 466, 372, 280) == 0);
    CHECK(renderChoiceIndex(466, 466, 0, 0) == 1);
    CHECK(renderChoiceIndex(466, 466, 320, 240) == 2);
    CHECK(renderChoiceIndex(466, 466, 400, 300) == -1);
    CHECK(frameLayout(960, 720).scale == 3);
    CHECK(frameLayout(960, 720).renderWidth == 320);
    CHECK(frameLayout(320, 240).scale == 1);
    CHECK(frameLayout(320, 240).renderWidth == 320);
    CHECK(frameLayout(320, 239).scale == 0);
    CHECK(frameLayout(0, 0).scale == 0);
  }

  // --- USB keys arrive as Doom codes ----------------------------------------
  CHECK(quakeKeyForDoomKey(KEY_UPARROW) == K_UPARROW);
  CHECK(quakeKeyForDoomKey(KEY_DOWNARROW) == K_DOWNARROW);
  CHECK(quakeKeyForDoomKey(KEY_LEFTARROW) == K_LEFTARROW);
  CHECK(quakeKeyForDoomKey(KEY_RIGHTARROW) == K_RIGHTARROW);
  CHECK(quakeKeyForDoomKey(KEY_FIRE) == K_CTRL);    // Ctrl, left button
  CHECK(quakeKeyForDoomKey(KEY_USE) == K_SPACE);    // Space, right button
  CHECK(quakeKeyForDoomKey(KEY_RSHIFT) == K_SHIFT);
  CHECK(quakeKeyForDoomKey(KEY_RALT) == K_ALT);
  CHECK(quakeKeyForDoomKey(KEY_ESCAPE) == K_ESCAPE);
  CHECK(quakeKeyForDoomKey(KEY_ENTER) == K_ENTER);
  CHECK(quakeKeyForDoomKey(KEY_BACKSPACE) == K_BACKSPACE);
  CHECK(quakeKeyForDoomKey(KEY_TAB) == K_TAB);
  CHECK(quakeKeyForDoomKey(KEY_PAUSE) == K_PAUSE);
  CHECK(quakeKeyForDoomKey(KEY_F1) == K_F1);
  CHECK(quakeKeyForDoomKey(KEY_F10) == K_F10);
  CHECK(quakeKeyForDoomKey(KEY_F12) == K_F12);
  CHECK(quakeKeyForDoomKey('w') == 'w');
  CHECK(quakeKeyForDoomKey('7') == '7');
  CHECK(quakeKeyForDoomKey('/') == '/');
  CHECK(quakeKeyForDoomKey(']') == ']');
  CHECK(quakeKeyForDoomKey(0) == 0);
  // Doom's strafe codes only come from its gameplay context, which Quake
  // never polls; they are not keys Quake binds.
  CHECK(quakeKeyForDoomKey(KEY_STRAFE_L) == 0);
  CHECK(quakeMouseY(5) == -5);
  CHECK(quakeMouseY(-3) == 3);

  // --- BOOT tiers ---------------------------------------------------------------
  {
    BootButton b;
    CHECK(b.update(true, 1000) == BootAction::None);
    CHECK(b.update(false, 1010) == BootAction::None);  // bounce
    CHECK(b.update(true, 2000) == BootAction::None);
    CHECK(b.update(false, 2100) == BootAction::Escape);
    CHECK(b.update(true, 3000) == BootAction::None);
    CHECK(b.update(false, 3700) == BootAction::Enter);
    CHECK(b.update(true, 4000) == BootAction::None);
    CHECK(b.update(true, 6999) == BootAction::None);
    // Exit fires while still held, once, and the release adds nothing.
    CHECK(b.update(true, 7000) == BootAction::Exit);
    CHECK(b.update(true, 9000) == BootAction::None);
    CHECK(b.update(false, 9100) == BootAction::None);
    // Across millis() wrap.
    CHECK(b.update(true, 0xFFFFFF00u) == BootAction::None);
    CHECK(b.update(false, 0x00000040u) == BootAction::Escape);
  }

  // --- touch in a menu ----------------------------------------------------------
  {
    TouchControls c;
    TouchSnapshot t = {};
    t.swipe = Swipe::Up;
    Poll p = apply(c, t, true);
    CHECK(p.events.size() == 2 && has(p, K_UPARROW, true) &&
          has(p, K_UPARROW, false));
    t.swipe = Swipe::Down;
    CHECK(has(apply(c, t, true), K_DOWNARROW, true));
    t.swipe = Swipe::Left;
    CHECK(has(apply(c, t, true), K_LEFTARROW, true));
    t.swipe = Swipe::Right;
    CHECK(has(apply(c, t, true), K_RIGHTARROW, true));
    t.swipe = Swipe::None;
    t.tap = true;
    CHECK(has(apply(c, t, true), K_ENTER, true));
    t.tap = false;
    CHECK(apply(c, t, true).events.empty());
  }

  // --- touch in play: the left-half stick ---------------------------------------
  {
    TouchControls c;
    TouchSnapshot t = press(100, 400);
    CHECK(apply(c, t, false).events.empty());  // inside the dead zone
    t.pressStarted = false;
    t.y = 400 - STICK_DEADZONE_PX - 1;          // up: forward
    Poll p = apply(c, t, false);
    CHECK(p.events.size() == 1 && has(p, TOUCH_FORWARD_KEY, true));
    CHECK(apply(c, t, false).events.empty());   // held, no repeats
    t.x = 100 + STICK_DEADZONE_PX + 1;          // and right: strafe
    p = apply(c, t, false);
    CHECK(p.events.size() == 1 && has(p, TOUCH_RIGHT_KEY, true));
    t.y = 400 + STICK_DEADZONE_PX + 1;          // down: back
    p = apply(c, t, false);
    CHECK(has(p, TOUCH_FORWARD_KEY, false) && has(p, TOUCH_BACK_KEY, true));
    CHECK(p.mouseX == 0 && p.mouseY == 0);      // the stick never aims
    t.secondPressed = true;                     // a second finger runs
    CHECK(has(apply(c, t, false), K_SHIFT, true));
    t.pressed = false;                          // lift: everything released
    t.secondPressed = false;
    p = apply(c, t, false);
    CHECK(has(p, TOUCH_BACK_KEY, false) && has(p, TOUCH_RIGHT_KEY, false) &&
          has(p, K_SHIFT, false));
    CHECK(p.events.size() == 3);
  }
  {
    // Opening a menu mid-drag releases the held movement keys, so the player
    // does not walk on behind the menu.
    TouchControls c;
    TouchSnapshot t = press(100, 400);
    apply(c, t, false);
    t.pressStarted = false;
    t.y = 300;
    CHECK(has(apply(c, t, false), TOUCH_FORWARD_KEY, true));
    Poll p = apply(c, t, true);
    CHECK(p.events.size() == 1 && has(p, TOUCH_FORWARD_KEY, false));
  }

  // --- touch in play: the right half ------------------------------------------
  {
    TouchControls c;
    TouchSnapshot t = press(500, 400);
    Poll p = apply(c, t, false);
    CHECK(p.events.empty() && p.mouseX == 0 && p.mouseY == 0);
    t.pressStarted = false;
    t.x = 510;  // 10 px right: 5 counts
    t.y = 397;  // 3 px up: 1 count, 1 px carried
    p = apply(c, t, false);
    CHECK(p.mouseX == 10 / LOOK_PX_PER_COUNT);
    CHECK(p.mouseY == -1);
    t.y = 396;  // the carried pixel plus this one make the next count
    p = apply(c, t, false);
    CHECK(p.mouseX == 0 && p.mouseY == -1);
    CHECK(p.events.empty());  // aiming presses no keys
    // A second press starts its own drag: no jump from the old point.
    t = press(600, 200);
    p = apply(c, t, false);
    CHECK(p.mouseX == 0 && p.mouseY == 0);
  }
  {
    TouchControls c;
    TouchSnapshot t = {};
    t.startX = 500;
    t.tap = true;
    Poll p = apply(c, t, false);
    CHECK(p.events.size() == 2 && has(p, K_MOUSE1, true) &&
          has(p, K_MOUSE1, false));
    t.tap = false;
    t.doubleTap = true;
    p = apply(c, t, false);
    CHECK(has(p, K_SPACE, true) && !has(p, K_MOUSE1, true));
    t.doubleTap = false;
    t.swipe = Swipe::Up;
    CHECK(has(apply(c, t, false), WHEEL_NEXT_KEY, true));
    t.swipe = Swipe::Down;
    CHECK(has(apply(c, t, false), WHEEL_PREV_KEY, true));
    // A tap on the stick half is not a shot.
    t.swipe = Swipe::None;
    t.tap = true;
    t.startX = 100;
    CHECK(!has(apply(c, t, false), K_MOUSE1, true));
  }

  // --- the key queue --------------------------------------------------------------
  {
    KeyQueue q;
    KeyEvent e;
    CHECK(!q.pop(e));
    CHECK(!q.push(0, true));  // not a key
    size_t pushed = 0;
    while (q.push('a', true)) ++pushed;
    CHECK(pushed == KeyQueue::CAPACITY - 1);
    size_t popped = 0;
    while (q.pop(e)) ++popped;
    CHECK(popped == pushed);
    CHECK(q.push(K_ENTER, false) && q.pop(e) && e.key == K_ENTER && !e.down);
  }

  if (failures != 0) {
    std::fprintf(stderr, "test_quake_input: %d failure(s)\n", failures);
    return 1;
  }
  std::printf("test_quake_input: OK\n");
  return 0;
}
