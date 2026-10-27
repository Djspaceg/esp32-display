// Host tests for the USB keyboard and mouse model
// (firmware/doom/src/platform/doom_usb_input_model.h): which carriers host a
// device at all, and what a HID boot report means to Doom.
#include <cstdio>
#include <cstring>

#include "../doom/src/platform/doom_usb_input_model.h"

static int checks = 0;
#define CHECK(cond)                                          \
  do {                                                       \
    checks++;                                                \
    if (!(cond)) {                                           \
      printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      return 1;                                              \
    }                                                        \
  } while (0)

using doomusb::Context;
using doomusb::Device;
using doomusb::KeyboardTracker;
using doomusb::KeyEvent;
using doomusb::MouseTracker;
using doomusb::ReportQueue;

// One boot-protocol keyboard report: modifier byte then up to six usages.
static void kbReport(uint8_t out[8], uint8_t modifiers, uint8_t u0 = 0,
                     uint8_t u1 = 0, uint8_t u2 = 0) {
  memset(out, 0, 8);
  out[0] = modifiers;
  out[2] = u0;
  out[3] = u1;
  out[4] = u2;
}

static bool hasEvent(const KeyEvent* events, size_t count, unsigned char key,
                     bool pressed) {
  for (size_t i = 0; i < count; ++i) {
    if (events[i].key == key && events[i].pressed == pressed) return true;
  }
  return false;
}

static int testHostingIsPerBoard() {
  // The 4B hosts but cannot power: its only host-capable connector advertises
  // itself as a sink and nothing on the board drives 5 V out.
  // Every board's host port is its descriptor's carrier.usb_host fact.
  for (const auto &identity : board::GENERATED_BOARD_IDENTITIES) {
    const board::GeneratedUsbHost *fact =
        board::generatedUsbHost(identity.variant);
    CHECK(fact != nullptr);
    if (fact == nullptr) continue;
    CHECK(doomusb::hostPortFor(identity.variant).hostCapable ==
          fact->hostCapable);
    CHECK(doomusb::hostPortFor(identity.variant).suppliesVbus ==
          fact->suppliesVbus);
  }
  CHECK(doomusb::hostPortFor(board::Variant::P4_4B).hostCapable);
  CHECK(!doomusb::hostPortFor(board::Variant::P4_4B).suppliesVbus);

  // The 4C and 3.4C carry a USB-A receptacle fed by a load switch that is
  // always enabled, so they do power a keyboard.
  CHECK(doomusb::hostPortFor(board::Variant::P4_4C).suppliesVbus);
  CHECK(doomusb::hostPortFor(board::Variant::P4_34C).suppliesVbus);

  // On every S3 and smaller carrier the chip's one USB pair goes to the
  // connector the board is flashed and logged through, and none of them can
  // drive 5 V outward. Hosting stays off there -- and a variant added later
  // starts off there too, which is why this sweeps the whole enum range rather
  // than a hand-written list.
  for (int raw = 0; raw <= 64; ++raw) {
    const board::Variant variant = (board::Variant)raw;
    const bool isP4 = variant == board::Variant::P4_4B ||
                      variant == board::Variant::P4_4C ||
                      variant == board::Variant::P4_34C;
    CHECK(doomusb::inputSupported(variant) == isP4);
    if (!isP4) CHECK(!doomusb::hostPortFor(variant).suppliesVbus);
  }
  return 0;
}

