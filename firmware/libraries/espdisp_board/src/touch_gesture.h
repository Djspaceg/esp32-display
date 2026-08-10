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

/// What a press turned out to be.
///
/// LongPress is the one gesture that does not wait for the finger to lift: it
/// fires the moment the hold threshold passes, which is what a hold is supposed
/// to feel like. Everything else is only knowable on release.
enum class Gesture : uint8_t {
  None = 0,
  Tap = 1,
  SwipeLeft = 2,
  SwipeRight = 3,
  SwipeUp = 4,
  SwipeDown = 5,
  LongPress = 6,
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

/// How long a stationary press is held before it counts as a long press.
///
/// Comfortably above TAP_MAX_MS so the two can never be the same press: between
/// 400ms and this the press is still nothing, which leaves room for a finger that
/// lingers without the panel deciding it meant something.
static const uint32_t LONG_PRESS_MS = 600;

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
  void reset() {
    active_ = false;
    fired_ = false;
  }

  bool pressActive() const { return active_; }

  /// Give the tracker a chance to report a gesture that completes while the
  /// finger is still down. Call it every loop, whether or not a report arrived.
  ///
  /// This exists because reports only arrive on controller interrupts: a finger
  /// held perfectly still generates none at all, so a long press waiting for the
  /// next report would fire late, or never. Firing from a tick instead is what
  /// makes a hold feel like a hold - it happens while you are still holding,
  /// rather than when you give up and lift.
  Event tick(uint32_t nowMs) {
    Event event;
    if (!active_ || fired_) {
      return event;
    }
    if ((uint32_t)(nowMs - startMs_) < LONG_PRESS_MS) {
      return event;
    }
    // A finger that has wandered is on its way to being a swipe, not a hold.
    // Tap slop is the same allowance a tap gets, so "stationary" means one thing
    // throughout the classifier.
    const int16_t dx = (int16_t)(lastX_ - startX_);
    const int16_t dy = (int16_t)(lastY_ - startY_);
    if (dx > TAP_MAX_MOVE_PX || dx < -TAP_MAX_MOVE_PX ||
        dy > TAP_MAX_MOVE_PX || dy < -TAP_MAX_MOVE_PX) {
      return event;
    }
    fired_ = true;
    event.gesture = Gesture::LongPress;
    event.startX = startX_;
    event.startY = startY_;
    return event;
  }

  /// Feed one report. `pressed` false means the controller said the finger
  /// lifted; x and y are ignored in that case.
  Event onReport(bool pressed, int16_t x, int16_t y, uint32_t nowMs) {
    Event event;

    // Abandon a press that has been open implausibly long: a lost release
    // report would otherwise fold the next real press into it.
    if (active_ && (uint32_t)(nowMs - startMs_) > PRESS_MAX_MS) {
      active_ = false;
      fired_ = false;
    }

    if (pressed) {
      if (!active_) {
        active_ = true;
        fired_ = false;
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
    // A press that already reported a long press is spent. The finger lifting is
    // not a second gesture, and classifying it would send a tap or a swipe after
    // the hold had already been acted on.
    if (fired_) {
      fired_ = false;
      return event;
    }
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
  /// Whether this press has already reported a long press, so it reports once and
  /// its release reports nothing.
  bool fired_ = false;
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
    case Gesture::LongPress:
      return "long-press";
    default:
      return "none";
  }
}

}  // namespace touchgesture
