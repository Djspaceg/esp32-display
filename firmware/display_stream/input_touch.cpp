#include "input_touch.h"

#include <Arduino.h>

#include <board_touch.h>
#include <touch_gesture.h>
#include <touch_map.h>

#include "app_state.h"
#include "device_protocol.h"
#include "display_power.h"
#include "net_link.h"
#include "orientation.h"
#include "ui_screens.h"

static touchgesture::Tracker touchTracker;
static uint16_t touchSequence = 0;
// True while the current press has already been spent waking the panel.
static bool touchConsumed = false;
// Report a completed gesture to whoever is driving this panel.
//
// The internal gesture enum and the wire one are separate types: touch_gesture.h
// lives in the shared library and device_protocol.h lives here, so the library
// cannot see the wire format - and should not, because what the classifier can
// recognise and what the protocol has agreed to carry are allowed to differ. The
// translation is this switch, deliberately explicit so adding a gesture forces a
// decision about whether it goes on the wire rather than silently renumbering it.
//
// The mapping is inline rather than a helper because the Arduino preprocessor
// hoists function prototypes above the "device_protocol.h" include below, so a
// function taking a deviceproto type as a parameter does not compile here.
static void sendTouchEvent(touchgesture::Gesture gesture, int16_t x, int16_t y) {
  deviceproto::TouchGesture wire;
  switch (gesture) {
    case touchgesture::Gesture::Tap:
      wire = deviceproto::TouchGesture::Tap;
      break;
    case touchgesture::Gesture::SwipeLeft:
      wire = deviceproto::TouchGesture::SwipeLeft;
      break;
    case touchgesture::Gesture::SwipeRight:
      wire = deviceproto::TouchGesture::SwipeRight;
      break;
    case touchgesture::Gesture::SwipeUp:
      wire = deviceproto::TouchGesture::SwipeUp;
      break;
    case touchgesture::Gesture::SwipeDown:
      wire = deviceproto::TouchGesture::SwipeDown;
      break;
    case touchgesture::Gesture::LongPress:
      wire = deviceproto::TouchGesture::LongPress;
      break;
    default:
      return;  // not a gesture this protocol carries
  }
  if (hbPort == 0) {
    // No sender has ever spoken to this panel, so there is nowhere to report a
    // gesture to. Log it: a user tapping a panel that no Mac is driving should
    // be able to see that the touch registered and simply had no audience.
    Serial.printf("touch: %s ignored, no sender\n",
                  touchgesture::gestureName(gesture));
    return;
  }
  uint8_t packet[deviceproto::TOUCH_PACKET_BYTES];
  deviceproto::writeTouch(
      packet, wire, ++touchSequence, (uint16_t)x, (uint16_t)y,
      panelLandscape ? deviceproto::TOUCH_FLAG_LANDSCAPE : (uint8_t)0);
  sendToSender(packet, sizeof(packet));
  Serial.printf("touch: %s at (%d,%d) seq=%u -> sender\n",
                touchgesture::gestureName(gesture), x, y, touchSequence);
}

// Poll the touch controller and act on whatever the finger turned out to mean.
//
// Two behaviours share one finger, and the order between them matters. While the
// panel is dimmed - showing the idle card, or dark because the Mac's displays
// slept - a touch lights it and is *consumed*, so waking a panel never also
// toggles whatever the sender maps a tap to. Once the panel is lit, completed
// gestures go to the sender and it decides what they mean.
void serviceTouch() {
  if (!touchAvailable) {
    return;
  }

  // Let an expired wake window hand the backlight back to the state machine.
  if (touchWakeUntil != 0 && !touchWakeActive()) {
    touchWakeUntil = 0;
    applyBacklight();
  }

  // Ticked before the poll, and regardless of whether one arrives: a long press
  // completes while the finger is still down, and a finger holding still produces
  // no controller interrupts to carry it. Polling first would mean the hold could
  // only be noticed when the user moved or lifted, which is exactly what a hold
  // is not.
  touchgesture::Event held = touchTracker.tick(millis());
  if (held.gesture != touchgesture::Gesture::None && !touchConsumed) {
    sendTouchEvent(held.gesture, held.startX, held.startY);
  }

  boardtouch::Sample sample;
  if (!boardtouch::poll(sample)) {
    return;
  }

  // Through the same orientation transform the pixels went through, so a swipe
  // means the direction the user actually swiped. Calibration is per board:
  // each controller/panel pair has its own raw X/Y mirror facts (see
  // touch_map.h), so touchCalibration is picked once at boot from bcfg->touch
  // rather than taking the AXS5106L default implicitly.
  touchmap::Point p = touchmap::map(
      (int16_t)sample.rawX, (int16_t)sample.rawY, panelLandscape,
      appliedPanelRotation, touchCalibration);
  if (panelMirrorX) {
    p = touchmap::mirrorFrameX(
        p, touchmap::swapsAxes(panelLandscape, appliedPanelRotation),
        touchCalibration);
  }
  touchgesture::Event event =
      touchTracker.onReport(sample.pressed, p.x, p.y, millis());

  // Wake-swallow only while the panel is actually DIM: once a wake press has
  // lit the status card (touchWakeActive), or the survey meter is up at full
  // brightness, the next tap must reach the handlers below - that second tap
  // is how the survey mode is entered and left.
  if (event.pressStarted && !surveyActive &&
      (displaySleeping || (idleActive && !touchWakeActive()))) {
    touchConsumed = true;
    touchWakeUntil = millis() + TOUCH_WAKE_MS;
    applyBacklight();
    Serial.printf("touch: wake for %lus\n", (unsigned long)(TOUCH_WAKE_MS / 1000));
    return;
  }

  // The press that woke the panel is swallowed whole, so lighting a dark panel
  // never also fires whatever the gesture is bound to.
  //
  // Cleared when that press *ends*, whatever it classified as. Clearing it only
  // on a recognised gesture was a latent bug: a deliberate hold classifies as
  // nothing, so a waking press held for a moment left the flag set and ate the
  // next real gesture. Long press makes that path far more likely, since holding
  // is now something users are told to do.
  const bool consumed = touchConsumed;
  if (consumed && !touchTracker.pressActive()) {
    touchConsumed = false;
  }
  if (event.gesture == touchgesture::Gesture::None || consumed) {
    return;
  }
  // A plain tap on a lit panel shows the quick info bar, independent of and
  // in addition to reporting the gesture below - the two are separate
  // reactions to the same event, not alternatives. Swipes and long presses
  // do not: they already have a job (whatever the sender's gesture preset
  // binds them to), and a bar popping up on every swipe would fight that
  // rather than complement it.
  // A tap on the lit status card enters the signal survey; a tap on the
  // survey leaves it. Handled before the info bar and before gesture
  // forwarding: a survey tap is panel-local by definition (the whole point
  // is that no Mac is nearby), so the sender never hears about it.
  if (event.gesture == touchgesture::Gesture::Tap &&
      (surveyActive || idleActive)) {
    surveyActive = !surveyActive;
    if (surveyActive) {
      Serial.println("touch: signal survey on");
      drawSurveyScreen();
    } else {
      Serial.println("touch: signal survey off");
      applyBacklight();  // back to the state-driven level
      if (idleActive) drawIdleScreen();
    }
    return;
  }
  if (event.gesture == touchgesture::Gesture::Tap) {
    showInfoBar(defaultInfoBarText());
  }
  sendTouchEvent(event.gesture, event.startX, event.startY);
}