static int testMovementKeys() {
  KeyboardTracker tracker;
  KeyEvent events[KeyboardTracker::MAX_EVENTS];
  uint8_t report[8];

  // W presses forward once, and holding it across further reports does not
  // repeat: Doom samples held state, so a repeat would be a second stride.
  kbReport(report, 0, doomusb::USAGE_W);
  size_t count = tracker.apply(report, 8, Context::Gameplay, events,
                               KeyboardTracker::MAX_EVENTS);
  CHECK(count == 1);
  CHECK(events[0].key == KEY_UPARROW);
  CHECK(events[0].pressed);
  count = tracker.apply(report, 8, Context::Gameplay, events,
                        KeyboardTracker::MAX_EVENTS);
  CHECK(count == 0);

  // Releasing it releases forward.
  kbReport(report, 0);
  count = tracker.apply(report, 8, Context::Gameplay, events,
                        KeyboardTracker::MAX_EVENTS);
  CHECK(count == 1);
  CHECK(events[0].key == KEY_UPARROW);
  CHECK(!events[0].pressed);

  // A and D strafe, the arrows turn.
  kbReport(report, 0, doomusb::USAGE_A, doomusb::USAGE_ARROW_RIGHT);
  count = tracker.apply(report, 8, Context::Gameplay, events,
                        KeyboardTracker::MAX_EVENTS);
  CHECK(count == 2);
  CHECK(hasEvent(events, count, KEY_STRAFE_L, true));
  CHECK(hasEvent(events, count, KEY_RIGHTARROW, true));
  tracker.reset();

  kbReport(report, 0, doomusb::USAGE_D);
  count = tracker.apply(report, 8, Context::Gameplay, events,
                        KeyboardTracker::MAX_EVENTS);
  CHECK(count == 1);
  CHECK(events[0].key == KEY_STRAFE_R);
  return 0;
}

static int testFireRunStrafeModifiers() {
  KeyboardTracker tracker;
  KeyEvent events[KeyboardTracker::MAX_EVENTS];
  uint8_t report[8];

  // Ctrl fires, Shift runs, Alt strafes -- Doom's own default bindings.
  kbReport(report, doomusb::MOD_LEFTCTRL | doomusb::MOD_LEFTSHIFT |
                       doomusb::MOD_RIGHTALT);
  size_t count = tracker.apply(report, 8, Context::Gameplay, events,
                               KeyboardTracker::MAX_EVENTS);
  CHECK(count == 3);
  CHECK(hasEvent(events, count, KEY_FIRE, true));
  CHECK(hasEvent(events, count, KEY_RSHIFT, true));
  CHECK(hasEvent(events, count, KEY_RALT, true));

  // Swapping left Ctrl for right Ctrl is the same logical key: no edge, so
  // fire does not stutter when a player rolls from one Ctrl to the other.
  kbReport(report, doomusb::MOD_RIGHTCTRL | doomusb::MOD_LEFTSHIFT |
                       doomusb::MOD_RIGHTALT);
  count = tracker.apply(report, 8, Context::Gameplay, events,
                        KeyboardTracker::MAX_EVENTS);
  CHECK(count == 0);

  // Dropping every modifier releases all three.
  kbReport(report, 0);
  count = tracker.apply(report, 8, Context::Gameplay, events,
                        KeyboardTracker::MAX_EVENTS);
  CHECK(count == 3);
  CHECK(hasEvent(events, count, KEY_FIRE, false));
  CHECK(hasEvent(events, count, KEY_RSHIFT, false));
  CHECK(hasEvent(events, count, KEY_RALT, false));

  // A modifier this firmware does not map (the GUI/Windows keys) is no key at
  // all, and pressing one alone changes nothing.
  CHECK(doomusb::doomKeyForModifier(0x08) == 0);
  CHECK(doomusb::doomKeyForModifier(0x80) == 0);
  CHECK(doomusb::doomKeyForModifier(0) == 0);
  kbReport(report, 0x08 | 0x80);
  CHECK(tracker.apply(report, 8, Context::Gameplay, events,
                      KeyboardTracker::MAX_EVENTS) == 0);
  CHECK(tracker.heldCount() == 0);
  return 0;
}

