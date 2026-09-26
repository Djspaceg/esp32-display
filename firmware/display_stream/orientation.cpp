#include "orientation.h"

#include <Arduino.h>

#include <board_motion.h>
#include <board_touch.h>
#include <motion_orientation.h>
#include <display_backend.h>
#include <panel_orientation.h>

#include "app_state.h"


// QMI8658 state. Automatic correction is intentionally transient: the user's
// mounting rotation remains the only value persisted or reported to the Mac.
// Square panels accept all four gravity cardinals. Rectangular panels accept
// only upright/upside-down of their mount, holding the last stable flip while
// gravity points at either side; mounted in landscape that flip is read across
// the panel's other axis (motionorient::forMounting).
bool motionAvailable = false;
static motionorient::Tracker motionTracker;
static boardmotion::Sample lastMotionSample = {0, 0, 0};
static bool motionSampleValid = false;
static uint32_t lastMotionPollAt = 0;

bool panelLandscape = false;              // current panel MADCTL state
// The user's mounting rotation, clockwise quarter turns 0-3. Supersedes the
// old flip180 bool: rotation 2 IS the old flip, and the BOOT long press still
// steps by 2. Quarter-turn availability remains a panel-backend capability;
// automatic rotation is independently restricted to flips on rectangular
// glass.
uint8_t panelRotation = 0;
// Optical installations can reverse handedness without rotating the panel.
bool panelMirrorX = false;
// User-selectable and persisted. The correction itself remains transient.
bool automaticRotationEnabled = true;
// Gravity-derived correction, RAM-only. `appliedPanelRotation` records the
// effective value actually in MADCTL, so touch never gets ahead of a pending
// DMA-gated orientation change.
uint8_t automaticRotation = 0;
uint8_t appliedPanelRotation = 0;

bool panelIsRectangular() {
  return bcfg->panel->width != bcfg->panel->height;
}

// The mounting parity the flip-only tracker last started in; -1 before it has
// run. See serviceAutoRotation.
static int8_t autoTrackedParity = -1;

uint8_t desiredPanelRotation() {
  // A flip learned in the other mounting parity is void from the moment the
  // mount changes, not only once the tracker next polls, or the first repaint
  // after a 0 -> 1 change would flash 180 degrees wrong.
  if (panelIsRectangular() &&
      autoTrackedParity != (int8_t)(panelRotation & 1)) {
    return (uint8_t)(panelRotation & 3);
  }
  return motionorient::compose(panelRotation, automaticRotation);
}

uint8_t addressedPanelRotation() {
  return panelorient::addressedRotation(appliedPanelRotation,
                                        panelIsRectangular());
}

bool localFrameLandscape() {
  return panelIsRectangular() && (panelRotation & 1) != 0;
}

void setAutomaticRotationEnabled(bool enabled) {
  automaticRotationEnabled = enabled;
  automaticRotation = 0;
  motionTracker.reset(millis());
  madctlDirty = true;
}

bool madctlDirty = false;                 // panel config needs reapplying
// Apply orientation + the user's mounting rotation, then record what the panel
// now holds. The MADCTL/gap arithmetic itself is in
// boardpanel::applyOrientation, shared with display_test; it is identical on
// both boards (verified against Waveshare's own example for the JD9853, not
// assumed from the ST7789).
void applyPanelConfig(bool landscape) {
  appliedPanelRotation = desiredPanelRotation();
  boarddisplay::applyOrientation(panel, *bcfg, landscape,
                                 appliedPanelRotation, panelMirrorX);
  panelLandscape = landscape;
  madctlDirty = false;
}
// Poll gravity at 10Hz and commit a new cardinal correction only after the
// pure classifier has held it for 500ms. A live press resets the candidate so
// one gesture cannot begin under one coordinate transform and end under another.
void serviceAutoRotation() {
  if (!motionAvailable || !automaticRotationEnabled) return;
  const uint32_t now = millis();

  const motionorient::AutomaticMode mode =
      motionorient::automaticModeForPanel(bcfg->panel->width,
                                          bcfg->panel->height);
  // A flip learned in one mounting parity means nothing in the other: the
  // classifier's axes turn with the mount (motionorient::forMounting), so
  // start that half over from upright rather than carry a stale 180. Ahead
  // of the poll rate limit so the reset is never late.
  const int8_t parity = (int8_t)(panelRotation & 1);
  if (mode == motionorient::AutomaticMode::FlipOnly &&
      parity != autoTrackedParity) {
    autoTrackedParity = parity;
    motionTracker.reset(now);
    // No MADCTL change: desiredPanelRotation already ignored the old flip.
    automaticRotation = 0;
  }

  if ((uint32_t)(now - lastMotionPollAt) < 100) return;
  lastMotionPollAt = now;

  boardmotion::Sample sample;
  if (!boardmotion::read(sample)) return;
  lastMotionSample = sample;
  motionSampleValid = true;

  const int16_t raw[3] = {sample.x, sample.y, sample.z};
  const motionorient::Calibration calibration = motionorient::forMounting(
      {bcfg->motionXAxis, bcfg->motionXSign,
       bcfg->motionYAxis, bcfg->motionYSign},
      panelRotation, mode);
  if (!motionTracker.update(raw, calibration, mode, now,
                            !boardtouch::isPressed())) {
    return;
  }

  automaticRotation = motionTracker.rotation();
  madctlDirty = true;
  Serial.printf("motion: auto=%u manual=%u target=%u applied=%u\n",
                automaticRotation, panelRotation, desiredPanelRotation(),
                appliedPanelRotation);
}
// The motion half of loop()'s 5-second serial report: raw sample, candidate,
// and the rotation actually applied.
void reportMotionDiagnostics() {
    if (motionAvailable && motionSampleValid) {
      Serial.printf(
          "motion: raw=%d,%d,%d candidate=%d auto=%u effective=%u mode=%s\n",
          (int)lastMotionSample.x, (int)lastMotionSample.y,
          (int)lastMotionSample.z,
          motionTracker.candidate() == motionorient::INVALID_ROTATION
              ? -1 : (int)motionTracker.candidate(),
          automaticRotation, appliedPanelRotation,
          automaticRotationEnabled
              ? (bcfg->panel->width == bcfg->panel->height
                     ? "four-way"
                     : "flip-only")
              : "off");
    }
}
