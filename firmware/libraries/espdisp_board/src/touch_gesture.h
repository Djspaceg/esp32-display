// Turning a stream of touch reports into discrete gestures.
//
// The panel reports a position whenever the controller raises its interrupt,
// which is not what a caller wants to act on: "the user tapped" and "the user
// swiped left" are decisions about a whole press, from touch-down to lift. This
// file makes those decisions and nothing else.
//
// Hardware-free, and the caller supplies the timestamp rather than this calling
// millis(), so the whole classifier is unit tested on the host like
// band_protocol.h and touch_map.h. Gesture timing is the sort of logic that is
// almost impossible to check by hand on a device and trivial to check in a test.
//
// Coordinates in and out are framebuffer coordinates, i.e. already through
// touch_map.h. That matters for the swipe directions: "left" means left as the
// user sees it, not left along some fixed panel axis, so a swipe keeps its
// meaning when macOS rotates the panel.
#pragma once

#include <stdint.h>

namespace touchgesture {

/// What a completed press turned out to be.
///
/// There is deliberately no LongPress. Nothing currently acts on one, and an
/// unused gesture is a guess about a future caller. Long holds are classified as
/// None rather than as taps, though, because otherwise resting a finger on the
/// panel would fire whatever a tap is wired to.
enum class Gesture : uint8_t {
  None = 0,
  Tap = 1,
  SwipeLeft = 2,
  SwipeRight = 3,
  SwipeUp = 4,
  SwipeDown = 5,
};

/// Movement, in framebuffer pixels, that makes a press a swipe rather than a
/// tap. The panel's short axis is 172px, so 24 is about 14% of it: far enough
/// that it cannot be finger wobble, close enough to feel like a flick.
static const int16_t SWIPE_MIN_PX = 24;

/// How far a press may drift and still count as a tap. Between this and
/// SWIPE_MIN_PX is a dead band that classifies as None, which is intentional:
/// an ambiguous smudge should do nothing rather than pick one of two actions.
static const int16_t TAP_MAX_MOVE_PX = 12;

/// Longest press still considered a tap. A deliberate hold is not a tap.
static const uint32_t TAP_MAX_MS = 400;

/// A press held longer than this is abandoned. The controller signals lift with
/// a zero-touch report, so a release is normally observed - but a dropped report
/// would otherwise leave a press open forever and make the next touch look like
/// a continuation of it.
static const uint32_t PRESS_MAX_MS = 10000;

/// What a single report produced.
struct Event {
  /// The gesture this report completed, or None.
  Gesture gesture = Gesture::None;
  /// True when this report began a new press. Callers that want to react to a
  /// finger landing - lighting a dimmed panel, say - need touch-down, not the
  /// gesture, which is only known on release.
  bool pressStarted = false;
  /// Where the press began, in framebuffer coordinates. Meaningful when either
  /// gesture is not None or pressStarted is true.
  int16_t startX = 0;
  int16_t startY = 0;
};

/// Classifies one finger's presses. One panel, one finger: multi-touch is
/// available from the controller but this project has no use for it.
class Tracker {
 public:
  void reset() { active_ = false; }

  bool pressActive() const { return active_; }

  /// Feed one report. `pressed` false means the controller said the finger
  /// lifted; x and y are ignored in that case.
  Event onReport(bool pressed, int16_t x, int16_t y, uint32_t nowMs) {
    Event event;

    // Abandon a press that has been open implausibly long: a lost release
    // report would otherwise fold the next real press into it.
    if (active_ && (uint32_t)(nowMs - startMs_) > PRESS_MAX_MS) {
      active_ = false;
    }

    if (pressed) {
      if (!active_) {
        active_ = true;
        startMs_ = nowMs;
        startX_ = x;
        startY_ = y;
        event.pressStarted = true;
      }
      lastX_ = x;
      lastY_ = y;
      event.startX = startX_;
      event.startY = startY_;
      return event;
    }

    if (!active_) {
      return event;  // release with no press: nothing to classify
    }
    active_ = false;
    event.startX = startX_;
    event.startY = startY_;
    event.gesture = classify(nowMs);
    return event;
  }

 private:
  Gesture classify(uint32_t nowMs) const {
    const int16_t dx = (int16_t)(lastX_ - startX_);
    const int16_t dy = (int16_t)(lastY_ - startY_);
    const int16_t adx = dx < 0 ? (int16_t)-dx : dx;
    const int16_t ady = dy < 0 ? (int16_t)-dy : dy;

    // Distance decides a swipe, not duration: a slow drag across the panel is
    // still a swipe, and treating it as a hold would make the gesture depend on
    // how fast the user happens to move.
    if (adx >= SWIPE_MIN_PX || ady >= SWIPE_MIN_PX) {
      if (adx >= ady) {
        return dx < 0 ? Gesture::SwipeLeft : Gesture::SwipeRight;
      }
      return dy < 0 ? Gesture::SwipeUp : Gesture::SwipeDown;
    }

    const uint32_t heldMs = (uint32_t)(nowMs - startMs_);
    if (heldMs <= TAP_MAX_MS && adx <= TAP_MAX_MOVE_PX &&
        ady <= TAP_MAX_MOVE_PX) {
      return Gesture::Tap;
    }
    return Gesture::None;
  }

  bool active_ = false;
  uint32_t startMs_ = 0;
  int16_t startX_ = 0;
  int16_t startY_ = 0;
  int16_t lastX_ = 0;
  int16_t lastY_ = 0;
};

/// Short stable name, for logs and for the serial diagnostics.
inline const char *gestureName(Gesture g) {
  switch (g) {
    case Gesture::Tap:
      return "tap";
    case Gesture::SwipeLeft:
      return "swipe-left";
    case Gesture::SwipeRight:
      return "swipe-right";
    case Gesture::SwipeUp:
      return "swipe-up";
    case Gesture::SwipeDown:
      return "swipe-down";
    default:
      return "none";
  }
}

}  // namespace touchgesture