static int testWeaponsAndMenuKeys() {
  KeyboardTracker tracker;
  KeyEvent events[KeyboardTracker::MAX_EVENTS];
  uint8_t report[8];

  for (int weapon = 1; weapon <= 7; ++weapon) {
    kbReport(report, 0, (uint8_t)(doomusb::USAGE_1 + (weapon - 1)));
    size_t count = tracker.apply(report, 8, Context::Gameplay, events,
                                 KeyboardTracker::MAX_EVENTS);
    CHECK(count == 1);
    CHECK(events[0].key == (unsigned char)('0' + weapon));
    tracker.reset();
  }

  // The engine binds the weapon-cycle directions to '.' and '/', so those two
  // physical keys must arrive as themselves.
  kbReport(report, 0, doomusb::USAGE_SLASH);
  CHECK(tracker.apply(report, 8, Context::Gameplay, events,
                      KeyboardTracker::MAX_EVENTS) == 1);
  CHECK(events[0].key == '/');
  tracker.reset();
  kbReport(report, 0, doomusb::USAGE_PERIOD);
  CHECK(tracker.apply(report, 8, Context::Gameplay, events,
                      KeyboardTracker::MAX_EVENTS) == 1);
  CHECK(events[0].key == '.');
  tracker.reset();

  // Menu navigation: Escape opens and closes, Enter selects, Backspace goes
  // back, Space is Use in play, and Tab is the map.
  const struct {
    uint8_t usage;
    unsigned char key;
  } cases[] = {
      {doomusb::USAGE_ESCAPE, (unsigned char)KEY_ESCAPE},
      {doomusb::USAGE_ENTER, (unsigned char)KEY_ENTER},
      {doomusb::USAGE_KEYPAD_ENTER, (unsigned char)KEY_ENTER},
      {doomusb::USAGE_BACKSPACE, (unsigned char)KEY_BACKSPACE},
      {doomusb::USAGE_SPACE, (unsigned char)KEY_USE},
      {doomusb::USAGE_TAB, (unsigned char)KEY_TAB},
      {doomusb::USAGE_PAUSE, (unsigned char)KEY_PAUSE},
      {doomusb::USAGE_F1, (unsigned char)KEY_F1},
      {doomusb::USAGE_F10, (unsigned char)KEY_F10},
      {doomusb::USAGE_MINUS, (unsigned char)KEY_MINUS},
      {doomusb::USAGE_EQUAL, (unsigned char)KEY_EQUALS},
  };
  for (const auto& one : cases) {
    kbReport(report, 0, one.usage);
    CHECK(tracker.apply(report, 8, Context::Gameplay, events,
                        KeyboardTracker::MAX_EVENTS) == 1);
    CHECK(events[0].key == one.key);
    tracker.reset();
  }
  return 0;
}

static int testMenuContextTypesLetters() {
  KeyboardTracker tracker;
  KeyEvent events[KeyboardTracker::MAX_EVENTS];
  uint8_t report[8];

  // A save-game name needs the letters themselves, so inside a menu the
  // movement four are characters rather than movement.
  const struct {
    uint8_t usage;
    unsigned char letter;
  } letters[] = {{doomusb::USAGE_W, 'w'},
                 {doomusb::USAGE_A, 'a'},
                 {doomusb::USAGE_S, 's'},
                 {doomusb::USAGE_D, 'd'}};
  for (const auto& one : letters) {
    kbReport(report, 0, one.usage);
    CHECK(tracker.apply(report, 8, Context::Menu, events,
                        KeyboardTracker::MAX_EVENTS) == 1);
    CHECK(events[0].key == one.letter);
    tracker.reset();
  }

  // A key held while the engine opens a menu is released as what it was
  // pressed as. Releasing it as the menu letter instead would leave the player
  // walking forward with nothing holding the key.
  kbReport(report, 0, doomusb::USAGE_W);
  CHECK(tracker.apply(report, 8, Context::Gameplay, events,
                      KeyboardTracker::MAX_EVENTS) == 1);
  CHECK(events[0].key == KEY_UPARROW);
  kbReport(report, 0);
  CHECK(tracker.apply(report, 8, Context::Menu, events,
                      KeyboardTracker::MAX_EVENTS) == 1);
  CHECK(events[0].key == KEY_UPARROW);
  CHECK(!events[0].pressed);
  tracker.reset();

  // The same, but with reports in between, which is what actually happens: hold
  // W in gameplay, tap Escape to open the menu, then let W go. Every one of
  // those reports still names W, so the tracker has to carry the key it first
  // emitted rather than re-deciding from the new context.
  kbReport(report, 0, doomusb::USAGE_W);
  CHECK(tracker.apply(report, 8, Context::Gameplay, events,
                      KeyboardTracker::MAX_EVENTS) == 1);
  CHECK(events[0].key == KEY_UPARROW && events[0].pressed);
  kbReport(report, 0, doomusb::USAGE_W, doomusb::USAGE_ESCAPE);
  CHECK(tracker.apply(report, 8, Context::Gameplay, events,
                      KeyboardTracker::MAX_EVENTS) == 1);
  CHECK(events[0].key == KEY_ESCAPE && events[0].pressed);
  // The menu is open now, so this and every later report is menu context.
  kbReport(report, 0, doomusb::USAGE_W);
  CHECK(tracker.apply(report, 8, Context::Menu, events,
                      KeyboardTracker::MAX_EVENTS) == 1);
  CHECK(events[0].key == KEY_ESCAPE && !events[0].pressed);
  kbReport(report, 0);
  CHECK(tracker.apply(report, 8, Context::Menu, events,
                      KeyboardTracker::MAX_EVENTS) == 1);
  CHECK(events[0].key == KEY_UPARROW);
  CHECK(!events[0].pressed);
  CHECK(tracker.heldCount() == 0);
  return 0;
}

