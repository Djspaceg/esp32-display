// Hardware-free cardinal orientation classifier for QMI8658 acceleration.
#pragma once

#include <stdint.h>

namespace motionorient {

static const uint8_t INVALID_ROTATION = 0xFF;
static const int32_t ENTER_MIN = 5325;       // 0.65g at +/-4g (8192 LSB/g)
static const int32_t HOLD_MIN = 4505;        // 0.55g: hysteresis for the stable side
static const int32_t ENTER_DOMINANCE = 1229; // 0.15g away from a diagonal
static const int32_t HOLD_DOMINANCE = 819;   // 0.10g while retaining a side
static const uint32_t DWELL_MS = 500;

struct Calibration {
  uint8_t panelXAxis;
  int8_t panelXSign;
  uint8_t panelYAxis;
  int8_t panelYSign;
};

inline int32_t magnitude(int32_t value) { return value < 0 ? -value : value; }

inline int32_t calibratedAxis(const int16_t raw[3], uint8_t axis, int8_t sign) {
  return (int32_t)raw[axis] * sign;
}

// Rotation is the correction applied to the content. With panel X pointing
// right and panel Y down, gravity +Y is upright. A clockwise physical turn
// produces +X gravity and therefore needs correction 3 (counter-clockwise).
inline uint8_t cardinalFor(int32_t panelX, int32_t panelY) {
  if (magnitude(panelX) > magnitude(panelY)) return panelX > 0 ? 3 : 1;
  return panelY > 0 ? 0 : 2;
}

inline int32_t stableProjection(uint8_t rotation, int32_t panelX,
                                int32_t panelY) {
  switch (rotation & 3) {
    case 0: return panelY;
    case 1: return -panelX;
    case 2: return -panelY;
    default: return panelX;
  }
}

inline uint8_t classify(const int16_t raw[3], const Calibration &calibration,
                        uint8_t stableRotation) {
  const int32_t x = calibratedAxis(
      raw, calibration.panelXAxis, calibration.panelXSign);
  const int32_t y = calibratedAxis(
      raw, calibration.panelYAxis, calibration.panelYSign);
  const int32_t ax = magnitude(x);
  const int32_t ay = magnitude(y);
  const int32_t dominance = magnitude(ax - ay);

  // Hold the current side through a wider threshold band than a new side is
  // allowed to enter. This is the hysteresis that prevents boundary chatter;
  // dwell below handles sustained motion rather than replacing it.
  if (stableProjection(stableRotation, x, y) >= HOLD_MIN &&
      dominance >= HOLD_DOMINANCE) {
    return stableRotation & 3;
  }
  if ((ax < ENTER_MIN && ay < ENTER_MIN) || dominance < ENTER_DOMINANCE) {
    return INVALID_ROTATION;  // face-up/down, moving, or too close to diagonal
  }
  return cardinalFor(x, y);
}

inline uint8_t compose(uint8_t manualRotation, uint8_t automaticRotation) {
  return (uint8_t)((manualRotation + automaticRotation) & 3);
}

class Tracker {
 public:
  uint8_t rotation() const { return stable_; }
  uint8_t candidate() const { return candidate_; }

  bool update(const int16_t raw[3], const Calibration &calibration,
              uint32_t nowMs, bool allowCommit = true) {
    if (!allowCommit) {
      candidate_ = INVALID_ROTATION;
      candidateSince_ = nowMs;
      return false;
    }

    const uint8_t next = classify(raw, calibration, stable_);
    if (next == INVALID_ROTATION || next == stable_) {
      candidate_ = INVALID_ROTATION;
      candidateSince_ = nowMs;
      return false;
    }
    if (next != candidate_) {
      candidate_ = next;
      candidateSince_ = nowMs;
      return false;
    }
    if ((uint32_t)(nowMs - candidateSince_) < DWELL_MS) return false;

    stable_ = candidate_;
    candidate_ = INVALID_ROTATION;
    candidateSince_ = nowMs;
    return true;
  }

 private:
  uint8_t stable_ = 0;
  uint8_t candidate_ = INVALID_ROTATION;
  uint32_t candidateSince_ = 0;
};

}  // namespace motionorient
