// Minimal QMI8658/QMI8658A accelerometer reader for automatic orientation.
#pragma once

#include <Arduino.h>
#include <Wire.h>

#include <board_config.h>

namespace boardmotion {

static const uint8_t I2C_ADDR = 0x6B;
static const uint8_t REG_WHO_AM_I = 0x00;
static const uint8_t REG_CTRL1 = 0x02;
static const uint8_t REG_CTRL2 = 0x03;
static const uint8_t REG_CTRL7 = 0x08;
static const uint8_t REG_ACCEL_X_LOW = 0x35;
static const uint8_t REG_RESET = 0x60;
static const uint8_t WHO_AM_I = 0x05;
static const uint32_t I2C_HZ = 400000;

struct Sample {
  int16_t x;
  int16_t y;
  int16_t z;
};

static bool enabled = false;

inline bool writeRegister(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(I2C_ADDR);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

inline bool readRegisters(uint8_t reg, uint8_t *out, size_t len) {
  Wire.beginTransmission(I2C_ADDR);
  Wire.write(reg);
  if (Wire.endTransmission() != 0) return false;
  Wire.requestFrom(I2C_ADDR, len);
  if (Wire.available() != (int)len) return false;
  Wire.readBytes(out, len);
  return true;
}

inline bool init(const board::Config &cfg, bool verbose = true) {
  enabled = false;
  if (!cfg.hasMotion()) {
    if (verbose) Serial.printf("motion: not present on %s\n", cfg.name);
    return false;
  }
  if (cfg.motion != board::MotionController::Qmi8658) {
    if (verbose) Serial.printf("motion: unsupported controller on %s\n", cfg.name);
    return false;
  }
  if (!Wire.begin(cfg.pinTouchSda, cfg.pinTouchScl, I2C_HZ)) {
    if (verbose) Serial.println("motion: ERROR I2C bus would not start");
    return false;
  }

  // QMI8658 soft reset used by both Waveshare board support packages. Wait
  // conservatively, then configure normal mode with self-test bits clear:
  // CTRL1 address auto-increment, CTRL2 +/-4g at 1kHz, CTRL7 accelerometer only.
  if (!writeRegister(REG_RESET, 0xB0)) {
    if (verbose) Serial.println("motion: ERROR reset write failed");
    return false;
  }
  delay(20);

  uint8_t identity = 0;
  if (!readRegisters(REG_WHO_AM_I, &identity, 1) || identity != WHO_AM_I) {
    if (verbose) {
      Serial.printf("motion: ERROR QMI8658 identity 0x%02X (expected 0x%02X)\n",
                    identity, WHO_AM_I);
    }
    return false;
  }
  bool ok = writeRegister(REG_CTRL1, 0x60);
  ok = writeRegister(REG_CTRL2, 0x13) && ok;
  ok = writeRegister(REG_CTRL7, 0x01) && ok;
  if (!ok) {
    if (verbose) Serial.println("motion: ERROR configuration write failed");
    return false;
  }
  delay(10);
  enabled = true;
  if (verbose) {
    Serial.printf("motion: QMI8658 ready at 0x%02X (sda=%d scl=%d, +/-4g)\n",
                  I2C_ADDR, cfg.pinTouchSda, cfg.pinTouchScl);
  }
  return true;
}

inline bool available() { return enabled; }

inline bool read(Sample &out) {
  if (!enabled) return false;
  uint8_t data[6] = {0};
  if (!readRegisters(REG_ACCEL_X_LOW, data, sizeof(data))) return false;
  out.x = (int16_t)((uint16_t)data[0] | ((uint16_t)data[1] << 8));
  out.y = (int16_t)((uint16_t)data[2] | ((uint16_t)data[3] << 8));
  out.z = (int16_t)((uint16_t)data[4] | ((uint16_t)data[5] << 8));
  return true;
}

}  // namespace boardmotion