static int testMenuContextTypesEveryLetter() {
  KeyboardTracker tracker;
  KeyEvent events[KeyboardTracker::MAX_EVENTS];
  uint8_t report[8];

  // A save-game name, and the engine's own y/n prompts, need the whole
  // alphabet inside a menu.
  for (int i = 0; i < 26; ++i) {
    kbReport(report, 0, (uint8_t)(doomusb::USAGE_A + i));
    CHECK(tracker.apply(report, 8, Context::Menu, events,
                        KeyboardTracker::MAX_EVENTS) == 1);
    CHECK(events[0].key == (unsigned char)('a' + i));
    tracker.reset();
  }

  // In play only the movement four are mapped; the rest are ignored, so stray
  // typing cannot reach a cheat code.
  for (int i = 0; i < 26; ++i) {
    const uint8_t usage = (uint8_t)(doomusb::USAGE_A + i);
    const bool isMovement =
        usage == doomusb::USAGE_W || usage == doomusb::USAGE_A ||
        usage == doomusb::USAGE_S || usage == doomusb::USAGE_D;
    kbReport(report, 0, usage);
    const size_t count = tracker.apply(report, 8, Context::Gameplay, events,
                                       KeyboardTracker::MAX_EVENTS);
    CHECK(count == (isMovement ? 1u : 0u));
    tracker.reset();
  }
  return 0;
}

static int testHeldKeysCanBePressedAgain() {
  KeyboardTracker tracker;
  MouseTracker mouse;
  KeyEvent events[KeyboardTracker::MAX_EVENTS];
  uint8_t report[8];

  // The touch and tilt path releases the movement keys whenever the engine
  // leaves gameplay, and those are the same engine keys a keyboard holds. A
  // keyboard sends nothing while its key set is unchanged, so the held set has
  // to be re-pressable on demand or the key goes dead.
  kbReport(report, doomusb::MOD_LEFTCTRL, doomusb::USAGE_W);
  CHECK(tracker.apply(report, 8, Context::Gameplay, events,
                      KeyboardTracker::MAX_EVENTS) == 2);
  size_t count = tracker.reassertHeld(events, KeyboardTracker::MAX_EVENTS);
  CHECK(count == 2);
  CHECK(hasEvent(events, count, KEY_UPARROW, true));
  CHECK(hasEvent(events, count, KEY_FIRE, true));
  // It re-presses what was pressed, never a release, and changes nothing.
  for (size_t i = 0; i < count; ++i) CHECK(events[i].pressed);
  CHECK(tracker.heldCount() == 2);

  // Nothing held, nothing re-pressed.
  tracker.reset();
  CHECK(tracker.reassertHeld(events, KeyboardTracker::MAX_EVENTS) == 0);

  // Same for a held mouse button.
  const uint8_t down[] = {doomusb::MOUSE_LEFT, 0, 0, 0};
  mouse.apply(down, sizeof(down), events, MouseTracker::MAX_EVENTS);
  count = mouse.reassertHeld(events, KeyboardTracker::MAX_EVENTS);
  CHECK(count == 1);
  CHECK(events[0].key == KEY_FIRE && events[0].pressed);
  mouse.releaseAll(events, KeyboardTracker::MAX_EVENTS);
  CHECK(mouse.reassertHeld(events, KeyboardTracker::MAX_EVENTS) == 0);
  return 0;
}

static int testTooSmallABufferIsRefused() {
  KeyboardTracker tracker;
  MouseTracker mouse;
  KeyEvent events[KeyboardTracker::MAX_EVENTS];
  uint8_t report[8];

  // Truncating the event list while still updating the held set is how a key
  // gets stranded down, so a buffer that cannot hold the worst case is refused
  // and nothing changes.
  kbReport(report, 0, doomusb::USAGE_W);
  CHECK(tracker.apply(report, 8, Context::Gameplay, events,
                      KeyboardTracker::MAX_EVENTS - 1) == 0);
  CHECK(tracker.heldCount() == 0);
  CHECK(tracker.releaseAll(events, KeyboardTracker::MAX_EVENTS - 1) == 0);
  CHECK(tracker.reassertHeld(events, KeyboardTracker::MAX_EVENTS - 1) == 0);

  const uint8_t click[] = {doomusb::MOUSE_LEFT, 0, 0, 0};
  CHECK(mouse.apply(click, sizeof(click), events, MouseTracker::MAX_EVENTS - 1) ==
        0);
  int dx = 0;
  int dy = 0;
  mouse.takeMovement(&dx, &dy);
  CHECK(dx == 0 && dy == 0);
  return 0;
}

static int testReportQueue() {
  ReportQueue queue;
  ReportQueue::Entry entry;
  const uint8_t kb[8] = {0, 0, doomusb::USAGE_W, 0, 0, 0, 0, 0};
  const uint8_t ms[4] = {doomusb::MOUSE_LEFT, 3, 4, 0};

  CHECK(queue.empty());
  CHECK(!queue.pop(entry));

  // It exists so a press and the release a few milliseconds later do not land
  // in one engine poll and cancel out: both survive, in order.
  queue.push(Device::Keyboard, kb, sizeof(kb));
  queue.push(Device::Mouse, ms, sizeof(ms));
  CHECK(queue.size() == 2);
  CHECK(queue.pop(entry));
  CHECK(entry.device == Device::Keyboard);
  CHECK(entry.length == 8);
  CHECK(entry.data[2] == doomusb::USAGE_W);
  CHECK(queue.pop(entry));
  CHECK(entry.device == Device::Mouse);
  CHECK(entry.length == 4);
  CHECK(entry.data[1] == 3 && entry.data[2] == 4);
  CHECK(queue.empty());

  // An ignored interface queues nothing, and neither does an empty report.
  queue.push(Device::None, kb, sizeof(kb));
  queue.push(Device::Keyboard, kb, 0);
  queue.push(Device::Keyboard, nullptr, 8);
  CHECK(queue.empty());

  // A longer report than the boot protocol's is kept only as far as it fits.
  const uint8_t oversize[12] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12};
  queue.push(Device::Keyboard, oversize, sizeof(oversize));
  CHECK(queue.pop(entry));
  CHECK(entry.length == ReportQueue::MAX_REPORT);
  CHECK(entry.data[7] == 8);

  // Full drops the OLDEST, not the newest. A boot report names what is held
  // right now, so the newest is authoritative; dropping it would throw away a
  // key-up the keyboard will never send again.
  queue.clear();
  for (int i = 0; i < (int)ReportQueue::CAPACITY + 5; ++i) {
    uint8_t one[8] = {0, 0, (uint8_t)(doomusb::USAGE_1 + (i % 7)), 0, 0, 0, 0, 0};
    queue.push(Device::Keyboard, one, sizeof(one));
  }
  CHECK(queue.size() == ReportQueue::CAPACITY);
  // The first one still queued is report 5, and the last is the newest.
  CHECK(queue.pop(entry));
  CHECK(entry.data[2] == (uint8_t)(doomusb::USAGE_1 + (5 % 7)));
  int last = 0;
  while (queue.pop(entry)) last = entry.data[2];
  CHECK(last == (uint8_t)(doomusb::USAGE_1 +
                          ((int)ReportQueue::CAPACITY + 4) % 7));

  // Unplugging a device forgets what it had already sent, keeping the other
  // device's reports in order. Folding those afterwards would press keys again
  // that nothing is left to release.
  queue.clear();
  queue.push(Device::Keyboard, kb, sizeof(kb));
  queue.push(Device::Mouse, ms, sizeof(ms));
  queue.push(Device::Keyboard, kb, sizeof(kb));
  queue.push(Device::Mouse, ms, sizeof(ms));
  queue.dropDevice(Device::Keyboard);
  CHECK(queue.size() == 2);
  CHECK(queue.pop(entry) && entry.device == Device::Mouse);
  CHECK(queue.pop(entry) && entry.device == Device::Mouse);
  CHECK(queue.empty());

  // Dropping a device that queued nothing changes nothing, and the queue still
  // works after a wrap.
  queue.clear();
  for (int round = 0; round < 3; ++round) {
    for (size_t i = 0; i < ReportQueue::CAPACITY - 4; ++i) {
      queue.push(Device::Mouse, ms, sizeof(ms));
    }
    queue.dropDevice(Device::Keyboard);
    CHECK(queue.size() == ReportQueue::CAPACITY - 4);
    while (queue.pop(entry)) CHECK(entry.device == Device::Mouse);
    CHECK(queue.empty());
  }
  return 0;
}

static int testUnpluggedKeyboardStopsWalking() {
  KeyboardTracker tracker;
  KeyEvent events[KeyboardTracker::MAX_EVENTS];
  uint8_t report[8];

  kbReport(report, doomusb::MOD_LEFTSHIFT, doomusb::USAGE_W,
           doomusb::USAGE_ARROW_LEFT);
  CHECK(tracker.apply(report, 8, Context::Gameplay, events,
                      KeyboardTracker::MAX_EVENTS) == 3);
  CHECK(tracker.heldCount() == 3);

  const size_t released =
      tracker.releaseAll(events, KeyboardTracker::MAX_EVENTS);
  CHECK(released == 3);
  CHECK(hasEvent(events, released, KEY_UPARROW, false));
  CHECK(hasEvent(events, released, KEY_LEFTARROW, false));
  CHECK(hasEvent(events, released, KEY_RSHIFT, false));
  CHECK(tracker.heldCount() == 0);
  return 0;
}

static int testKeyboardIgnoresJunk() {
  KeyboardTracker tracker;
  KeyEvent events[KeyboardTracker::MAX_EVENTS];
  uint8_t report[8];

  // A short report is not a boot-protocol report; reading six usages out of it
  // would read past the buffer.
  kbReport(report, 0, doomusb::USAGE_W);
  CHECK(tracker.apply(report, 4, Context::Gameplay, events,
                      KeyboardTracker::MAX_EVENTS) == 0);
  CHECK(tracker.apply(nullptr, 8, Context::Gameplay, events,
                      KeyboardTracker::MAX_EVENTS) == 0);

  // The rollover code a keyboard sends when too many keys are down is not a
  // key, and neither are unmapped usages such as Caps Lock.
  kbReport(report, 0, 0x01, 0x01, 0x01);
  CHECK(tracker.apply(report, 8, Context::Gameplay, events,
                      KeyboardTracker::MAX_EVENTS) == 0);
  kbReport(report, 0, 0x39 /* caps lock */);
  CHECK(tracker.apply(report, 8, Context::Gameplay, events,
                      KeyboardTracker::MAX_EVENTS) == 0);

  // The same usage repeated across slots is one key, not three presses.
  kbReport(report, 0, doomusb::USAGE_W, doomusb::USAGE_W, doomusb::USAGE_W);
  CHECK(tracker.apply(report, 8, Context::Gameplay, events,
                      KeyboardTracker::MAX_EVENTS) == 1);
  CHECK(tracker.heldCount() == 1);
  return 0;
}

static int testMouseTurnsAndLooks() {
  MouseTracker mouse;
  KeyEvent events[MouseTracker::MAX_EVENTS];
  int dx = 0;
  int dy = 0;

  // Moving right turns right; Doom subtracts the horizontal delta from
  // angleturn, so right must stay positive.
  const uint8_t right[] = {0, 20, 0, 0};
  CHECK(mouse.apply(right, sizeof(right), events, MouseTracker::MAX_EVENTS) ==
        0);
  mouse.takeMovement(&dx, &dy);
  CHECK(dx == 20);
  CHECK(dy == 0);

  // Movement is taken once: the next poll starts from zero.
  mouse.takeMovement(&dx, &dy);
  CHECK(dx == 0 && dy == 0);

  // A HID mouse reports y growing downwards, Doom adds it to forward, so
  // pushing the mouse away from the player must walk forward.
  const uint8_t forward[] = {0, 0, (uint8_t)(int8_t)-10, 0};
  mouse.apply(forward, sizeof(forward), events, MouseTracker::MAX_EVENTS);
  mouse.takeMovement(&dx, &dy);
  CHECK(dy == 10);

  // Reports between two polls accumulate rather than overwrite.
  const uint8_t step[] = {0, 5, 0, 0};
  mouse.apply(step, sizeof(step), events, MouseTracker::MAX_EVENTS);
  mouse.apply(step, sizeof(step), events, MouseTracker::MAX_EVENTS);
  mouse.takeMovement(&dx, &dy);
  CHECK(dx == 10);

  // A fast flick, or a burst left unpolled, is capped rather than spinning the
  // view through several turns in one tic. The two axes are capped
  // differently: turning matches the touch joystick's 160, while walking stops
  // at Doom's own MAXPLMOVE of 50, past which `forward` saturates anyway.
  const uint8_t flick[] = {0, 127, 127, 0};
  for (int i = 0; i < 8; ++i) {
    mouse.apply(flick, sizeof(flick), events, MouseTracker::MAX_EVENTS);
  }
  mouse.takeMovement(&dx, &dy);
  CHECK(doomusb::MOUSE_MAX_TURN_DELTA == 160);
  CHECK(doomusb::MOUSE_MAX_WALK_DELTA == 50);
  CHECK(dx == 160);
  CHECK(dy == -50);

  const uint8_t backflick[] = {0, (uint8_t)(int8_t)-127, (uint8_t)(int8_t)-127, 0};
  for (int i = 0; i < 8; ++i) {
    mouse.apply(backflick, sizeof(backflick), events, MouseTracker::MAX_EVENTS);
  }
  mouse.takeMovement(&dx, &dy);
  CHECK(dx == -160);
  CHECK(dy == 50);
  return 0;
}

static int testMouseButtonsAndWheel() {
  MouseTracker mouse;
  KeyEvent events[MouseTracker::MAX_EVENTS];

  // The left button fires and keeps firing while held; the engine samples held
  // state, so a repeat per report would be wrong.
  const uint8_t down[] = {doomusb::MOUSE_LEFT, 0, 0, 0};
  CHECK(mouse.apply(down, sizeof(down), events, MouseTracker::MAX_EVENTS) == 1);
  CHECK(events[0].key == KEY_FIRE);
  CHECK(events[0].pressed);
  CHECK(mouse.apply(down, sizeof(down), events, MouseTracker::MAX_EVENTS) == 0);

  // The right button is Use, and releasing the left one stops firing.
  const uint8_t both[] = {doomusb::MOUSE_RIGHT, 0, 0, 0};
  size_t count = mouse.apply(both, sizeof(both), events,
                             MouseTracker::MAX_EVENTS);
  CHECK(count == 2);
  CHECK(hasEvent(events, count, KEY_FIRE, false));
  CHECK(hasEvent(events, count, KEY_USE, true));

  // An unplugged mouse must not leave Fire or Use down.
  const uint8_t armed[] = {(uint8_t)(doomusb::MOUSE_LEFT | doomusb::MOUSE_RIGHT),
                           0, 0, 0};
  mouse.apply(armed, sizeof(armed), events, MouseTracker::MAX_EVENTS);
  count = mouse.releaseAll(events, MouseTracker::MAX_EVENTS);
  CHECK(count == 2);
  CHECK(hasEvent(events, count, KEY_FIRE, false));
  CHECK(hasEvent(events, count, KEY_USE, false));

  // Wheel notches cycle weapons, one per poll: a weapon-cycle key has to stay
  // down across a tic to be seen, so the caller holds each notch for one poll.
  const uint8_t up[] = {0, 0, 0, 2};
  mouse.apply(up, sizeof(up), events, MouseTracker::MAX_EVENTS);
  CHECK(mouse.takeWheelNotch() == 1);
  CHECK(mouse.takeWheelNotch() == 1);
  CHECK(mouse.takeWheelNotch() == 0);

  const uint8_t downWheel[] = {0, 0, 0, (uint8_t)(int8_t)-1};
  mouse.apply(downWheel, sizeof(downWheel), events, MouseTracker::MAX_EVENTS);
  CHECK(mouse.takeWheelNotch() == -1);
  CHECK(mouse.takeWheelNotch() == 0);

  // An unplugged mouse drops any notch it had not delivered.
  mouse.apply(up, sizeof(up), events, MouseTracker::MAX_EVENTS);
  mouse.releaseAll(events, MouseTracker::MAX_EVENTS);
  CHECK(mouse.takeWheelNotch() == 0);

  // One vigorous scroll must not cycle weapons for seconds: the engine acts on
  // one notch per tic, so the queue of unspent notches is bounded.
  const uint8_t spin[] = {0, 0, 0, 100};
  for (int i = 0; i < 5; ++i) {
    mouse.apply(spin, sizeof(spin), events, MouseTracker::MAX_EVENTS);
  }
  int notches = 0;
  while (mouse.takeWheelNotch() != 0) {
    ++notches;
    CHECK(notches <= doomusb::MOUSE_MAX_WHEEL_QUEUE);
  }
  CHECK(notches == doomusb::MOUSE_MAX_WHEEL_QUEUE);
  CHECK(doomusb::MOUSE_MAX_WHEEL_QUEUE == 4);

  // A short report is not a mouse report.
  const uint8_t truncated[] = {doomusb::MOUSE_LEFT, 0};
  CHECK(mouse.apply(truncated, sizeof(truncated), events,
                    MouseTracker::MAX_EVENTS) == 0);
  return 0;
}

int main() {
  if (testHostingIsPerBoard()) return 1;
  if (testMovementKeys()) return 1;
  if (testFireRunStrafeModifiers()) return 1;
  if (testWeaponsAndMenuKeys()) return 1;
  if (testMenuContextTypesLetters()) return 1;
  if (testMenuContextTypesEveryLetter()) return 1;
  if (testHeldKeysCanBePressedAgain()) return 1;
  if (testTooSmallABufferIsRefused()) return 1;
  if (testReportQueue()) return 1;
  if (testUnpluggedKeyboardStopsWalking()) return 1;
  if (testKeyboardIgnoresJunk()) return 1;
  if (testMouseTurnsAndLooks()) return 1;
  if (testMouseButtonsAndWheel()) return 1;
  printf("test_usb_input: %d checks passed\n", checks);
  return 0;
}
